#!/usr/bin/env bash
# install.sh — install color-terminal and wire it into your shells.
#
# Idempotent: run it as many times as you like. Everything it writes is either a file
# it owns outright or a marker-delimited block inside a file you own, and it never
# edits a line it did not write.
#
# In phase 2 this hands off to `ct-setup`, a small Rust binary with an interactive
# wizard and a live theme preview. Until then — and forever on hosts without a Rust
# toolchain — it is flag-driven with sane defaults, which is exactly what an
# unattended installer (cli-tools-installer vendors this tool) needs anyway.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/rcsplice.sh"

PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin/color-terminal"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/color-terminal"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/color-terminal"

HOOK_BEGIN="# >>> color-terminal hook >>>"
HOOK_END="# <<< color-terminal hook <<<"
# cli-tools-installer splices this pair. Its position in the rc is load-bearing:
# below the local-bin PATH block (so `command -v` can find us) and above the
# splashboard block (so the splash palette is in step before the splash draws).
# Replacing it IN PLACE keeps both; delete-then-append would break both.
LEGACY_BEGINS=("# >>> cli-tools-installer: color-ghostty hook >>>" "# >>> cli-tools-installer: color-terminal hook >>>")
LEGACY_ENDS=("# <<< cli-tools-installer: color-ghostty hook <<<" "# <<< cli-tools-installer: color-terminal hook <<<")
SPLASH_MARK="# >>> splashboard >>>"

DRY=0 DO_WIRE=1 UNINSTALL=0 TRIGGER=pane SHELLS=auto

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

  --trigger=pane|shell|manual   when colors change (default: pane — the first shell
                                in each new pane, so nested shells do not re-randomize
                                the window while you are typing in it)
  --shells=auto|zsh,bash        which rc files to wire (default: those that exist)
  --no-wire                     install, but do not add the include line to your
                                terminal's own config (live recoloring only; new
                                windows will not keep the theme)
  --dry-run                     print every change without making one
  --uninstall                   remove everything, including the include line
EOF
}

for arg in "$@"; do
    case "$arg" in
        --trigger=*) TRIGGER=${arg#*=} ;;
        --shells=*)  SHELLS=${arg#*=} ;;
        --no-wire)   DO_WIRE=0 ;;
        --dry-run|-n) DRY=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --help|-h)   usage; exit 0 ;;
        *)           printf 'unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

msg()  { printf '[color-terminal] %s\n' "$*"; }
step() { if [ "$DRY" = 1 ]; then printf '[dry-run] %s\n' "$*"; return 1; fi; return 0; }

# --- rc wiring ----------------------------------------------------------------------
# Three placements, in priority order, because WHERE the block sits changes whether it
# works. Only the last one is a plain append.
wire_rc() {                                   # <rcfile> <zsh|bash>
    local rc=$1 ext=$2 snip body line i
    # Split from the declaration above deliberately: `local a=$1 b="$a"` does NOT
    # work, because every argument to `local` is word-expanded before the builtin
    # assigns any of them — so "$a" would resolve to whatever the GLOBAL a was. That
    # bug shipped for exactly one test run here and wrote hook.bash into ~/.zshrc.
    snip="$CONF/hook.$ext"
    body="[ -r \"$snip\" ] && . \"$snip\""

    [ -f "$rc" ] || { msg "${rc##*/} absent — skipping"; return 0; }

    # One backup, the first time we ever touch this file. The marker-block surgery is
    # precise and `--uninstall` reverses it, but this is somebody's login shell: cheap
    # insurance beats being right.
    [ -e "$rc.pre-color-terminal" ] || [ "$DRY" = 1 ] || cp "$rc" "$rc.pre-color-terminal"

    if ct_has_block "$rc" "$HOOK_BEGIN"; then
        step "refresh the existing hook block in ${rc##*/}" || return 0
        printf '%s\n' "$body" | ct_splice_block "$rc" "$HOOK_BEGIN" "$HOOK_END"
        msg "${rc##*/}: hook block refreshed"
        return 0
    fi

    for i in 0 1; do
        if ct_has_block "$rc" "${LEGACY_BEGINS[i]}"; then
            step "replace the legacy hook block in ${rc##*/}, in place" || return 0
            replace_block_in_place "$rc" "${LEGACY_BEGINS[i]}" "${LEGACY_ENDS[i]}" "$body"
            msg "${rc##*/}: replaced legacy hook in place (position preserved)"
            return 0
        fi
    done

    if ct_has_block "$rc" "$SPLASH_MARK"; then
        step "insert the hook above the splashboard block in ${rc##*/}" || return 0
        insert_before "$rc" "$SPLASH_MARK" "$body"
        msg "${rc##*/}: inserted above the splashboard block"
        return 0
    fi

    step "append the hook to ${rc##*/}" || return 0
    printf '%s\n' "$body" | ct_splice_block "$rc" "$HOOK_BEGIN" "$HOOK_END"
    msg "${rc##*/}: hook appended"
}

replace_block_in_place() {                    # <file> <old-begin> <old-end> <body>
    local file=$1 ob=$2 oe=$3 body=$4 line skip=0
    ct_tmpname "$file"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$ob"*) skip=1; printf '%s\n' "$HOOK_BEGIN" "$body" "$HOOK_END"; continue ;;
            "$oe"*) [ "$skip" = 1 ] && { skip=0; continue; } ;;
        esac
        [ "$skip" = 1 ] || printf '%s\n' "$line"
    done < "$file" > "$CT_TMP"
    cat "$CT_TMP" > "$file"; rm -f "$CT_TMP"
}

insert_before() {                             # <file> <marker> <body>
    local file=$1 mark=$2 body=$3 line done=0
    ct_tmpname "$file"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$done" = 0 ]; then
            case "$line" in
                "$mark"*) printf '%s\n' "$HOOK_BEGIN" "$body" "$HOOK_END" ""; done=1 ;;
            esac
        fi
        printf '%s\n' "$line"
    done < "$file" > "$CT_TMP"
    cat "$CT_TMP" > "$file"; rm -f "$CT_TMP"
}

unwire_rc() {                                 # <rcfile>
    [ -f "$1" ] || return 0
    ct_has_block "$1" "$HOOK_BEGIN" || return 0
    step "remove the hook block from ${1##*/}" || return 0
    ct_unsplice_block "$1" "$HOOK_BEGIN" "$HOOK_END"
    msg "${1##*/}: hook removed"
}

# --- uninstall ------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    # The include line comes out before the binary does, and the binary is what knows
    # how to remove it: some terminals (foot) refuse to start when an include points
    # at a file that no longer exists.
    if [ -x "$BIN" ]; then step "unwire the terminal config" && "$BIN" --unwire; fi
    unwire_rc "$HOME/.zshrc"
    unwire_rc "$HOME/.bashrc"
    step "remove $BIN, $SHARE and $CONF/hook.*" && {
        rm -f "$BIN" "$CONF/hook.zsh" "$CONF/hook.bash"
        rm -rf "$SHARE"
    }
    msg "uninstalled. Your config at $CONF/config and any per-host pins were kept."
    msg "State (~/.local/state/color-terminal) and the legacy ~/.cache/ghostty_theme_history were left alone."
    # If we replaced a cli-tools-installer block on the way in, we do not put it back:
    # it belongs to another tool, and silently resurrecting a hook the user may have
    # deliberately migrated away from would be worse than saying so.
    msg "If a cli-tools-installer color-ghostty hook was replaced at install time, it was NOT restored."
    exit 0
fi

# --- install --------------------------------------------------------------------------
msg "building the single-file script ..."
if [ "$DRY" = 0 ]; then
    make -s -C "$HERE" dist >/dev/null || ct_die "make dist failed"
fi

step "install $HERE/dist/color-terminal -> $BIN" && {
    install -Dm755 "$HERE/dist/color-terminal" "$BIN" || ct_die "cannot write $BIN"
    msg "installed $BIN"
}

step "install $(ls "$HERE"/themes/*.theme 2>/dev/null | wc -l) themes -> $SHARE/themes/" && {
    mkdir -p "$SHARE/themes"
    # Ours to replace wholesale on upgrade. A user's own themes live in
    # $CONF/themes, which is searched first and never touched by an install.
    rm -f "$SHARE/themes"/*.theme
    cp "$HERE"/themes/*.theme "$SHARE/themes/" || ct_die "cannot install themes"
    msg "installed themes -> $SHARE/themes/"
}

step "generate hook snippets -> $CONF/hook.{zsh,bash}" && {
    mkdir -p "$CONF"
    for _ext in zsh bash; do
        sed "s|@BIN@|$BIN|g" "$HERE/shell/color-terminal.$_ext.in" > "$CONF/hook.$_ext"
    done
    msg "generated $CONF/hook.zsh and $CONF/hook.bash"
}

if [ ! -e "$CONF/config" ]; then
    step "write the default config -> $CONF/config" && {
        mkdir -p "$CONF"
        cat > "$CONF/config" <<EOF
# color-terminal configuration. Flat key = value; '#' starts a comment only as the
# first character on a line. Delete any line to fall back to its default.

# When colors change.
#   pane   — the first shell in each new pane or window (default). Nested shells,
#            su, ':!sh' from vim and agent subshells do NOT re-randomize the window.
#   shell  — every interactive shell. This was v1's behaviour; it changes colors
#            while you are typing in a nested shell.
#   manual — only when you run 'color-terminal' yourself.
trigger = $TRIGGER

# random (no immediate repeats) | rotate | fixed | repo (same project, same theme)
pick-mode = random
# fixed-theme = catppuccin-mocha

# mixed | dark | light | clock (light 07:00-19:00, dark otherwise)
variant = mixed

# Restrict the rotation. Space separated ids; empty means every installed theme.
# themes =

# Write the palette into this terminal's own config so new windows keep the theme.
persist = yes

# Pre-pick the NEXT window's theme and write THAT to the config, so a new window
# opens already wearing it instead of visibly swapping a moment after it appears.
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
        msg "wrote $CONF/config"
    }
else
    msg "$CONF/config exists — leaving it alone"
fi

case "$SHELLS" in
    auto) wire_rc "$HOME/.zshrc" zsh; wire_rc "$HOME/.bashrc" bash ;;
    *)    case ",$SHELLS," in *,zsh,*)  wire_rc "$HOME/.zshrc"  zsh  ;; esac
          case ",$SHELLS," in *,bash,*) wire_rc "$HOME/.bashrc" bash ;; esac ;;
esac

if [ "$DO_WIRE" = 1 ]; then
    if [ "$DRY" = 1 ]; then
        printf '[dry-run] would add one include line to this terminal'"'"'s config\n'
    elif [ -x "$BIN" ]; then
        case "$("$BIN" --wire >/dev/null 2>&1; echo $?)" in
            0) msg "added the include line to your terminal's config (new windows keep the theme)" ;;
            3) msg "your terminal's config is already wired" ;;
            *) msg "did not wire this terminal's config — live recoloring still works" ;;
        esac
    fi
fi

msg "done. Open a new terminal window, or run: color-terminal"
[ "$DRY" = 1 ] && msg "(dry run — nothing was written)"
exit 0
