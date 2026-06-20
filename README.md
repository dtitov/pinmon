# PINMON · GPU Monitor

A real-time NVIDIA GPU sensor dashboard. Reads voltage, current, power draw, core temperature, VRAM usage, fan speeds, and compute utilization - rendered as an ANSI-styled panel in your terminal.

This project is based on the original work by [jan-provaznik](https://github.com/jan-provaznik/sus). Many thanks to him for the foundation.

## Features

- **Multi-GPU support** - auto-detects compatible NVIDIA cards
- **Rich sensor readout** - per-pin current balancing, gauge bars, dynamic color thresholds
- **Dual-stack compatibility** - works on both X11 (`wmctrl`) and Wayland (GNOME "Window Calls" extension)
- **Configurable display** - target monitor geometry and font size via environment variables

## Requirements

| Component | Purpose |
|-----------|---------|
| Go 1.21+ | Building the `pinmon` binary |
| Kitty terminal emulator | Displays the dashboard |
| NVIDIA drivers + NVML | GPU sensor access (`nvml`) |
| wmctrl (X11 only) | Window placement & fullscreen |
| GNOME "Window Calls" extension (Wayland only) | Window placement on Wayland |

### Dependencies for Ubuntu/Debian

```bash
sudo apt install kitty wmctrl \
                 gnome-shell-extension-manager \
                 gnome-shell-extensions
```

On Wayland, enable the **Window Calls** extension (Extensions app → browse → "Window Calls").

## Installation

You can use the provided one-step installer or follow the manual steps below.

### Automated Installer

Run the automated installer to build, install dependencies, and configure passwordless sudo access:

```bash
sudo ./install.sh
```

### Manual Installation

1. Build the binary:
   ```bash
   make
   ```

2. Install `pinmon` to your system path:
   ```bash
   sudo install -m 0755 bin/pinmon /usr/local/bin/pinmon
   ```

3. Allow passwordless `sudo pinmon` for your user:
   ```bash
   echo "$(whoami) ALL=(root) NOPASSWD: /usr/local/bin/pinmon" \
     | sudo tee /etc/sudoers.d/pinmon
   sudo chmod 0440 /etc/sudoers.d/pinmon
   ```

## Usage

### Autostart on Login

To automatically launch PINMON when your desktop session starts:

```bash
./register-startup.sh
```

This script installs an XDG autostart entry (`~/.config/autostart/pinmon.desktop`) and a systemd user service for reliability. Follow the printed instructions to reload and enable the systemd service if desired.

### Quick start

```bash
./pinmon.sh
```

This launches `pinmon` inside kitty, pins the window to a pre-configured monitor, and switches it to fullscreen. Press **Enter** after the monitoring process exits to close the terminal.

### Customization

All launch parameters are environment variables with sensible defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `TARGET_X` | `5120` | Monitor X origin in global layout |
| `TARGET_Y` | `2880` | Monitor Y origin in global layout |
| `TARGET_W` | `1728` | Window width (pixels) |
| `TARGET_H` | `3072` | Window height (pixels) |
| `FONT_SIZE` | `21` | Kitty font size |

Override any value when launching:

```bash
TARGET_X=5120 FONT_SIZE=28 ./pinmon.sh
```

### Monitor coordinates

Find your target monitor's top-left corner with:

```bash
xrandr --listmonitors
```

Look for the `+X+Y` offset of the screen you want. For example, `HDMI-3 +5120+2880 1728×3072+5120+2880`.

### Manual run (no launcher)

```bash
sudo pinmon -t 1s
```

Run anywhere you like - any terminal emulator. The `-t` flag sets the refresh interval (default: 1 second).

## Disclaimer

This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages, or other liability arising from, out of, or in connection with the software or the use or other dealings in this software.

Use at your own risk.
