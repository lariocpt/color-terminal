#!/usr/bin/env bash
# test/containers/probe.sh — runs INSIDE the terminal under test.
#
# This is the oracle. It does not look at pixels and it does not trust
# color-terminal's own output: it applies a theme and then asks the terminal, over
# the terminal's own protocol, what colour it is now using.
#
#     printf '\033]11;?\033\\'     what is your background?
#     printf '\033]4;1;?\033\\'    what is ANSI colour 1?
#
# and the terminal answers on this process's stdin. That answer is exact, textual,
# and comes from the same table the renderer reads, so a PASS here means the pixels
# are right without ever having to look at one.
#
# Three things make this reliable rather than flaky:
#
#  1. RAW MODE. In cooked mode the line discipline buffers until a newline that an
#     OSC reply never contains, and echoes the reply back at the terminal. Both are
#     fatal. stty is restored on every exit path via trap.
#
#  2. A DA1 SENTINEL. `printf '\033[c'` is queued after the colour queries. Every
#     terminal worth testing answers DA1, and answers in order, so its reply is the
#     "that is everything I am going to say" marker. Without it there is no way to
#     distinguish "this terminal does not implement colour queries" from "this
#     terminal is still thinking", and the only options are to hang or to guess.
#
#  3. AN ABSOLUTE DEADLINE. A terminal that answers nothing must fail the assertion
#     cleanly, never wedge the suite. The read loop is bounded twice: per-byte via
#     `read -t`, and overall via a wall-clock deadline.
#
# Everything this process prints goes to a log file, never to the screen. That is
# not tidiness — it keeps the terminal's viewport a flat field of the background
# colour so that the grim pixel fallback in run.sh has something unambiguous to
# measure.

set -uo pipefail

TERM_NAME=${1:?usage: probe.sh <terminal-name>}
OUT=${CT_OUT_DIR:-/out}
THEME=${CT_TEST_THEME:-catppuccin-mocha}
TIMEOUT=${CT_QUERY_TIMEOUT:-5}          # seconds to wait for the whole reply burst
HOLD=${CT_SHOT_HOLD:-4}                 # seconds to stay alive so grim can shoot

mkdir -p "$OUT"
exec >>"$OUT/$TERM_NAME.probe.log" 2>&1
printf '=== probe %s === %s\n' "$TERM_NAME" "$(date -Is)"

ESC=$'\033'
BEL=$'\007'

# --- result accumulation -----------------------------------------------------------
# Written as shell-sourceable key=value so run.sh can read it without a parser.
declare -a RESULT=()
put() { RESULT+=("$1=$2"); }

flush() {
    local tmp="$OUT/.$TERM_NAME.env.$$"
    printf '%s\n' "${RESULT[@]}" > "$tmp" && mv -f "$tmp" "$OUT/$TERM_NAME.env"
}

# --- colour normalisation ----------------------------------------------------------
# Terminals answer in whatever X11 colour syntax they feel like. Observed in the
# wild across the five terminals this rig drives:
#
#     rgb:1e1e/1e1e/2e2e      xterm, foot, alacritty  (16 bits per channel)
#     rgb:1e/1e/2e            some builds             (8 bits)
#     #1e1e2e                 kitty's remote-control output
#     #1e1e1e1e2e2e           possible per the X spec
#     rgba:1e1e/1e1e/2e2e/ffff  wezterm has shipped this form
#
# Per the X colour-string spec each channel is 1-4 hex digits holding a value that
# is left-aligned in 16 bits, so the top 8 bits are the first two digits — with the
# single-digit case scaling as d*17, which is the digit written twice. That makes
# the whole conversion "first two digits, or the digit doubled", and it is exact
# rather than an approximation.
hex8() {                                      # <1-4 hex digits> -> 2 hex digits
    local h=${1//[^0-9a-fA-F]/}
    h=${h,,}
    case ${#h} in
        0) return 1 ;;
        1) printf '%s%s' "$h" "$h" ;;
        *) printf '%s' "${h:0:2}" ;;
    esac
}

norm_color() {                                # <colour-spec> -> rrggbb, or rc 1
    local s=$1 r g b
    s=${s//[$'\r'$'\n'$'\t' ]/}
    s=${s,,}
    case $s in
        rgba:*) s=${s#rgba:} ;;
        rgb:*)  s=${s#rgb:} ;;
        '#'*)
            s=${s#\#}
            case ${#s} in
                3|6|9|12) ;;
                *) return 1 ;;
            esac
            local n=$(( ${#s} / 3 ))
            r=${s:0:n} g=${s:n:n} b=${s:2*n:n}
            printf '%s%s%s' "$(hex8 "$r")" "$(hex8 "$g")" "$(hex8 "$b")" || return 1
            return 0 ;;
        *) return 1 ;;
    esac
    IFS=/ read -r r g b _ <<<"$s"
    [ -n "$r" ] && [ -n "$g" ] && [ -n "$b" ] || return 1
    printf '%s%s%s' "$(hex8 "$r")" "$(hex8 "$g")" "$(hex8 "$b")" || return 1
}

# --- the escape conversation -------------------------------------------------------
STTY_SAVED=
restore_tty() {
    [ -n "$STTY_SAVED" ] && stty -F /dev/tty "$STTY_SAVED" 2>/dev/null
    STTY_SAVED=
}
trap 'restore_tty' EXIT INT TERM

# Ask everything at once, then read one stream. Interleaving query/read per colour
# would multiply the timeout by the number of queries and would still need the same
# sentinel logic; one burst plus one sentinel is strictly better.
converse() {                                  # -> RAW
    RAW=
    if ! exec 9<>/dev/tty; then
        put osc_status notty
        return 1
    fi

    STTY_SAVED=$(stty -F /dev/tty -g 2>/dev/null)
    if [ -z "$STTY_SAVED" ]; then
        put osc_status nostty
        exec 9<&-
        return 1
    fi
    # -echo so the replies are not painted onto the viewport (which would ruin the
    # pixel fallback); raw so read sees bytes the instant they arrive.
    stty -F /dev/tty raw -echo 2>/dev/null

    printf '%s]11;?%s\\' "$ESC" "$ESC" >&9
    printf '%s]4;1;?%s\\' "$ESC" "$ESC" >&9
    printf '%s[c' "$ESC" >&9                  # DA1 sentinel — must be last

    # DA1 answers as ESC [ ? <params> c. Anchoring on the CSI introducer matters:
    # a bare "ends with c" test would fire on the 'c' inside a hex colour like
    # rgb:cdcd/d6d6/f4f4.
    local da1_re=$ESC'\[\?[0-9;]*c'
    local ch deadline=$(( SECONDS + TIMEOUT )) sentinel=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        if IFS= read -r -u 9 -N 1 -t 0.25 ch; then
            RAW+=$ch
            if [[ $RAW =~ $da1_re ]]; then sentinel=1; break; fi
        fi
    done

    restore_tty
    exec 9<&-

    if [ -n "$RAW" ]; then
        put osc_status $([ "$sentinel" = 1 ] && echo ok || echo partial)
    else
        put osc_status silent
    fi
    return 0
}

# --- 1. apply the theme ------------------------------------------------------------
CT=${CT_BIN:-color-terminal}
printf -- '--- applying %s via %s\n' "$THEME" "$CT"
"$CT" --theme "$THEME"
ct_rc=$?
printf -- '--- color-terminal rc=%d\n' "$ct_rc"

put terminal "$TERM_NAME"
put theme "$THEME"
put ct_rc "$ct_rc"
put term_env "${TERM:-}"
put ct_detected "$("$CT" --print-detected 2>/dev/null | tr -d '\n')"

# Give the terminal a beat to consume the burst it was just sent. Without this the
# query can overtake the OSC 11 that precedes it on a terminal that parses on a
# different thread from the one that applies.
sleep 0.3

# --- 2. query it back --------------------------------------------------------------
RAW=
converse

# %q renders the raw bytes as a single printable line, so the env file stays
# sourceable and a failure is debuggable without a hex dump.
put raw_reply "$(printf '%q' "$RAW")"

osc11_re=$ESC'\]11;([^'$BEL$ESC']*)'
osc41_re=$ESC'\]4;1;([^'$BEL$ESC']*)'

if [[ $RAW =~ $osc11_re ]]; then
    put osc11_raw "${BASH_REMATCH[1]}"
    put osc11 "$(norm_color "${BASH_REMATCH[1]}" || true)"
else
    put osc11_raw ""
    put osc11 ""
fi

if [[ $RAW =~ $osc41_re ]]; then
    put osc4_1_raw "${BASH_REMATCH[1]}"
    put osc4_1 "$(norm_color "${BASH_REMATCH[1]}" || true)"
else
    put osc4_1_raw ""
    put osc4_1 ""
fi

# --- 3. kitty's independent oracle -------------------------------------------------
# `kitten @ get-colors` reads kitty's own colour table over its remote-control
# protocol. It shares no code with the escape parser above, so agreement between the
# two is real corroboration: it rules out the failure mode where a terminal happily
# echoes back a colour it stored but never actually rendered with.
if [ -n "${KITTY_WINDOW_ID:-}" ] && command -v kitten >/dev/null 2>&1; then
    if kc=$(kitten @ get-colors 2>&1); then
        printf -- '--- kitten @ get-colors\n%s\n' "$kc"
        kbg=$(printf '%s\n' "$kc" | awk '$1=="background"{print $2; exit}')
        kc1=$(printf '%s\n' "$kc" | awk '$1=="color1"{print $2; exit}')
        put rc_status ok
        put rc_bg "$(norm_color "$kbg" || true)"
        put rc_color1 "$(norm_color "$kc1" || true)"
    else
        printf -- '--- kitten @ get-colors FAILED\n%s\n' "$kc"
        put rc_status failed
    fi
else
    put rc_status na
fi

flush

# --- 4. hold the window open for the pixel fallback --------------------------------
# run.sh's screenshotter waits on this marker. The terminal has to still be alive
# and still be showing the new background when grim fires, so the marker goes down
# only after everything above has been written, and the process then idles.
: > "$OUT/$TERM_NAME.ready"
sleep "$HOLD"
printf -- '--- done\n'
exit 0
