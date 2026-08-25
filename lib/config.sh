# config.sh — the user's answers, as flat key = value.
#
# PARSED, NEVER SOURCED. Sourcing a config file makes every key an arbitrary code
# execution point; this file is written by a wizard and hand-edited afterwards, and
# the same parser is reused for theme files, which people will paste from gists.

# Defaults. Any key absent from the config keeps the value set here, so a config file
# may be as short as one line and an older config never breaks on a newer binary.
ct_config_defaults() {
    CT_CFG_terminal=                # detection override; empty = autodetect
    CT_CFG_trigger=pane             # pane | shell | manual
    CT_CFG_pick_mode=random         # random | rotate | fixed | repo
    CT_CFG_fixed_theme=
    CT_CFG_variant=mixed            # mixed | dark | light | clock
    CT_CFG_themes=                  # space-separated allowlist; empty = every bundled theme
    CT_CFG_persist=yes              # write the terminal's include fragment
    CT_CFG_ssh=reset                # reset | keep | never
    CT_CFG_splashboard=auto         # auto | always | never
    CT_CFG_legacy_history=import    # import | share | ignore
    CT_CFG_no_repeat=5
    CT_CFG_preseed=yes              # pre-pick the NEXT theme into the fragment (no-flash)
}

# The shared flat parser. Same grammar as a theme file:
#   - split on the FIRST "="; trim whitespace around key and value
#   - a line whose first non-blank character is "#" is a comment
#   - "#" anywhere else is DATA — it begins every colour value, which is why this
#     cannot be the usual ${line%%#*} strip
#   - unknown keys are ignored rather than fatal, so config files roll forward
# Calls <callback> "$key" "$value" for each pair. Shared verbatim by the config
# loader and the theme loader so the two grammars cannot drift apart.
ct_parse_kv() {                               # <file> <callback>
    local line key val
    [ -r "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"             # rtrim key
        val="${val#"${val%%[![:space:]]*}"}"             # ltrim value
        val="${val%"${val##*[![:space:]]}"}"             # rtrim value
        "$2" "$key" "$val"
    done < "$1"
}

ct_config_kv() {                              # <key> <value>
    case "$1" in
        terminal)        CT_CFG_terminal=$2 ;;
        trigger)         CT_CFG_trigger=$2 ;;
        pick-mode)       CT_CFG_pick_mode=$2 ;;
        fixed-theme)     CT_CFG_fixed_theme=$2 ;;
        variant)         CT_CFG_variant=$2 ;;
        themes)          CT_CFG_themes=$2 ;;
        persist)         CT_CFG_persist=$2 ;;
        ssh)             CT_CFG_ssh=$2 ;;
        splashboard)     CT_CFG_splashboard=$2 ;;
        legacy-history)  CT_CFG_legacy_history=$2 ;;
        no-repeat)       CT_CFG_no_repeat=$2 ;;
        preseed)         CT_CFG_preseed=$2 ;;
    esac
}

ct_config_load() {
    ct_config_defaults
    ct_parse_kv "$CT_CONFIG_DIR/config" ct_config_kv
    # A per-host pin outranks the config file: it is the escape hatch for "I chose
    # this theme on this box on purpose, stop randomising it". Its mere existence
    # switches the pick mode, so no second key has to be kept in sync.
    local pin="$CT_CONFIG_DIR/hosts/${HOSTNAME:-$(uname -n 2>/dev/null)}"
    if [ -r "$pin" ]; then
        local t
        IFS= read -r t < "$pin"
        t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
        if [ -n "$t" ]; then
            CT_CFG_pick_mode=fixed
            CT_CFG_fixed_theme=$t
            ct_debug "host pin -> $t"
        fi
    fi
    return 0
}
