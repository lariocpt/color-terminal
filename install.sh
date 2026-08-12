#!/usr/bin/env bash
# install.sh — install color-terminal and wire it into the shell rc files.
#
# Idempotent. What it does:
#   1. bin/color-terminal        -> ~/.local/bin/color-terminal
#   2. shell/color-terminal.*    -> ~/.config/color-terminal/
#   3. Wires ~/.zshrc / ~/.bashrc to source the snippet on shell init. If the rc
#      still has the legacy cli-tools-installer color-ghostty hook block, the new
#      block REPLACES it in place — position matters, because the snippet must run
#      before splashboard's init block renders the splash. Otherwise the block is
#      inserted just above the `# >>> splashboard >>>` block, or appended.
#
# Safe on hosts with a different setup: missing rc files are skipped, and the
# runtime script itself skips splash sync when ~/.splashboard is absent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"
SNIP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/color-terminal"

BEGIN="# >>> color-terminal hook >>>"
END="# <<< color-terminal hook <<<"
OLD_BEGIN="# >>> cli-tools-installer: color-ghostty hook >>>"
OLD_END="# <<< cli-tools-installer: color-ghostty hook <<<"
SPLASH_MARK="# >>> splashboard >>>"

msg() { printf '[color-terminal] %s\n' "$*"; }

install -Dm755 "$HERE/bin/color-terminal" "$LOCAL_BIN/color-terminal"
msg "installed $LOCAL_BIN/color-terminal"

install -Dm644 "$HERE/shell/color-terminal.zsh"  "$SNIP_DIR/color-terminal.zsh"
install -Dm644 "$HERE/shell/color-terminal.bash" "$SNIP_DIR/color-terminal.bash"
msg "installed snippets -> $SNIP_DIR/"

wire_rc() {  # <rcfile> <zsh|bash>
    local rc="$1" ext="$2" tmp
    # '$HOME' stays literal in the rc — expanded at shell init, portable across hosts.
    local snip="\$HOME/.config/color-terminal/color-terminal.$ext"

    [ -f "$rc" ] || { msg "$(basename "$rc") absent — skipping"; return 0; }
    if grep -qF "color-terminal.$ext" "$rc"; then
        msg "$(basename "$rc") already sources color-terminal.$ext — skipping"
        return 0
    fi

    [ -f "$rc.pre-color-terminal" ] || cp "$rc" "$rc.pre-color-terminal"
    tmp="$(mktemp)"

    if grep -qF "$OLD_BEGIN" "$rc"; then
        # Replace the legacy color-ghostty hook block in place (keeps ordering).
        awk -v ob="$OLD_BEGIN" -v oe="$OLD_END" \
            -v nb="$BEGIN" -v ne="$END" -v snip="$snip" '
            index($0, ob) == 1 {
                print nb
                print "[ -f \"" snip "\" ] && . \"" snip "\""
                print ne
                skip=1; next
            }
            index($0, oe) == 1 {skip=0; next}
            !skip
        ' "$rc" > "$tmp"
        msg "$(basename "$rc"): replaced legacy color-ghostty hook with color-terminal hook"
    elif grep -qF "$SPLASH_MARK" "$rc"; then
        # No legacy block: insert just above splashboard so the sync runs first.
        awk -v sm="$SPLASH_MARK" -v nb="$BEGIN" -v ne="$END" -v snip="$snip" '
            index($0, sm) == 1 && !done {
                print nb
                print "[ -f \"" snip "\" ] && . \"" snip "\""
                print ne
                print ""
                done=1
            }
            {print}
        ' "$rc" > "$tmp"
        msg "$(basename "$rc"): inserted color-terminal hook above the splashboard block"
    else
        cat "$rc" > "$tmp"
        {
            echo ""
            echo "$BEGIN"
            echo "[ -f \"$snip\" ] && . \"$snip\""
            echo "$END"
        } >> "$tmp"
        msg "$(basename "$rc"): appended color-terminal hook"
    fi

    cat "$tmp" > "$rc"   # cat-not-mv preserves the rc's inode/perms/symlinkness
    rm -f "$tmp"
}

wire_rc "$HOME/.zshrc"  zsh
wire_rc "$HOME/.bashrc" bash

msg "done. Open a new ghostty window (or run color-terminal) to see it."
