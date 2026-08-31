# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# shellcheck disable=SC2034
# tier: 3
# name: Warp
# Warp — identified, and deliberately NOT recoloured. Warp owns its palette through
# its own theme system and ignores OSC 4/10/11 entirely.

ct_be_warp_detect() {
    # TERM_PROGRAM is set by the terminal that owns the shell and OVERWRITTEN by any
    # terminal launched from it, so unlike an inherited private variable it always
    # names the innermost terminal. That is why this backend runs before ghostty's.
    if [ "${TERM_PROGRAM:-}" = WarpTerminal ]; then
        CT_CONF=certain; ct_env_local && CT_LOCAL=1; return 0
    fi
    return 1
}

ct_be_warp_caps() { printf ''; }

ct_be_warp_decline() {
    printf 'Warp ignores OSC palette sequences; its theme is set in its own settings'
}
