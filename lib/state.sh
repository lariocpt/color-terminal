# shellcheck shell=bash
# SC2154: CT_CFG_* are assigned by the config parser at runtime.
# shellcheck disable=SC2154
# state.sh — what has been picked recently, what the next pane should get, and which
# panes have already been coloured.
#
# v1 kept its history with `echo >> F; tail -n 5 F > F.tmp; mv F.tmp F` and a FIXED
# temp name. Twelve concurrent shells — one tiling-WM session restore — empties that
# file: measured here, 0 lines in four runs out of five. So the anti-repeat guarantee
# evaporated in exactly the case where repeats are most visible.
#
# The fix is to make the hot path append-only. A short O_APPEND write is atomic, so
# panes interleave lines but never truncate each other, and nothing needs a lock.
# Trimming happens in ct_state_compact, which is rare and locked.

ct_state_init() {
    CT_HISTORY_FILE="$CT_STATE_DIR/history"
    CT_NEXT_FILE="$CT_STATE_DIR/next"
    CT_PANE_DIR="$CT_RUNTIME_DIR/panes"
}

# --- pane identity ------------------------------------------------------------------
# "Have the colours already been set in this pane?" A shell cannot see its terminal
# window, but it can see its SESSION: every subshell, `su`, `:!sh`, agent, and `exec`
# inside one pane shares one session id, and a new pane gets a new one. Pairing the
# session id with the session leader's start time makes the key unique even after pid
# reuse.
#
# This is the whole answer to the bug where SHLVL=3 means three nested shells each
# re-randomise the window while you are typing.
#
# Read straight out of /proc — no ps(1) fork. comm (field 2) may contain spaces and
# parentheses, so everything is taken after the LAST ')' before splitting.
ct_pane_key() {                               # -> CT_PANE_KEY ("" if undeterminable)
    CT_PANE_KEY=
    [ -r /proc/self/stat ] || return 1
    local line rest fields sid start
    IFS= read -r line < /proc/self/stat || return 1
    rest="${line##*) }"
    # shellcheck disable=SC2206  # deliberate word-splitting of a known-numeric line
    fields=($rest)
    # After comm, fields are: state ppid pgrp session tty_nr ... (0-indexed here)
    sid="${fields[3]}"
    [ -n "$sid" ] && [ -r "/proc/$sid/stat" ] || return 1
    IFS= read -r line < "/proc/$sid/stat" || return 1
    rest="${line##*) }"
    # shellcheck disable=SC2206  # deliberate word-splitting of a known-numeric line
    fields=($rest)
    start="${fields[19]}"                     # starttime
    CT_PANE_KEY="$sid.$start"
}

# 0 if this pane has not been coloured yet (and claims it), 1 if it already was.
#
# Under --dry-run it reports without claiming. A dry run that silently consumed the
# pane marker would make the very next real run a no-op — which is the opposite of
# what "show me what would happen" means.
ct_pane_claim() {
    ct_pane_key || return 0                   # no /proc: cannot tell, so always allow
    [ -e "$CT_PANE_DIR/$CT_PANE_KEY" ] && return 1
    [ "${CT_DRY:-0}" = 1 ] && return 0
    ct_mkdir "$CT_PANE_DIR"
    : > "$CT_PANE_DIR/$CT_PANE_KEY" 2>/dev/null
    return 0
}

# --- history --------------------------------------------------------------------------
ct_state_history() {                          # -> CT_HISTORY (most recent last)
    CT_HISTORY=() CT_HISTORY_COUNT=0
    [ -r "$CT_HISTORY_FILE" ] || return 0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && { CT_HISTORY+=("$line"); CT_HISTORY_COUNT=$((CT_HISTORY_COUNT + 1)); }
    done < "$CT_HISTORY_FILE"
    # Keep only the tail we actually consult.
    local n=${#CT_HISTORY[@]} keep=$((CT_CFG_no_repeat + 1))
    if [ "$n" -gt "$keep" ]; then
        CT_HISTORY=("${CT_HISTORY[@]:n-keep}")
    fi
    return 0
}

ct_state_record() {                           # <theme-id>
    ct_mkdir "$CT_STATE_DIR"
    ct_append "$CT_HISTORY_FILE" "$1"
    # Compaction is driven off the line count ct_state_history already counted while
    # reading the file, so the common path costs nothing extra. Append-only growth of
    # 50 lines is a few hundred bytes; there is no urgency.
    [ "${CT_HISTORY_COUNT:-0}" -gt 50 ] && ct_state_compact
    return 0
}

ct_state_compact() {
    ct_lock "$CT_HISTORY_FILE" || return 0    # busy: another pane is doing it
    local keep=$((CT_CFG_no_repeat + 1)) lines=() line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && lines+=("$line")
    done < "$CT_HISTORY_FILE"
    local n=${#lines[@]}
    [ "$n" -gt "$keep" ] && lines=("${lines[@]:n-keep}")
    ct_tmpname "$CT_HISTORY_FILE"
    printf '%s\n' "${lines[@]}" > "$CT_TMP" && mv -f "$CT_TMP" "$CT_HISTORY_FILE"
    rm -f "$CT_TMP" 2>/dev/null
    ct_unlock
    return 0
}

# --- the pre-seeded next pick -----------------------------------------------------
# Why this exists: with persistence on, a brand-new window opens showing whatever the
# include fragment says — the PREVIOUS theme — and then the shell hook swaps it. That
# is a visible flash on every new window.
#
# So after applying theme N we pick N+1 immediately, write THAT into the fragment, and
# remember it here. The next window therefore opens already wearing N+1, and its hook
# consumes this file instead of re-randomising: same theme, no flash.
ct_next_read() {                              # -> CT_NEXT ("" if none)
    CT_NEXT=
    [ -r "$CT_NEXT_FILE" ] || return 1
    IFS= read -r CT_NEXT < "$CT_NEXT_FILE" || return 1
    CT_NEXT="${CT_NEXT#"${CT_NEXT%%[![:space:]]*}"}"
    CT_NEXT="${CT_NEXT%"${CT_NEXT##*[![:space:]]}"}"
    [ -n "$CT_NEXT" ]
}

ct_next_write() {                             # <theme-id>
    ct_mkdir "$CT_STATE_DIR"
    printf '%s\n' "$1" | ct_write_atomic "$CT_NEXT_FILE"
}

# --- migration from v1 ------------------------------------------------------------
# v1 shared ~/.cache/ghostty_theme_history with the older color-ghostty tool, storing
# ghostty DISPLAY NAMES. v2 stores theme ids. Import once, map what maps, drop what
# does not — an anti-repeat window that is briefly shorter is not worth code.
# The old file is never deleted: it belongs to a tool we do not own.
ct_migrate_history() {
    local old="${XDG_CACHE_HOME:-$HOME/.cache}/ghostty_theme_history"
    [ "$CT_CFG_legacy_history" = ignore ] && return 0
    [ -r "$old" ] || return 0
    [ -e "$CT_HISTORY_FILE" ] && return 0     # already migrated
    ct_mkdir "$CT_STATE_DIR"
    local line id
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        ct_legacy_name_to_id "$line" && ct_append "$CT_HISTORY_FILE" "$id"
    done < "$old"
    [ -e "$CT_HISTORY_FILE" ] || : > "$CT_HISTORY_FILE"
    return 0
}

# Ghostty display name -> bundled theme id, by family. Only the families the bundled
# corpus actually contains; anything else is dropped rather than invented.
ct_legacy_name_to_id() {                      # <display name> -> sets $id
    case "$1" in
        "Catppuccin Mocha")       id=catppuccin-mocha ;;
        "Dracula")                id=dracula ;;
        "Nord")                   id=nord ;;
        "Rose Pine Moon")         id=rose-pine-moon ;;
        TokyoNight*)              id=tokyonight-storm ;;
        "Ayu Mirage")             id=ayu-mirage ;;
        "Solarized Dark Patched"|"iTerm2 Solarized Dark") id=solarized-dark ;;
        "Monokai Pro")            id=monokai-pro ;;
        "Gruvbox Dark")           id=gruvbox-material-dark ;;
        "Gruvbox Light")          id=gruvbox-material-light ;;
        "Alabaster")              id=alabaster ;;
        *) return 1 ;;
    esac
    return 0
}
