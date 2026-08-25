# common.sh — logging, hashing, and the file-write primitives.
#
# HOT-PATH RULE, and it is the reason this file exists: color-terminal runs on
# every new terminal pane, so nothing here may fork unless it truly must. v1 spent
# ~105 ms per run on `$(printf … | tr …)` inside its parse loop — measured 523 ms
# for 5 iterations against 4 ms for the identical work done with parameter
# expansion. Every helper below is a bash builtin except where a comment says
# otherwise and explains why.

CT_VERSION=2.0.0-dev

# --- diagnostics ------------------------------------------------------------------
# Everything goes to stderr. stdout is reserved for machine-readable output
# (--print-detected, --list) and fd 3 is reserved for escape sequences.
ct_warn()  { printf 'color-terminal: %s\n' "$*" >&2; }
ct_die()   { ct_warn "$*"; exit 1; }
ct_debug() { [ -n "${COLOR_TERMINAL_DEBUG:-}" ] && printf 'color-terminal: [debug] %s\n' "$*" >&2; return 0; }

# --- paths ------------------------------------------------------------------------
ct_paths_init() {
    CT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/color-terminal"
    CT_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/color-terminal"
    CT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/color-terminal"
    # Per-pane markers belong on tmpfs: they describe a pty that dies at logout, and
    # leaving them in ~/.local/state would accumulate one stale file per pane forever.
    CT_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$CT_STATE_DIR/run}/color-terminal"
}

# --- hashing ----------------------------------------------------------------------
# djb2 over the bytes of $1, in pure bash. Used to derive a deterministic theme from
# a repo path (so one project always looks the same) and to fingerprint a generated
# file so we can tell "the user edited this" from "we wrote this".
# Not a security primitive; collisions are cosmetic.
ct_hash() {                                   # <string> -> CT_HASH
    local s=$1 i=0 n=${#1} h=5381 c
    while [ "$i" -lt "$n" ]; do
        printf -v c '%d' "'${s:i:1}"
        # h*33 + c, kept inside 32 bits so the value is stable across hosts.
        h=$(( (h * 33 + c) & 0xffffffff ))
        i=$((i + 1))
    done
    CT_HASH=$h
}

# --- file writes ------------------------------------------------------------------
# A unique temp name without mktemp(1), which would be a fork. $$ is unique per
# process and $RANDOM per call, which is enough: the name only has to avoid the
# collision v1 hit by hardcoding "$STATE_FILE.tmp" and having twelve simultaneous
# shells clobber each other's rename.
ct_tmpname() { CT_TMP="$1.$$.$RANDOM.tmp"; }

# Replace a file atomically. rename(2) is atomic, so a reader either sees the whole
# old file or the whole new one — never a truncated one. `mv` is one fork; it is the
# only fork on the persist path and there is no builtin alternative.
ct_write_atomic() {                           # <dest> < content-on-stdin
    local dest=$1
    ct_tmpname "$dest"
    cat > "$CT_TMP" || { rm -f "$CT_TMP"; return 1; }
    mv -f "$CT_TMP" "$dest" || { rm -f "$CT_TMP"; return 1; }
}

# Same, but the content comes from a file we already rendered.
ct_move_atomic() {                            # <src> <dest>
    mv -f "$1" "$2"
}

# Append one short line. O_APPEND writes below PIPE_BUF are atomic, so concurrent
# panes interleave lines but never corrupt or truncate one another. This is what
# lets the history file be lock-free on the hot path; compaction (ct_state_compact)
# is the rare locked operation.
ct_append() {                                 # <file> <line>
    printf '%s\n' "$2" >> "$1" 2>/dev/null
}

# Advisory lock for the rare read-modify-write. flock(1) is a fork, so this is only
# ever called from compaction and from install-time wiring — never from a swap.
# Falls back to a noclobber sentinel where flock is absent (macOS), which is
# forkless but cannot block, so it spins briefly and then proceeds unlocked rather
# than deadlocking a login shell.
ct_lock() {                                   # <lockfile>; sets CT_LOCK_FD or CT_LOCK_FILE
    CT_LOCK_FD= CT_LOCK_FILE=
    if [ -n "$CT_HAVE_FLOCK" ]; then
        exec {CT_LOCK_FD}>>"$1" 2>/dev/null || return 1
        flock -w 2 "$CT_LOCK_FD" 2>/dev/null || { exec {CT_LOCK_FD}>&-; CT_LOCK_FD=; return 1; }
        return 0
    fi
    local tries=0
    set -o noclobber
    while ! { : > "$1.lock"; } 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -gt 40 ] && { set +o noclobber; return 1; }
        # No sleep(1) fork: a bounded busy spin is cheaper than a process for a lock
        # that is held for microseconds.
        local spin=0; while [ "$spin" -lt 200 ]; do spin=$((spin + 1)); done
    done
    set +o noclobber
    CT_LOCK_FILE="$1.lock"
}

ct_unlock() {
    [ -n "$CT_LOCK_FD" ] && exec {CT_LOCK_FD}>&- 2>/dev/null
    [ -n "$CT_LOCK_FILE" ] && rm -f "$CT_LOCK_FILE"
    CT_LOCK_FD= CT_LOCK_FILE=
    return 0
}

ct_mkdir() { [ -d "$1" ] || mkdir -p "$1" 2>/dev/null; }
