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
  network namespace**, pinned to its **own country**, so the live exit IPs sit in
  `WORKERS` different `/16` ranges.
- Downloads audio + a `.meta` sidecar per video with `yt-dlp`, classifying every
  failure (block / permanent / transient) so retries and IP rotations are correct.
- Rotates each worker to a fresh server **within its own country** after `LIMIT`
  successful downloads — a new IP, same clean range.
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
| `COUNTRIES` | `south_korea japan singapore …` | Space-separated, **one distinct country per worker**. Use names as `vopono servers nordvpn` lists them. Must have **≥ `WORKERS`** entries. |
| `WORKERS` | `8` | Parallel workers. **≤ number of `COUNTRIES`** and **≤ 9** (NordVPN's 10-connection cap). |
| `THREADS` | `2` | Within-worker concurrency per IP. `2` is YouTube-safe; `>2` trips the per-IP detector. |
| `LIMIT` | `60` | Successful downloads per IP before rotating to the next server. |
| `BLOCK_BUDGET` | `20` | Per-IP blocks tolerated before ending a batch early (most 403s are transient). |
| `SETUP_WINDOW` | `8` | Seconds the global setup-lock is held per worker (WireGuard ~5–8; OpenVPN ~20). |
| `STAGGER` | `8` | Seconds between initial worker launches. |
| `SETTLE` | `3` | Base seconds between a teardown and the next spawn (jittered). |
| `MAX_FAILS` | `8` | Consecutive setup failures before a worker aborts its shard. |
| `MIN_SUBSET` | `3` | Minimum distinct servers a worker must cycle before reusing an IP. |
| `CAP` | `9` | NordVPN simultaneous-connection ceiling to honor. |
| `AUTH_COOLDOWN` | `150` | OpenVPN only: global fleet pause (s) when auth throttling is detected. |
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

**Country pinning.** Worker `i` is pinned to `COUNTRIES[i]` and rotates **only
within that country's servers**. So the `WORKERS` live IPs are always in
`WORKERS` distinct ranges — the diversity that defeats subnet-level bot detection.

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

## Troubleshooting

The four walls, by symptom:

| Symptom | Cause | Fix |
| --- | --- | --- |
| **~86% "Sign in to confirm you're not a bot"** | All workers concentrated on one provider `/24` → YouTube's subnet-level bot detection flags the whole block. | **Multi-country**: one distinct country per worker (`COUNTRIES` ≥ `WORKERS`). Diversity beats rotation frequency. |
| **Runs fast, then the whole fleet collapses to ~0** (OpenVPN) | Per-connection OpenVPN auth + NordVPN auth rate-limit + parallel reconnect churn → retry cascade. | **Switch to `VPN_PROTOCOL=wireguard`** (static key, no auth). Don't tune OpenVPN; this is architecture, not parameters. |
| **Workers ABORT on simultaneous start** (`Failed to create veth pair`, `RTNETLINK: File exists`, `unmanaged.conf … NotFound`) | Concurrent `vopono` startup races on NetworkManager's shared `unmanaged.conf`; or stale state from a previous hard-kill. | The **setup-lock** + `STAGGER` already serialize startup. After a crash, run **`./bin/cleanup.sh`** to clear stale veths/netns/NM before restarting. |
| **WireGuard: `fopen: Permission denied` / silent NO_HANDSHAKE** | **AppArmor**'s `wg` profile blocks reading `vopono`'s temp config from `/tmp`. Confirm: `dmesg \| grep -i 'apparmor.*DENIED.*wg'`. | `setup.sh` adds `/tmp/vopono*.conf r,` to `/etc/apparmor.d/local/wg` and reloads the profile. Re-run `./bin/setup.sh` if you skipped it. |

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

---

## Credits

Built with [Claude Code](https://claude.com/claude-code) (Anthropic), hardened
over a real multi-day crawl. The four walls documented above were debugged the
hard way so you don't have to.

See [README.ko.md](README.ko.md) for the Korean-language version.
</content>
</invoke>
