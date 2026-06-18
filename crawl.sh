#!/usr/bin/env bash
#
# crawl.sh — main entrypoint + supervisor for parallel YouTube crawling with
# per-worker NordVPN exit-IP isolation via vopono.
#
# WHAT THIS DOES
#   Launches $WORKERS parallel crawler workers. Each worker runs INSIDE its own
#   vopono network namespace bound to a DISTINCT country's VPN server (= a
#   distinct exit IP in a distinct /16), and processes a DISJOINT shard of the
#   id list (index % WORKERS == shard). The HOST default route is NEVER touched,
#   so SSH / the agent / everything else keeps its clean, non-VPN connection.
#
#   Within a worker, a "batch" of up to $LIMIT successful downloads runs back to
#   back on one IP; when the batch ends the worker relaunches in a fresh
#   namespace on the NEXT server within ITS OWN country -> a new IP, same /16.
#
# WHY (the hard-won facts — see README / skill for the full story):
#   * ONE distinct COUNTRY per worker  -> the W live IPs sit in W distinct /16s,
#     which avoids YouTube's subnet-level bot detection (workers stacked on one
#     provider /24 trip "Sign in to confirm you're not a bot" ~86% of the time).
#   * WireGuard (static key, no per-connection auth) -> nothing for NordVPN to
#     auth-throttle, so the fleet does not collapse under reconnect churn.
#   * A global setup-lock serializes the racy vopono netns/veth/NetworkManager
#     setup window (concurrent starts race on the shared unmanaged.conf).
#   * The HOST stays OFF the VPN. That is the whole point.
#
# RUNS AS ROOT (netns needs it). If launched unprivileged it re-execs under sudo
# (one password prompt), forwarding HOME so vopono finds ~/.config/vopono, and
# passes RUN_USER so vopono --user keeps the downloads owned by you, not root.
#
# USAGE
#   ./crawl.sh                 # run the crawl (the entrypoint)
#   WORKERS=4 LIMIT=40 ./crawl.sh
#   ./crawl.sh run             # explicit (same as no subcommand)
#   ./crawl.sh preflight       # run the preflight checks only, then exit
#
# Prereqs (one-time): see bin/install.sh, bin/setup.sh and the README. In short:
#   sudo bin/install.sh ; vopono sync nordvpn ; sudo bin/setup.sh ;
#   nordvpn disconnect && nordvpn set killswitch off
# (bin/setup.sh derives the protocol from VPN_PROTOCOL in config.env.)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repo root from THIS script's location (no hardcoded paths) and
# source config. Do this BEFORE the sudo re-exec so the values forward.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE"
# CLI/env overrides must WIN over config.env (e.g. `WORKERS=4 ./crawl.sh`): snapshot
# any config knobs already set in the environment, source config, then re-apply.
_ypcn_keys=(IDS_FILE OUTPUT_DIR YTDLP_FORMAT COOKIES_FILE VPN_PROVIDER VPN_PROTOCOL
  COUNTRIES WORKERS THREADS LIMIT BLOCK_BUDGET SETUP_WINDOW STAGGER SETTLE
  MAX_FAILS MIN_SUBSET CAP AUTH_COOLDOWN POOL_FILE WG_DIR VENV)
_ypcn_ovr=()
for _k in "${_ypcn_keys[@]}"; do [[ -n "${!_k+x}" ]] && _ypcn_ovr+=("$_k=${!_k}"); done
# shellcheck source=/dev/null
source "$REPO/config.env" 2>/dev/null || source "$REPO/config.example.env"
for _kv in "${_ypcn_ovr[@]:-}"; do [[ -n "$_kv" ]] && export "${_kv?}"; done

# Optional subcommand. Keep `./crawl.sh` (no args) as the run entrypoint.
SUBCMD="${1:-run}"
case "$SUBCMD" in
  run|preflight) shift || true ;;
  -*|"") SUBCMD="run" ;;            # a leading flag/empty is not a subcommand
  *) SUBCMD="run" ;;                # unknown token -> treat as the run entrypoint
esac

# ---------------------------------------------------------------------------
# Resolve every path/tunable relative to the repo root when it is relative, so
# a fresh clone "just works" regardless of the current working directory. Each
# value is overridable by an env var of the same name (config.example.env).
# ---------------------------------------------------------------------------
abspath() {  # abspath <path> -- absolutize against $REPO if not already absolute
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s\n' "$REPO/$1" ;;
  esac
}

IDS_FILE="$(abspath "$IDS_FILE")"
OUTPUT_DIR="$(abspath "$OUTPUT_DIR")"
POOL_FILE="$(abspath "$POOL_FILE")"
VENV="$(abspath "$VENV")"
# WG_DIR is conventionally an absolute, root-owned path (/etc/wireguard/...) but
# absolutize defensively in case a relative override is supplied.
WG_DIR="$(abspath "$WG_DIR")"
[[ -n "${COOKIES_FILE:-}" ]] && COOKIES_FILE="$(abspath "$COOKIES_FILE")"

PY="${PY:-$VENV/bin/python}"
CRAWLER="${CRAWLER:-$REPO/crawler/crawler.py}"
VOPONO="${VOPONO:-vopono}"

# Normalize VPN_PROTOCOL (the config uses VPN_PROTOCOL; accept lower-case).
VPN_PROTOCOL="$(printf '%s' "${VPN_PROTOCOL:-wireguard}" | tr '[:upper:]' '[:lower:]')"
VPN_PROVIDER="${VPN_PROVIDER:-nordvpn}"

# The user the downloads should be owned by (vopono --user). Root runs vopono,
# but the files must stay owned by the human who started the crawl.
RUN_USER="${RUN_USER:-${SUDO_USER:-$USER}}"

# Circuit-breaker + setup-lock state files. Kept in /tmp (root-writable, shared
# across all worker subshells).
AUTH_PAUSE_FILE="${AUTH_PAUSE_FILE:-/tmp/ypcn_auth_pause}"
SETUP_LOCK="${SETUP_LOCK:-/tmp/ypcn_setup.lock}"

# ---------------------------------------------------------------------------
# Elevate: netns needs root. Re-exec under sudo, forwarding HOME (so vopono
# finds the synced config), RUN_USER (so downloads stay user-owned), and every
# resolved path/tunable so the elevated process does not re-resolve them.
# ---------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo ">> netns needs root; re-running under sudo (one password prompt)..."
  exec sudo \
    HOME="$HOME" XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}" \
    RUN_USER="$RUN_USER" \
    IDS_FILE="$IDS_FILE" OUTPUT_DIR="$OUTPUT_DIR" POOL_FILE="$POOL_FILE" \
    WG_DIR="$WG_DIR" VENV="$VENV" PY="$PY" CRAWLER="$CRAWLER" \
    YTDLP_FORMAT="$YTDLP_FORMAT" COOKIES_FILE="${COOKIES_FILE:-}" \
    VPN_PROVIDER="$VPN_PROVIDER" VPN_PROTOCOL="$VPN_PROTOCOL" \
    COUNTRIES="$COUNTRIES" WORKERS="$WORKERS" THREADS="$THREADS" LIMIT="$LIMIT" \
    BLOCK_BUDGET="$BLOCK_BUDGET" SETUP_WINDOW="$SETUP_WINDOW" STAGGER="$STAGGER" \
    SETTLE="$SETTLE" MAX_FAILS="$MAX_FAILS" MIN_SUBSET="$MIN_SUBSET" CAP="$CAP" \
    AUTH_COOLDOWN="$AUTH_COOLDOWN" \
    VOPONO="$VOPONO" AUTH_PAUSE_FILE="$AUTH_PAUSE_FILE" SETUP_LOCK="$SETUP_LOCK" \
    "$0" "$SUBCMD" "$@"
fi

# ---------------------------------------------------------------------------
# Worker -> country pinning and the rotation subset for each worker.
#
# COUNTRIES is a space-separated list, ONE distinct country per worker. The pool
# file ($POOL_FILE) lists concrete server tokens (e.g. "south_korea-kr112"), one
# per line. We derive each server's country by stripping the "-<serverid>" tail,
# group servers by country, and give worker i the servers of COUNTRIES[i].
# ---------------------------------------------------------------------------
# COUNTRIES is an intentionally word-split, space-separated list (one country
# per worker). Split it on whitespace into an array, then drop blanks/duplicates.
read -ra _countries_raw <<< "$COUNTRIES"
mapfile -t WANTED_COUNTRIES < <(printf '%s\n' "${_countries_raw[@]}" | awk 'NF && !seen[$0]++')
NC_WANTED="${#WANTED_COUNTRIES[@]}"

LOGDIR="$OUTPUT_DIR/logs/parallel"

# ---------------------------------------------------------------------------
# Preflight: fail fast and loud on anything that would make the long run abort
# halfway. (vopono present; ids/pool exist; WG configs exist in WireGuard mode;
# enough distinct countries; cap honored; host not on the VPN; disk headroom.)
# ---------------------------------------------------------------------------
preflight() {
  local ok=1

  command -v "$VOPONO" >/dev/null 2>&1 || {
    echo "ERROR: vopono not found. Install it: sudo bin/install.sh" >&2; ok=0; }

  [[ -x "$PY" ]] || {
    echo "ERROR: python venv interpreter not found/executable: $PY (run bin/setup.sh)." >&2; ok=0; }
  [[ -f "$CRAWLER" ]] || {
    echo "ERROR: crawler not found: $CRAWLER" >&2; ok=0; }

  [[ -f "$IDS_FILE" ]] || {
    echo "ERROR: id list not found: $IDS_FILE (set IDS_FILE in config.env)." >&2; ok=0; }
  [[ -f "$POOL_FILE" ]] || {
    echo "ERROR: server pool not found: $POOL_FILE (run bin/setup.sh to build it)." >&2; ok=0; }

  (( WORKERS >= 1 )) || { echo "ERROR: WORKERS must be >= 1 (got '$WORKERS')." >&2; ok=0; }

  # Honor the provider simultaneous-connection ceiling. Steady state needs
  # WORKERS live tunnels; over the cap, excess workers fail-and-rotate forever.
  if (( WORKERS > CAP )); then
    echo "ERROR: WORKERS=$WORKERS exceeds the provider connection cap CAP=$CAP. " \
         "Each worker holds one live tunnel; over the cap the excess just thrash. " \
         "Lower WORKERS (<= $CAP) or raise CAP if your plan allows more." >&2
    ok=0
  fi

  # One distinct country per worker.
  if (( NC_WANTED < WORKERS )); then
    echo "ERROR: only $NC_WANTED distinct COUNTRIES but WORKERS=$WORKERS -- each worker " \
         "needs its own country/range. Add countries to COUNTRIES in config.env." >&2
    ok=0
  fi

  # WireGuard mode needs per-server configs in WG_DIR.
  if [[ "$VPN_PROTOCOL" == "wireguard" ]]; then
    local n_wg
    n_wg=$(find "$WG_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)
    if (( n_wg < 1 )); then
      echo "ERROR: no WireGuard configs in $WG_DIR. Generate them: sudo bin/setup.sh (with VPN_PROTOCOL=wireguard)" >&2
      ok=0
    else
      echo ">> WireGuard mode: $n_wg server config(s) in $WG_DIR (no per-connection auth)."
    fi
  fi

  (( ok )) || { echo ">> preflight FAILED." >&2; return 1; }

  # --- non-fatal warnings ---------------------------------------------------
  # Host should be OFF the VPN (that is the whole point).
  if command -v nordvpn >/dev/null 2>&1 && nordvpn status 2>/dev/null | grep -q "Status: Connected"; then
    echo ">> WARN: host nordvpn is Connected. The host must stay OFF the VPN: " \
         "'nordvpn disconnect && nordvpn set killswitch off'." >&2
  fi

  # Disk headroom (warn under ~50 GB).
  local avail_kb
  avail_kb="$(df -P "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "${avail_kb:-}" ]] && (( avail_kb < 50*1024*1024 )); then
    echo ">> WARN: only $(( avail_kb/1024/1024 ))GB free on $OUTPUT_DIR." >&2
  fi

  return 0
}

# Load the server pool and group it by country. Sets the globals SRV (all pool
# servers) and, per worker, the COUNTRY[i] it is pinned to. Each worker computes
# its own rotation subset at launch (so WireGuard config presence is checked
# there). Run this only after preflight has confirmed the pool exists.
load_pool() {
  mapfile -t SRV < <(grep -vE '^[[:space:]]*(#|$)' "$POOL_FILE" | awk '!seen[$0]++')
  (( ${#SRV[@]} > 0 )) || { echo "ERROR: server pool $POOL_FILE is empty." >&2; exit 1; }

  # Warn if a worker's country is too shallow to rotate within.
  local i c cn s
  for (( i=0; i<WORKERS; i++ )); do
    c="${WANTED_COUNTRIES[$i]}"; cn=0
    for s in "${SRV[@]}"; do [[ "$(server_country "$s")" == "$c" ]] && cn=$(( cn + 1 )); done
    (( cn >= 1 )) || echo ">> WARN: country '$c' has NO servers in $POOL_FILE -- worker $i will idle." >&2
    (( cn >= 1 && cn < MIN_SUBSET )) && \
      echo ">> WARN: country '$c' has only $cn server(s) to rotate within (< MIN_SUBSET=$MIN_SUBSET)." >&2
  done
}

# server_country <token> -- the country of a pool server token. Tokens look like
# "south_korea-kr112"; the country is everything before the final "-<serverid>".
# (Country names may themselves contain underscores but not a trailing "-id".)
server_country() { printf '%s\n' "${1%-*}"; }

say() {  # say <wlog> <msg...> -- to the worker log (best-effort) AND supervisor stdout
  local wl="$1"; shift
  printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$wl" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# One worker: own ONE country, rotate within its servers, relaunch on a fresh
# IP each batch. Runs the crawler INSIDE a vopono netns; the crawler itself
# never touches the VPN.
# ---------------------------------------------------------------------------
run_worker() {
  set +e                                     # manage exit codes explicitly; do not let
                                             # a tee/sleep failure kill the worker
  local i="$1" wlog="$LOGDIR/worker$1.out"
  local mycountry="${WANTED_COUNTRIES[$i]}"

  # Build this worker's rotation subset: the pool servers in its country. In
  # WireGuard mode, only servers we actually generated a --custom config for.
  local subset=() s
  for s in "${SRV[@]}"; do
    [[ "$(server_country "$s")" == "$mycountry" ]] || continue
    if [[ "$VPN_PROTOCOL" == "wireguard" && ! -f "$WG_DIR/$s.conf" ]]; then continue; fi
    subset+=("$s")
  done
  local m="${#subset[@]}"
  if (( m == 0 )); then
    say "$wlog" "[w$i] ABORT: no usable servers for country '$mycountry'" \
                "(WireGuard configs missing? empty country in pool?)."
    return 1
  fi

  local si=0 fails=0 noprog=0
  # After cycling every IP a couple times with zero progress, the remaining ids
  # look genuinely non-IP-blocked (network elsewhere); stop rather than spin.
  local noprog_cap=$(( m * 2 ))
  (( noprog_cap > 16 )) && noprog_cap=16
  (( noprog_cap < 4 ))  && noprog_cap=4
  RANDOM=$(( (i + 1) * 7919 ))               # per-worker seed so jitter desyncs workers
  say "$wlog" "[w$i] shard $i/$WORKERS | country $mycountry | $m server(s) to rotate"

  # The per-shard crawler command, as ONE shell-split string (vopono 0.10 takes
  # the application as a single argument, NOT a `-- cmd args` list). No `--vpn-*`
  # flag: the surrounding namespace owns the IP; the crawler never calls vopono.
  local appcmd="$PY $CRAWLER $IDS_FILE $OUTPUT_DIR"
  appcmd+=" --num-shards $WORKERS --shard $i --threads $THREADS"
  appcmd+=" --limit $LIMIT --block-budget $BLOCK_BUDGET"
  [[ -n "${YTDLP_FORMAT:-}" ]] && appcmd+=" --format $YTDLP_FORMAT"
  [[ -n "${COOKIES_FILE:-}" ]] && appcmd+=" --cookies $COOKIES_FILE"

  while :; do
    # Circuit-breaker: if any worker hit the provider's auth throttle (OpenVPN),
    # the whole fleet waits here until the cooldown expires (no retry cascade).
    if [[ -f "$AUTH_PAUSE_FILE" ]]; then
      local pu nowt; pu=$(cat "$AUTH_PAUSE_FILE" 2>/dev/null || echo 0); nowt=$(date +%s)
      if (( pu > nowt )); then
        say "$wlog" "[w$i] auth-cooldown: waiting $(( pu - nowt ))s"
        sleep $(( pu - nowt + RANDOM % 8 ))
      fi
    fi

    local server="${subset[$(( si % m ))]}"; si=$(( si + 1 ))
    say "$wlog" "[w$i] batch via $VPN_PROVIDER:$server ($VPN_PROTOCOL, shard $i/$WORKERS)"

    # Hold the global setup-lock ONLY while vopono builds its netns/veth + edits
    # NetworkManager (+ authenticates, for OpenVPN) -- the racy, not-concurrency-
    # safe window -- then release it so the long download runs in parallel with
    # the other workers.
    exec 8>"$SETUP_LOCK"; flock 8
    if [[ "$VPN_PROTOCOL" == "wireguard" ]]; then
      # WireGuard: hand-built per-server config fed to vopono via --custom. No
      # per-connection auth -> nothing for the provider to throttle.
      "$VOPONO" exec --custom "$WG_DIR/$server.conf" --protocol wireguard \
        --user "$RUN_USER" "$appcmd" >>"$wlog" 2>&1 &
    else
      # OpenVPN: provider + server name (full config name, e.g. south_korea-kr112).
      "$VOPONO" exec --provider "$VPN_PROVIDER" --protocol openvpn \
        --server "$server" --user "$RUN_USER" "$appcmd" >>"$wlog" 2>&1 &
    fi
    local vp=$! held=0
    while (( held < SETUP_WINDOW )) && kill -0 "$vp" 2>/dev/null; do
      sleep 1; held=$(( held + 1 ))
    done
    flock -u 8; exec 8>&-
    wait "$vp"; local rc=$?

    case "$rc" in
      64) say "$wlog" "[w$i] SHARD COMPLETE -- stopping worker."; return 0 ;;
      0)  fails=0; noprog=0 ;;                         # progress -> rotate IP and continue
      75)                                              # batch downloaded nothing
        noprog=$(( noprog + 1 ))
        say "$wlog" "[w$i] no downloads on $server (#$noprog/$noprog_cap); rotating IP."
        if (( noprog >= noprog_cap )); then
          say "$wlog" "[w$i] STUCK: cycled all $m IP(s) x2 with zero progress; remaining ids " \
                      "look non-IP-blocked. Stopping shard $i (re-run later to retry)."
          return 2
        fi
        sleep $(( SETTLE + RANDOM % 12 )); continue ;;
      *)                                               # vopono/setup/crash failure
        if tail -n 40 "$wlog" 2>/dev/null | grep -q 'authentication failed'; then
          # Provider auth throttle (OpenVPN) -> GLOBAL cooldown so every worker
          # pauses and the throttle resets, instead of a retry cascade.
          echo $(( $(date +%s) + AUTH_COOLDOWN )) > "$AUTH_PAUSE_FILE"
          say "$wlog" "[w$i] AUTH THROTTLE on $server -> global ${AUTH_COOLDOWN}s cooldown (fleet pauses)."
          sleep "$AUTH_COOLDOWN"
          fails=0; continue
        fi
        fails=$(( fails + 1 ))
        say "$wlog" "[w$i] vopono/setup FAILURE on $server rc=$rc (#$fails/$MAX_FAILS)"
        if (( fails >= MAX_FAILS )); then
          say "$wlog" "[w$i] ABORT after $fails consecutive failures. Check: host off-VPN? " \
                      "creds synced? connection cap? '$VPN_PROTOCOL' configs present?"
          return 1
        fi
        # Exponential backoff, capped at 60s.
        local back=$(( SETTLE * (1 << (fails - 1)) )); (( back > 60 )) && back=60
        sleep "$back"; continue ;;
    esac
    sleep $(( SETTLE + RANDOM % 12 ))            # jittered settle between batches
  done
}

# ---------------------------------------------------------------------------
# Teardown: SIGTERM (not SIGKILL) the whole process tree of each worker so the
# VPN session releases cleanly, then wait for vopono to reclaim its namespaces.
# ---------------------------------------------------------------------------
kill_tree() {
  local pid="$1" c
  for c in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$c"; done
  kill -TERM "$pid" 2>/dev/null || true
}
cleanup() {
  trap - INT TERM
  echo; echo ">> stopping ${#pids[@]} worker(s) + tearing down namespaces..."
  local p
  for p in "${pids[@]}"; do kill_tree "$p"; done
  local _
  for _ in $(seq 1 15); do
    "$VOPONO" list namespaces 2>/dev/null | grep -q . || break
    sleep 1
  done
  if "$VOPONO" list namespaces 2>/dev/null | grep -q .; then
    echo ">> WARN: vopono namespaces still present -- inspect '$VOPONO list namespaces'" \
         "and your provider's active connections; run bin/cleanup.sh." >&2
  fi
  exit 130
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  preflight || exit 1
  if [[ "$SUBCMD" == "preflight" ]]; then
    echo ">> preflight OK."
    exit 0
  fi

  mkdir -p "$LOGDIR"
  load_pool

  # Supervisor lifecycle log: bin/watch.sh reads this to distinguish a clean
  # FINISH ("all shards complete") from a CRASH. Append so re-runs accumulate.
  local SUP_LOG="$OUTPUT_DIR/crawl.out"
  echo "[$(date -Is)] === run start: $WORKERS workers, $VPN_PROVIDER:$VPN_PROTOCOL ===" >> "$SUP_LOG"

  echo "=== youtube-parallel-crawl-nordvpn (vopono per-worker isolation) ==="
  echo " ids       : $IDS_FILE"
  echo " output    : $OUTPUT_DIR"
  echo " run-as    : root (netns); downloads owned by '$RUN_USER'; HOME=$HOME"
  echo " workers   : $WORKERS (each pinned to a DISTINCT country), threads=$THREADS,"
  echo "             limit=$LIMIT dl/IP, block-budget=$BLOCK_BUDGET, $VPN_PROVIDER:$VPN_PROTOCOL"
  echo " countries : ${WANTED_COUNTRIES[*]:0:$WORKERS}"
  echo " pool      : ${#SRV[@]} server(s) in $POOL_FILE"
  echo " logs      : $LOGDIR/worker<i>.out"
  echo

  # Clear any stale auth cooldown from a previous run.
  rm -f "$AUTH_PAUSE_FILE" 2>/dev/null || true

  pids=(); declare -A pid2shard
  trap cleanup INT TERM                       # install BEFORE launch (no untrapped window)
  local i pid
  for (( i=0; i<WORKERS; i++ )); do
    run_worker "$i" &
    pid="$!"; pids+=("$pid"); pid2shard[$pid]=$i
    # Stagger initial launches: many vopono processes creating netns + editing
    # the shared NetworkManager unmanaged.conf at the same instant race and fail.
    (( i < WORKERS - 1 )) && sleep "$STAGGER"
  done
  echo ">> all $WORKERS worker(s) launched (staggered ${STAGGER}s); supervising..."

  # Supervise: wait on each worker; surface any incomplete shard and exit nonzero
  # so a wrapper/cron knows to re-run (resume) the missing ids.
  local bad=0 rc
  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      :
    else
      rc=$?
      echo ">> ERROR: worker shard ${pid2shard[$pid]} exited rc=$rc -> shard INCOMPLETE." >&2
      bad=1
    fi
  done
  if (( bad )); then
    echo ">> FINISHED WITH INCOMPLETE SHARD(S) -- re-run ./crawl.sh to resume the missing ids." | tee -a "$SUP_LOG" >&2
    exit 1
  fi
  echo ">> all shards complete." | tee -a "$SUP_LOG"
}

main "$@"
