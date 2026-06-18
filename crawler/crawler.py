#!/usr/bin/env python3
"""Per-shard YouTube audio crawler — the worker that runs INSIDE a vopono netns.

This process NEVER touches the VPN. The surrounding network namespace (set up by
the supervisor, crawl.sh, via `vopono exec`) owns the exit IP, so the crawler's
only job is to fetch audio + metadata with yt-dlp, classify failures correctly,
and tell the supervisor — via its exit code — whether the shard is finished, made
progress, or got nothing (so the supervisor can rotate this worker to a fresh IP).

It is self-contained: a plain ids/urls file in, an OUTPUT_DIR tree out, no
project-specific JSON, no host-VPN mode, no external helper modules.

Work split: IDS_FILE is a flat list of YouTube video IDs OR full URLs (one per
line). With `--num-shards N --shard i` this process handles only the ids whose
0-based index among the PARSEABLE ids (blank/comment lines skipped) satisfies
`index % N == i`. Every worker parses the same file the same way, so N workers
cover it with no coordination and no overlap.

On-disk layout (resumable — re-running skips everything already fetched):

    OUTPUT_DIR/audio/<id[:2]>/<id>.<ext>     # audio (ext from yt-dlp: m4a/webm/...)
    OUTPUT_DIR/audio/<id[:2]>/<id>.meta      # sanitized yt-dlp metadata (json)
    OUTPUT_DIR/logs/<id[:2]>/<id>.log        # ONLY for permanent failures (skip marker)
    OUTPUT_DIR/archive.shard<N>.txt          # yt-dlp download archive (fast-path resume)

Failure classification (the whole point of doing this carefully):

  * BLOCK     — 429 / 403 / "not a bot" / "Please sign in" / "unable to download
                video data". A per-IP symptom that a *fresh IP* fixes. Re-queue
                the id, write NO marker. Once this IP has burned through
                --block-budget blocks, end the batch so the supervisor hands the
                worker a fresh IP.
                (NB: yt-dlp prints a CURLY apostrophe in "you're not a bot", so we
                key on the substring "not a bot" and NEVER match "you're".)
  * PERMANENT — Video unavailable / Private / removed by the uploader / copyright
                ("who has blocked it") / "Sign in to confirm your age" / account
                terminated. A fresh IP does NOT help — write a skip marker so the
                id is never re-attempted.
  * TRANSIENT — 5xx / timeout / network. Retry, write NO marker.

Exit codes (the supervisor keys off these):
  * 64  shard complete — the pruned work set was EMPTY (every id already on disk or
        permanently skip-marked) -> supervisor stops relaunching this shard.
  * 0   batch made progress — at least one download succeeded, ids remain ->
        supervisor rotates this worker to a fresh IP and relaunches.
  * 75  no progress — there was work but nothing downloaded (bad/blocked IP, stuck
        ids) -> supervisor rotates the IP, counts it toward a stuck cap.
"""

import argparse
import csv
import json
import os
import queue
import re
import sys
import threading
import time


# --- exit codes the supervisor (crawl.sh) keys off of -----------------------
EX_SHARD_COMPLETE = 64   # pruned work set EMPTY -> stop relaunching this shard
EX_BATCH_DONE = 0        # batch made progress, ids remain -> rotate IP, relaunch
EX_NO_PROGRESS = 75      # had work, downloaded nothing -> rotate IP (toward a cap)


# A mobile Safari UA: YouTube serves these formats more reliably and they draw
# less bot-detection heat than a stock desktop python-requests UA.
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.6 Mobile/15E148 Safari/604.1"
)

# yt-dlp default format: m4a audio-only (itag 140) then best available audio.
DEFAULT_FORMAT = "140/bestaudio[ext=m4a]/bestaudio"

_ANSI_RE = re.compile(r"(?:\x1B[@-_]|[\x80-\x9F])[0-?]*[ -/]*[@-~]")
_YT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


def escape_ansi(text):
    """Strip ANSI escape sequences yt-dlp may embed in error strings."""
    return _ANSI_RE.sub("", text)


def parse_video_id(line):
    """Extract an 11-char YouTube id from a bare id OR a full URL.

    Accepts:  dQw4w9WgXcQ
              https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=...
              https://youtu.be/dQw4w9WgXcQ
              https://www.youtube.com/shorts/dQw4w9WgXcQ
              https://www.youtube.com/embed/dQw4w9WgXcQ
    Returns the id, or None if no 11-char id can be found.
    """
    line = line.strip()
    if not line:
        return None
    if _YT_ID_RE.match(line):
        return line
    # watch?v=ID  (anywhere in the string, before any & param)
    m = re.search(r"[?&]v=([A-Za-z0-9_-]{11})", line)
    if m:
        return m.group(1)
    # youtu.be/ID , /shorts/ID , /embed/ID , /v/ID
    m = re.search(r"(?:youtu\.be/|/shorts/|/embed/|/v/)([A-Za-z0-9_-]{11})", line)
    if m:
        return m.group(1)
    # Last resort: a lone 11-char token sitting on the line.
    m = re.search(r"([A-Za-z0-9_-]{11})", line)
    if m:
        return m.group(1)
    return None


def youtube_url(yt_id):
    return f"https://www.youtube.com/watch?v={yt_id}"


# --- failure classification -------------------------------------------------
#
# PERMANENT: a fresh IP / retry does NOT help — the video is genuinely gone or
# restricted. Record a skip marker so we never re-attempt it.
_PERMANENT_MARKERS = (
    "Video unavailable",
    "This video is unavailable",
    "This video is not available",
    "This video is no longer available",
    "no longer available",
    "Private video",
    "This video is private",
    "has been removed by the uploader",
    "removed by the uploader",
    "This video has been removed",
    "violating YouTube's Terms of Service",
    "account associated with this video has been terminated",
    "has been terminated",
    "The uploader has not made this video available in your country",
    "not made this video available",
    "who has blocked it",                 # copyright block ("...on copyright grounds")
    "blocked it on copyright grounds",
    "copyright grounds",
    "Sign in to confirm your age",        # age gate — permanent without cookies
    "This video may be inappropriate",
    "members-only content",
    "This video is only available to Music Premium members",
    "Join this channel",                  # members-only
)

# BLOCK: a per-IP symptom — a fresh IP usually fixes it. Re-queue, NO marker.
# NB: yt-dlp prints a CURLY apostrophe in "you're not a bot"; we MUST key on the
# substring "not a bot" and never on "you're".
_BLOCK_MARKERS = (
    "HTTP Error 429",
    "Too Many Requests",
    "HTTP Error 403",
    "not a bot",
    "Please sign in",
    "Sign in to confirm you",             # "...you're not a bot" (apostrophe-safe prefix)
    "unable to download video data",
    "The following content is not available on this app",
)


def is_permanent_failure(status):
    s = status.lower()
    return any(m.lower() in s for m in _PERMANENT_MARKERS)


def is_block_failure(status):
    # An age-gate ("Sign in to confirm your age") is permanent, not a block, even
    # though it contains "Sign in to confirm you". Permanent wins, so callers MUST
    # test is_permanent_failure() first; this function assumes that has been done.
    return any(m.lower() in status.lower() for m in _BLOCK_MARKERS)


# --- on-disk paths + resume -------------------------------------------------
def _paths(yt_id, root):
    prefix = yt_id[:2]
    audio_dir = os.path.join(root, "audio", prefix)
    log_dir = os.path.join(root, "logs", prefix)
    return audio_dir, log_dir


def _audio_glob_done(audio_dir, yt_id):
    """A finished download is <id>.<ext> + <id>.meta in the audio dir. The ext is
    whatever yt-dlp produced (m4a/webm/...), so accept any non-.meta sibling."""
    meta = os.path.join(audio_dir, f"{yt_id}.meta")
    if not os.path.exists(meta):
        return False
    try:
        for name in os.listdir(audio_dir):
            if name == f"{yt_id}.meta":
                continue
            if name == f"{yt_id}.meta.tmp":
                continue
            if name.startswith(f"{yt_id}.") and not name.endswith(".part"):
                return True
    except OSError:
        return False
    return False


def _has_permanent_marker(log_dir, yt_id):
    log_path = os.path.join(log_dir, f"{yt_id}.log")
    if not os.path.exists(log_path):
        return False
    try:
        with open(log_path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                status = line.split("\t")[-1].strip()
                return is_permanent_failure(status)
    except OSError:
        return False
    return False


def already_done(yt_id, root):
    """True if this id needs no network work: either fully fetched (audio+meta on
    disk) or recorded as a permanent failure. Used to prune the work queue in the
    main thread so finished ids never cost a worker lock / log write."""
    if not yt_id:
        return False
    audio_dir, log_dir = _paths(yt_id, root)
    if _audio_glob_done(audio_dir, yt_id):
        return True
    if _has_permanent_marker(log_dir, yt_id):
        return True
    return False


def _write_meta(meta_path, info):
    os.makedirs(os.path.dirname(meta_path), exist_ok=True)
    tmp = meta_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(info, ensure_ascii=False) + "\n")
    os.replace(tmp, meta_path)


def _write_permanent_marker(log_dir, yt_id, status):
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, f"{yt_id}.log")
    with open(log_path, "w", encoding="utf-8") as handle:
        handle.write("\t".join((yt_id, status)) + "\n")
    return log_path


# --- yt-dlp options ---------------------------------------------------------
def build_ydl_opts(outtmpl, archive, fmt, cookies, user_agent):
    import yt_dlp  # imported lazily so --help works without yt-dlp installed

    opts = {
        "format": fmt,
        "noplaylist": True,
        "outtmpl": outtmpl,
        "retries": 3,
        "fragment_retries": 3,
        "force_ipv4": True,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "no_color": True,
        "ignoreerrors": False,
        "http_headers": {
            "User-Agent": user_agent,
            "Accept": ("text/html,application/xhtml+xml,application/xml;"
                       "q=0.9,*/*;q=0.8"),
            "Accept-Language": "en-US,en;q=0.5",
            "Accept-Encoding": "gzip, deflate",
            "Connection": "keep-alive",
        },
    }
    if archive:
        opts["download_archive"] = archive
    if cookies:
        opts["cookiefile"] = cookies
    return yt_dlp, opts


def download_one(yt_id, root, fmt, archive, cookies, user_agent):
    """Fetch one id. Returns (yt_id, status) where status is one of:
        downloaded | file exists | blocked | permanent | transient | empty id
    """
    import yt_dlp.utils as ytu

    if not yt_id:
        return (yt_id, "empty id")

    audio_dir, log_dir = _paths(yt_id, root)
    # <id>.%(ext)s so yt-dlp picks the real container; meta is a sibling.
    out_base = os.path.join(audio_dir, yt_id)
    outtmpl = out_base + ".%(ext)s"
    meta_path = out_base + ".meta"

    if _audio_glob_done(audio_dir, yt_id):
        return (yt_id, "file exists")
    if _has_permanent_marker(log_dir, yt_id):
        return (yt_id, "permanent")

    os.makedirs(audio_dir, exist_ok=True)
    yt_dlp, opts = build_ydl_opts(outtmpl, archive, fmt, cookies, user_agent)

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(youtube_url(yt_id), download=True)
            if info:
                _write_meta(meta_path, ydl.sanitize_info(info))
            return (yt_id, "downloaded")
    except ytu.DownloadError as exc:
        status = escape_ansi(str(exc))
        # PERMANENT first: an age gate contains "Sign in to confirm you" which also
        # matches a block marker, but it is permanent — order matters.
        if is_permanent_failure(status):
            _write_permanent_marker(log_dir, yt_id, status)
            return (yt_id, "permanent")
        if is_block_failure(status):
            return (yt_id, "blocked")
        # 5xx / timeout / network / anything else -> transient, retry, no marker.
        return (yt_id, "transient")
    except Exception as exc:  # noqa: BLE001  (don't let one bad id kill the worker)
        status = escape_ansi(str(exc))
        if is_permanent_failure(status):
            _write_permanent_marker(log_dir, yt_id, status)
            return (yt_id, "permanent")
        if is_block_failure(status):
            return (yt_id, "blocked")
        return (yt_id, "transient")


# --- the shard crawl --------------------------------------------------------
def crawl(args):
    nshard = max(1, args.num_shards)
    shard = args.shard
    archive = os.path.join(args.output_dir, f"archive.shard{shard}.txt")
    log_dir = os.path.join(args.output_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    user_agent = args.user_agent or DEFAULT_USER_AGENT
    fmt = args.format or DEFAULT_FORMAT
    cookies = args.cookies if (args.cookies and os.path.exists(args.cookies)) else None
    if args.cookies and not cookies:
        print(f"!! cookies file not found: {args.cookies} (continuing without)",
              flush=True)

    # Build this shard's work queue, pruning ids already on disk / skip-marked.
    work = queue.Queue()
    queued = 0
    skipped = 0
    seen = 0
    with open(args.ids_file, encoding="utf-8") as handle:
        for line in handle:
            yt_id = parse_video_id(line)
            if yt_id is None:
                continue
            if (seen % nshard) != shard:
                seen += 1
                continue
            seen += 1
            if already_done(yt_id, args.output_dir):
                skipped += 1
                continue
            work.put(yt_id)
            queued += 1
    total = queued

    tag = f"shard {shard}/{nshard}"
    skip_note = f" (skipped {skipped:,} done)" if skipped else ""
    print(f">> {tag}: {total:,} ids queued{skip_note} | threads={args.threads} "
          f"limit={args.limit} block-budget={args.block_budget} format={fmt}",
          flush=True)

    # Per-shard tab-separated progress log (id, status). Not a skip marker — that
    # lives under logs/<id[:2]>/ and is written only for permanent failures.
    progress_log = open(os.path.join(log_dir, f"shard{shard}.tsv"),
                        "a", encoding="utf-8")
    logger = csv.writer(progress_log, delimiter="\t")

    stop = threading.Event()           # set when the batch should end (limit/budget)
    lock = threading.Lock()
    state = {
        "downloaded": 0,               # successful network downloads this batch
        "blocks": 0,                   # per-IP blocks this batch
        "done": 0,                     # terminal ids (not re-queued)
        "retries": 0,                  # block re-queues
    }
    counts = {}                        # status -> count, for the summary
    attempts = {}                      # yt_id -> block-retry attempts
    t0 = time.monotonic()

    def record(yt_id, status, terminal):
        with lock:
            logger.writerow((yt_id, status))
            progress_log.flush()
            counts[status] = counts.get(status, 0) + 1
            if terminal:
                state["done"] += 1
                if state["done"] % 50 == 0:
                    el = time.monotonic() - t0
                    rate = state["done"] / (el / 60) if el else 0.0
                    summary = " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
                    print(f"== {tag}: {state['done']:,}/{total:,} done | "
                          f"{rate:.1f}/min | dl={state['downloaded']} "
                          f"blocks={state['blocks']} | {summary}", flush=True)

    def worker():
        while not stop.is_set():
            try:
                yt_id = work.get(timeout=2)
            except queue.Empty:
                # Nothing left to claim — if the queue is drained, exit.
                if work.empty():
                    return
                continue

            _, status = download_one(yt_id, args.output_dir, fmt, archive,
                                     cookies, user_agent)

            if status == "blocked":
                # Per-IP block: re-queue (NO marker). When this IP's block budget
                # is spent, end the batch so the supervisor rotates to a fresh IP.
                with lock:
                    attempts[yt_id] = attempts.get(yt_id, 0) + 1
                    over = attempts[yt_id] > args.max_retries
                    state["blocks"] += 1
                    state["retries"] += 1
                    counts["blocked"] = counts.get("blocked", 0) + 1
                    budget_spent = (args.block_budget > 0
                                    and state["blocks"] >= args.block_budget)
                if over:
                    # Give up on this id for this batch but DON'T mark it: it is a
                    # block, not a permanent failure. It stays in the file and is
                    # retried in a later batch on a fresh IP.
                    record(yt_id, "blocked-gaveup", terminal=True)
                else:
                    work.put(yt_id)
                if budget_spent:
                    stop.set()
                continue

            terminal = True
            record(yt_id, status, terminal=terminal)
            if status == "downloaded":
                with lock:
                    state["downloaded"] += 1
                    if args.limit > 0 and state["downloaded"] >= args.limit:
                        stop.set()      # per-IP budget reached -> supervisor rotates

    threads = [threading.Thread(target=worker, name=f"w{shard}.{i}")
               for i in range(max(1, args.threads))]
    try:
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        stop.set()
        print("\n!! interrupted — fetched ids are saved; re-run to resume.",
              flush=True)
        for thread in threads:
            thread.join(timeout=5)
    finally:
        progress_log.close()

    el = time.monotonic() - t0
    rate = state["done"] / (el / 60) if el else 0.0

    # Exit code:
    #   total == 0           -> nothing left to fetch        -> SHARD COMPLETE (64)
    #   downloaded == 0       -> had work, fetched nothing     -> NO PROGRESS  (75)
    #   else                  -> made progress, ids remain     -> BATCH DONE   (0)
    if total == 0:
        code, reason = EX_SHARD_COMPLETE, "shard complete (nothing left to fetch)"
    elif state["downloaded"] == 0:
        code, reason = EX_NO_PROGRESS, "no downloads this IP (bad/blocked exit)"
    else:
        code, reason = EX_BATCH_DONE, "batch made progress — ids remain"

    summary = " ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "-"
    print(f"\nDone ({reason}). {tag}: {state['done']:,} terminal, "
          f"{state['downloaded']} downloaded, {state['blocks']} blocks in "
          f"{el:.0f}s | {rate:.1f}/min | {summary}", flush=True)
    return code


def build_parser():
    parser = argparse.ArgumentParser(
        description="Per-shard YouTube audio crawler (runs inside a vopono netns; "
                    "never touches the VPN).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("ids_file",
                        help="File of YouTube video IDs OR full URLs, one per line.")
    parser.add_argument("output_dir",
                        help="Output root: audio/, logs/, archive.shard<N>.txt.")
    parser.add_argument("--num-shards", type=int, default=1,
                        help="Total number of shards. This worker handles ids whose "
                             "0-based index among parseable ids satisfies index %% num_shards == shard.")
    parser.add_argument("--shard", type=int, default=0,
                        help="This worker's shard id in [0, num_shards).")
    parser.add_argument("--threads", type=int, default=2,
                        help="Within-worker concurrency per IP (2 is YouTube-safe; "
                             ">2 trips the per-IP detector).")
    parser.add_argument("--limit", type=int, default=0,
                        help="Per-IP budget: end the batch after N successful "
                             "downloads so the supervisor rotates to a fresh IP "
                             "(0 = unlimited).")
    parser.add_argument("--block-budget", type=int, default=0,
                        help="End the batch after N per-IP blocks so the supervisor "
                             "rotates to a fresh IP (0 = unlimited).")
    parser.add_argument("--max-retries", type=int, default=4,
                        help="Max block re-queues for a single id within one batch "
                             "before giving up on it for this batch (no marker).")
    parser.add_argument("--format", default=None,
                        help=f"yt-dlp -f format selector (default: {DEFAULT_FORMAT}).")
    parser.add_argument("--cookies", default=None,
                        help="Path to a cookies.txt (bypasses many age/bot gates).")
    parser.add_argument("--user-agent", default=None,
                        help="Override the HTTP User-Agent.")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.num_shards < 1:
        parser.error(f"--num-shards must be >= 1 (got {args.num_shards})")
    if not (0 <= args.shard < args.num_shards):
        parser.error(f"--shard {args.shard} out of range for "
                     f"--num-shards {args.num_shards}")
    if not os.path.exists(args.ids_file):
        print(f"ERROR: ids file not found: {args.ids_file}", file=sys.stderr)
        return EX_NO_PROGRESS
    os.makedirs(args.output_dir, exist_ok=True)
    return crawl(args)


if __name__ == "__main__":
    sys.exit(main())
