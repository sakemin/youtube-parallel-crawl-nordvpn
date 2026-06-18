#!/usr/bin/env bash
#
# watch.sh — collapse watcher. Prints exactly one status line:
#
#   OK ...        healthy: workers up and downloading above the floor
#   COLLAPSE ...  running but stalled / aborting / auth-throttling
#   CRASHED ...   supervisor gone without a clean "all shards complete"
#   FINISHED ...  supervisor gone AFTER "all shards complete"
#
# It diffs against the previous invocation (a state file under $OUTPUT_DIR) to
# get the download rate over the interval, so it is meant to run on a short cron
# and notify only when the line is not "OK". Exit code: 0 on OK/FINISHED,
# 1 on COLLAPSE/CRASHED (so a cron wrapper can alert on nonzero).
#
# Usage:   ./bin/watch.sh        # FLOOR=<downloads/min> overrides the stall floor
#
set -uo pipefail

# --- resolve repo root from this script's location, then source config -------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/config.env" 2>/dev/null || source "$REPO/config.example.env"

case "$OUTPUT_DIR" in /*) OUT="$OUTPUT_DIR" ;; *) OUT="$REPO/$OUTPUT_DIR" ;; esac
case "$IDS_FILE"   in /*) IDS="$IDS_FILE"   ;; *) IDS="$REPO/$IDS_FILE"   ;; esac

AUDIO="$OUT/audio"
LOGDIR="$OUT/logs/parallel"
SUP_LOG="${SUP_LOG:-$OUT/crawl.out}"   # supervisor stdout (where crawl.sh is teed)
STATE="$OUT/.collapse_state"           # state file lives under $OUTPUT_DIR
FLOOR="${FLOOR:-10}"                   # downloads/min floor; below this while running = stalled
STALL_WINDOW="${STALL_WINDOW:-120}"    # min seconds between samples before judging a stall
# Clamp both to non-negative integers so a stray/non-numeric env value can't
# crash the arithmetic comparisons below.
[[ "$FLOOR"        =~ ^[0-9]+$ ]] || FLOOR=10
[[ "$STALL_WINDOW" =~ ^[0-9]+$ ]] || STALL_WINDOW=120

mkdir -p "$OUT" 2>/dev/null || true

# --- current sample ----------------------------------------------------------
now=$(date +%s)
run=$(pgrep -fc 'crawl\.sh'   2>/dev/null); run=${run:-0}
wrk=$(pgrep -fc 'vopono exec' 2>/dev/null); wrk=${wrk:-0}

# Extension-agnostic completed-download count: one .meta marker per success.
done_n=0
[[ -d "$AUDIO" ]] && done_n=$(find "$AUDIO" -type f -name '*.meta' 2>/dev/null | wc -l)

total=0
[[ -f "$IDS" ]] && total=$(grep -cvE '^\s*(#|$)' "$IDS" 2>/dev/null || echo 0)
pct="n/a"
(( total > 0 )) && pct=$(awk -v d="$done_n" -v t="$total" 'BEGIN{printf "%.2f%%", 100*d/t}')

sum() {  # sum <grep-ERE> across worker logs -> integer
  local n
  n=$(grep -hcE "$1" "$LOGDIR"/worker*.out 2>/dev/null | paste -sd+ - | bc 2>/dev/null)
  echo "${n:-0}"
}
af=$(sum 'authentication failed')
ab=$(sum '\] ABORT')

# --- diff against the previous sample ----------------------------------------
p_t=$now p_done=$done_n p_af=$af p_ab=$ab
[[ -f "$STATE" ]] && read -r p_t p_done p_af p_ab < "$STATE"
printf '%s %s %s %s\n' "$now" "$done_n" "$af" "$ab" > "$STATE"

dt=$(( now - p_t )); (( dt < 0 )) && dt=0
ddone=$(( done_n - p_done ))
rate=0; (( dt > 0 )) && rate=$(( ddone * 60 / dt ))
d_af=$(( af - p_af ))
d_ab=$(( ab - p_ab ))

# --- verdict -----------------------------------------------------------------
if (( run == 0 )); then
  if grep -q 'all shards complete' "$SUP_LOG" 2>/dev/null; then
    echo "FINISHED: supervisor stopped after 'all shards complete' — $done_n downloaded ($pct)."
    exit 0
  fi
  echo "CRASHED: supervisor not running and no clean finish — $done_n downloaded ($pct); needs a restart (sudo ./crawl.sh)."
  exit 1
elif (( d_ab > 2 )); then
  echo "COLLAPSE: $d_ab new worker ABORT(s) since last check — $wrk workers up, ~${rate}/min, $pct."
  exit 1
elif (( d_af > 5 )); then
  echo "COLLAPSE: auth-failures returned (+$d_af) — OpenVPN auth throttle / WireGuard regression? $wrk workers, $pct."
  exit 1
elif (( dt >= STALL_WINDOW && rate < FLOOR )); then
  echo "COLLAPSE: STALLED at ~${rate}/min (floor $FLOOR), only $wrk workers up — $done_n downloaded ($pct)."
  exit 1
else
  echo "OK: ~${rate}/min, $wrk workers up, $done_n downloaded ($pct)."
  exit 0
fi
