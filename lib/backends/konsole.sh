# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# shellcheck disable=SC2034
# tier: 3
# name: konsole
# konsole — identified, and deliberately NOT recoloured.
#
# konsole parses OSC 4, stores the colour, answers an OSC 4;N;? query with it, and
# never renders with it. A recolour therefore LOOKS like it worked — even a probe
# would confirm it — while the window stays exactly as it was. That is worse than
# doing nothing, so this backend exists to say no, and to say why.

ct_be_konsole_detect() {
    # KONSOLE_VERSION is exported by the konsole process itself. ssh does not forward
    # it, so over ssh FROM konsole we cannot tell, fall through to generic, and emit
    # into a terminal that ignores it: harmless, and the honest limit of detection
    # without a probe. It IS inherited by anything launched from a konsole shell,
    # which is why the TERM_PROGRAM-based backends (which every terminal overwrites)
    # are registered ahead of this one.
    if [ -n "${KONSOLE_VERSION:-}" ]; then
        CT_CONF=certain; ct_env_local && CT_LOCAL=1; return 0
    fi
    return 1
}

ct_be_konsole_caps() { printf ''; }

ct_be_konsole_decline() {
    printf 'konsole accepts OSC 4, stores it and answers queries about it, but never renders with it — a recolour would look like it worked and change nothing'
}
