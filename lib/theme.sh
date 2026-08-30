# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# SC1007: `VAR=` clears a global; the space-separated form is deliberate.
# shellcheck disable=SC2034,SC1007
# theme.sh — load one theme file into the CT_* globals the emitter and the backends
# read. Themes are DATA: parsed with the shared flat parser, never sourced. People
# paste theme files from gists, and a sourced theme file is arbitrary code execution.

# Where themes come from, in precedence order: the user's own directory wins over the
# bundled corpus, so overriding a shipped theme never means editing a file that the
# next upgrade will overwrite.
ct_theme_dirs() {
    CT_THEME_DIRS=("$CT_CONFIG_DIR/themes" "$CT_DATA_DIR/themes")
    # Running straight out of a checkout (bin/color-terminal rather than the
    # amalgamated dist), so `make test` and a dev run see the repo's corpus.
    [ -n "$CT_REPO_DIR" ] && CT_THEME_DIRS+=("$CT_REPO_DIR/themes")
}

ct_theme_path() {                             # <theme-id> -> CT_THEME_FILE
    local d
    for d in "${CT_THEME_DIRS[@]}"; do
        if [ -r "$d/$1.theme" ]; then CT_THEME_FILE="$d/$1.theme"; return 0; fi
    done
    return 1
}

# Build the id list once. Two parallel indexed arrays rather than one associative
# array on purpose: associative arrays are bash 4, and macOS still ships bash 3.2 —
# which matters because this script gets scp'd to whatever host you ssh into.
ct_theme_index() {
    CT_THEME_IDS=() CT_THEME_VARIANTS=()
    local d f id seen
    for d in "${CT_THEME_DIRS[@]}"; do
        [ -d "$d" ] || continue
        for f in "$d"/*.theme; do
            [ -r "$f" ] || continue           # unmatched glob
            id="${f##*/}"; id="${id%.theme}"
            seen=0
            for s in "${CT_THEME_IDS[@]}"; do [ "$s" = "$id" ] && { seen=1; break; }; done
            [ "$seen" = 1 ] && continue       # earlier directory already won
            CT_THEME_IDS+=("$id")
            ct_theme_variant_of "$f"
            CT_THEME_VARIANTS+=("$CT_VAR")
        done
    done
}

# Read just the variant line. Reading the whole 24-file corpus in pure bash costs well
# under a millisecond (the 463-file ghostty corpus measures 4.4 ms), so there is no
# reason to fork a grep to avoid it.
#
# Sets a variable rather than printing, because the caller would have had to wrap it in
# $( ) — and a command substitution is a fork. One per theme is 24 forks on a path that
# runs at every shell start, which is the exact mistake v1 made in its parse loop.
ct_theme_variant_of() {                       # <file> -> CT_VAR
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            variant*=*)
                line="${line#*=}"
                line="${line#"${line%%[![:space:]]*}"}"
                line="${line%"${line##*[![:space:]]}"}"
                CT_VAR=$line; return 0 ;;
        esac
    done < "$1"
    CT_VAR=dark
}

ct_theme_kv() {                               # <key> <value>
    case "$1" in
        color0)  CT_PAL[0]=$2 ;;   color1)  CT_PAL[1]=$2 ;;
        color2)  CT_PAL[2]=$2 ;;   color3)  CT_PAL[3]=$2 ;;
        color4)  CT_PAL[4]=$2 ;;   color5)  CT_PAL[5]=$2 ;;
        color6)  CT_PAL[6]=$2 ;;   color7)  CT_PAL[7]=$2 ;;
        color8)  CT_PAL[8]=$2 ;;   color9)  CT_PAL[9]=$2 ;;
        color10) CT_PAL[10]=$2 ;;  color11) CT_PAL[11]=$2 ;;
        color12) CT_PAL[12]=$2 ;;  color13) CT_PAL[13]=$2 ;;
        color14) CT_PAL[14]=$2 ;;  color15) CT_PAL[15]=$2 ;;
        name)                 CT_NAME=$2 ;;
        variant)              CT_VARIANT=$2 ;;
        family)               CT_FAMILY=$2 ;;
        pairs-with)           CT_PAIR=$2 ;;
        background)           CT_BG=$2 ;;
        foreground)           CT_FG=$2 ;;
        cursor)               CT_CURSOR=$2 ;;
        cursor-text)          CT_CURSOR_TEXT=$2 ;;
        selection-background) CT_SEL_BG=$2 ;;
        selection-foreground) CT_SEL_FG=$2 ;;
        splash)               CT_SPLASH=$2 ;;
    esac
}

ct_theme_load() {                             # <theme-id>
    CT_PAL=() CT_NAME= CT_VARIANT= CT_FAMILY= CT_PAIR=
    CT_BG= CT_FG= CT_CURSOR= CT_CURSOR_TEXT= CT_SEL_BG= CT_SEL_FG= CT_SPLASH=
    ct_theme_path "$1" || { ct_warn "no such theme: $1"; return 1; }
    ct_parse_kv "$CT_THEME_FILE" ct_theme_kv

    # A theme with no background or foreground is not a theme. v1 had no such check
    # and shipped a theme name that did not resolve at all: apply_ghostty returned
    # silently while the config rewrite and the splash sync went ahead anyway, so one
    # shell in twenty-four got no colours, a ghostty config pointing at a nonexistent
    # theme, and a mismatched splash. Fail loudly instead.
    if [ -z "$CT_BG" ] || [ -z "$CT_FG" ]; then
        ct_warn "theme '$1' is missing background or foreground: $CT_THEME_FILE"
        return 1
    fi

    # Documented fallbacks, applied once at load so no backend has to repeat them.
    [ -n "$CT_CURSOR" ]      || CT_CURSOR=$CT_FG
    [ -n "$CT_CURSOR_TEXT" ] || CT_CURSOR_TEXT=$CT_BG
    [ -n "$CT_SEL_BG" ]      || CT_SEL_BG=$CT_FG
    [ -n "$CT_SEL_FG" ]      || CT_SEL_FG=$CT_BG
    [ -n "$CT_NAME" ]        || CT_NAME=$1
    [ -n "$CT_VARIANT" ]     || CT_VARIANT=dark
    CT_THEME_ID=$1
}
