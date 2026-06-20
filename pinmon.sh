#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Launch pinmon in kitty and pin it, fullscreen, to a chosen monitor.
# ---------------------------------------------------------------------------

TARGET_MONITOR="${TARGET_MONITOR:-HDMI-3}"    # Configurable monitor name/ID
TARGET_W=${TARGET_W:-1728}                    # Fallback width
TARGET_H=${TARGET_H:-3072}                    # Fallback height
FONT_SIZE=${FONT_SIZE:-28}

WM_CLASS="pinmon-monitor"

# Use XDG_RUNTIME_DIR (auto-cleaned on logout) instead of /tmp to prevent stale socket errors
KITTY_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/kitty-pinmon-socket"

# ---------------------------------------------------------------------------
# Dynamically detect the target monitor's position & size from xrandr
# Expected line format: HDMI-3 connected 1728x3072+5120+2880 inverted ...
# ---------------------------------------------------------------------------
MON_INFO=$(xrandr --query 2>/dev/null | grep "${TARGET_MONITOR} connected")
if [ -n "$MON_INFO" ]; then
    # Extract resolution (WIDTHxHEIGHT)
    RES=$(echo "$MON_INFO" | grep -oE '[0-9]+x[0-9]+' | head -1)
    TARGET_W=${RES%%x*}
    TARGET_H=${RES##*x}
    
    # Extract position (+X+Y) safely by splitting on '+' delimiters
    POS=$(echo "$MON_INFO" | grep -oE '\+[0-9]+\+[0-9]+' | head -1)
    TARGET_X=$(echo "$POS" | cut -d'+' -f2)
    TARGET_Y=$(echo "$POS" | cut -d'+' -f3)
    
    echo "[pinmon.sh] Dynamically detected ${TARGET_MONITOR} at +${TARGET_X}+${TARGET_Y} (${TARGET_W}x${TARGET_H})"
else
    echo "[pinmon.sh] ERROR: '${TARGET_MONITOR}' not found in xrandr output." >&2
    exit 1
fi

session="${XDG_SESSION_TYPE:-x11}"
echo "[pinmon.sh] session type: $session -> targeting ${TARGET_X},${TARGET_Y} (${TARGET_W}x${TARGET_H})"

# ---------------------------------------------------------------------------
# X11 path: classic wmctrl move + fullscreen.
# ---------------------------------------------------------------------------
run_x11 () {
    kitty --class "$WM_CLASS" --title "$WM_CLASS" -o font_size=$FONT_SIZE \
          bash -c 'sudo pinmon; echo; echo "[pinmon exited - press enter]"; read' &

    for _ in {1..50}; do
        wmctrl -lx 2>/dev/null | grep -q "${WM_CLASS}\.${WM_CLASS}" && break
        sleep 0.1
    done

    wmctrl -x -r "${WM_CLASS}.${WM_CLASS}" -b remove,maximized_vert,maximized_horz
    wmctrl -x -r "${WM_CLASS}.${WM_CLASS}" -b remove,fullscreen
    wmctrl -x -r "${WM_CLASS}.${WM_CLASS}" -e 0,"$TARGET_X","$TARGET_Y","$TARGET_W","$TARGET_H"
    wmctrl -x -r "${WM_CLASS}.${WM_CLASS}" -b add,fullscreen
}

# ---------------------------------------------------------------------------
# Wayland path: GNOME "Window Calls" extension over D-Bus.
# ---------------------------------------------------------------------------
wc_call () {  # $1 = method, rest = args
    local method="$1"; shift
    gdbus call --session \
        --dest org.gnome.Shell \
        --object-path /org/gnome/Shell/Extensions/Windows \
        --method "org.gnome.Shell.Extensions.Windows.$method" "$@"
}

run_wayland () {
    if ! gdbus introspect --session --dest org.gnome.Shell \
            --object-path /org/gnome/Shell/Extensions/Windows >/dev/null 2>&1; then
        echo "[pinmon.sh] ERROR: GNOME 'Window Calls' extension not found on D-Bus." >&2
        echo "         Install & enable it: https://extensions.gnome.org/extension/4724/window-calls/" >&2
        echo "         (wmctrl/xdotool cannot move windows under Wayland.)" >&2
        exit 1
    fi

    # Clean up any stale kitty remote-control socket from a previous crash.
    rm -f "$KITTY_SOCKET"

    # Launch kitty as your user; run pinmon with sudo inside it.
    kitty --class "$WM_CLASS" --title "$WM_CLASS" -o font_size=$FONT_SIZE \
          -o allow_remote_control=yes --listen-on "unix:$KITTY_SOCKET" \
          bash -c 'sudo pinmon; echo; echo "[pinmon exited - press enter]"; read' &

    # Find our window id by wm_class (the List method returns JSON).
    local winid=""
    for _ in {1..50}; do
        winid=$(wc_call List 2>/dev/null \
            | sed "s/^('//; s/',)$//" \
            | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in data:
    if w.get("wm_class") == "'"$WM_CLASS"'":
        print(w["id"]); break
' 2>/dev/null || true)
        [ -n "$winid" ] && break
        sleep 0.1
    done

    if [ -z "$winid" ]; then
        echo "[pinmon.sh] ERROR: could not locate the kitty window (wm_class=$WM_CLASS)." >&2
        exit 1
    fi
    echo "[pinmon.sh] window id: $winid"

    # Make sure it is not maximized, then move + size it onto the target monitor.
    wc_call Unmaximize "$winid"  >/dev/null 2>&1 || true
    wc_call Move    "$winid" "$TARGET_X" "$TARGET_Y" >/dev/null
    wc_call Resize  "$winid" "$TARGET_W" "$TARGET_H" >/dev/null

    # Toggle fullscreen via kitty remote control (allowed under Wayland).
    kitten @ --to "unix:$KITTY_SOCKET" resize-os-window --action toggle-fullscreen \
        >/dev/null 2>&1 || \
        wc_call Maximize "$winid" >/dev/null 2>&1 || true
}

case "$session" in
    wayland) run_wayland ;;
    *)       run_x11 ;;
esac
