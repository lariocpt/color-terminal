# shellcheck shell=bash
# SC2154: CT_CFG_* are assigned by the config parser at runtime.
# shellcheck disable=SC2154
# splashboard — the splash-screen sibling. Keeps the splash animation's palette in
# step with the terminal, so the two never clash on a new shell.
#
# The managed block owns the file's ONLY [theme] table: TOML forbids duplicate tables,
# so a second one anywhere else in the file is a parse error. That is why the whole
# table lives inside the markers rather than just the keys.

CT_SB_BEGIN="# >>> color-terminal >>>"
CT_SB_END="# <<< color-terminal <<<"

ct_sink_splashboard_available() {
    case "$CT_CFG_splashboard" in
        never)  return 1 ;;
        always) return 0 ;;
    esac
    [ -d "$HOME/.splashboard" ]
}

ct_sink_splashboard_sync() {
    local settings="$HOME/.splashboard/settings.toml"

    # v1 gated this only on the directory existing, so sshing into any host that also
    # runs splashboard rewrote THAT host's settings.toml on every login, with a preset
    # chosen for the local window — and --reset never undid it. Pure drift on every
    # remote box. The splash is a local artifact; a remote session has no business
    # touching it.
    [ -z "$CT_SSH" ] || { ct_debug "splashboard: skipped (ssh session)"; return 0; }
    [ -d "$HOME/.splashboard" ] || return 0
    [ -e "$settings" ] || : > "$settings" 2>/dev/null || return 0

    local body
    if [ -n "$CT_SPLASH" ]; then
        body="preset = \"$CT_SPLASH\""
    else
        # No matching preset for this theme. "reset" tokens make the splash inherit
        # whatever colours we just applied, which is strictly better than picking a
        # near-miss preset: bg/bg_subtle stop it painting its own background over the
        # theme, and panel_title is what colours the hero animation.
        body='panel_title = "reset"
panel_border = "reset"
bg = "reset"
bg_subtle = "reset"'
    fi

    ct_splice_block "$settings" "$CT_SB_BEGIN" "$CT_SB_END" <<EOF
# Managed by color-terminal — rewritten on every run; do not edit inside the markers.
# This is the file's only [theme] table (TOML forbids duplicates); to take manual
# control of the splash palette, delete the whole block.
[theme]
$body
EOF
}
