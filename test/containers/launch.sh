#!/usr/bin/env bash
# test/containers/launch.sh — runs INSIDE the container. Brings up a headless display
# and launches one terminal in it, with probe.sh as that terminal's command.
#
# Each terminal needs a different incantation to run a command and then be told to go
# away, and each has its own opinion about how to be given a headless display. Keeping
# that per-terminal knowledge here rather than in run.sh means the host side stays a
# plain loop, and adding a terminal is one case arm.
set -uo pipefail

NAME=${1:?usage: launch.sh <terminal>}
export CT_OUT_DIR=${CT_OUT_DIR:-/out}
export CT_BIN=${CT_BIN:-/usr/local/bin/color-terminal}
mkdir -p "$CT_OUT_DIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

PROBE="bash /rig/probe.sh $NAME"

# Two display strategies, and which one a terminal gets is not a style choice.
#
# cage (a one-application wlroots compositor) is the Wayland option, but in a
# container wlroots can only use its pixman software renderer: WLR_RENDERER=gles2
# dies with "no DRM FD available", because there is no /dev/dri to open. A
# pixman-only compositor advertises neither wl_drm nor linux-dmabuf, which is exactly
# what mesa's Wayland EGL needs — so every GPU-accelerated terminal fails to get a
# context and never draws.
#
# Xvfb has no such problem: GLX over llvmpipe is a fully software path that needs no
# DRM node at all. So anything that wants GL goes through X11, and cage is reserved
# for foot, which is Wayland-only and needs no GL whatsoever.
wl()  { cage -- "$@"; }
x11() { xvfb-run -a --server-args='-screen 0 200x60x24' env -u WAYLAND_DISPLAY "$@"; }

case "$NAME" in
    foot)
        # foot needs no GL at all, so it is the one terminal that works under the
        # pixman software renderer with nothing else negotiated.
        wl foot -- bash /rig/probe.sh foot ;;
    kitty)
        # Remote control on, so probe.sh can cross-check the escape reply against
        # `kitten @ get-colors` — an oracle that shares no code with the escape parser.
        x11 kitty -o allow_remote_control=yes --listen-on=unix:/tmp/kitty.sock \
            -1 bash /rig/probe.sh kitty ;;
    alacritty)
        x11 alacritty -e bash /rig/probe.sh alacritty ;;
    wezterm)
        x11 wezterm start --always-new-process -- bash /rig/probe.sh wezterm ;;
    xterm)
        # `-fa` picks a scalable font so the run does not depend on the X core font
        # path being populated.
        x11 xterm -fa DejaVuSansMono -fs 10 -e bash /rig/probe.sh xterm ;;
    *)
        echo "launch.sh: no recipe for '$NAME'" >&2; exit 2 ;;
esac
rc=$?
# cage's exit status reflects the compositor, not the probe, so the probe's own record
# is what decides. Absence of it is itself the failure signal, handled by run.sh.
exit $((rc > 1 ? 0 : 0))
