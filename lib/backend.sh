# backend.sh — the terminal backend registry and the operations the core drives.
#
# A backend is one file, lib/backends/<id>.sh, defining functions prefixed
# ct_be_<id>_. It may read the CT_* globals; it must not read "$@", must not write to
# fd 3 (only lib/emit.sh does that), and must not call exit.
#
#   ct_be_<id>_detect()    -> 0 if this backend owns the current terminal.
#                             Sets CT_CONF, and CT_LOCAL=1 only on a signal that
#                             proves the terminal process is on THIS host.
#                             Parameter expansion only: it runs on every shell.
#   ct_be_<id>_caps()      -> prints a space-separated capability token list:
#                             set4 set10 set11 set12 set17 set19
#                             rst104 rst110 rst111 rst112 rst117 rst119
#                             persist unfork
#   ct_be_<id>_render()    -> writes this terminal's config syntax for the loaded
#                             theme to STDOUT. A pure function of the CT_* theme
#                             globals; this is exactly what the golden tests diff.
#   ct_be_<id>_persist()   <rendered-file> -> move into place atomically (+ reload).
#   ct_be_<id>_wire()      -> one-time: add ONE include line to the user's own
#                             config. Idempotent. 0 wired / 3 already / 1 refused.
#   ct_be_<id>_unwire()    -> exact inverse; remove the include line FIRST, then the
#                             fragment, because some terminals treat a missing
#                             include as a hard startup error.
#
# Optional: _reload, _fragment, _decline (defining _decline is what marks a tier-3
# backend — one we can identify but must not send colours to).

# Registration order IS detection order, so it is an explicit list and not a glob.
# Trap terminals must precede anything that matches on $TERM, and `generic` accepts
# everything so it must be last.
CT_BACKENDS=(ghostty foot generic)

CT_MARK_BEGIN="# >>> color-terminal >>>"
CT_MARK_END="# <<< color-terminal <<<"

# Default fragment location. A backend overrides it only when the terminal insists on
# a particular directory or extension.
ct_fragment_path() {                          # -> CT_FRAGMENT
    if ct_fn_exists "ct_be_${CT_BACKEND}_fragment"; then
        CT_FRAGMENT=$("ct_be_${CT_BACKEND}_fragment")
    else
        CT_FRAGMENT="${XDG_CONFIG_HOME:-$HOME/.config}/$CT_BACKEND/color-terminal.conf"
    fi
}

ct_fn_exists() { declare -F "$1" >/dev/null 2>&1; }

ct_is_tier3() { ct_fn_exists "ct_be_${CT_BACKEND}_decline"; }

# Render the loaded theme and move it into place. Never called unless
# ct_may_persist() said yes, so backends do not re-check locality.
ct_persist() {
    ct_fn_exists "ct_be_${CT_BACKEND}_render" || return 0
    ct_fragment_path
    ct_mkdir "${CT_FRAGMENT%/*}"
    ct_tmpname "$CT_FRAGMENT"
    "ct_be_${CT_BACKEND}_render" > "$CT_TMP" || { rm -f "$CT_TMP"; return 1; }
    "ct_be_${CT_BACKEND}_persist" "$CT_TMP" || { rm -f "$CT_TMP"; return 1; }
    ct_fn_exists "ct_be_${CT_BACKEND}_reload" && "ct_be_${CT_BACKEND}_reload"
    return 0
}

ct_wire()   { ct_fn_exists "ct_be_${CT_BACKEND}_wire"   && "ct_be_${CT_BACKEND}_wire";   }
ct_unwire() { ct_fn_exists "ct_be_${CT_BACKEND}_unwire" && "ct_be_${CT_BACKEND}_unwire"; }
