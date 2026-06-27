#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Launch pinmon in kitty and pin it, fullscreen, to a chosen monitor.
# ---------------------------------------------------------------------------

TARGET_MONITOR="${TARGET_MONITOR:-HDMI-3}"    # Configurable monitor name/ID
FONT_SIZE=${FONT_SIZE:-28}

WM_CLASS="pinmon-monitor"

# Use XDG_RUNTIME_DIR (auto-cleaned on logout) instead of /tmp to prevent stale socket errors
KITTY_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/kitty-pinmon-socket"

# ---------------------------------------------------------------------------
# Get monitor position & size from GNOME's monitors.xml.
# Falls back to xrandr if monitors.xml doesn't have the target (only for X11).
# ---------------------------------------------------------------------------
MON_X="" MON_Y="" MON_W="" MON_H="" MON_NAME=""

CONF="$HOME/.config/monitors.xml"
if [ -f "$CONF" ]; then
    # Parse monitors.xml; output is: NAME X Y W H (space-separated)
    MON_DATA=$(python3 << PYEOF
import xml.etree.ElementTree as ET, sys

def get_connector_name(lm):
    """Get connector name from logicalmonitor, trying multiple locations."""
    # Method 1: Direct <connector> child (older GNOME format)
    conn = lm.find("connector")
    if conn is not None and conn.text:
        return conn.text
    
    # Method 2: <monitorspec><connector> descendant (current GNOME format)  
    ms = lm.find(".//monitorspec")
    if ms is not None:
        c = ms.find("connector")
        if c is not None and c.text:
            return c.text
    
    # Method 3: <monitor>/<monitorspec>/name attribute
    if ms is not None and "connector" in ms.attrib:
        return ms.attrib["connector"]
    
    # Method 4: Any <connector> element anywhere (fallback)
    conn = lm.find(".//connector")
    if conn is not None and conn.text:
        return conn.text
    
    return None

def get_monitor_position(lm):
    """Get x, y from logicalmonitor. Try direct children first."""
    # <x> and <y> should be direct children of logicalmonitor
    x_el = lm.find("x")
    y_el = lm.find("y")
    
    if x_el is not None and y_el is not None:
        return int(x_el.text), int(y_el.text)
    
    # Fallback: search recursively (some GNOME versions may nest differently)
    x_el = lm.find(".//x")
    y_el = lm.find(".//y")
    if x_el is not None and y_el is not None:
        return int(x_el.text), int(y_el.text)
    
    return None, None

def get_monitor_size(lm):
    """Get resolution (W, H) from logicalmonitor."""
    mode = lm.find(".//mode")
    if mode is not None:
        w_el = mode.find("width")
        h_el = mode.find("height")
        if w_el is not None and h_el is not None:
            return int(w_el.text), int(h_el.text)
    return None, None

tree = ET.parse("$CONF")
for lm in tree.findall(".//logicalmonitor"):
    name = get_connector_name(lm)
    if name is None:
        continue
    
    x, y = get_monitor_position(lm)
    w, h = get_monitor_size(lm)
    
    # Skip entries with missing coordinates or size
    if x is None or y is None or w is None or h is None:
        continue
    
    print(f"{name} {x} {y} {w} {h}")
PYEOF
    )
    
    # Find the target monitor (case-insensitive prefix match)
    TARGET_PREFIX=$(echo "$TARGET_MONITOR" | cut -d- -f1 | tr '[:upper:]' '[:lower:]')
    while read -r name x y w h; do
        NAME_LOWER=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        if [[ "$NAME_LOWER" == ${TARGET_PREFIX}* ]]; then
            MON_NAME="$name"
            MON_X="$x"
            MON_Y="$y"
            MON_W="$w"
            MON_H="$h"
            break
        fi
    done <<< "$MON_DATA"
fi

# Fall back to xrandr ONLY for X11 (where physical pixels = screen coordinates)
if [ -z "$MON_X" ]; then
    SESSION="${XDG_SESSION_TYPE:-x11}"
    if [ "$SESSION" = "wayland" ]; then
        # On Wayland, we MUST use monitors.xml (logical coordinates).
        # xrandr physical pixels will not work with gnome-window-calls.
        echo "[pinmon.sh] ERROR: '${TARGET_MONITOR}' not found in monitors.xml." >&2
        echo "         This is required for proper window placement on Wayland." >&2
        exit 1
    fi
    
    # X11 fallback: xrandr provides physical pixel coordinates which wmctrl expects
    MON_INFO=$(xrandr --query 2>/dev/null | grep "${TARGET_MONITOR} connected")
    if [ -n "$MON_INFO" ]; then
        MON_NAME=$(echo "$MON_INFO" | awk '{print $1}')
        RES=$(echo "$MON_INFO" | grep -oE '[0-9]+x[0-9]+' | head -1)
        MON_W=${RES%%x*}
        MON_H=${RES##*x}
        
        POS=$(echo "$MON_INFO" | grep -oE '\+[0-9]+\+[0-9]+' | head -1)
        MON_X=$(echo "$POS" | cut -d'+' -f2)
        MON_Y=$(echo "$POS" | cut -d'+' -f3)
    fi
fi

if [ -z "$MON_X" ]; then
    echo "[pinmon.sh] ERROR: '${TARGET_MONITOR}' not found in monitors.xml or xrandr." >&2
    exit 1
fi

# Use physical mode (resolution) for the window size
echo "[pinmon.sh] Monitor ${MON_NAME:-$TARGET_MONITOR} at +${MON_X}+${MON_Y} (${MON_W}x${MON_H})"

session="${XDG_SESSION_TYPE:-x11}"
echo "[pinmon.sh] session type: $session -> targeting ${MON_X},${MON_Y} (${MON_W}x${MON_H})"

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
    wmctrl -x -r "${WM_CLASS}.${WM_CLASS}" -e 0,"$MON_X","$MON_Y","$MON_W","$MON_H"
    wmctrl -x -r "${WM_CLASS}.${WM_CLASS}" -b add,fullscreen
}

# ---------------------------------------------------------------------------
# Wayland path: GNOME "Window Calls" extension over D-Bus.
# The coordinates come from monitors.xml which matches Mutter's logical coordinate space.
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
    wc_call Move    "$winid" "$MON_X" "$MON_Y" >/dev/null
    wc_call Resize  "$winid" "$MON_W" "$MON_H" >/dev/null

    # Toggle fullscreen via kitty remote control (allowed under Wayland).
    kitten @ --to "unix:$KITTY_SOCKET" resize-os-window --action toggle-fullscreen \
        >/dev/null 2>&1 || \
        wc_call Maximize "$winid" >/dev/null 2>&1 || true
}

case "$session" in
    wayland) run_wayland ;;
    *)       run_x11 ;;
esac
