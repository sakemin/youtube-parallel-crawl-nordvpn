#!/usr/bin/env bash
#
# setup.sh — build the server pool and (for WireGuard) generate per-server
# VPN configs. Run this ONCE after `bin/install.sh` and `vopono sync nordvpn`,
# and re-run it whenever you change COUNTRIES or VPN_PROTOCOL.
#
# What it does:
#   1. Builds $POOL_FILE: a pool of DISTINCT per-country NordVPN server tokens
#      (full config names like `south_korea-kr112`) covering every country in
#      $COUNTRIES. The supervisor pins worker i to COUNTRIES[i] and rotates it
#      only within that country's servers, so the W live exit IPs always sit in
#      W different countries (= different /16s) — that is what defeats YouTube's
#      subnet-level bot detection.
#   2. If VPN_PROTOCOL=wireguard: relaxes the AppArmor `wg` profile so vopono's
#      /tmp configs are readable, then generates one WireGuard config per pool
#      server into $WG_DIR from this host's NordLynx private key + NordVPN's
#      PUBLIC server API (no token, no extra credentials). WireGuard has no
#      per-connection auth, which is why it survives parallel reconnect churn
#      where OpenVPN auth-throttles and collapses.
#
# Idempotent: safe to re-run. Existing configs are overwritten in place; the
# AppArmor allowance is added only once.
#
# Needs root for the AppArmor edit and writing under /etc/wireguard. The script
# self-elevates via sudo while preserving the variables it needs (it forwards
# HOME so it can still find ~/.config/vopono after the sudo hop).
#
# Usage:
#   bin/setup.sh                 # uses config.env (or config.example.env)
#   COUNTRIES="japan taiwan" bin/setup.sh
#
set -euo pipefail

# --- locate the repo root from this script's own location, then load config ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# Snapshot any of our knobs already set in the environment so they win over the
# config file (the config uses plain VAR="..." assignments, which `source` would
# otherwise clobber). This honors the contract: `COUNTRIES=... ./setup.sh`.
_pre_env="$(mktemp)"
for _v in IDS_FILE OUTPUT_DIR POOL_FILE WG_DIR VENV VPN_PROVIDER VPN_PROTOCOL \
          COUNTRIES WORKERS MIN_SUBSET; do
  if [[ -n "${!_v+x}" ]]; then
    printf '%s=%q\n' "$_v" "${!_v}" >>"$_pre_env"
  fi
done

# shellcheck source=/dev/null
source "$REPO/config.env" 2>/dev/null || source "$REPO/config.example.env"

# Re-apply the command-line overrides captured above, then drop the temp file.
# shellcheck source=/dev/null
source "$_pre_env"
rm -f "$_pre_env"

# --- resolve config-relative paths against the repo root ----------------------
# Bare/relative paths in the config are interpreted relative to the repo so the
# script works from a fresh clone regardless of the caller's cwd.
abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s\n' "$REPO/$1" ;;
  esac
}
POOL_FILE="$(abspath "${POOL_FILE:-./servers.txt}")"
WG_DIR="$(abspath "${WG_DIR:-/etc/wireguard/nordwg}")"   # normally absolute (/etc/...); abspath a relative override
VPN_PROTOCOL="${VPN_PROTOCOL:-wireguard}"
VPN_PROVIDER="${VPN_PROVIDER:-nordvpn}"
COUNTRIES="${COUNTRIES:-south_korea}"
WORKERS="${WORKERS:-8}"
MIN_SUBSET="${MIN_SUBSET:-3}"

# --- self-elevate (only WireGuard needs root; do it before any root work) -----
# Forward HOME so post-sudo we still resolve the user's ~/.config/vopono, and
# carry the few overridable knobs across the sudo hop.
if [[ "${VPN_PROTOCOL}" == "wireguard" && "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo ">> WireGuard setup needs root (AppArmor + /etc/wireguard); re-running with sudo..."
  exec sudo --preserve-env=HOME,POOL_FILE,WG_DIR,VPN_PROTOCOL,VPN_PROVIDER,COUNTRIES,WORKERS,MIN_SUBSET \
       HOME="$HOME" bash "$0" "$@"
fi

# Where to look for vopono's synced configs. After self-elevation HOME is the
# invoking user's home (we forwarded it), so this still points at the right tree.
VOPONO_HOME="${HOME:-$(eval echo "~${SUDO_USER:-root}")}"

# ----------------------------------------------------------------------------
# Step 1: build the distinct per-country server pool ($POOL_FILE)
# ----------------------------------------------------------------------------
# A token is the FULL config name vopono's prefix-matcher expects, e.g.
# `south_korea-kr112` (a bare `kr112` would match nothing). Distinct tokens =>
# distinct namespaces => distinct exit IPs.
build_pool() {
  # Build a regex alternation of the requested countries: ^(c1|c2|...)-<id>
  local alt pat
  # shellcheck disable=SC2206  # word-splitting COUNTRIES into an array is intended
  local countries=( $COUNTRIES )
  [[ "${#countries[@]}" -gt 0 ]] || { echo "ERROR: COUNTRIES is empty." >&2; exit 1; }
  alt="$(IFS='|'; echo "${countries[*]}")"
  pat="^(${alt})-[a-z0-9]+"

  local tmp; tmp="$(mktemp)"
  # local trap so it doesn't clobber any outer trap
  trap 'rm -f "$tmp"' RETURN

  # Source 1: vopono's own server listing (tab-separated; col 3 = config file).
  if command -v vopono >/dev/null 2>&1; then
    vopono servers "$VPN_PROVIDER" 2>/dev/null \
      | awk -F'\t' 'NR>1{print $3}' \
      | sed -E 's/\.(ovpn|conf)$//' \
      | grep -iE "$pat" >>"$tmp" || true
  fi
  # Source 2: the synced config filenames on disk (covers older vopono builds
  # whose `servers` output format differs). Look in every plausible subdir.
  local d
  for d in "$VOPONO_HOME/.config/vopono/$VPN_PROVIDER/openvpn" \
           "$VOPONO_HOME/.config/vopono/$VPN_PROVIDER/wireguard" \
           "$VOPONO_HOME/.config/vopono/$VPN_PROVIDER"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 1 -type f \( -name '*.ovpn' -o -name '*.conf' \) -printf '%f\n' 2>/dev/null \
      | sed -E 's/\.(ovpn|conf)$//' | grep -iE "$pat" >>"$tmp" || true
  done

  sort -u "$tmp" >"$POOL_FILE.new"
  local n; n="$(wc -l <"$POOL_FILE.new" | tr -d ' ')"
  if [[ "$n" -eq 0 ]]; then
    rm -f "$POOL_FILE.new"
    cat >&2 <<EOF
ERROR: found 0 server tokens matching /$pat/.
  - Did 'vopono sync $VPN_PROVIDER' finish? Check:
        vopono servers $VPN_PROVIDER | grep -iE '${alt}'
  - Or hand-write $POOL_FILE, one FULL token per line (e.g. south_korea-kr112),
    at least \$WORKERS*\$MIN_SUBSET tokens spread across \$COUNTRIES.
EOF
    exit 1
  fi
  mv "$POOL_FILE.new" "$POOL_FILE"

  echo ">> wrote $n distinct server tokens -> $POOL_FILE"

  # --- sanity: every worker's country must have >= MIN_SUBSET servers ---------
  # Worker i is pinned to COUNTRIES[i] and must cycle >= MIN_SUBSET distinct
  # servers before reusing an IP. Warn (don't fail) if any worker's country is
  # too thin, and confirm there are at least WORKERS countries to assign.
  local need="$MIN_SUBSET" c cnt covered=0 thin=0 i
  for (( i=0; i<WORKERS; i++ )); do
    # the country this worker would be pinned to (wraps if COUNTRIES < WORKERS)
    c="${countries[$(( i % ${#countries[@]} ))]}"
    cnt="$(grep -cE "^${c}-[a-z0-9]+$" "$POOL_FILE" || true)"
    if [[ "$cnt" -ge "$need" ]]; then
      covered=$(( covered + 1 ))
    else
      thin=$(( thin + 1 ))
      echo "   WARNING: worker $i -> '$c' has only $cnt server(s); want >= $need (MIN_SUBSET)." >&2
    fi
  done
  if [[ "${#countries[@]}" -lt "$WORKERS" ]]; then
    echo "   WARNING: only ${#countries[@]} distinct countries for $WORKERS workers;" >&2
    echo "            workers will share countries (same /16) — add more to COUNTRIES." >&2
  fi
  echo "   ($covered/$WORKERS workers have >= $need servers in their country; $thin thin)"
  echo "   per country:"
  for c in "${countries[@]}"; do
    cnt="$(grep -cE "^${c}-[a-z0-9]+$" "$POOL_FILE" || true)"
    printf '     %-16s %s\n' "$c" "$cnt"
  done
}

# ----------------------------------------------------------------------------
# Step 2 (WireGuard only): AppArmor allowance + per-server config generation
# ----------------------------------------------------------------------------
setup_apparmor() {
  # The distro `wg` AppArmor profile is locked to /etc/wireguard, but vopono
  # copies the chosen config into /tmp before invoking wg — which AppArmor then
  # blocks (symptom: `fopen: Permission denied` + silent NO_HANDSHAKE). Allow
  # reading vopono's /tmp configs. Reversible and added only once.
  if [[ ! -d /etc/apparmor.d ]]; then
    echo ">> AppArmor not present on this host; skipping the wg-profile relaxation."
    return 0
  fi
  echo ">> AppArmor: allowing wg to read vopono's temp configs in /tmp (idempotent)..."
  mkdir -p /etc/apparmor.d/local
  if ! grep -qF '/tmp/vopono*.conf r,' /etc/apparmor.d/local/wg 2>/dev/null; then
    printf '/tmp/vopono*.conf r,\n/tmp/vopono*/** r,\n' >> /etc/apparmor.d/local/wg
    echo "   added /tmp/vopono*.conf allowance to /etc/apparmor.d/local/wg"
  else
    echo "   already present in /etc/apparmor.d/local/wg"
  fi
  # Reload the main wg profile so the local include takes effect. Tolerate the
  # absence of either the parser or the profile on minimal hosts.
  if command -v apparmor_parser >/dev/null 2>&1 && [[ -f /etc/apparmor.d/wg ]]; then
    apparmor_parser -r /etc/apparmor.d/wg 2>/dev/null || true
  fi
}

generate_wireguard_configs() {
  # NordLynx private key already on the host (registered when the NordVPN
  # app/CLI first connected with WireGuard). No token / extra creds needed.
  local priv
  priv="$(wg show nordlynx private-key 2>/dev/null || true)"
  if [[ -z "$priv" ]]; then
    cat >&2 <<'EOF'
ERROR: could not read the NordLynx WireGuard private key.
  The key is created when the NordVPN client first connects over WireGuard.
  Fix: connect once with the NordVPN CLI (`nordvpn set technology nordlynx`
       then `nordvpn connect`), confirm `sudo wg show nordlynx private-key`
       prints a key, then `nordvpn disconnect` and re-run this script.
EOF
    exit 1
  fi
  [[ -f "$POOL_FILE" ]] || { echo "ERROR: server pool $POOL_FILE missing (step 1 should have built it)." >&2; exit 1; }

  echo ">> fetching the NordVPN server list (WireGuard public keys + endpoints)..."
  local tmpj; tmpj="$(mktemp)"
  trap 'rm -f "$tmpj"' RETURN
  curl -fsS --max-time 90 'https://api.nordvpn.com/v1/servers?limit=8000' >"$tmpj" || true
  [[ -s "$tmpj" ]] || { echo "ERROR: empty/failed response from the NordVPN server API." >&2; exit 1; }

  mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"
  echo ">> generating per-server WireGuard configs in $WG_DIR ..."
  # Map each pool token -> short hostname id (kr112) -> (station IP, WG pubkey)
  # from the public API, and emit a vopono-ready custom WireGuard config.
  WGPRIV="$priv" python3 - "$POOL_FILE" "$WG_DIR" "$tmpj" <<'PY'
import sys, json, os

pool, out, jf = sys.argv[1], sys.argv[2], sys.argv[3]
priv = os.environ["WGPRIV"]

try:
    servers = json.load(open(jf))
except Exception as e:                       # noqa: BLE001 - surface any parse error
    sys.stderr.write("ERROR: could not parse NordVPN API JSON: %s\n" % e)
    sys.exit(1)

# short server id (e.g. "kr112") -> (station_ip, wireguard_public_key)
by_id = {}
for s in servers:
    sid = (s.get("hostname") or "").split(".")[0]
    pub = None
    for tech in s.get("technologies", []):
        if tech.get("identifier") == "wireguard_udp":
            for md in (tech.get("metadata") or []):
                if md.get("name") == "public_key":
                    pub = md.get("value")
    if sid and pub:
        by_id[sid] = (s.get("station"), pub)

made = miss = 0
missing = []
with open(pool) as fh:
    for line in fh:
        tok = line.strip()
        if not tok or tok.startswith("#"):
            continue
        sid = tok.split("-")[-1]              # south_korea-kr112 -> kr112
        rec = by_id.get(sid)
        if not rec:
            miss += 1
            missing.append(tok)
            continue
        station, pub = rec
        cfg = (
            "[Interface]\n"
            f"PrivateKey={priv}\n"
            "Address=10.5.0.2/32\n"
            "DNS=103.86.96.100\n"
            "\n"
            "[Peer]\n"
            f"PublicKey={pub}\n"
            "AllowedIPs=0.0.0.0/0\n"
            f"Endpoint={station}:51820\n"
            "PersistentKeepalive=25\n"
        )
        path = os.path.join(out, tok + ".conf")
        with open(path, "w") as cf:
            cf.write(cfg)
        os.chmod(path, 0o600)
        made += 1

print(f"   generated {made} WireGuard configs ({miss} pool tokens had no WG data)")
if missing:
    shown = ", ".join(missing[:8]) + (" ..." if len(missing) > 8 else "")
    print(f"   no WG metadata for: {shown}")
if made == 0:
    sys.stderr.write("ERROR: produced 0 WireGuard configs — pool tokens did not "
                     "match any servers in the API list.\n")
    sys.exit(1)
PY

  local total
  total="$(find "$WG_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')"
  echo ">> done: $total WireGuard config(s) in $WG_DIR"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
echo "== setup: provider=$VPN_PROVIDER protocol=$VPN_PROTOCOL =="
echo "   countries: $COUNTRIES"
echo "   pool file: $POOL_FILE"

build_pool

case "$VPN_PROTOCOL" in
  wireguard)
    echo ">> WireGuard selected: dir=$WG_DIR"
    setup_apparmor
    generate_wireguard_configs
    cat <<EOF

>> setup complete (WireGuard).
   next: free the host from the VPN, then start the crawl:
       nordvpn disconnect 2>/dev/null; nordvpn set killswitch off 2>/dev/null
       ./crawl.sh
EOF
    ;;
  openvpn)
    echo ">> OpenVPN selected: no WireGuard config generation needed."
    echo "   vopono uses the synced OpenVPN configs directly via --server <token>."
    cat <<EOF

>> setup complete (OpenVPN).
   note: OpenVPN re-authenticates per connection and NordVPN throttles auth, so
   parallel reconnect churn can collapse the fleet. Prefer VPN_PROTOCOL=wireguard.
   next:
       nordvpn disconnect 2>/dev/null; nordvpn set killswitch off 2>/dev/null
       ./crawl.sh
EOF
    ;;
  *)
    echo "ERROR: unknown VPN_PROTOCOL='$VPN_PROTOCOL' (expected wireguard|openvpn)." >&2
    exit 1
    ;;
esac
