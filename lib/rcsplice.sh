# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# shellcheck disable=SC2034
# rcsplice.sh — marker-block surgery on somebody else's file.
#
# Used for shell rc files, for terminal config files, and for the splashboard
# settings sink. The contract is the same everywhere and it is the whole reason v2 is
# safe to run on a hand-edited dotfile: we own the bytes between our two markers and
# nothing else in the file is ever read, reordered, or rewritten.
#
# v1 broke that contract in one place — `sed -i "s/^theme =.*/theme = $1/"` on the
# user's ghostty config, on every interactive shell. That is unbounded churn on a file
# we do not own, and it silently destroys a `theme = light:X,dark:Y` setting (verified:
# the light/dark form becomes a single theme name and the pairing is gone). v2 never
# edits a line it did not write.

ct_has_block() {                              # <file> <begin-marker>
    [ -r "$1" ] || return 1
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$2"*) return 0 ;; esac
    done < "$1"
    return 1
}

# Replace the block if it exists, otherwise append it. Idempotent: running twice
# leaves a byte-identical file, which test/unit/rcsplice.bats asserts.
# Body comes from stdin.
ct_splice_block() {                           # <file> <begin> <end>  < body
    local file=$1 begin=$2 end=$3 body line skip=0 had=0
    body=$(cat)
    ct_mkdir "${file%/*}"
    [ -e "$file" ] || : > "$file"
    ct_tmpname "$file"
    {
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$begin"*) skip=1; had=1
                           printf '%s\n' "$begin" "$body" "$end"
                           continue ;;
                "$end"*)   [ "$skip" = 1 ] && { skip=0; continue; } ;;
            esac
            [ "$skip" = 1 ] || printf '%s\n' "$line"
        done < "$file"
        if [ "$had" = 0 ]; then
            [ -s "$file" ] && printf '\n'
            printf '%s\n' "$begin" "$body" "$end"
        fi
    } > "$CT_TMP" || { rm -f "$CT_TMP"; return 1; }
    # cat-not-mv, deliberately: it preserves the destination's inode, permissions and
    # symlink-ness. Plenty of people keep ~/.zshrc as a symlink into a dotfiles repo,
    # and a rename would replace the link with a regular file.
    cat "$CT_TMP" > "$file" && rm -f "$CT_TMP"
}

ct_unsplice_block() {                         # <file> <begin> <end>
    [ -r "$1" ] || return 0
    local file=$1 begin=$2 end=$3 line skip=0 prev_blank=0
    ct_tmpname "$file"
    {
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$begin"*) skip=1; continue ;;
                "$end"*)   [ "$skip" = 1 ] && { skip=0; continue; } ;;
            esac
            [ "$skip" = 1 ] && continue
            printf '%s\n' "$line"
        done < "$file"
    } > "$CT_TMP" || { rm -f "$CT_TMP"; return 1; }
    # Removing a block that was appended after a blank separator would otherwise leave
    # the file ending in blank lines, and a second install/uninstall cycle would stack
    # more of them.
    ct_strip_trailing_blanks "$CT_TMP"
    cat "$CT_TMP" > "$file" && rm -f "$CT_TMP"
}

ct_strip_trailing_blanks() {                  # <file>
    local lines=() line n
    while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done < "$1"
    n=${#lines[@]}
    while [ "$n" -gt 0 ] && [ -z "${lines[n-1]}" ]; do n=$((n - 1)); done
    if [ "$n" -eq 0 ]; then : > "$1"; return 0; fi
    printf '%s\n' "${lines[@]:0:n}" > "$1"
}
