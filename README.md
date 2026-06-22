# youtube-parallel-crawl-nordvpn

Crawl **many** YouTube videos (audio + metadata, via `yt-dlp`) **in parallel**,
where **each worker exits through a different NordVPN IP in a different country**,
inside per-app network namespaces — so the **host's own connection (SSH, your
agent, everything else) never goes through the VPN**.

This is the configuration that survives YouTube's anti-bot defenses at scale. It
was hardened over a real multi-day run; the [Troubleshooting](#troubleshooting)
section documents the four non-obvious walls that cost the most time so you don't
have to re-derive them.

> 한국어 문서: [README.ko.md](README.ko.md)

```
                          host default route  ─────────────►  your real ISP IP
                          (SSH / agent / apt — NEVER on VPN)
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  crawl.sh  (supervisor, runs as root for netns, downloads stay user-owned) │
  │                                                                            │
  │   worker 0 ─ vopono netns ─ WireGuard ─► south_korea  ─► exit IP  /16  #1  │
  │   worker 1 ─ vopono netns ─ WireGuard ─► japan        ─► exit IP  /16  #2  │
  │   worker 2 ─ vopono netns ─ WireGuard ─► singapore    ─► exit IP  /16  #3  │
  │   …          (one DISTINCT country per worker)                  …          │
  │                                                                            │
  │   ids.txt ── split by index % WORKERS ──► disjoint shards (no coordination)│
  │   each worker: yt-dlp audio+meta → output/audio/<id[:2]>/<id>.{m4a,meta}    │
  └──────────────────────────────────────────────────────────────────────────┘
```

---

## What it does

- Reads a flat list of YouTube **video IDs or full URLs** (`ids.txt`, one per line).
- Splits the work into `WORKERS` disjoint shards by `index % WORKERS` — no
  inter-worker coordination, fully resumable.
- Runs each shard in its **own [vopono](https://github.com/jamesmcm/vopono)
  network namespace**, leasing one exit IP from a **shared pool** of all servers
  across `COUNTRIES`.
- The **lease allocator** gives four guarantees: no two workers ever hold the
  **same IP** at once; the live IPs stay in **distinct countries** (so they sit in
  `WORKERS` different `/16` ranges); a just-released IP is **not reused
  back-to-back**; and an IP that trips YouTube's *"not a bot"* check goes
  **dormant ~30 min** before it can be leased again.
- Downloads audio + a `.meta` sidecar per video with `yt-dlp`, classifying every
  failure (block / permanent / transient) so retries and IP rotations are correct.
- Leases a **fresh IP each batch** (after `LIMIT` successful downloads), and uses
  `--dns` so the in-namespace resolver doesn't choke under `WORKERS` parallel
  namespaces.
- The **host stays off the VPN entirely**. Only the worker namespaces are tunneled.

## Why per-worker distinct IPs, and why the host stays clean

Two design decisions are load-bearing:

1. **One distinct country per worker.** A VPN provider's per-country servers
   cluster into just a few `/24`s. Stack `WORKERS` workers on one `/24` and
   YouTube's **subnet-level** bot detection flags the whole block (~86% "Sign in
   to confirm you're not a bot"). The *same* IPs used one-at-a-time are fine
   (~1.5%). The fix is address **diversity**, not rotation frequency: spread
   workers across countries so each live IP is in its own `/16`.

2. **WireGuard, not OpenVPN.** OpenVPN re-authenticates on every connection;
   NordVPN rate-limits auth, so `WORKERS` parallel workers reconnecting trigger a
   retry cascade that collapses the whole fleet (~8 minutes in, in the reference
   run). WireGuard uses a **static key — no per-connection auth — nothing to
   throttle.**

And because each worker lives in its own namespace, the **host default route is
never modified**. Your SSH session, your agent, `apt`, and every other process on
the box keep their normal, non-VPN connection. That is the whole point of using
`vopono` instead of a system-wide VPN.

---

## Requirements

- **Linux** with `sudo`/root (network namespaces require root).
- A **NordVPN account** (any standard plan; up to 10 simultaneous connections).
- `bash`, `curl`, Python 3 (for the `yt-dlp` venv). The installer pulls
  `wireguard-tools`, `openvpn`, `iproute2`, and `vopono` for you.
- **No API token is needed** — see the [FAQ](#faq).

---

## Quickstart

```bash
# 1. Clone and install vopono + deps (one-time, needs root)
git clone <this-repo> youtube-parallel-crawl-nordvpn
cd youtube-parallel-crawl-nordvpn
./bin/install.sh

# 2. Sync your NordVPN credentials into vopono (YOU run this; enter your
#    NordVPN *service* credentials, found in the Nord dashboard)
vopono sync nordvpn

# 3. Configure
cp config.example.env config.env
$EDITOR config.env          # set COUNTRIES, WORKERS, OUTPUT_DIR, etc.

# 4. Put the work in place — one video ID or URL per line
$EDITOR ids.txt             # (see examples/ids.example.txt)

# 5. Build the server pool + WireGuard configs + AppArmor fix (needs root)
./bin/setup.sh

# 6. Make sure the HOST is off the VPN (this tool only tunnels the workers)
nordvpn disconnect && nordvpn set killswitch off

# 7. Crawl. (self-elevates via sudo once; downloads stay owned by you)
./crawl.sh

# 8. Watch it
./bin/status.sh
```

Steady-state from the reference run: **~86–96 downloads/min, 0 auth failures, 0
bot-detection, no fleet collapse.** (The OpenVPN + single-country setup collapsed
at ~8 minutes with ~86% bot-detection — that is exactly what this design avoids.)

---

## Configuration

Everything lives in `config.env` (copied from `config.example.env`). Any value can
be overridden inline, e.g. `WORKERS=4 ./crawl.sh`.

| Variable | Default | What it does |
| --- | --- | --- |
| `IDS_FILE` | `./ids.txt` | Input list: one YouTube **video ID or full URL** per line. |
| `OUTPUT_DIR` | `./output` | Root for `audio/`, `logs/`, and `archive.shard<N>.txt`. |
| `YTDLP_FORMAT` | `140/bestaudio[ext=m4a]/bestaudio` | `yt-dlp -f` format selector. |
| `COOKIES_FILE` | *(empty)* | Optional `cookies.txt`; bypasses many age/bot gates. |
| `VPN_PROVIDER` | `nordvpn` | VPN provider (this repo is tuned for NordVPN). |
| `VPN_PROTOCOL` | `wireguard` | `wireguard` (recommended, no auth throttle) or `openvpn`. |
| `VPN_DNS` | `1.1.1.1` | In-namespace resolver (through the tunnel — no leak). The provider's own DNS rate-limits under `WORKERS` parallel namespaces. Empty = vopono default. |
| `COUNTRIES` | `south_korea japan singapore …` | Space-separated countries the shared IP pool draws from. The allocator keeps live IPs in **distinct** countries, so give it **≥ `WORKERS`** entries. Use names as `vopono servers nordvpn` lists them. |
| `WORKERS` | `8` | Parallel workers. **≤ number of `COUNTRIES`** and **≤ 9** (NordVPN's 10-connection cap). |
| `THREADS` | `2` | Within-worker concurrency per IP. `2` is YouTube-safe; `>2` trips the per-IP detector. |
| `LIMIT` | `60` | Successful downloads per IP before rotating to the next server. |
| `BLOCK_BUDGET` | `20` | Per-IP blocks tolerated before ending a batch early; also the 403-count in a batch that marks an IP bot-flagged → dormant. |
| `SETUP_WINDOW` | `8` | Seconds the global setup-lock is held per worker (WireGuard ~5–8; OpenVPN ~20). |
| `STAGGER` | `8` | Seconds between initial worker launches. |
| `SETTLE` | `3` | Base seconds between a teardown and the next spawn (jittered). |
| `MAX_FAILS` | `8` | Consecutive setup failures before a worker aborts its shard. |
| `MIN_SUBSET` | `3` | Warn if a country has fewer than this many dialable servers. |
| `CAP` | `9` | NordVPN simultaneous-connection ceiling to honor. |
| `AUTH_COOLDOWN` | `150` | OpenVPN only: global fleet pause (s) when auth throttling is detected. |
| `COOLDOWN_MIN` | `30` | Minutes a bot-flagged IP stays **dormant** before it can be leased again. |
| `RECENT_SEC` | `180` | Seconds a just-released IP is held out (no back-to-back reuse). |
| `LEASE_TTL` | `1800` | Seconds after which an abandoned lease (crashed worker) is reclaimed. |
| `BOT_FLAG_THRESHOLD` | `3` | `not a bot` hits within one batch that flag the IP → dormant. |
| `POOL_FILE` | `./servers.txt` | Generated server pool (written by `setup.sh`). |
| `WG_DIR` | `/etc/wireguard/nordwg` | Generated per-server WireGuard configs (root-owned). |
| `VENV` | `./.venv` | Python venv holding `yt-dlp`. |

---

## How it works

**Per-app network-namespace isolation.** Each worker is a single `vopono exec`
that builds its own network namespace + veth pair, brings up a tunnel inside it,
and runs the crawler there. The **host's routing table is never touched** — only
the namespace sees the VPN. `vopono` runs as root (netns requires it) but with
`--user $RUN_USER` so the downloaded files stay owned by you, and `crawl.sh`
forwards `HOME` so `vopono` finds the config you synced.

**Shared IP pool with leasing.** All dialable servers across `COUNTRIES` form one
pool. Each batch a worker **leases** a server under a `flock`'d lock that enforces:
*(1)* **no duplicate IPs** — a leased server is excluded from every other worker,
so the `WORKERS` live IPs are always distinct; *(2)* **distinct ranges** — the
allocator prefers a server whose country no live worker holds, keeping the live
IPs in `WORKERS` different `/16`s (the diversity that defeats subnet-level bot
detection); *(3)* **no back-to-back reuse** — a just-released IP is held out for
`RECENT_SEC`; *(4)* **dormancy** — an IP that trips `not a bot`/≥`BLOCK_BUDGET`
403s in a batch is quarantined for `COOLDOWN_MIN` minutes and never handed back
early. A crashed worker's lease is reclaimed after `LEASE_TTL` so the pool never
shrinks. (This replaced naive per-worker country pinning, which couldn't quarantine
a burned IP or guarantee no two workers shared a range.)

**Sharding.** The id list is split by `index % WORKERS`; worker `i` processes
only the lines where `index % WORKERS == i`. No locking, no coordination.
Resume is on-disk: an already-downloaded `audio/<id[:2]>/<id>.<ext>` or a
permanent-fail marker prunes that id from the work set on the next batch. A shard
is "complete" only when its **pruned work set is empty** (every id downloaded or
permanently marked), not merely when one batch drained.

**WireGuard configs without a token.** `vopono` cannot `sync` NordVPN WireGuard,
so `setup.sh` builds the configs by hand: it reads the account's already-registered
WireGuard private key from the host (`wg show nordlynx private-key`) and pulls each
server's **public** key + endpoint from NordVPN's **public** API
(`api.nordvpn.com/v1/servers`). Each generated config in `WG_DIR` is fed to
`vopono exec --custom`. WireGuard's static key means there is **no per-connection
auth to throttle** — which is what keeps the fleet from collapsing.

**Serialized setup, parallel download.** `vopono`'s startup is *not* concurrency-
safe (it races on NetworkManager's shared `unmanaged.conf`). So `crawl.sh` holds a
global `flock` for `SETUP_WINDOW` seconds per worker — just long enough to build
the namespace — then releases it so the long downloads run fully in parallel.
Initial launches are staggered by `STAGGER`; relaunches are jittered.

**Output layout**

```
$OUTPUT_DIR/
  audio/<id[:2]>/<id>.<ext>      # the audio file
  audio/<id[:2]>/<id>.meta       # yt-dlp metadata sidecar
  logs/<id[:2]>/<id>.log         # permanent-fail markers ONLY
  logs/parallel/worker<i>.out    # per-worker supervisor log
  archive.shard<N>.txt           # per-shard yt-dlp archive (resume)
```

**Failure classification** (so rotations/retries are correct):

| Class | Examples | Action |
| --- | --- | --- |
| **block** | `429`, `403`, `not a bot`*, `Please sign in` | re-queue on a fresh IP, **no marker** |
| **permanent** | `Video unavailable`, `Private`, `removed by the uploader`, `who has blocked it` (copyright), `Sign in to confirm your age`, account terminated | write a **skip marker**, never retry |
| **transient** | HTTP 5xx, timeouts, `Network unreachable` | retry, **no marker** |

\* yt-dlp prints a **curly apostrophe** in "you're not a bot", so the matcher keys
on the substring **`not a bot`** and never on `you're`.

**Crawler exit codes**: `64` = shard complete (pruned work set empty), `0` = batch
made progress, `75` = batch downloaded nothing (rotate IP).

---

## Monitoring

- **`./bin/status.sh`** — running state: active workers, current rate, totals.
  Note it counts `vopono exec` processes; with WireGuard the kernel `wg` module
  handles the tunnel, so seeing zero `openvpn` processes is normal.
- **`./bin/watch.sh`** — prints a quiet `OK` when healthy and emits
  `COLLAPSE` / `CRASHED` / `FINISHED` on a new-abort spike, returning auth
  failures, a rate stall (< ~10/min while running), or a dead supervisor. Drive it
  from a short cron and alert only on non-`OK`.
- **`./bin/verify.sh`** — acceptance check before the long run: confirms the host
  egress IP is your real ISP IP (no leak), and that each worker namespace gets a
  **distinct** exit IP, different from the host.

After any crash or hard-kill, run **`./bin/cleanup.sh`** *before* restarting —
stale veth pairs / netns / NetworkManager state will make a fresh `vopono` panic.

---

## Recover region-locked failures (retry from a different region)

Some videos aren't gone — they're **region-locked** (`This video is not available
in your country` / `blocked it in your country`). When the crawl ran from regions
A they failed and got a permanent skip-marker, but a **different region's** exit IP
can usually fetch them. `bin/retry-region.sh` automates a one-pass recovery:

```bash
# 1. Select the region-recoverable failures, clear their skip-markers, write the list.
#    (Skips the genuinely-gone: deleted / private / terminated / global copyright /
#     age-gated / members-only — a different region can't help those.)
./bin/retry-region.sh                 # region-locks + ambiguous "unavailable"
./bin/retry-region.sh --strict        # ONLY explicit "...in your country" (high-confidence)
./bin/retry-region.sh --dry-run       # just print the breakdown; change nothing

# 2. It prints the exact two commands — build the pool for NEW regions, then retry:
COUNTRIES="united_states united_kingdom canada germany france brazil australia japan" sudo bin/setup.sh
IDS_FILE="$OUTPUT_DIR/retry_region.txt" COUNTRIES="united_states united_kingdom …" ./crawl.sh
```

Pick regions geographically *different* from your first run (e.g. crawled from Asia
→ retry from the Americas/Europe) so a video locked out of the originals is likely
available in at least one. Recovered videos land in `audio/` as usual; any that
fail again get a fresh skip-marker, and already-downloaded ids are skipped. In a
real run this recovered ~7% of the "failed" set (the region-locked slice).

---

## Troubleshooting

The four walls, by symptom:

| Symptom | Cause | Fix |
| --- | --- | --- |
| **~86% "Sign in to confirm you're not a bot"** | All workers concentrated on one provider `/24` → YouTube's subnet-level bot detection flags the whole block. | **Multi-country**: one distinct country per worker (`COUNTRIES` ≥ `WORKERS`). Diversity beats rotation frequency. |
| **Runs fast, then the whole fleet collapses to ~0** (OpenVPN) | Per-connection OpenVPN auth + NordVPN auth rate-limit + parallel reconnect churn → retry cascade. | **Switch to `VPN_PROTOCOL=wireguard`** (static key, no auth). Don't tune OpenVPN; this is architecture, not parameters. |
| **Workers ABORT on simultaneous start** (`Failed to create veth pair`, `RTNETLINK: File exists`, `unmanaged.conf … NotFound`) | Concurrent `vopono` startup races on NetworkManager's shared `unmanaged.conf`; or stale state from a previous hard-kill. | The **setup-lock** + `STAGGER` already serialize startup. After a crash, run **`./bin/cleanup.sh`** to clear stale veths/netns/NM before restarting. |
| **WireGuard: `fopen: Permission denied` / silent NO_HANDSHAKE** | **AppArmor**'s `wg` profile blocks reading `vopono`'s temp config from `/tmp`. Confirm: `dmesg \| grep -i 'apparmor.*DENIED.*wg'`. | `setup.sh` adds `/tmp/vopono*.conf r,` to `/etc/apparmor.d/local/wg` and reloads the profile. Re-run `./bin/setup.sh` if you skipped it. |
| **Ran fine for ~1h, then ALL tunnels go dead** (`wg show` = `0 B received` / `handshake=NONE` on every server, but the host can ICMP the endpoint) | NordVPN **rate-limited this account's WireGuard handshakes** — too many handshakes to too many distinct servers (heavy rotation), often kicked off by a *dead-tunnel rotation storm* that then keeps the limit tripped. | **Stop the fleet ~1–2 min** so the limit resets, then restart. Built-in defense: the `CONN_RE` **connectivity-aware exponential backoff** stops the storm (workers wait the outage out instead of hammering). Reduce baseline handshakes with a **higher `LIMIT`** (fewer rotations) if it recurs. |

Other quick checks:

- **Worker can't get an IP / aborts immediately** — is the **host off the VPN**?
  Run `nordvpn disconnect && nordvpn set killswitch off`. A host killswitch blocks
  the namespaces.
- **`W exceeds the NordVPN connection cap`** — keep `WORKERS ≤ 9`; NordVPN allows
  10 simultaneous connections and you want headroom.
- **`0 server tokens` from setup** — did `vopono sync nordvpn` finish? Check
  `vopono servers nordvpn | grep -i <country>`.

---

## OpenVPN vs. WireGuard

| | **WireGuard** (default) | **OpenVPN** |
| --- | --- | --- |
| Per-connection auth | **None** (static key) | Yes (every connect) |
| NordVPN auth throttle | Not affected | Collapses the fleet under parallel churn |
| Setup time per worker | ~5–8 s | ~20 s |
| Config source | Hand-built from the public API (no token) | `vopono sync nordvpn` |
| Recommendation | **Use this.** | Only if WireGuard is unavailable; relies on the `AUTH_COOLDOWN` circuit-breaker and still hits a ceiling under sustained load. |

Set the choice with `VPN_PROTOCOL` in `config.env`.

---

## FAQ

**Do I need a NordVPN API token?** No. The WireGuard private key is already on the
host once you've connected the NordVPN app/CLI at least once
(`wg show nordlynx private-key`), and every server's public key + endpoint come
from the **public** API `api.nordvpn.com/v1/servers`. OpenVPN configs come from
`vopono sync nordvpn`, which uses your normal NordVPN **service** credentials.

**Why does the host need to be off the VPN?** Because the whole design tunnels
*only the worker namespaces*. If the host itself is on a VPN (or has a killswitch
on), it interferes with the namespaces and defeats the "host stays clean" goal.

**Can I run more than ~10 workers?** Not on NordVPN — its 10-connection cap is
hard, so `WORKERS ≤ 9`. Beyond a handful of clean isolated IPs, switch to a
**rotating residential/datacenter proxy pool**; `vopono` is the right tool for "a
few clean isolated IPs," a proxy pool for hundreds.

**Can I target something other than YouTube?** The isolation + diversity +
failure-classification skeleton is reusable. Swap the `yt-dlp` invocation and the
block/permanent/transient string matches in `crawler/crawler.py`.

### Failure scenarios (what each looks like, and what to do)

These are the walls you actually hit at scale, in the order they tend to appear.
The defenses below are all built in — this is for understanding *why* throughput
moves the way it does.

**Throughput was high, then ALL tunnels die at once (`wg show` → `0 B received`,
`handshake=NONE` on every server) — but the host can still ping the endpoint.**
This is the big one. NordVPN **rate-limited your account's WireGuard handshakes**.
The shared pool deliberately spreads across many distinct servers for IP
diversity, and that means *many distinct handshakes* — and once a few tunnels go
dead, workers rotate faster and faster trying to find a live one (a "rotation
storm" — we measured ~32 distinct servers in 5 minutes), which is exactly the
pattern NordVPN throttles, so it stays tripped at 0. Defenses, all built in:
(1) **`PER_COUNTRY_CAP`** bounds the pool to N servers per country (default 15 →
~100 total instead of 400+), so the fleet re-uses IPs and emits far fewer distinct
handshakes — the limit is hit *much* less often; (2) the crawler's **dead-exit
circuit breaker** (`--max-consec-fail`) ends a batch after a run of consecutive
failures with zero downloads — a dead tunnel fails every id with `name resolution`,
which is *not* a "block", so without this the batch would grind the whole shard at
0 and the backoff below would never even get to fire; (3) the **`CONN_RE`
connectivity-aware exponential backoff** then backs off up to 120 s instead of
rotating, so the fleet quiets down, the limit resets, and it **self-heals**;
(4) raise **`LIMIT`** (more downloads per IP → fewer handshakes). If you're
impatient, stop the fleet for 1–2 minutes and restart.

**Downloads crawl, logs full of `Temporary failure in name resolution`.** The
provider's own DNS rate-limits under `WORKERS` parallel namespaces. Set
**`VPN_DNS=1.1.1.1`** (or `8.8.8.8`) — it's queried *through* the tunnel, so the
exit IP is unchanged and nothing leaks. (Distinct from the handshake rate-limit
above: there the *tunnel* is dead; here the tunnel is up but DNS is throttled.)

**`Sign in to confirm you're not a bot` on most requests.** Subnet-level
detection: too many workers in one provider `/24`. Spread across more
`COUNTRIES` — the allocator keeps the live IPs in distinct ranges. **Diversity
beats rotation frequency.**

**Still seeing `VPN/Proxy Detected` / occasional bot blocks even with diverse,
rotating IPs — can I get to zero?** Not with a commercial VPN: NordVPN's ranges
are *known* datacenter IPs, so YouTube flags a fraction no matter how you rotate.
The **dormancy** mechanism quarantines the worst offenders for `COOLDOWN_MIN`, so
throughput recovers, but a low background level remains. The only way to ~zero is
**authenticated requests**: set `COOKIES_FILE` to a `cookies.txt` exported from a
logged-in session (use a throwaway account — heavy automated use can flag it).

**The whole fleet collapsed to ~0 and the logs say `authentication failed`
(OpenVPN).** OpenVPN's per-connection auth gets rate-limited under parallel
reconnect churn → retry cascade. Don't tune OpenVPN — **use
`VPN_PROTOCOL=wireguard`** (static key, no per-connection auth). This is
architecture, not parameters.

**Two workers seem to be on the same IP or same country.** They shouldn't be —
the `flock`'d lease excludes a server from every other worker and prefers an
unused country. If you see it, you have fewer dialable servers than `WORKERS`
(check `bin/verify.sh`) or `COUNTRIES < WORKERS`.

**A shard logged `STUCK` / a worker exited — did I lose data?** No. Everything is
resumable from disk: a downloaded file or a permanent-fail marker prunes that id
on the next run. `STUCK` means that shard cycled many fresh IPs with zero
progress, so its *remaining* ids look genuinely non-downloadable (private/removed/
age-gated). Just re-run `./crawl.sh` to retry the rest.

**How do I trade throughput against getting blocked?** `LIMIT` is the main dial:
**higher** = fewer WireGuard handshakes (safer for NordVPN) but more downloads per
IP (more YouTube per-IP exposure); **lower** = the reverse. `BLOCK_BUDGET` caps how
many blocks an IP absorbs before its batch ends early (and, at that count, marks it
dormant). Keep `THREADS=2` — `>2` trips YouTube's *per-IP* concurrency detector.

---

## Use as a Claude Code skill

This repo ships with an [Agent Skill](https://agentskills.io) — the open, portable
skill format used by Claude Code, the Claude apps, and the Claude Agent SDK — at
`.claude/skills/youtube-parallel-crawl-nordvpn/SKILL.md`. It encodes the operating
playbook and the four hard-won walls so an agent works from the proven config
instead of re-deriving them.

**Two ways to install it:**

```bash
# A) Project skill (auto-discovered) — just work inside the cloned repo:
git clone https://github.com/sakemin/youtube-parallel-crawl-nordvpn
cd youtube-parallel-crawl-nordvpn
claude          # Claude Code auto-discovers .claude/skills/ for this project.
                # (If .claude/skills/ did not exist when Claude Code started, restart it.)

# B) Personal skill (global) — available in every project:
mkdir -p ~/.claude/skills/youtube-parallel-crawl-nordvpn
cp .claude/skills/youtube-parallel-crawl-nordvpn/SKILL.md \
   ~/.claude/skills/youtube-parallel-crawl-nordvpn/
# then restart Claude Code / start a new session
```

It auto-activates when you ask about parallel YouTube crawling, per-worker VPN
IPs, or YouTube bot-detection / 429 / 403 at scale. Being an open Agent Skill, the
same `SKILL.md` also works on claude.ai and via the Agent SDK.

---

## Credits

Built with [Claude Code](https://claude.com/claude-code) (Anthropic), hardened
over a real multi-day crawl. The four walls documented above were debugged the
hard way so you don't have to.

See [README.ko.md](README.ko.md) for the Korean-language version.
</content>
</invoke>
