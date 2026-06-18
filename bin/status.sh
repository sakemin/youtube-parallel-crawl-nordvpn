#!/usr/bin/env bash
#
# status.sh — one-shot snapshot of the crawl: running?, active workers, recent
# download rate, totals, and overall progress vs the id list.
#
# "Active workers" = number of live `vopono exec` processes. This is the right
# count for BOTH protocols: OpenVPN shows extra `openvpn` procs and WireGuard
# shows none (the tunnel is a kernel `wg` interface), but each worker is always
# wrapped in exactly one `vopono exec`, so counting those is protocol-agnostic.
#
# Usage:   ./bin/status.sh
#
set -uo pipefail

# --- resolve repo root from this script's location, then source config -------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/config.env" 2>/dev/null || source "$REPO/config.example.env"

# Resolve possibly-relative config paths against the repo root so the script
# works no matter the caller's cwd.
case "$OUTPUT_DIR" in /*) OUT="$OUTPUT_DIR" ;; *) OUT="$REPO/$OUTPUT_DIR" ;; esac
case "$IDS_FILE"   in /*) IDS="$IDS_FILE"   ;; *) IDS="$REPO/$IDS_FILE"   ;; esac

AUDIO="$OUT/audio"
LOGDIR="$OUT/logs/parallel"
WINDOW="${WINDOW:-2}"   # minutes of look-back for the recent-rate estimate
# Clamp to a positive integer: a stray/0/non-numeric WINDOW in the environment
# must never divide-by-zero below.
if ! [[ "$WINDOW" =~ ^[1-9][0-9]*$ ]]; then WINDOW=2; fi

# --- running? + active worker count ------------------------------------------
# crawl.sh is the supervisor; 'vopono exec' is one-per-worker (see header).
run=$(pgrep -fc 'crawl\.sh'    2>/dev/null); run=${run:-0}
wrk=$(pgrep -fc 'vopono exec'  2>/dev/null); wrk=${wrk:-0}
cp=$(pgrep -fc 'crawler\.py'   2>/dev/null); cp=${cp:-0}

state="STOPPED"; (( run > 0 )) && state="RUNNING"
echo "crawl: $state | active workers=$wrk | crawler-procs=$cp"

# --- totals + progress vs the id list ----------------------------------------
# Count finished audio files extension-agnostically: yt-dlp may write .m4a /
# .mp4 / .webm / .opus depending on YTDLP_FORMAT, so we count any audio file
# that has a sibling .meta (the marker the crawler writes on success).
done_n=0
if [[ -d "$AUDIO" ]]; then
  done_n=$(find "$AUDIO" -type f -name '*.meta' 2>/dev/null | wc -l)
fi

total=0
[[ -f "$IDS" ]] && total=$(grep -cvE '^\s*(#|$)' "$IDS" 2>/dev/null || echo 0)

pct="n/a"
if (( total > 0 )); then
  pct=$(awk -v d="$done_n" -v t="$total" 'BEGIN{printf "%.2f%%", 100*d/t}')
fi
echo "progress: $done_n / $total ($pct)"

# --- recent download rate ----------------------------------------------------
# Count .meta markers written within the look-back window -> downloads/min.
recent=0
if [[ -d "$AUDIO" ]]; then
  recent=$(find "$AUDIO" -type f -name '*.meta' \
             -newermt "$WINDOW minutes ago" 2>/dev/null | wc -l)
fi
rate=$(( recent / WINDOW ))
echo "downloads last ${WINDOW} min: $recent  (~${rate}/min)"

# --- error/health tallies from the worker logs -------------------------------
sum() {  # sum <grep-args...> across all worker logs; prints an integer
  local n
  n=$(grep -hcE "$1" "$LOGDIR"/worker*.out 2>/dev/null | paste -sd+ - | bc 2>/dev/null)
  echo "${n:-0}"
}
aborts=$(sum '\] ABORT|STUCK')
# yt-dlp's bot-wall uses a CURLY apostrophe in "you're"; match the stable
# substring "not a bot" instead (never the apostrophe).
bots=$(sum 'not a bot')
authf=$(sum 'authentication failed')
echo "totals: aborts/stuck=$aborts  auth-fails=$authf  bot-detection=$bots"
