#!/usr/bin/env bash
#
# retry-region.sh — re-attempt videos that failed for a REGION reason, from a
# DIFFERENT set of regions.
#
# Some YouTube videos are region-locked: "not available in your country" /
# "blocked it in your country". When the crawl ran from regions A, those failed
# and got a permanent skip-marker (logs/<id[:2]>/<id>.log). They are NOT gone —
# a different region's exit IP can often fetch them. This script:
#
#   1. scans OUTPUT_DIR/logs for permanent-failure markers,
#   2. selects the REGION-recoverable ones (and skips the genuinely-gone:
#      deleted / private / terminated-account / global copyright / age-gated),
#   3. writes their ids to OUTPUT_DIR/retry_region.txt,
#   4. DELETES those ids' skip-markers so the crawler will re-attempt them,
#   5. prints the two commands to run the retry from new regions.
#
# It does NOT delete audio, does NOT touch the genuinely-gone markers, and does
# NOT start a crawl itself — you run the printed commands with new COUNTRIES.
#
# Usage:
#   ./bin/retry-region.sh                 # default: region-locks + ambiguous "unavailable"
#   ./bin/retry-region.sh --strict        # ONLY explicit "...in your country" (high-confidence)
#   ./bin/retry-region.sh --dry-run       # show the breakdown only; change nothing
#   ./bin/retry-region.sh --countries "united_states united_kingdom canada germany"
#   ./bin/retry-region.sh --out /path/retry.txt
#
set -uo pipefail

# --- resolve repo root + config (same convention as the other bin/ scripts) ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
_pre_out="${OUTPUT_DIR:-}"   # an OUTPUT_DIR set in the env wins over config.env
# shellcheck source=/dev/null
source "$REPO/config.env" 2>/dev/null || source "$REPO/config.example.env"
[[ -n "$_pre_out" ]] && OUTPUT_DIR="$_pre_out"
case "$OUTPUT_DIR" in /*) OUT="$OUTPUT_DIR" ;; *) OUT="$REPO/$OUTPUT_DIR" ;; esac

# A globally-diverse default set so a video locked OUT of your original regions
# is likely available in at least one of these. Override with --countries.
SUGGEST="${RETRY_COUNTRIES:-united_states united_kingdom canada germany france brazil australia japan}"

STRICT=0; DRYRUN=0; OUTFILE="$OUT/retry_region.txt"; COUNTRIES_OVERRIDE=""
while (( $# )); do
  case "$1" in
    --strict)    STRICT=1 ;;
    --dry-run|-n) DRYRUN=1 ;;
    --out)       OUTFILE="$2"; shift ;;
    --countries) COUNTRIES_OVERRIDE="$2"; shift ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$COUNTRIES_OVERRIDE" ]] && SUGGEST="$COUNTRIES_OVERRIDE"

LOGS="$OUT/logs"
[[ -d "$LOGS" ]] || { echo "ERROR: no logs dir at $LOGS (nothing to retry; run a crawl first)." >&2; exit 1; }

echo ">> scanning permanent-failure markers under $LOGS ..."
# Read the status (last tab-field) of every per-id marker and bucket it. Order
# matters: a REGION match wins over a copyright/gone match, so e.g. "blocked it
# in your country on copyright grounds" is treated as region-recoverable.
tmp_ids="$(mktemp)"; trap 'rm -f "$tmp_ids"' EXIT
counts="$(
  find "$LOGS" -mindepth 2 -name '*.log' 2>/dev/null | xargs -r cat 2>/dev/null \
  | awk -F'\t' -v strict="$STRICT" -v out="$tmp_ids" '
      { id=$1; s=tolower($NF) }
      id !~ /^[A-Za-z0-9_-]{11}$/ { next }
      {
        region = (s ~ /not available in your country|not made this video available|blocked it in your country/)
        gone   = (s ~ /has been terminated|private video|this video is private|removed by the uploader|this video has been removed|violating youtube|no longer available|copyright grounds|sign in to confirm your age|this video may be inappropriate|members-only|join this channel|music premium members/)
        ambig  = (s ~ /video unavailable|this video is unavailable|this video is not available/)
        if (region)      { print id > out; r++ }
        else if (gone)   { g++ }
        else if (ambig)  { if (!strict) { print id > out; a++ } else { askip++ } }
        else             { o++ }
      }
      END { printf "%d %d %d %d %d", r+0, a+0, askip+0, g+0, o+0 }
  '
)"
read -r N_REGION N_AMBIG N_AMBIG_SKIP N_GONE N_OTHER <<<"$counts"
sort -u "$tmp_ids" > "$tmp_ids.u" && mv "$tmp_ids.u" "$tmp_ids"
N_RETRY="$(grep -c . "$tmp_ids" 2>/dev/null || echo 0)"

echo
echo "== failure breakdown =="
echo "  region-locked (explicit '...in your country')   : $N_REGION   -> RETRY"
if (( STRICT )); then
  echo "  ambiguous 'unavailable' (could be region)        : $N_AMBIG_SKIP  -> skipped (--strict)"
else
  echo "  ambiguous 'unavailable' (could be region)        : $N_AMBIG   -> RETRY (omit with --strict)"
fi
echo "  genuinely gone (deleted/private/terminated/global"
echo "    copyright/age-gated/members-only)              : $N_GONE   -> kept skipped"
echo "  other/unclassified                               : $N_OTHER"
echo "  --------------------------------------------------"
echo "  TO RETRY                                         : $N_RETRY"

if (( N_RETRY == 0 )); then
  echo ">> nothing region-recoverable to retry. Done."
  exit 0
fi

if (( DRYRUN )); then
  echo
  echo ">> --dry-run: no markers cleared, no list written. Re-run without --dry-run to prepare the retry."
  exit 0
fi

# Write the retry id list and DELETE those ids' skip-markers so already_done()
# re-attempts them. (Audio + the genuinely-gone markers are left untouched.)
mkdir -p "$(dirname "$OUTFILE")"
cp -f "$tmp_ids" "$OUTFILE"
cleared=0
while read -r id; do
  [[ -n "$id" ]] || continue
  m="$LOGS/${id:0:2}/${id}.log"
  [[ -e "$m" ]] && { rm -f "$m" && cleared=$(( cleared + 1 )); }
done < "$OUTFILE"

echo
echo ">> wrote $N_RETRY ids -> $OUTFILE"
echo ">> cleared $cleared skip-markers (these ids will be re-attempted)."
echo
echo "== next: retry from DIFFERENT regions =="
echo "  1) one-time, build the pool + WireGuard configs for the new regions:"
echo "       COUNTRIES=\"$SUGGEST\" sudo bin/setup.sh"
echo "  2) run the retry on just these ids, from the new regions:"
echo "       IDS_FILE=\"$OUTFILE\" COUNTRIES=\"$SUGGEST\" ./crawl.sh"
echo
echo "  (Recovered videos land in OUTPUT_DIR/audio as usual; any that fail again get"
echo "   a fresh skip-marker. Already-downloaded ids are skipped automatically.)"
