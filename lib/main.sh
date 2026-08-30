# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# SC2154: CT_CFG_* are assigned by the config parser at runtime.
# SC1007: `VAR=` clears a global; the space-separated form is deliberate.
# SC1090: the source path is built at runtime.
# shellcheck disable=SC2034,SC2154,SC1007,SC1090
# main.sh — argument handling and the one flow everything else serves.

ct_usage() {
    cat <<'EOF'
color-terminal — recolor the terminal you are typing in.

Usage:
  color-terminal                 pick a theme and apply it
  color-terminal --theme ID      apply one specific theme
  color-terminal --reset         hand the terminal back its configured colors
  color-terminal --list          list available themes (id, variant, name)
  color-terminal --print-detected
                                 print "<terminal> <local|remote> <confidence>"
  color-terminal --doctor        explain what was detected and what will happen
  color-terminal --install       install: themes, shell hooks, rc wiring, terminal
                                 config include. Everything needed rides inside this
                                 one file, so this works on a machine with nothing
                                 else set up.
  color-terminal --uninstall     remove all of it again
  color-terminal --wire          add just the include line to this terminal's config
  color-terminal --unwire        remove it again, and our palette fragment
  color-terminal --dry-run       say what would happen; emit nothing, write nothing
  color-terminal --version

Install options:
  --trigger=pane|shell|manual    when colors change (default: pane)
  --no-wire                      do not touch the terminal's own config
  --prefix=DIR                   install root (default: ~/.local)
  --quiet                        no progress output

Environment:
  NO_COLOR=1            do nothing (no-color.org convention)
  COLOR_TERMINAL=0      do nothing
  COLOR_TERMINAL_TERM   force the detected terminal, e.g. "kitty"
  COLOR_TERMINAL_DEBUG  trace decisions on stderr
EOF
}

# Honoured here AND in the shell hook. The hook's copy is what saves the fork; this
# one is what makes the rule true no matter how the tool is invoked.
ct_opted_out() {
    [ -n "${NO_COLOR:-}" ] && { ct_debug "opt-out: NO_COLOR"; return 0; }
    case "${COLOR_TERMINAL:-}" in 0|no|off|false) ct_debug "opt-out: COLOR_TERMINAL"; return 0 ;; esac
    return 1
}

# Should this invocation actually recolour anything?
#
# The default is "the first shell in each pane", and that default is a bug fix. v1
# fired on EVERY interactive shell, so every `su`, every `:!sh` from vim, every
# `poetry shell`, and every coding-agent subshell re-randomised the window while you
# were typing in it. SHLVL is routinely 3 on this machine for exactly that reason.
#
# A shell cannot see its window, but it can see its SESSION: every nested shell in one
# pane shares one session id, and a new pane gets a new one. See ct_pane_key.
ct_should_swap() {
    case "$CT_CFG_trigger" in
        shell)  return 0 ;;
        manual) return 1 ;;
        pane|*) ct_pane_claim ;;
    esac
}

ct_main() {
    local action=swap
    CT_OPT_terminal= CT_OPT_theme= CT_DRY=0 CT_FROM_HOOK=0
    CT_OPT_trigger= CT_NO_WIRE=0 CT_QUIET=${CT_QUIET:-0} CT_PREFIX=${CT_PREFIX:-$HOME/.local}

    while [ $# -gt 0 ]; do
        case "$1" in
            --reset)            action=reset ;;
            --list)             action=list ;;
            --print-detected)   action=detected ;;
            --doctor)           action=doctor ;;
            --wire)             action=wire ;;
            --unwire)           action=unwire ;;
            --install)          action=install ;;
            --uninstall)        action=uninstall ;;
            --no-wire)          CT_NO_WIRE=1 ;;
            --trigger)          shift; CT_OPT_trigger=${1:-} ;;
            --trigger=*)        CT_OPT_trigger=${1#--trigger=} ;;
            --prefix)           shift; CT_PREFIX=${1:-} ;;
            --prefix=*)         CT_PREFIX=${1#--prefix=} ;;
            --quiet|-q)         CT_QUIET=1 ;;
            --hook)             CT_FROM_HOOK=1 ;;
            --dry-run|-n)       CT_DRY=1 ;;
            --theme)            shift; CT_OPT_theme=${1:-} ;;
            --theme=*)          CT_OPT_theme=${1#--theme=} ;;
            --terminal)         shift; CT_OPT_terminal=${1:-} ;;
            --terminal=*)       CT_OPT_terminal=${1#--terminal=} ;;
            --version|-V)       printf 'color-terminal %s\n' "$CT_VERSION"; return 0 ;;
            --help|-h)          ct_usage; return 0 ;;
            *)                  ct_warn "unknown option: $1"; ct_usage >&2; return 2 ;;
        esac
        shift
    done

    ct_paths_init
    ct_config_load
    ct_state_init
    ct_theme_dirs

    # flock(1) is a fork and dynamic file descriptors need bash 4.1, so both are
    # probed once rather than assumed. Where either is missing, ct_lock falls back to
    # a forkless noclobber sentinel.
    CT_HAVE_FLOCK=
    if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 1 ]; }; then
        [ -x /usr/bin/flock ] && CT_HAVE_FLOCK=1
    fi

    if ct_opted_out && [ "$action" != doctor ] && [ "$action" != list ]; then
        return 0
    fi

    ct_tty_init
    ct_detect
    ct_caps_resolve

    case "$action" in
        detected)
            local where=remote
            [ "$CT_LOCAL" = 1 ] && where=local
            printf '%s %s %s\n' "$CT_TERM" "$where" "$CT_CONF"
            return 0 ;;
        list)
            ct_theme_index
            local i
            for ((i = 0; i < ${#CT_THEME_IDS[@]}; i++)); do
                printf '%-24s %-5s\n' "${CT_THEME_IDS[i]}" "${CT_THEME_VARIANTS[i]}"
            done
            return 0 ;;
        doctor)    ct_doctor; return 0 ;;
        install)   ct_install; return $? ;;
        uninstall) ct_uninstall; return $? ;;
        wire)     [ "$CT_DRY" = 1 ] && { printf 'would wire %s\n' "$CT_TERM"; return 0; }
                  ct_wire; return $? ;;
        unwire)   [ "$CT_DRY" = 1 ] && { printf 'would unwire %s\n' "$CT_TERM"; return 0; }
                  ct_unwire; return $? ;;
        reset)
            # A tier-3 terminal never received colours from us, so there is nothing to
            # undo and the reset codes would be equally ignored.
            ct_is_tier3 && return 0
            [ "$CT_DRY" = 1 ] && { printf 'would reset %s\n' "$CT_TERM"; return 0; }
            ct_reset_live
            return 0 ;;
    esac

    # --- the swap -----------------------------------------------------------------
    # Declining is a feature. konsole accepts OSC 4, stores it, answers queries about
    # it, and never renders with it; Warp ignores it; mosh drops it; Apple Terminal
    # prints some of it. Emitting into those is worse than doing nothing, because it
    # looks like it worked.
    if ct_is_tier3; then
        ct_debug "declining: $("ct_be_${CT_BACKEND}_decline")"
        return 0
    fi

    # The trigger policy lives here and nowhere else. Putting it in the shell hook
    # would mean three implementations (zsh, bash, fish) of one rule, drifting apart;
    # a no-op run costs a fork and two file reads, which is cheaper than that bug.
    if [ "$CT_FROM_HOOK" = 1 ] && ! ct_should_swap; then
        ct_debug "trigger '$CT_CFG_trigger' says no"
        return 0
    fi

    ct_theme_index
    [ ${#CT_THEME_IDS[@]} -gt 0 ] || { ct_warn "no themes found in ${CT_THEME_DIRS[*]}"; return 1; }

    ct_migrate_history
    ct_state_history

    local id=
    if [ -n "$CT_OPT_theme" ]; then
        id=$CT_OPT_theme                      # explicit: no pre-seed, fully deterministic
    elif [ "$CT_CFG_preseed" = yes ] && ct_next_read && ct_theme_path "$CT_NEXT"; then
        # The previous swap already wrote this theme into the terminal's config
        # fragment, so the window opened wearing it. Consuming it here means the hook
        # applies the SAME theme it is already showing: no flash.
        id=$CT_NEXT
        ct_debug "consuming pre-seeded pick: $id"
    else
        ct_pick || { ct_warn "nothing to pick from"; return 1; }
        id=$CT_PICK
    fi

    ct_theme_load "$id" || return 1

    if [ "$CT_DRY" = 1 ]; then
        printf 'terminal : %s (%s, %s)\n' "$CT_TERM" "$CT_CONF" "$([ "$CT_LOCAL" = 1 ] && echo local || echo remote)"
        printf 'theme    : %s (%s, %s)\n' "$CT_THEME_ID" "$CT_NAME" "$CT_VARIANT"
        printf 'caps     :%s\n' "$CT_CAPS"
        printf 'persist  : %s\n' "$(ct_may_persist && echo "yes -> $(ct_fragment_path; printf '%s' "$CT_FRAGMENT")" || echo no)"
        printf 'splash   : %s\n' "$(ct_sink_splashboard_available && echo "yes (${CT_SPLASH:-inherit})" || echo no)"
        return 0
    fi

    ct_apply_live
    ct_sink_splashboard_available && ct_sink_splashboard_sync
    ct_state_record "$CT_THEME_ID"

    # Pre-seed: choose the theme the NEXT window will open on, and write that into the
    # terminal's config fragment rather than the one we just applied. Without this a
    # new window opens on the previous theme and visibly swaps a moment later.
    if [ -z "$CT_OPT_theme" ] && [ "$CT_CFG_preseed" = yes ]; then
        CT_HISTORY+=("$CT_THEME_ID")
        if ct_pick; then
            ct_next_write "$CT_PICK"
            ct_may_persist && ct_theme_load "$CT_PICK" && ct_persist
            return 0
        fi
    fi
    ct_may_persist && ct_persist
    return 0
}
