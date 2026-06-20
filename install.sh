#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# PINMON · GPU Monitor — One-step installer for Ubuntu/Debian

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()     { echo -e "${GREEN}►${NC} $*"; }
warn()     { echo -e "${YELLOW}⚠${NC} $*"; }
err()      { echo -e "${RED}✗${NC} $*" >&2; }
check_cmd() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# 0. Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]] && ! check_cmd sudo; then
    err "This script requires either root or `sudo`."
    exit 1
fi

need_sudo=()
for cmd in go make apt; do
    if check_cmd "$cmd"; then continue; fi
    need_sudo+=("$cmd")
done

if [[ ${#need_sudo[@]} -gt 0 ]]; then
    warn "Missing packages: ${need_sudo[*]}"
    info "Installing prerequisites…"
    sudo apt update -qq && sudo apt install -y --no-install-recommends \
        "${need_sudo[@]}"
fi

if ! check_cmd go; then
    err "Go 1.21+ is required but not found."
    err "Install from https://go.dev/doc/install or use 'sudo snap install go --classic'"
    exit 1
fi

info "Go $(go version | awk '{print $3}')"

# ---------------------------------------------------------------------------
# 1. Build & install `pinmon`
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

info "Building pinmon…"
make

if [[ ! -f bin/pinmon ]]; then
    err "Build failed — no binary at bin/pinmon."
    exit 1
fi

sudo install -m 0755 bin/pinmon /usr/local/bin/pinmon
info "Installed → /usr/local/bin/pinmon"

# ---------------------------------------------------------------------------
# 2. Passwordless sudo rule (idempotent)
# ---------------------------------------------------------------------------
SUDOERS="/etc/sudoers.d/pinmon"
if [[ -f "$SUDOERS" ]]; then
    CURRENT=$(sudo cat "$SUDOERS" 2>/dev/null || echo "")
    EXPECTED="$(whoami) ALL=(root) NOPASSWD: /usr/local/bin/pinmon"
    if [[ "$CURRENT" == "$EXPECTED" ]]; then
        info "sudoers rule already in place — skipping."
    else
        warn "Existing $SUDOERS differs from expected value."
        info "Overwriting with correct rule…"
        echo "$EXPECTED" | sudo tee "$SUDOERS" >/dev/null
        sudo chmod 0440 "$SUDOERS"
        info "Updated."
    fi
else
    echo "$(whoami) ALL=(root) NOPASSWD: /usr/local/bin/pinmon" | sudo tee "$SUDOERS" >/dev/null
    sudo chmod 0440 "$SUDOERS"
    info "sudoers rule created at $SUDOERS"
fi

# ---------------------------------------------------------------------------
# 3. Optional packages (kitty, wmctrl, Wayland extensions)
# ---------------------------------------------------------------------------
OPTIONAL=("kitty")
SESSION="${XDG_SESSION_TYPE:-x11}"

if [[ "$SESSION" == "x11" ]]; then
    OPTIONAL+=("wmctrl")
else
    OPTIONAL+=("gnome-shell-extension-manager" "gnome-shell-extensions")
fi

info "Optional packages for your session ($SESSION): ${OPTIONAL[*]}"
read -rp "  Install them now? [Y/n] " -n1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    warn "Skipping optional packages. You may need to install them manually."
else
    sudo apt update -qq && sudo apt install -y --no-install-recommends "${OPTIONAL[@]}"
fi

# ---------------------------------------------------------------------------
# 4. Done — show usage hint
# ---------------------------------------------------------------------------
echo
info "✓ Installation complete!"
echo
echo "  Run the monitor:  ./pinmon.sh"
echo "  Or directly:      sudo pinmon -t 1s"
echo
if [[ "$SESSION" == "x11" ]]; then
    echo "  ℹ  X11 window placement uses wmctrl."
else
    echo "  ℹ  Wayland needs the GNOME \"Window Calls\" extension:"
    echo "     https://extensions.gnome.org/extension/4724/window-calls/"
fi
