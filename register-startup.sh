#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Register PINMON to run on desktop login.
# Run from the repo root, or pass the full path to pinmon.sh as $1.

set -euo pipefail

PINMON_SH="${1:-$(cd "$(dirname "$0")" && pwd)/pinmon.sh}"

if [[ ! -f "$PINMON_SH" ]]; then
    echo "Error: pinmon.sh not found at $PINMON_SH" >&2
    exit 1
fi

# Ensure it's executable
[[ -x "$PINMON_SH" ]] || chmod +x "$PINMON_SH"

echo "Registering startup autostart for PINMON…"
echo ""

# ---------------------------------------------------------------------------
# 1. XDG Autostart (universally supported by GNOME, KDE, Xfce, etc.)
# ---------------------------------------------------------------------------
AUTOSTART_DIR="$HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_DIR/pinmon.desktop" << EOF
[Desktop Entry]
Type=Application
Name=PINMON GPU Monitor
Comment=Start the PINMON dashboard on login
Exec=$PINMON_SH
Icon=text-x-script
Terminal=false
X-GNOME-Autostart-enabled=true
Hidden=false
Categories=System;Monitor;Utility;
StartupNotify=false
EOF

echo "✓ XDG autostart: $AUTOSTART_DIR/pinmon.desktop"
echo "  → Your desktop environment will launch it automatically on next login."
echo ""

# ---------------------------------------------------------------------------
# 2. Systemd User Service (more robust, survives WM restarts)
# ---------------------------------------------------------------------------
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SYSTEMD_USER_DIR/pinmon.service" << EOF
[Unit]
Description=PINMON GPU Monitor Dashboard
After=graphical-session.target

[Service]
Type=simple
ExecStart=$PINMON_SH
Restart=on-failure
RestartSec=5
Environment=XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-x11}
Environment=DISPLAY=:0

[Install]
WantedBy=default.target
EOF

echo "✓ Systemd user service: $SYSTEMD_USER_DIR/pinmon.service"
echo "  → To enable it:"
echo "    systemctl --user daemon-reload && systemctl --user enable --now pinmon.service"
echo ""

echo "Done. (Both methods installed; XDG autostart handles GUI session launch, systemd adds reliability.)"
