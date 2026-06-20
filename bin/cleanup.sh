#!/usr/bin/env bash
#
# cleanup.sh — return the host to a pristine state after a crash / hard kill.
#
# vopono builds one network namespace + veth pair per worker and edits a single
# shared NetworkManager file (conf.d/unmanaged.conf). A hard kill leaves these
# behind: orphan vopono netns/veths and a stale unmanaged.conf whose missing
# backup is exactly what makes the NEXT concurrent vopono start panic
# ("Failed to restore backup of NetworkManager unmanaged.conf: NotFound").
# This script kills the supervisor + vopono/OpenVPN cleanly, deletes the orphan
# vo_nd_* (provider/OpenVPN) AND vo_c_* (WireGuard --custom) interfaces/namespaces,
# and resets unmanaged.conf. (Cleaning only vo_nd_* lets stale WireGuard vo_c_*
# veths pile up until 'RTNETLINK: File exists' collisions abort workers.)
#
# Safe for the host: it only touches vopono (vo_*) interfaces and RELOADS (never
# restarts) NetworkManager, so the host's WiFi / SSH / agent session stays up.
# The host is never on the VPN, so nothing here changes the host's route.
#
# Usage:   sudo ./bin/cleanup.sh
#
set -uo pipefail

# --- resolve repo root from this script's location, then source config -------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/config.env" 2>/dev/null || source "$REPO/config.example.env"

# netns / link / netns-list edits all need root; re-exec under sudo (one prompt).
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo ">> netns teardown needs root; re-running under sudo..."
  exec sudo "$0" "$@"
fi

VOPONO="${VOPONO:-vopono}"

echo ">> stopping any running supervisor (its own teardown runs first)..."
# crawl.sh is the supervisor; INT lets its trap tear namespaces down gracefully.
pkill -INT -f 'crawl\.sh' 2>/dev/null || true
sleep 5

# A CLEAN shutdown matters for OpenVPN: SIGTERM makes the client send a disconnect
# so NordVPN frees the session slot immediately. SIGKILL leaves the session
# lingering server-side for minutes, eating into the 10-connection cap so later
# connects fail as "authentication failed". WireGuard has no such session, but
# SIGTERM-first is harmless there, so we always try the graceful path first.
echo ">> stopping vopono workers + any OpenVPN (graceful SIGTERM first)..."
pkill -TERM -f 'vopono exec' 2>/dev/null || true
pkill -TERM -x openvpn       2>/dev/null || true
sleep 4
pkill -9 -f 'vopono exec'    2>/dev/null || true   # stragglers only
pkill -9 -x openvpn          2>/dev/null || true
sleep 1

# vopono's own teardown is the preferred path when it still works; best-effort.
"$VOPONO" list namespaces >/dev/null 2>&1 || true

echo ">> deleting orphaned vopono network namespaces (vo_nd_* + vo_c_*)..."
ip netns list 2>/dev/null | awk '/vo_(nd|c)_/{print $1}' | while read -r n; do
  ip netns delete "$n" 2>/dev/null && echo "   netns $n"
done

echo ">> deleting orphaned vopono veth interfaces (vo_nd_* + vo_c_*)..."
# 'ip -br link' prints "name@peer"; strip the @peer and de-dup before deleting.
# vo_nd_* = provider/OpenVPN mode; vo_c_* = WireGuard --custom mode. Missing vo_c_*
# lets stale WireGuard veths accumulate across hard-kills until 'RTNETLINK: File
# exists' veth collisions abort workers.
ip -br link 2>/dev/null | awk '/vo_(nd|c)_/{print $1}' | sed 's/@.*//' | sort -u | while read -r l; do
  ip link del "$l" 2>/dev/null && echo "   link $l"
done

echo ">> resetting vopono's NetworkManager unmanaged.conf..."
rm -f /etc/NetworkManager/conf.d/unmanaged.conf
# reload (NOT restart) re-reads conf.d without dropping the active WiFi/SSH link.
systemctl reload NetworkManager 2>/dev/null \
  || nmcli connection reload 2>/dev/null \
  || true

# clear the OpenVPN auth circuit-breaker flag + setup lock so the next run starts
# clean (names must match crawl.sh's AUTH_PAUSE_FILE / SETUP_LOCK defaults).
rm -f "${AUTH_PAUSE_FILE:-/tmp/ypcn_auth_pause}" "${SETUP_LOCK:-/tmp/ypcn_setup.lock}" 2>/dev/null || true

left="$(ip -br link 2>/dev/null | grep -cE 'vo_(nd|c)_')"
echo ">> remaining vopono (vo_nd_*/vo_c_*) interfaces: $left  (want 0)"
if [[ "$left" == "0" ]]; then
  echo ">> CLEAN. Restart with:  sudo ./crawl.sh"
else
  echo ">> WARN: some vopono interfaces remain; re-run, or delete by hand:" >&2
  echo "          ip -br link | grep -E 'vo_(nd|c)_'   then   sudo ip link del <name>" >&2
  exit 1
fi
