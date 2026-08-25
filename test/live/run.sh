#!/usr/bin/env bash
# test/live/run.sh — open a REAL window in each locally installed terminal and ask it
# back what colour it is.
#
# This complements test/run.sh (which fakes a terminal with a pty and needs none
# installed) and test/containers/ (which brings its own terminals in podman). This one
# tests what is actually on THIS machine, on the real compositor, which is the only
# layer that would catch a bug in how a specific build of a specific terminal behaves.
#
# It opens visible windows for a second or two. That is unavoidable and it is the point.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO=$PWD
CT_BIN="${CT_BIN:-$REPO/dist/color-terminal}"
[ -x "$CT_BIN" ] || make -s dist >/dev/null

if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
    echo "no display — skipping live terminal tests"; exit 0
fi

OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
FAIL=0

probe() {                                     # <name> <command...>
    local name=$1; shift
    command -v "$1" >/dev/null 2>&1 || { printf '  %-10s SKIP  (not installed)\n' "$name"; return 0; }
    rm -f "$OUT/$name"
    CT_BIN="$CT_BIN" timeout 30 "$@" >/dev/null 2>&1
    if [ ! -s "$OUT/$name" ]; then
        printf '  %-10s FAIL  (no reply file — the window did not run the probe)\n' "$name"; FAIL=1; return 0
    fi
    local verdict; verdict=$(grep '^VERDICT=' "$OUT/$name" | cut -d= -f2)
    if [ "$verdict" = PASS ]; then
        printf '  %-10s PASS  %s\n' "$name" "$(grep '^background=' "$OUT/$name")"
    else
        printf '  %-10s FAIL\n' "$name"; sed 's/^/           /' "$OUT/$name"; FAIL=1
    fi
}

echo "live terminals on this machine:"
probe foot    foot    --title=color-terminal-probe        python3 "$REPO/test/live/probe.py" "$OUT/foot"
probe ghostty ghostty --title=color-terminal-probe -e     python3 "$REPO/test/live/probe.py" "$OUT/ghostty"
probe kitty   kitty   --title=color-terminal-probe        python3 "$REPO/test/live/probe.py" "$OUT/kitty"

exit $FAIL
