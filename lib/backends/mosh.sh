# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# shellcheck disable=SC2034
# tier: 3
# name: mosh
# mosh — identified, and deliberately NOT recoloured. mosh's state-sync protocol
# carries the screen, not the byte stream: OSC palette sequences are dropped on the
# server side and never reach the terminal on your desk.

ct_be_mosh_detect() {
    # There is no environment variable to test. mosh forwards TERM verbatim and sets
    # nothing of its own — which is exactly why TERM=xterm-ghostty over mosh would
    # otherwise be claimed by the ghostty backend and recoloured into a transport
    # that discards the bytes. So this backend is registered first, and it finds
    # mosh the only way it can be found: mosh-server is an ancestor of the shell.
    #
    # The walk is gated on CT_SSH because mosh-server is launched through an ssh
    # session whose SSH_CONNECTION it inherits, so a local shell never pays for it.
    # It reads /proc with builtins — no ps(1), no fork — and gives up quietly where
    # there is no /proc; a wrong answer there costs one ignored recolour.
    [ -n "$CT_SSH" ] || return 1
    [ -r /proc/self/stat ] || return 1
    local pid=$$ line comm rest fields depth=0
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 16 ]; do
        IFS= read -r line 2>/dev/null < "/proc/$pid/stat" || return 1
        # comm sits between the first '(' and the LAST ')': it may itself contain
        # spaces and parentheses.
        comm=${line#*\(}; comm=${comm%\)*}
        case "$comm" in mosh-server*) CT_CONF=certain; return 0 ;; esac
        rest=${line##*\) }
        # shellcheck disable=SC2206  # deliberate word-splitting of a known-numeric line
        fields=($rest)
        pid=${fields[1]:-}                    # ppid
        depth=$((depth + 1))
    done
    return 1
}

ct_be_mosh_caps() { printf ''; }

ct_be_mosh_decline() {
    printf 'mosh does not relay OSC palette sequences — nothing sent here reaches your terminal'
}
