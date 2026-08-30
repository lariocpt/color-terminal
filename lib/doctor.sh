# shellcheck shell=bash
# SC2154: CT_CFG_* are assigned by the config parser at runtime.
# shellcheck disable=SC2154
# doctor.sh — "why is my terminal not changing colour?", answered without guessing.
#
# Everything here is read-only. It exists because most failures of a tool like this
# are silent by construction: the escape sequence is written, the terminal ignores it,
# and nothing anywhere reports a problem.

ct_doctor() {
    local i n
    printf 'color-terminal %s\n\n' "$CT_VERSION"

    printf 'terminal\n'
    printf '  detected     : %s\n' "$CT_TERM"
    [ "$CT_BACKEND" = "$CT_TERM" ] || printf '  handled by   : %s backend (no dedicated backend for %s yet)\n' "$CT_BACKEND" "$CT_TERM"
    printf '  confidence   : %s\n' "$CT_CONF"
    printf '  locality     : %s\n' "$([ "$CT_LOCAL" = 1 ] && echo 'local (config persistence allowed)' || echo 'remote or unproven (live colours only)')"
    printf '  multiplexer  : %s\n' "${CT_MUX:-none}"
    printf '  ssh session  : %s\n' "$([ -n "$CT_SSH" ] && echo yes || echo no)"
    printf '  tty          : %s\n' "$([ "$CT_HAVE_TTY" = 1 ] && echo 'fd 3 open on /dev/tty' || echo 'none — escapes suppressed, files still written')"
    printf '  TERM         : %s\n' "${TERM:-unset}"
    printf '  TERM_PROGRAM : %s\n' "${TERM_PROGRAM:-unset}"
    if ct_is_tier3; then
        printf '  VERDICT      : declining — %s\n' "$("ct_be_${CT_BACKEND}_decline")"
    else
        printf '  capabilities :%s\n' "$CT_CAPS"
    fi
    printf '\n'

    printf 'opt-outs\n'
    printf '  NO_COLOR         : %s\n' "$([ -n "${NO_COLOR:-}" ] && echo 'set — doing nothing' || echo unset)"
    printf '  COLOR_TERMINAL   : %s\n' "${COLOR_TERMINAL:-unset}"
    local pin="$CT_CONFIG_DIR/hosts/${HOSTNAME:-$(uname -n 2>/dev/null)}"
    printf '  host pin         : %s\n' "$([ -r "$pin" ] && echo "$pin -> $CT_CFG_fixed_theme" || echo none)"
    printf '\n'

    printf 'themes\n'
    ct_theme_index
    n=${#CT_THEME_IDS[@]}
    local dark=0 light=0
    for ((i = 0; i < n; i++)); do
        case "${CT_THEME_VARIANTS[i]}" in light) light=$((light + 1)) ;; *) dark=$((dark + 1)) ;; esac
    done
    printf '  available    : %d (%d dark, %d light)\n' "$n" "$dark" "$light"
    printf '  search path  : %s\n' "${CT_THEME_DIRS[*]}"
    printf '  pick mode    : %s\n' "$CT_CFG_pick_mode"
    printf '  variant      : %s\n' "$CT_CFG_variant"
    ct_state_history
    printf '  recent       : %s\n' "${CT_HISTORY[*]:-none}"
    ct_next_read && printf '  next window  : %s (pre-seeded)\n' "$CT_NEXT"
    printf '\n'

    printf 'persistence\n'
    if ct_may_persist; then
        ct_fragment_path
        printf '  fragment     : %s\n' "$CT_FRAGMENT"
        printf '  wired        : %s\n' "$(ct_doctor_wired)"
    else
        printf '  disabled     : %s\n' "$(ct_doctor_why_no_persist)"
    fi
    printf '\n'

    ct_doctor_hooks
}

ct_doctor_why_no_persist() {
    [ "$CT_CFG_persist" = yes ] || { printf 'persist = no in the config'; return; }
    ct_cap persist          || { printf 'the %s backend has no config to write' "$CT_TERM"; return; }
    [ -z "$CT_MUX" ]        || { printf 'inside %s — the config belongs to a window it is not drawing' "$CT_MUX"; return; }
    [ "$CT_LOCAL" = 1 ]     || { printf 'terminal process is not proven to be on this host'; return; }
    printf 'unknown'
}

ct_doctor_wired() {
    local cfg
    case "$CT_TERM" in
        ghostty) cfg="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config" ;;
        foot)    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/foot/foot.ini" ;;
        *)       printf 'n/a'; return ;;
    esac
    if ct_has_block "$cfg" "$CT_MARK_BEGIN"; then
        printf 'yes, in %s' "$cfg"
    else
        printf 'NO — run `color-terminal --wire` so new windows keep the theme'
    fi
}

# The one cross-tool hazard worth reporting. cli-tools-installer vendors its own copy
# of this hook and splices its own marker block; if both end up in one rc file, every
# new shell recolours twice and you see a flash. We warn rather than police another
# tool's file.
ct_doctor_hooks() {
    printf 'shell hooks\n'
    local rc found=0
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [ -r "$rc" ] || continue
        local ours=0 legacy=0 line
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                '# >>> color-terminal hook >>>'*) ours=$((ours + 1)) ;;
                '# >>> cli-tools-installer: color-'*) legacy=$((legacy + 1)) ;;
            esac
        done < "$rc"
        [ $((ours + legacy)) -eq 0 ] && continue
        found=1
        printf '  %-28s ours=%d legacy=%d' "${rc##*/}" "$ours" "$legacy"
        if [ $((ours + legacy)) -gt 1 ]; then
            printf '   <-- TWO hooks: every shell recolours twice (visible flash)'
        fi
        printf '\n'
    done
    [ "$found" = 0 ] && printf '  none found in ~/.zshrc or ~/.bashrc\n'
    return 0
}
