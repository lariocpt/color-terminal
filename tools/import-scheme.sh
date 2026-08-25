#!/usr/bin/env bash
# import-scheme.sh — convert a ghostty theme file into a color-terminal .theme file.
#
# DEV-ONLY. This script is never installed and never runs at runtime. It exists so
# the shipped corpus in themes/ is reproducible: `tools/import-scheme.sh --all`
# regenerates every theme from the table embedded below.
#
# Ghostty's bundled corpus (/usr/share/ghostty/themes) is a port of
# mbadolato/iTerm2-Color-Schemes (MIT). Its file format is:
#
#     palette = 0=#3b4252      ... through 15
#     background = #2e3440
#     foreground = #d8dee9
#     cursor-color = #eceff4
#     cursor-text = #282828
#     selection-background = #eceff4
#     selection-foreground = #4c566a
#
# Our format is flat "key = value" with the palette flattened to color0..color15,
# because N is the OSC 4 index verbatim — the runtime emits `4;N;<value>` with zero
# translation.
#
# Usage:
#   tools/import-scheme.sh "<Ghostty Display Name>" <our-theme-id> [key=value ...]
#   tools/import-scheme.sh --all
#
# Trailing key=value arguments are written through as metadata (name, variant,
# family, pairs-with, author, upstream, license, splash). `name` defaults to the
# ghostty display name; `variant` is derived from background luminance if omitted.

set -euo pipefail

GHOSTTY_THEME_DIR="${GHOSTTY_THEME_DIR:-/usr/share/ghostty/themes}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
THEME_OUT_DIR="${THEME_OUT_DIR:-$REPO_ROOT/themes}"

UPSTREAM_REPO="mbadolato/iTerm2-Color-Schemes"

die() { printf 'import-scheme: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'import-scheme: %s\n' "$*" >&2; }

usage() {
    cat >&2 <<'EOF'
usage: tools/import-scheme.sh "<Ghostty Display Name>" <our-theme-id> [key=value ...]
       tools/import-scheme.sh --all
EOF
    exit 2
}

# --- colour normalisation ---------------------------------------------------------
# Accepts "#RRGGBB", "RRGGBB", and ghostty's occasional "#rgb" shorthand. Emits
# lowercase "#rrggbb". Anything else is rejected: a malformed colour must never
# reach a theme file, because the runtime pastes these straight into an escape
# sequence.
normalise_hex() {  # <raw value> -> lowercase #rrggbb on stdout, or non-zero
    local v="${1//[[:space:]]/}"
    v="${v#\#}"
    v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    case "$v" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
            printf '#%s' "$v" ;;
        [0-9a-f][0-9a-f][0-9a-f])
            printf '#%c%c%c%c%c%c' "${v:0:1}" "${v:0:1}" \
                                   "${v:1:1}" "${v:1:1}" \
                                   "${v:2:1}" "${v:2:1}" ;;
        *) return 1 ;;
    esac
}

# --- WCAG relative luminance ------------------------------------------------------
# Only used to derive `variant` when the caller does not state it. The validator
# re-derives this independently and is the authority; this is a convenience.
luminance() {  # <#rrggbb> -> float on stdout
    awk -v hex="${1#\#}" 'BEGIN {
        for (i = 0; i < 16; i++) v[sprintf("%x", i)] = i
        split("", c)
        for (ch = 0; ch < 3; ch++) {
            hi = substr(hex, ch * 2 + 1, 1); lo = substr(hex, ch * 2 + 2, 1)
            s = (v[hi] * 16 + v[lo]) / 255
            c[ch] = (s <= 0.04045) ? s / 12.92 : ((s + 0.055) / 1.055) ^ 2.4
        }
        printf "%.6f", 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }'
}

derive_variant() {  # <#rrggbb background>
    awk -v l="$(luminance "$1")" 'BEGIN { print (l > 0.18) ? "light" : "dark" }'
}

# --- the importer -----------------------------------------------------------------
import_one() {  # <ghostty display name> <theme id> [key=value ...]
    local ghostty_name="$1" theme_id="$2"; shift 2

    [[ "$theme_id" =~ ^[a-z0-9-]+$ ]] \
        || die "theme id '$theme_id' is not [a-z0-9-]+"

    local src="$GHOSTTY_THEME_DIR/$ghostty_name"
    # v1 shipped a theme name ("Solarized Light") that is not in ghostty's corpus.
    # Nothing checked, so roughly one shell in twenty-four silently no-opped for
    # months. That is what this test is for: a missing source is fatal, never a
    # warning, never a skip.
    [[ -f "$src" ]] \
        || die "ghostty theme '$ghostty_name' not found under $GHOSTTY_THEME_DIR"

    # Collected values, keyed by our key names.
    declare -A out=()

    local line key val idx
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" == *=* ]] || continue

        key="${line%%=*}"; val="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"

        case "$key" in
            palette)
                # "palette = 7=#e5e9f0" — the inner N= is the OSC 4 index, kept verbatim.
                idx="${val%%=*}"
                val="${val#*=}"
                val="${val#"${val%%[![:space:]]*}"}"
                [[ "$idx" =~ ^([0-9]|1[0-5])$ ]] || continue
                out["color$((10#$idx))"]="$(normalise_hex "$val")" \
                    || die "$ghostty_name: palette $idx has a malformed colour: $val"
                ;;
            background|foreground|cursor-text|selection-background|selection-foreground)
                out["$key"]="$(normalise_hex "$val")" \
                    || die "$ghostty_name: $key has a malformed colour: $val"
                ;;
            cursor-color)
                # ghostty's cursor-color is our `cursor`.
                out[cursor]="$(normalise_hex "$val")" \
                    || die "$ghostty_name: cursor-color has a malformed colour: $val"
                ;;
        esac
    done < "$src"

    # The 18 values that must survive conversion. Metadata is not checked here —
    # missing metadata degrades gracefully, a missing colour does not.
    local missing=() k i
    for k in background foreground; do
        [[ -n "${out[$k]:-}" ]] || missing+=("$k")
    done
    for ((i = 0; i < 16; i++)); do
        [[ -n "${out[color$i]:-}" ]] || missing+=("color$i")
    done
    (( ${#missing[@]} == 0 )) \
        || die "$ghostty_name -> $theme_id: missing after conversion: ${missing[*]}"

    # Trailing key=value metadata.
    declare -A meta=()
    local pair mk mv
    for pair in "$@"; do
        [[ "$pair" == *=* ]] || die "metadata argument '$pair' is not key=value"
        mk="${pair%%=*}"; mv="${pair#*=}"
        mk="${mk#"${mk%%[![:space:]]*}"}"; mk="${mk%"${mk##*[![:space:]]}"}"
        mv="${mv#"${mv%%[![:space:]]*}"}"; mv="${mv%"${mv##*[![:space:]]}"}"
        [[ "$mk" =~ ^[a-z0-9-]+$ ]] || die "metadata key '$mk' is not [a-z0-9-]+"
        [[ -n "$mv" ]] || die "metadata key '$mk' has an empty value; omit the key instead"
        meta["$mk"]="$mv"
    done

    [[ -n "${meta[name]:-}" ]] || meta[name]="$ghostty_name"
    [[ -n "${meta[variant]:-}" ]] || meta[variant]="$(derive_variant "${out[background]}")"
    [[ "${meta[variant]}" == dark || "${meta[variant]}" == light ]] \
        || die "$theme_id: variant must be dark or light, got '${meta[variant]}'"

    mkdir -p "$THEME_OUT_DIR"
    local dest="$THEME_OUT_DIR/$theme_id.theme"

    {
        # Two-line provenance header. A leading '#' is the only comment form the
        # loader recognises; '#' anywhere else on a line is data.
        printf '# Converted from ghostty theme "%s" by tools/import-scheme.sh — do not hand-edit.\n' \
            "$ghostty_name"
        printf '# Upstream: %s (MIT); ghostty bundles a port of that corpus.\n' "$UPSTREAM_REPO"
        printf '\n'

        printf 'name = %s\n' "${meta[name]}"
        printf 'variant = %s\n' "${meta[variant]}"
        for k in family pairs-with author upstream license splash; do
            [[ -n "${meta[$k]:-}" ]] && printf '%s = %s\n' "$k" "${meta[$k]}"
        done
        # Any metadata key we did not name above, in sorted order, so callers can
        # add keys without editing this script.
        for k in $(printf '%s\n' "${!meta[@]}" | sort); do
            case "$k" in
                name|variant|family|pairs-with|author|upstream|license|splash) continue ;;
            esac
            printf '%s = %s\n' "$k" "${meta[$k]}"
        done

        printf '\n'
        printf 'background = %s\n' "${out[background]}"
        printf 'foreground = %s\n' "${out[foreground]}"
        # Optional keys are written only when the source had them; the loader
        # defaults cursor->foreground, cursor-text->background,
        # selection-background->foreground, selection-foreground->background.
        for k in cursor cursor-text selection-background selection-foreground; do
            [[ -n "${out[$k]:-}" ]] && printf '%s = %s\n' "$k" "${out[$k]}"
        done

        printf '\n'
        printf '# color<N>: N is the OSC 4 palette index, used verbatim by the runtime.\n'
        for ((i = 0; i < 16; i++)); do
            printf 'color%d = %s\n' "$i" "${out[color$i]}"
        done
    } > "$dest"

    note "wrote $(basename "$dest")  <-  $ghostty_name"
}

# --- the corpus -------------------------------------------------------------------
# Pipe-separated, one theme per row. Empty column means "omit that key entirely".
#
#   id | ghostty display name | name | variant | family | pairs-with | author | splash
#
# `splash` names a preset of the sibling tool splashboard. The valid set is what
# `splashboard install --theme <bogus>` enumerates; as of writing:
#   ayu_mirage catppuccin_frappe catppuccin_latte catppuccin_macchiato
#   catppuccin_mocha default dracula everforest_dark github_dark github_light
#   gruvbox_dark gruvbox_light kanagawa material_palenight monokai night_owl nord
#   one_dark rose_pine rose_pine_dawn rose_pine_moon solarized_dark solarized_light
#   synthwave_84 tokyo_night tokyo_night_storm
# An empty splash column is the correct default: it means "no matching preset",
# and the splash then inherits the terminal colours we just applied. Never write
# splash = "" or splash = reset.
corpus_table() {
    cat <<'EOF'
catppuccin-mocha|Catppuccin Mocha|Catppuccin Mocha|dark|catppuccin||Catppuccin|catppuccin_mocha
dracula|Dracula|Dracula|dark|dracula||Zeno Rocha|dracula
nord|Nord|Nord|dark|nord||Arctic Ice Studio|nord
rose-pine-moon|Rose Pine Moon|Rosé Pine Moon|dark|rose-pine||Rosé Pine|rose_pine_moon
tokyonight-storm|TokyoNight Storm|TokyoNight Storm|dark|tokyonight|tokyonight-day|Folke Lemaitre|tokyo_night_storm
ayu-mirage|Ayu Mirage|Ayu Mirage|dark|ayu||Ike Ku|ayu_mirage
solarized-dark|iTerm2 Solarized Dark|Solarized Dark|dark|solarized||Ethan Schoonover|solarized_dark
atom-one-dark|Atom One Dark|Atom One Dark|dark|atom-one||Atom (GitHub)|one_dark
everforest-dark|Everforest Dark Hard|Everforest Dark Hard|dark|everforest||sainnhe|everforest_dark
kanagawa-wave|Kanagawa Wave|Kanagawa Wave|dark|kanagawa|kanagawa-lotus|rebelot|kanagawa
gruvbox-material-dark|Gruvbox Material Dark|Gruvbox Material Dark|dark|gruvbox|gruvbox-material-light|sainnhe|gruvbox_dark
monokai-pro|Monokai Pro|Monokai Pro|dark|monokai|monokai-pro-light|Wimer Hazenberg|monokai
onenord|Onenord|Onenord|dark|onenord|onenord-light|rmehri01|
night-owl|Night Owl|Night Owl|dark|night-owl||Sarah Drasner|night_owl
github-dark|GitHub Dark Default|GitHub Dark Default|dark|github|github-light|GitHub Primer|github_dark
oxocarbon|Oxocarbon|Oxocarbon|dark|oxocarbon||Nyoom Engineering (IBM Carbon)|
gruvbox-material-light|Gruvbox Material Light|Gruvbox Material Light|light|gruvbox|gruvbox-material-dark|sainnhe|gruvbox_light
kanagawa-lotus|Kanagawa Lotus|Kanagawa Lotus|light|kanagawa|kanagawa-wave|rebelot|
tokyonight-day|TokyoNight Day|TokyoNight Day|light|tokyonight|tokyonight-storm|Folke Lemaitre|
monokai-pro-light|Monokai Pro Light Sun|Monokai Pro Light Sun|light|monokai|monokai-pro|Wimer Hazenberg|
onenord-light|Onenord Light|Onenord Light|light|onenord|onenord|rmehri01|
github-light|GitHub Light Default|GitHub Light Default|light|github|github-dark|GitHub Primer|github_light
flexoki-light|Flexoki Light|Flexoki Light|light|flexoki||Steph Ango|
alabaster|Alabaster|Alabaster|light|alabaster||Nikita Prokopov|
EOF
}

import_all() {
    local id gname name variant family pairs author splash args
    local count=0
    while IFS='|' read -r id gname name variant family pairs author splash; do
        [[ -z "$id" || "$id" == \#* ]] && continue
        args=("$gname" "$id" "name=$name" "variant=$variant"
              "upstream=https://github.com/$UPSTREAM_REPO" "license=MIT")
        [[ -n "$family" ]] && args+=("family=$family")
        [[ -n "$pairs"  ]] && args+=("pairs-with=$pairs")
        [[ -n "$author" ]] && args+=("author=$author")
        [[ -n "$splash" ]] && args+=("splash=$splash")
        import_one "${args[@]}"
        count=$((count + 1))
    done < <(corpus_table)
    note "regenerated $count themes into $THEME_OUT_DIR"
}

main() {
    case "${1:---help}" in
        --all)  (( $# == 1 )) || die "--all takes no other arguments"; import_all ;;
        -h|--help) usage ;;
        -*)     die "unknown option '$1'" ;;
        *)      (( $# >= 2 )) || usage; import_one "$@" ;;
    esac
}

main "$@"
