#!/usr/bin/env bash
# test/containers/run.sh — verify color-terminal against REAL terminal emulators,
# headlessly, without installing one of them on this machine.
#
# Wired into `make test-terminals`. Complements the other two layers:
#   test/run.sh        fakes a terminal with a pty; needs none installed; fast
#   test/live/run.sh   real windows, but only for terminals that ARE installed here
#   this               brings its own terminals, in a rootless container
#
# The oracle is not a screenshot. Each terminal is asked, over its own escape
# protocol, what colour it is currently using (OSC 11 / OSC 4;1 query), and the answer
# is compared against the theme file. See probe.sh.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO=$PWD

IMAGE=${CT_IMAGE:-localhost/color-terminal-testrig:latest}
THEME=${CT_TEST_THEME:-catppuccin-mocha}
TERMINALS=(${CT_TERMINALS:-foot kitty alacritty xterm wezterm})

# Expected values come from the theme file itself, so the test cannot drift from the
# corpus it is testing.
want_bg=$(awk -F'= *' '/^background/{gsub(/#/,"",$2); print $2; exit}' "themes/$THEME.theme")
want_c1=$(awk -F'= *' '/^color1 /{gsub(/#/,"",$2); print $2; exit}' "themes/$THEME.theme")

if ! command -v podman >/dev/null 2>&1; then
    echo "podman is not installed — skipping the real-terminal container tests."
    echo "(the pty-level suite in test/run.sh covers the same escape bytes without it)"
    exit 0
fi

[ -x dist/color-terminal ] || make -s dist >/dev/null

if ! podman image exists "$IMAGE" 2>/dev/null; then
    echo "building $IMAGE (a few minutes, once) ..."
    podman build -t "$IMAGE" -f test/containers/Containerfile test/containers || {
        echo "image build failed — skipping"; exit 1; }
fi

OUT=$(mktemp -d "${TMPDIR:-/tmp}/ct-containers.XXXXXX")
trap 'rm -rf "$OUT"' EXIT

printf '\n%-11s %-7s %-14s %-14s %s\n' TERMINAL RESULT BACKGROUND COLOR1 ORACLE
printf '%.0s-' {1..64}; printf '\n'

FAIL=0 BROKEN=0 PASSED=0
for t in "${TERMINALS[@]}"; do
    # The image is a terminal zoo and contains no color-terminal: the binary, the
    # themes and the rig are all bind-mounted, so editing lib/*.sh and re-running
    # never needs a rebuild.
    podman run --rm \
        -v "$REPO/dist/color-terminal:/usr/local/bin/color-terminal:ro" \
        -v "$REPO/themes:/root/.local/share/color-terminal/themes:ro" \
        -v "$REPO/test/containers:/rig:ro" \
        -v "$OUT:/out" \
        -e "CT_TEST_THEME=$THEME" \
        "$IMAGE" bash /rig/launch.sh "$t" >"$OUT/$t.run.log" 2>&1

    if [ ! -f "$OUT/$t.env" ]; then
        cp "$OUT/$t.run.log" "$REPO/test/containers/last-$t.log" 2>/dev/null
        # "The terminal never started" and "the terminal got the colours wrong" are
        # different results and must not be reported as the same one. A distro package
        # that will not load its own shared libraries is not a regression in this tool,
        # and failing the suite for it would train people to ignore a red run — but
        # hiding it would silently shrink coverage while the table still looked full.
        why=$(grep -m1 -iE 'error while loading shared libraries|command not found|No such file or directory|cannot open shared object' "$OUT/$t.run.log" 2>/dev/null)
        if [ -n "$why" ]; then
            printf '%-11s %-7s %-29s %s\n' "$t" BROKEN "" "${why:0:60}"
            BROKEN=$((BROKEN + 1))
        else
            printf '%-11s %-7s %s\n' "$t" FAIL "no reply — see test/containers/last-$t.log"
            FAIL=1
        fi
        continue
    fi

    bg= c1= osc_status= rc_status= rc_bg=
    # shellcheck source=/dev/null
    while IFS='=' read -r k v; do
        case "$k" in
            osc11)     bg=$v ;;
            osc4_1)    c1=$v ;;
            osc_status) osc_status=$v ;;
            rc_status) rc_status=$v ;;
            rc_bg)     rc_bg=$v ;;
        esac
    done < "$OUT/$t.env"

    oracle="OSC query"
    [ "$rc_status" = ok ] && oracle="OSC query + kitten @ get-colors"

    if [ "$bg" = "$want_bg" ] && [ "$c1" = "$want_c1" ]; then
        # If a second, independent oracle is available, it must agree. A terminal that
        # echoes back a colour it stored but never rendered with (konsole does exactly
        # this) would pass the escape check alone.
        if [ "$rc_status" = ok ] && [ -n "$rc_bg" ] && [ "$rc_bg" != "$want_bg" ]; then
            printf '%-11s %-7s %-14s %-14s %s\n' "$t" FAIL "#$bg" "#$c1" "oracles disagree: remote control says #$rc_bg"
            FAIL=1; continue
        fi
        printf '%-11s %-7s %-14s %-14s %s\n' "$t" PASS "#$bg" "#$c1" "$oracle"
        PASSED=$((PASSED + 1))
    else
        printf '%-11s %-7s %-14s %-14s %s\n' "$t" FAIL "#${bg:-none}" "#${c1:-none}" "want #$want_bg/#$want_c1 (osc=$osc_status)"
        cp "$OUT/$t.probe.log" "$REPO/test/containers/last-$t.log" 2>/dev/null
        FAIL=1
    fi
done

printf '\n%d passed, %d failed, %d could not start\n' "$PASSED" "$FAIL" "$BROKEN"
printf 'expected from themes/%s.theme: background #%s, color1 #%s\n' "$THEME" "$want_bg" "$want_c1"
[ "$BROKEN" = 0 ] || echo "BROKEN = the terminal would not launch in the image; not a color-terminal failure, but it means that terminal was NOT covered by this run."
[ "$FAIL" = 0 ] || echo "failing probe logs copied to test/containers/last-*.log"
exit $FAIL
