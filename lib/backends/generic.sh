# shellcheck shell=bash
# SC2034: globals are written in one fragment and read in another.
# shellcheck disable=SC2034
# tier: 2
# name: everything else
# generic — every terminal we have not been introduced to, and every ssh session.
#
# This is not a fallback in the apologetic sense: it is the correct answer for the
# majority of real invocations. The subset below (16 palette entries, foreground,
# background, cursor, and their resets) is implemented by every terminal in tiers 1
# and 2 — xterm, urxvt, st, rio, contour, wezterm, iTerm2, Windows Terminal, VS Code's
# xterm.js, and the whole VTE family. Sending exactly this needs no handshake, no
# probe, and no per-terminal knowledge, which is why ssh needs no special case.
#
# What it deliberately does NOT do is touch a single file. We do not know what
# terminal this is, so we do not know what config to write, and guessing would mean
# writing a file some other program owns.

ct_be_generic_detect() {
    CT_CONF=guess
    return 0                                  # accepts everything; registered last
}

ct_be_generic_caps() {
    printf 'set4 set10 set11 set12 rst104 rst110 rst111 rst112'
}
