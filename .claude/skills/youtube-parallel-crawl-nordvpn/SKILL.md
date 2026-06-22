---
name: youtube-parallel-crawl-nordvpn
description: Use when crawling/downloading many YouTube videos (audio/metadata via yt-dlp) IN PARALLEL through a VPN with a DIFFERENT exit IP per worker, or hitting YouTube "Sign in to confirm you're not a bot" / 429 / 403 at scale, or wanting per-app VPN isolation so the host (SSH/agent) stays off the VPN. This repo IS the working reference implementation (NordVPN + vopono + per-worker WireGuard IP rotation). It encodes the non-obvious walls: subnet-level bot-detection, OpenVPN auth rate-limiting, vopono/NetworkManager concurrency races, and AppArmor blocking WireGuard.
version: 1.0.0
---

# youtube-parallel-crawl-nordvpn — operating playbook

This repo runs W parallel yt-dlp workers, each inside its own vopono network
namespace bound to a server in a DISTINCT country (= distinct exit IP / /16), so
the **host default route is never touched** (SSH / the agent stay on the real
connection). Built and hardened over a real multi-day run; start from the working
config and don't re-derive the four walls below.

## Two load-bearing decisions (already the defaults)
1. **WireGuard, not OpenVPN.** OpenVPN re-auths every connection; NordVPN
   rate-limits auth, so W parallel workers + frequent reconnects cascade into a
   fleet collapse (~8 min in). WireGuard's static key has **no per-connection auth
   — nothing to throttle.**
2. **One distinct COUNTRY per worker.** A provider's per-country servers cluster
   in a few /24s; W workers on one /24 trip YouTube's **subnet-level** bot
   detection (~86% "not a bot"). Spread workers across countries.

## Quickstart (from a fresh clone)
```bash
git clone <repo> && cd youtube-parallel-crawl-nordvpn
sudo ./bin/install.sh                     # vopono(.deb) + wireguard-tools + python venv + yt-dlp
vopono sync nordvpn                        # one-time: NordVPN service credentials
cp config.example.env config.env           # then edit (COUNTRIES, IDS_FILE, OUTPUT_DIR, ...)
printf '%s\n' VIDEO_ID_OR_URL ... > ids.txt # what to crawl
sudo ./bin/setup.sh                        # build server pool + AppArmor fix + WireGuard configs
nordvpn disconnect && nordvpn set killswitch off   # host MUST be off the VPN
./bin/verify.sh                            # optional: host clean + distinct per-worker IPs
./crawl.sh                                 # run (self-elevates via sudo once)
./bin/status.sh                            # running / active workers / rate / totals
```
Config knobs (all in `config.env`, overridable inline e.g. `WORKERS=4 ./crawl.sh`):
`VPN_PROTOCOL` (wireguard|openvpn), `COUNTRIES` (one distinct per worker),
`WORKERS`, `THREADS` (2 = YouTube-safe), `LIMIT` (downloads/IP before rotating),
`BLOCK_BUDGET`, `SETUP_WINDOW`, `IDS_FILE`, `OUTPUT_DIR`, `YTDLP_FORMAT`, `COOKIES_FILE`.

## The four walls (symptom → cause → fix)
1. **~86% "not a bot"** → W workers concentrated on one provider /24 (NordVPN KR =
   only 5 /24s). FIX: multi-country `COUNTRIES`, one distinct country per worker.
   Lesson: datacenter-IP blocking is about address **diversity**, not rotation
   *frequency*.
2. **Runs fast then the fleet collapses to ~0** (OpenVPN `authentication failed`
   cascade, ~43 auth/min mostly retries) → NordVPN auth rate-limit. FIX: WireGuard
   (`VPN_PROTOCOL=wireguard`). OpenVPN band-aid only: the auth circuit-breaker in
   `crawl.sh` (`AUTH_COOLDOWN`). Lesson: some bottlenecks are architecture, not params.
3. **8 workers ABORT on simultaneous start** (`Failed to restore backup of
   NetworkManager unmanaged.conf`, `RTNETLINK: File exists`) → concurrent vopono
   race on the shared `unmanaged.conf`. FIX: the setup-lock (`SETUP_WINDOW`) +
   stagger + jitter in `crawl.sh`; `bin/cleanup.sh` clears stale `vo_nd_*` state.
4. **WireGuard `Error: Wireguard not implemented` / `fopen: Permission denied` /
   NO_HANDSHAKE** → (a) vopono can't *sync* NordVPN WG → use `vopono exec --custom`;
   (b) **AppArmor** `wg` profile blocks reading vopono's `/tmp` config. FIX:
   `bin/setup.sh` adds `/tmp/vopono*.conf r,` to `/etc/apparmor.d/local/wg`.
   **No token:** the WG private key is the host's `sudo wg show nordlynx private-key`;
   server pubkeys/endpoints come from the public `api.nordvpn.com/v1/servers`
   (`wireguard_udp` metadata `public_key`; `Endpoint station:51820`; `Address 10.5.0.2/32`).

## yt-dlp failure handling (in crawler/crawler.py)
- **block** (retry on a fresh IP, NO marker): `429`, `403`, `not a bot` (match the
  substring `not a bot` — yt-dlp prints a CURLY apostrophe in `you're`, never match
  `you're`), `Please sign in`.
- **permanent** (write skip-marker): `Video unavailable`, `Private video`, `removed
  by the uploader`, `who has blocked it` (copyright), `Sign in to confirm your age`
  (age gate ≠ bot), account terminated.
- **transient** (retry, no marker): HTTP 5xx, timeouts, network unreachable.
- Shard "complete" (crawler exit 64) = the pruned work set is EMPTY; exit 0 = batch
  progress; exit 75 = no downloads on this IP. The supervisor owns IP rotation.

## Monitoring & recovery
- `bin/status.sh` — running / active workers (counts `vopono exec`, NOT openvpn —
  WireGuard uses kernel `wg`) / rate / totals.
- `bin/watch.sh` — prints `OK` when healthy, `COLLAPSE/CRASHED/FINISHED` otherwise
  (new-abort spike, returning auth-failures, rate stall, dead supervisor); drive
  from a short cron, notify only on non-OK. It reads `$OUTPUT_DIR/crawl.out` (the
  supervisor lifecycle log) to tell FINISHED from CRASHED.
- After any crash/hard-kill: `sudo ./bin/cleanup.sh` BEFORE re-running (stale
  veths/NetworkManager state makes new vopono panic).
- `bin/retry-region.sh` — recover REGION-LOCKED failures from a DIFFERENT region.
  Selects failures whose marker is region-recoverable ("...in your country" /
  "blocked it in your country"; `--strict` = explicit only, default also includes
  ambiguous "unavailable"), SKIPS the genuinely-gone (deleted/private/terminated/
  global-copyright/age-gated/members-only), clears those skip-markers, writes
  `retry_region.txt`, and prints: `COUNTRIES="<new diverse regions>" sudo bin/setup.sh`
  then `IDS_FILE=retry_region.txt COUNTRIES="..." ./crawl.sh`. Pick regions
  geographically different from the first run (~7% of "failures" recovered in practice).

## vopono gotchas (0.10.x)
- The application is ONE shell-split argument: `vopono exec ... "yt-dlp -x URL"`,
  NOT `-- yt-dlp -x URL`. Run vopono as root with `--user <you>` so output stays
  user-owned; forward `HOME` so it finds `~/.config/vopono`. NordVPN cap = 10
  simultaneous connections → keep `WORKERS ≤ 9` (`CAP`).

## Adapting
- Different VPN/target: keep the skeleton (per-app netns isolation + distinct-range
  workers + a static-key protocol + the failure classification); swap the downloader
  and the block/permanent/transient string matches. Beyond ~10 IPs, NordVPN's cap is
  hard — switch to a rotating residential/datacenter proxy pool.
