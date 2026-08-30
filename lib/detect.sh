# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# SC2154: CT_CFG_* are assigned by the config parser at runtime.
# SC1007: `VAR=` clears a global; the space-separated form is deliberate.
# shellcheck disable=SC2034,SC2154,SC1007
# detect.sh — which terminal is actually rendering this shell?
#
# v1 asked `[[ $TERM == xterm-ghostty* ]]` and stopped there. That is wrong three
# ways: it is blind to every other terminal, it is wrong inside tmux (which rewrites
# TERM to screen-256color), and it is wrong for terminals that ship a generic TERM on
# purpose — alacritty's CachyOS config sets TERM=xterm-256color.
#
# The ladder, cheapest and most trustworthy first:
#
#   rung 0  explicit override         --terminal= > $COLOR_TERMINAL_TERM > config
#   rung 1  multiplexer + trap terms  $TMUX/$STY/$ZELLIJ, and $ZUTTY_VERSION which
#                                     MUST be tested before $TERM because zutty sets
#                                     TERM=xterm-256color verbatim and would
#                                     otherwise be routed into the xterm path where
#                                     every sequence it is sent is silently discarded
#   rung 2  private env vars          GHOSTTY_RESOURCES_DIR, KITTY_PID, … — these
#                                     prove the terminal PROCESS is on this host, so
#                                     they are the only rung that may set CT_LOCAL
#   rung 3  $TERM prefix              travels over ssh, so it identifies the terminal
#                                     but says nothing about locality
#   rung 4  generic                   the safe universal OSC subset
#
# There is deliberately NO runtime escape probe here. Asking the terminal who it is
# (CSI >q) costs a blocking read with a timeout on a terminal that may never answer —
# 6-16x the entire per-shell latency budget — and it consumes keystrokes
# irrecoverably if the user types during the window. Rung 4 already handles the ssh
# case correctly, because the universal subset works everywhere.

# $TERM is only meaningful when nothing has rewritten it. Inside a multiplexer it has
# been replaced with the multiplexer's own value, so the rung-3 tests must not fire.
ct_term_is() {                                # <glob>
    [ -z "$CT_MUX" ] || return 1
    # $1 is a glob and must stay unquoted — that is the whole point of the argument.
    # shellcheck disable=SC2254
    case "$TERM" in $1) return 0 ;; *) return 1 ;; esac
}

# A private env var only proves locality when it cannot have been forwarded. ssh does
# not forward these (SendEnv defaults to LANG and LC_*), but a user's own SendEnv or
# an exported var inherited through a nested shell could lie, so the ssh check stays.
ct_env_local() { [ -z "${SSH_CONNECTION:-}" ] && [ -z "${SSH_TTY:-}" ]; }

ct_detect_context() {
    CT_MUX= CT_SCREEN= CT_SSH=
    [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ] && CT_SSH=1
    if   [ -n "${TMUX:-}" ];   then CT_MUX=tmux
    elif [ -n "${ZELLIJ:-}" ]; then CT_MUX=zellij
    elif [ -n "${STY:-}" ];    then CT_MUX=screen; CT_SCREEN=1
    fi
}

ct_detect() {
    CT_TERM= CT_BACKEND= CT_CONF=guess CT_LOCAL=0
    ct_detect_context

    # rung 0 — explicit override always wins, and is how you work around a terminal
    # we have not met yet without waiting for a release.
    local override="${CT_OPT_terminal:-${COLOR_TERMINAL_TERM:-$CT_CFG_terminal}}"
    if [ -n "$override" ]; then
        CT_TERM=$override CT_BACKEND=$override CT_CONF=override
        ct_env_local && CT_LOCAL=1
        ct_debug "detect: override -> $CT_TERM"
        return 0
    fi

    # rungs 1-3 — each backend answers for itself, in registration order. The order is
    # load-bearing (trap terminals before $TERM, generic last), so the list is
    # explicit rather than discovered from the filesystem.
    local be
    for be in "${CT_BACKENDS[@]}"; do
        if "ct_be_${be}_detect" 2>/dev/null; then
            CT_TERM=$be CT_BACKEND=$be
            ct_debug "detect: $be (confidence=$CT_CONF local=$CT_LOCAL mux=${CT_MUX:-none})"
            return 0
        fi
    done

    # rung 4 — unreachable in practice because `generic` accepts everything, but an
    # empty CT_BACKENDS in a test fixture should still produce something usable.
    CT_TERM=generic CT_BACKEND=generic CT_CONF=guess
    return 0
}

# Capabilities are the backend's, narrowed by whatever sits between us and the glass.
ct_caps_resolve() {
    # CT_TERM is what the terminal IS; CT_BACKEND is whose code handles it. They are
    # usually the same, and deliberately are not when --terminal= names a terminal we
    # have not shipped a backend for yet — which is exactly when someone reaches for
    # the override. That must degrade to the safe universal subset, not abort, and
    # --print-detected must still report the terminal the user named.
    CT_BACKEND=$CT_TERM
    if ! declare -F "ct_be_${CT_BACKEND}_caps" >/dev/null 2>&1; then
        ct_debug "no backend for '$CT_TERM'; handling it with generic"
        CT_BACKEND=generic
    fi
    CT_CAPS=" $("ct_be_${CT_BACKEND}_caps") "
    case "$CT_MUX" in
        tmux)
            # tmux implements OSC 4/10/11/12 and 104/110/111/112 against the pane's
            # own palette and swallows the rest, so anything else we send is wasted.
            # It also owns the config file question entirely: persisting to the
            # terminal's config would recolour a window tmux is not drawing.
            CT_CAPS=" set4 set10 set11 set12 rst104 rst110 rst111 rst112 " ;;
        zellij)
            # No DCS passthrough exists upstream, so only the pane can be recoloured.
            CT_CAPS=" set4 set10 set11 set12 rst104 rst110 rst111 rst112 " ;;
        screen)
            CT_CAPS=" set4 set10 set11 set12 rst104 rst110 rst111 rst112 " ;;
    esac
    ct_debug "caps:$CT_CAPS"
}

# Persistence is only ever correct when the terminal process is on this host AND
# nothing is multiplexing between us and it. Over ssh the config we would rewrite
# belongs to a machine with no window open; inside tmux it belongs to a window tmux
# is not drawing.
ct_may_persist() {
    [ "$CT_CFG_persist" = yes ] || return 1
    [ "$CT_LOCAL" = 1 ] || return 1
    [ -z "$CT_MUX" ] || return 1
    ct_cap persist || return 1
    return 0
}
