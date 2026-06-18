#!/usr/bin/env bash
#
# install.sh — one-shot installer for youtube-parallel-crawl-nordvpn.
#
# Installs everything a fresh Linux box needs to run the crawl:
#   * runtime deps via apt: wireguard-tools, openvpn, iproute2, curl, ca-certificates
#   * vopono (the per-app VPN netns tool) from the latest amd64 .deb on GitHub
#   * a Python virtualenv at $VENV with yt-dlp (from crawler/requirements.txt)
#
# Root is required for apt/dpkg. If you are not root we self-elevate via sudo,
# forwarding the few env vars the installer understands. The Python venv is then
# (re)owned by the invoking user so day-to-day runs need no root for pip.
#
# Pinning knobs (all optional):
#   VOPONO_DEB_URL=<url>   download this exact .deb instead of resolving "latest"
#   VOPONO_DEB=<path>      install this local .deb (skips all network lookup)
#
# Usage:
#   ./bin/install.sh           # self-elevates with sudo
#   sudo ./bin/install.sh      # already root
#
set -euo pipefail

# --- locate the repo and load the config contract --------------------------
# Derive everything from THIS script's location so the repo is relocatable and
# nothing is hardcoded. config.env (user copy) wins; fall back to the example.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/config.env" 2>/dev/null || source "$REPO/config.example.env"

# VENV from config may be relative (e.g. "./.venv"); resolve it against the repo
# root so it is stable no matter the caller's working directory.
VENV="${VENV:-$REPO/.venv}"
case "$VENV" in
  /*) ;;                         # already absolute
  *)  VENV="$REPO/${VENV#./}" ;; # make ./.venv -> $REPO/.venv
esac

# --- self-elevate (apt/dpkg need root) -------------------------------------
# Remember the real user so we can hand venv ownership back after pip.
RUN_USER="${SUDO_USER:-$(id -un)}"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    echo ">> Re-running with sudo (apt/dpkg need root)..."
    # Forward the optional pin knobs so they survive the privilege boundary.
    exec sudo -E env \
      VOPONO_DEB_URL="${VOPONO_DEB_URL:-}" \
      VOPONO_DEB="${VOPONO_DEB:-}" \
      "$0" "$@"
  fi
  echo "ERROR: must run as root. Try: sudo $0" >&2
  exit 1
fi

# --- 1. runtime dependencies via apt ---------------------------------------
echo ">> Installing runtime deps (wireguard-tools, openvpn, iproute2, curl, ca-certificates)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  wireguard-tools \
  openvpn \
  iproute2 \
  curl \
  ca-certificates \
  python3 \
  python3-venv \
  python3-pip

# --- 2. vopono -------------------------------------------------------------
if command -v vopono >/dev/null 2>&1; then
  echo ">> vopono already installed: $(vopono --version)"
else
  deb="${VOPONO_DEB:-}"
  if [[ -z "$deb" ]]; then
    url="${VOPONO_DEB_URL:-}"
    if [[ -z "$url" ]]; then
      echo ">> Resolving latest vopono amd64 .deb from GitHub releases..."
      api="https://api.github.com/repos/jamesmcm/vopono/releases/latest"
      # `|| true` keeps a SIGPIPE (141) from the grep -m1 short-circuit from
      # aborting the assignment under `set -o pipefail`; the empty-url guard
      # below produces a clear actionable error instead.
      url="$(curl -fsSL "$api" \
        | grep -m1 -oE '"browser_download_url": *"[^"]*amd64\.deb"' \
        | sed -E 's/.*"(https[^"]*)".*/\1/' || true)"
    fi
    [[ -n "$url" ]] || {
      echo "ERROR: could not find an amd64 .deb asset for vopono." >&2
      echo "       Download one manually from" >&2
      echo "         https://github.com/jamesmcm/vopono/releases" >&2
      echo "       then re-run with VOPONO_DEB=/path/to/vopono.deb sudo $0" >&2
      exit 1
    }
    deb="$(mktemp --suffix=.deb)"
    echo ">> Downloading $url"
    curl -fSL "$url" -o "$deb"
  fi
  echo ">> Installing $deb ..."
  # apt handles dependency resolution for a local .deb; the dpkg/-f fallback
  # covers older apt that refuses a path argument.
  apt-get install -y "$deb" \
    || dpkg -i "$deb" \
    || { apt-get -f install -y && dpkg -i "$deb"; }
  echo ">> vopono installed: $(vopono --version)"
fi

# --- 3. Python venv + yt-dlp -----------------------------------------------
echo ">> Creating Python venv at $VENV ..."
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --upgrade pip
req="$REPO/crawler/requirements.txt"
if [[ -f "$req" ]]; then
  echo ">> Installing Python deps from $req ..."
  "$VENV/bin/python" -m pip install -r "$req"
else
  echo ">> WARNING: $req not found; installing yt-dlp directly as a fallback."
  "$VENV/bin/python" -m pip install yt-dlp
fi

# Hand the venv back to the invoking user so later `pip`/runs need no root.
if [[ "$RUN_USER" != "root" ]] && id "$RUN_USER" >/dev/null 2>&1; then
  chown -R "$RUN_USER":"$(id -gn "$RUN_USER")" "$VENV"
fi

echo ">> yt-dlp: $("$VENV/bin/python" -m yt_dlp --version 2>/dev/null || echo '??')"

# --- next steps ------------------------------------------------------------
cat <<EOF

============================================================================
Install complete. Next steps (run as your normal user — the crawl scripts
self-elevate with sudo exactly when they need to):

  1. vopono sync nordvpn      # enter your NordVPN *service* credentials
                              # (Nord dashboard -> "Manual setup" / service creds,
                              #  NOT your account email/password)
  2. ./bin/setup.sh           # build the server pool + WireGuard configs,
                              #  free the host from any VPN, run preflight checks
  3. ./crawl.sh               # start the parallel crawl

Edit config.env (copy it from config.example.env) first to point IDS_FILE at
your id list and to pick COUNTRIES / WORKERS / VPN_PROTOCOL.
============================================================================
EOF
