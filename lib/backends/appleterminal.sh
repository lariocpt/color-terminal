# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# shellcheck disable=SC2034
# tier: 3
# name: Apple Terminal
# Terminal.app — identified, and deliberately NOT recoloured. It has no palette OSC
# at all; what it does not understand it partly prints, so emitting into it is
# strictly worse than silence.

ct_be_appleterminal_detect() {
    if [ "${TERM_PROGRAM:-}" = Apple_Terminal ]; then
        CT_CONF=certain; ct_env_local && CT_LOCAL=1; return 0
    fi
    return 1
}

ct_be_appleterminal_caps() { printf ''; }

ct_be_appleterminal_decline() {
    printf 'Apple Terminal has no palette OSC; it would print fragments of the sequences instead of applying them'
}
