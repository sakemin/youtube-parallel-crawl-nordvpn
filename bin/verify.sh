#!/usr/bin/env bash
#
# verify.sh — acceptance gate for the vopono isolation, run before the long crawl.
#
#   A. the HOST egress IP is the box's REAL ISP IP, not a VPN IP
#      (proves the host default route was never touched — SSH/agent stay clean).
#   B. each worker's FIRST server yields a DISTINCT exit IP, all != host
#      (proves per-worker isolation; duplicates => two workers share an IP and
#       the same /24 => YouTube subnet bot-detection).
#   C. the tunnel actually comes up (an IP is returned from inside the namespace).
#
# Supports BOTH protocols, matching crawl.sh exactly:
#   wireguard: vopono exec --custom $WG_DIR/<server>.conf --protocol wireguard ...
#   openvpn:   vopono exec --provider <prov> --protocol openvpn --server <server> ...
#
# We test ONE server per DISTINCT country (mirroring crawl.sh's one-country-per-
# worker pinning), up to WORKERS servers, so we validate the real cross-worker
# ranges. netns needs root -> re-exec under sudo forwarding HOME so vopono finds
# the synced config.
#
# Usage:   ./bin/verify.sh [N]      # test first N countries (default: WORKERS)
#
set -uo pipefail

# --- resolve repo root from this script's location, then source config -------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/config.env" 2>/dev/null || source "$REPO/config.example.env"

case "$POOL_FILE" in /*) POOL="$POOL_FILE" ;; *) POOL="$REPO/$POOL_FILE" ;; esac

VOPONO="${VOPONO:-vopono}"
PROV="${VPN_PROVIDER:-nordvpn}"
PROTO="${VPN_PROTOCOL:-wireguard}"
VOPONO_EXTRA="${VOPONO_EXTRA:-}"
N="${1:-${WORKERS:-8}}"
IPSVC="${IPSVC:-https://ifconfig.me}"

# netns needs root; re-exec under sudo, forwarding HOME (+ XDG) so vopono finds
# ~/.config/vopono, and forwarding the resolved values so the contract holds.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo ">> netns needs root; re-running under sudo (forwarding HOME for vopono config)..."
  exec sudo HOME="$HOME" XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}" \
    VOPONO="$VOPONO" VPN_PROVIDER="$PROV" VPN_PROTOCOL="$PROTO" \
    VOPONO_EXTRA="$VOPONO_EXTRA" POOL_FILE="$POOL" WG_DIR="$WG_DIR" IPSVC="$IPSVC" \
    "$0" "$@"
fi

command -v "$VOPONO" >/dev/null 2>&1 || { echo "ERROR: vopono not installed (run ./bin/install.sh)." >&2; exit 1; }
[[ -f "$POOL" ]] || { echo "ERROR: missing server pool $POOL (run ./bin/setup.sh to build it)." >&2; exit 1; }

# Server pool: one server token per line (e.g. south_korea-kr112); drop blanks/comments/dupes.
mapfile -t SRV < <(grep -vE '^\s*(#|$)' "$POOL" | awk '!seen[$0]++')
(( ${#SRV[@]} > 0 )) || { echo "ERROR: no servers in $POOL." >&2; exit 1; }

# Keep the FIRST server of each distinct country (country = token minus the
# trailing -<id>, e.g. south_korea-kr112 -> south_korea). This mirrors the
# supervisor assigning one distinct country per worker.
declare -A cseen; FIRST=()
for s in "${SRV[@]}"; do
  c="${s%-*}"                 # country = token up to the final dash (matches crawl.sh)
  [[ -n "${cseen[$c]:-}" ]] || { cseen[$c]=1; FIRST+=("$s"); }
done
(( ${#FIRST[@]} >= N )) || N="${#FIRST[@]}"

echo "== A. host egress (must be the box's real ISP IP, NOT a VPN IP) =="
HOST_IP="$(curl -fsS --max-time 12 "$IPSVC" 2>/dev/null || echo '???')"
echo "   host IP: $HOST_IP"
if command -v nordvpn >/dev/null 2>&1 && nordvpn status 2>/dev/null | grep -q "Status: Connected"; then
  echo "   !! host nordvpn is Connected -- run 'nordvpn disconnect' so the host stays off-VPN."
fi
echo
echo "== B/C. per-namespace exit IPs (must be distinct + != host), protocol=$PROTO =="
declare -A seen_ip
ok=1; ndist=0
for (( k=0; k<N; k++ )); do
  s="${FIRST[k]}"
  if [[ "$PROTO" == "wireguard" ]]; then
    conf="$WG_DIR/$s.conf"
    if [[ ! -f "$conf" ]]; then
      echo "   [$s] MISSING WireGuard config $conf (run ./bin/setup.sh)"; ok=0; continue
    fi
    # shellcheck disable=SC2086
    ip="$("$VOPONO" exec --custom "$conf" --protocol wireguard $VOPONO_EXTRA \
          "curl -fsS --max-time 25 $IPSVC" 2>/dev/null)"
  else
    # shellcheck disable=SC2086
    ip="$("$VOPONO" exec --provider "$PROV" --protocol "$PROTO" --server "$s" $VOPONO_EXTRA \
          "curl -fsS --max-time 25 $IPSVC" 2>/dev/null)"
  fi
  if [[ -z "$ip" ]]; then
    echo "   [$s] FAILED to get an IP (tunnel down? killswitch blocking? AppArmor on /tmp/vopono*.conf? bad key?)"; ok=0; continue
  fi
  flag=""
  [[ "$ip" == "$HOST_IP" ]] && { flag=" !! SAME AS HOST (leak!)"; ok=0; }
  if [[ -n "${seen_ip[$ip]:-}" ]]; then
    flag="$flag !! DUPLICATE of ${seen_ip[$ip]}"; ok=0
  else
    seen_ip[$ip]="$s"; ndist=$(( ndist + 1 ))
  fi
  echo "   [$s] -> $ip$flag"
done
echo
echo "== result =="
echo "   tested $N server(s) -> $ndist distinct exit IP(s); host IP=$HOST_IP"
if (( ok == 1 && ndist == N )); then
  echo "   PASS: host clean, every worker IP distinct and != host."
  exit 0
fi
echo "   FAIL: see flags above -- fix before the long run." >&2
exit 1
