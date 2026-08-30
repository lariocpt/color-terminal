# shellcheck shell=bash
# install.sh — the tool installs itself.
#
# color-terminal is published as a single raw binary and installed by fetching that one
# file, checking its sha256, and marking it executable:
#
#     curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh
#
# That is the whole installer contract — download, verify, chmod — so everything the
# tool needs at runtime has to travel INSIDE this one file: the 24 themes and the two
# shell-hook templates ride along as a payload appended after the final `exit`.
#
# Bash never parses past that exit, so the payload costs nothing at shell start — it
# is only read when --install asks for it. This is the makeself trick and it is why
# `scp color-terminal remote:` still gives you a working tool, which was true of v1
# and had to stay true.

CT_PAYLOAD_MARKER='#__CT_PAYLOAD__'

# Where this script actually lives, so it can read its own tail.
#
# The subscript is spelled out rather than written ${BASH_SOURCE[-1]}, which is the
# obvious form but needs bash 4.3. On bash 3.2 — still /bin/bash on macOS, which this
# project targets — a negative subscript is a "bad array subscript" error and CT_SELF
# ends up empty, so ct_has_payload finds nothing and the tool installs with ZERO
# themes. That failure is silent until first use, which is the worst shape it could
# have.
ct_self_path() {
    CT_SELF=${BASH_SOURCE[${#BASH_SOURCE[@]}-1]:-$0}
    case "$CT_SELF" in
        /*) ;;
        *)  CT_SELF="$PWD/$CT_SELF" ;;
    esac
}

ct_has_payload() {
    ct_self_path
    [ -r "$CT_SELF" ] && grep -q "^$CT_PAYLOAD_MARKER\$" "$CT_SELF" 2>/dev/null
}

# Extract the embedded themes/ and shell/ into <dir>. base64 and tar are the only
# tools this needs, and both are present anywhere bash and tar already are, so this
# adds no new dependency to a fresh machine.
ct_payload_extract() {                        # <destdir>
    ct_self_path
    ct_mkdir "$1"
    sed -n "/^$CT_PAYLOAD_MARKER\$/,\$p" "$CT_SELF" | tail -n +2 | base64 -d | tar xz -C "$1"
}

# Running from a checkout instead of the published artifact: the real directories are
# right there, so use them rather than failing.
ct_payload_dir() {                            # -> CT_PAYLOAD_DIR
    if ct_has_payload; then
        CT_PAYLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/color-terminal-payload.XXXXXX")"
        CT_PAYLOAD_TEMP=$CT_PAYLOAD_DIR
        ct_payload_extract "$CT_PAYLOAD_DIR" || return 1
    elif [ -n "$CT_REPO_DIR" ] && [ -d "$CT_REPO_DIR/themes" ]; then
        CT_PAYLOAD_DIR=$CT_REPO_DIR
        CT_PAYLOAD_TEMP=
    else
        ct_warn "no embedded payload and no checkout — cannot find themes to install"
        return 1
    fi
}

CT_HOOK_BEGIN="# >>> color-terminal hook >>>"
CT_HOOK_END="# <<< color-terminal hook <<<"
# cli-tools-installer splices these. Their POSITION in the rc is load-bearing: below
# the local-bin PATH block so `command -v` can find us, and above the splashboard block
# so the splash palette is in step before the splash draws. Replacing in place keeps
# both; delete-then-append breaks both.
CT_LEGACY_BEGINS=(
    "# >>> cli-tools-installer: color-ghostty hook >>>"
    "# >>> cli-tools-installer: color-terminal hook >>>"
)
CT_LEGACY_ENDS=(
    "# <<< cli-tools-installer: color-ghostty hook <<<"
    "# <<< cli-tools-installer: color-terminal hook <<<"
)
CT_SPLASH_MARK="# >>> splashboard >>>"

ct_install_msg() { [ "${CT_QUIET:-0}" = 1 ] || printf '[color-terminal] %s\n' "$*"; }

ct_install() {
    local self bin themes_dir hookdir ext rc
    ct_self_path; self=$CT_SELF
    bin="${CT_PREFIX:-$HOME/.local}/bin/color-terminal"
    themes_dir="$CT_DATA_DIR/themes"
    hookdir="$CT_CONFIG_DIR"

    ct_payload_dir || return 1

    # Installing over ourselves is the normal case when an upgrade just replaced this
    # binary, so copying self onto self has to be a no-op rather than a truncation.
    if [ "$self" != "$bin" ]; then
        [ "$CT_DRY" = 1 ] && ct_install_msg "would install $self -> $bin" || {
            ct_mkdir "${bin%/*}"
            install -m0755 "$self" "$bin" || { ct_warn "cannot write $bin"; return 1; }
            ct_install_msg "installed $bin"
        }
    else
        ct_install_msg "already running from $bin"
    fi

    if [ "$CT_DRY" = 1 ]; then
        ct_install_msg "would install $(ls "$CT_PAYLOAD_DIR"/themes/*.theme 2>/dev/null | wc -l) themes -> $themes_dir/"
    else
        ct_mkdir "$themes_dir"
        # Ours to replace wholesale on upgrade. A user's own themes live in
        # $CT_CONFIG_DIR/themes, which is searched first and never touched here.
        rm -f "$themes_dir"/*.theme
        cp "$CT_PAYLOAD_DIR"/themes/*.theme "$themes_dir/" 2>/dev/null || {
            ct_warn "cannot install themes into $themes_dir"; return 1; }
        ct_install_msg "installed $(ls "$themes_dir"/*.theme | wc -l) themes -> $themes_dir/"
    fi

    for ext in zsh bash; do
        local src="$CT_PAYLOAD_DIR/shell/color-terminal.$ext.in"
        [ -r "$src" ] || continue
        if [ "$CT_DRY" = 1 ]; then
            ct_install_msg "would generate $hookdir/hook.$ext"
        else
            ct_mkdir "$hookdir"
            # @BIN@ is baked to an absolute path: the hook runs before the rc has
            # necessarily finished setting PATH.
            sed "s|@BIN@|$bin|g" "$src" > "$hookdir/hook.$ext"
        fi
    done
    [ "$CT_DRY" = 1 ] || ct_install_msg "generated $hookdir/hook.{zsh,bash}"

    ct_write_default_config
    ct_wire_rc "$HOME/.zshrc"  zsh
    ct_wire_rc "$HOME/.bashrc" bash

    if [ "${CT_NO_WIRE:-0}" != 1 ]; then
        if [ "$CT_DRY" = 1 ]; then
            ct_install_msg "would add one include line to this terminal's config"
        else
            ct_wire
            case $? in
                0) ct_install_msg "wired $CT_TERM's config — new windows keep the theme" ;;
                3) ct_install_msg "$CT_TERM's config is already wired" ;;
                *) ct_install_msg "no config wiring for $CT_TERM — live recoloring still works" ;;
            esac
        fi
    fi

    [ -n "$CT_PAYLOAD_TEMP" ] && rm -rf "$CT_PAYLOAD_TEMP"
    ct_install_msg "done. Open a new terminal window, or run: color-terminal"
    [ "$CT_DRY" = 1 ] && ct_install_msg "(dry run — nothing was written)"
    return 0
}

ct_write_default_config() {
    [ -e "$CT_CONFIG_DIR/config" ] && { ct_install_msg "$CT_CONFIG_DIR/config exists — leaving it"; return 0; }
    [ "$CT_DRY" = 1 ] && { ct_install_msg "would write $CT_CONFIG_DIR/config"; return 0; }
    ct_mkdir "$CT_CONFIG_DIR"
    cat > "$CT_CONFIG_DIR/config" <<EOF
# color-terminal configuration. Flat key = value; '#' starts a comment only as the
# first character on a line. Delete any line to fall back to its default.

# When colors change.
#   pane   — the first shell in each new pane or window (default). Nested shells, su,
#            ':!sh' from vim and agent subshells do NOT re-randomize the window.
#   shell  — every interactive shell. This was v1's behaviour.
#   manual — only when you run 'color-terminal' yourself.
trigger = ${CT_OPT_trigger:-pane}

# random (no immediate repeats) | rotate | fixed | repo (same project, same theme)
pick-mode = random
# fixed-theme = catppuccin-mocha

# mixed | dark | light | clock (light 07:00-19:00, dark otherwise)
variant = mixed

# Restrict the rotation. Space separated ids; empty means every installed theme.
# themes =

# Write the palette into this terminal's own config so new windows keep the theme.
persist = yes

# Pre-pick the NEXT window's theme and write THAT to the config, so a new window opens
# already wearing it instead of visibly swapping a moment after it appears.
preseed = yes

# reset — recolor over ssh, restore the local window on exit (default)
# keep  — recolor and leave it
# never — do not recolor over ssh at all
ssh = reset

# auto (when ~/.splashboard exists) | always | never
splashboard = auto

# How many recent picks to exclude, so back-to-back windows do not repeat.
no-repeat = 5
EOF
    ct_install_msg "wrote $CT_CONFIG_DIR/config"
}

# Three placements, in priority order, because WHERE the block sits changes whether it
# works. Only the last is a plain append.
ct_wire_rc() {                                # <rcfile> <zsh|bash>
    local rc=$1 ext=$2 snip body i
    snip="$CT_CONFIG_DIR/hook.$ext"
    body="[ -r \"$snip\" ] && . \"$snip\""

    [ -f "$rc" ] || { ct_install_msg "${rc##*/} absent — skipping"; return 0; }

    if ct_has_block "$rc" "$CT_HOOK_BEGIN"; then
        [ "$CT_DRY" = 1 ] && { ct_install_msg "would refresh the hook block in ${rc##*/}"; return 0; }
        printf '%s\n' "$body" | ct_splice_block "$rc" "$CT_HOOK_BEGIN" "$CT_HOOK_END"
        ct_install_msg "${rc##*/}: hook block refreshed"
        return 0
    fi

    # One backup, the first time we ever touch this file. The surgery is precise and
    # --uninstall reverses it, but this is somebody's login shell.
    [ "$CT_DRY" = 1 ] || [ -e "$rc.pre-color-terminal" ] || cp "$rc" "$rc.pre-color-terminal"

    for i in 0 1; do
        if ct_has_block "$rc" "${CT_LEGACY_BEGINS[i]}"; then
            [ "$CT_DRY" = 1 ] && { ct_install_msg "would replace the legacy hook in ${rc##*/}, in place"; return 0; }
            ct_replace_block_in_place "$rc" "${CT_LEGACY_BEGINS[i]}" "${CT_LEGACY_ENDS[i]}" "$body"
            ct_install_msg "${rc##*/}: replaced legacy hook in place (position preserved)"
            return 0
        fi
    done

    if ct_has_block "$rc" "$CT_SPLASH_MARK"; then
        [ "$CT_DRY" = 1 ] && { ct_install_msg "would insert the hook above the splashboard block in ${rc##*/}"; return 0; }
        ct_insert_before "$rc" "$CT_SPLASH_MARK" "$body"
        ct_install_msg "${rc##*/}: inserted above the splashboard block"
        return 0
    fi

    [ "$CT_DRY" = 1 ] && { ct_install_msg "would append the hook to ${rc##*/}"; return 0; }
    printf '%s\n' "$body" | ct_splice_block "$rc" "$CT_HOOK_BEGIN" "$CT_HOOK_END"
    ct_install_msg "${rc##*/}: hook appended"
}

ct_replace_block_in_place() {                 # <file> <old-begin> <old-end> <body>
    local file=$1 ob=$2 oe=$3 body=$4 line skip=0
    ct_tmpname "$file"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$ob"*) skip=1; printf '%s\n' "$CT_HOOK_BEGIN" "$body" "$CT_HOOK_END"; continue ;;
            "$oe"*) [ "$skip" = 1 ] && { skip=0; continue; } ;;
        esac
        [ "$skip" = 1 ] || printf '%s\n' "$line"
    done < "$file" > "$CT_TMP"
    cat "$CT_TMP" > "$file"; rm -f "$CT_TMP"
}

ct_insert_before() {                          # <file> <marker> <body>
    local file=$1 mark=$2 body=$3 line placed=0
    ct_tmpname "$file"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$placed" = 0 ]; then
            case "$line" in
                "$mark"*) printf '%s\n' "$CT_HOOK_BEGIN" "$body" "$CT_HOOK_END" ""; placed=1 ;;
            esac
        fi
        printf '%s\n' "$line"
    done < "$file" > "$CT_TMP"
    cat "$CT_TMP" > "$file"; rm -f "$CT_TMP"
}

ct_uninstall() {
    local rc
    # The include line comes out before the binary does, and the binary is what knows
    # how to remove it: foot refuses to start when an include points at a missing file.
    [ "$CT_DRY" = 1 ] && ct_install_msg "would unwire $CT_TERM's config" || ct_unwire
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [ -f "$rc" ] || continue
        ct_has_block "$rc" "$CT_HOOK_BEGIN" || continue
        [ "$CT_DRY" = 1 ] && { ct_install_msg "would remove the hook from ${rc##*/}"; continue; }
        ct_unsplice_block "$rc" "$CT_HOOK_BEGIN" "$CT_HOOK_END"
        ct_install_msg "${rc##*/}: hook removed"
    done
    if [ "$CT_DRY" != 1 ]; then
        rm -f "$CT_CONFIG_DIR/hook.zsh" "$CT_CONFIG_DIR/hook.bash"
        rm -rf "$CT_DATA_DIR"
        rm -f "${CT_PREFIX:-$HOME/.local}/bin/color-terminal"
    fi
    ct_install_msg "uninstalled. Your config at $CT_CONFIG_DIR/config and any host pins were kept."
    ct_install_msg "State and the legacy ~/.cache/ghostty_theme_history were left alone."
    ct_install_msg "A cli-tools-installer hook replaced at install time was NOT restored."
    return 0
}
