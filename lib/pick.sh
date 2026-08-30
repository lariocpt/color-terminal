# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# SC2154: CT_CFG_* are assigned by the config parser at runtime.
# shellcheck disable=SC2034,SC2154
# pick.sh — choose which theme this pane gets.
#
# Four modes, all fed by the same candidate set: the bundled corpus, narrowed by the
# user's allowlist and their light/dark policy, minus whatever the anti-repeat window
# has seen recently.

# Build CT_CANDIDATES from the index, applying `themes =` and `variant =`.
ct_candidates() {
    CT_CANDIDATES=()
    local i n=${#CT_THEME_IDS[@]} id var want allow
    ct_variant_wanted; want=$CT_VAR
    for ((i = 0; i < n; i++)); do
        id="${CT_THEME_IDS[i]}"
        var="${CT_THEME_VARIANTS[i]}"
        if [ -n "$CT_CFG_themes" ]; then
            allow=0
            case " $CT_CFG_themes " in *" $id "*) allow=1 ;; esac
            [ "$allow" = 1 ] || continue
        fi
        [ "$want" = mixed ] || [ "$var" = "$want" ] || continue
        CT_CANDIDATES+=("$id")
    done
    # An allowlist plus a variant filter can legitimately intersect to nothing (all
    # your chosen themes are dark, and it is daytime). Falling back to the whole
    # corpus beats refusing to colour the terminal.
    if [ ${#CT_CANDIDATES[@]} -eq 0 ]; then
        ct_debug "no candidates after filtering; falling back to the full corpus"
        CT_CANDIDATES=("${CT_THEME_IDS[@]}")
    fi
}

# mixed | dark | light, resolving `clock` to one of the latter two. Sets CT_VAR rather
# than printing, for the same no-fork reason as ct_theme_variant_of.
ct_variant_wanted() {                         # -> CT_VAR
    case "$CT_CFG_variant" in
        dark|light|mixed) CT_VAR=$CT_CFG_variant; return 0 ;;
    esac
    # clock: light during the working day, dark otherwise. printf's %(...)T is a bash
    # builtin (4.2+), so the common case costs no fork; date(1) is the fallback.
    local hour
    if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
        printf -v hour '%(%H)T' -1
    else
        hour=$(date +%H 2>/dev/null) || hour=12
    fi
    hour=$((10#$hour))
    if [ "$hour" -ge 7 ] && [ "$hour" -lt 19 ]; then CT_VAR=light; else CT_VAR=dark; fi
}

ct_in_history() {                             # <id>
    local h
    for h in "${CT_HISTORY[@]}"; do [ "$h" = "$1" ] && return 0; done
    return 1
}

ct_pick() {                                   # -> CT_PICK
    CT_PICK=

    # A per-host pin or an explicit `fixed` mode short-circuits everything, including
    # the pre-seed. This is the "I chose this on purpose, leave it alone" path.
    if [ "$CT_CFG_pick_mode" = fixed ] && [ -n "$CT_CFG_fixed_theme" ]; then
        CT_PICK=$CT_CFG_fixed_theme
        return 0
    fi

    ct_candidates
    local n=${#CT_CANDIDATES[@]}
    [ "$n" -gt 0 ] || return 1

    case "$CT_CFG_pick_mode" in
        repo)
            # Every checkout of a project looks the same every time you enter it,
            # which makes the theme a memory aid rather than noise. Derived from the
            # repo path, so it needs no state and agrees across machines.
            ct_hash "${CT_REPO_ROOT:-$PWD}"
            CT_PICK="${CT_CANDIDATES[CT_HASH % n]}"
            return 0 ;;
        rotate)
            local last="" i=0
            [ ${#CT_HISTORY[@]} -gt 0 ] && last="${CT_HISTORY[${#CT_HISTORY[@]} - 1]}"
            for ((i = 0; i < n; i++)); do
                if [ "${CT_CANDIDATES[i]}" = "$last" ]; then
                    CT_PICK="${CT_CANDIDATES[(i + 1) % n]}"; return 0
                fi
            done
            CT_PICK="${CT_CANDIDATES[0]}"
            return 0 ;;
    esac

    # random, with the anti-repeat window. Build the not-recently-seen set first.
    local avail=() id
    for id in "${CT_CANDIDATES[@]}"; do
        ct_in_history "$id" || avail+=("$id")
    done
    # Everything is in the window (a small allowlist, or no-repeat set too high):
    # repeat rather than refuse.
    [ ${#avail[@]} -eq 0 ] && avail=("${CT_CANDIDATES[@]}")
    CT_PICK="${avail[RANDOM % ${#avail[@]}]}"
    return 0
}
