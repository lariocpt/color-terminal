# shellcheck shell=bash
# emit.sh — the ONLY place in color-terminal that writes an escape byte.
#
# Everything is emitted on fd 3, which is /dev/tty, never on stdout. stdout may be a
# pipe (scp, rsync, git-over-ssh) and a stray escape byte there corrupts the stream.
# test/pty.py asserts that a full run puts zero 0x1b bytes on stdout; that assertion
# is the entire justification for the extra descriptor.

# Open fd 3 on the controlling terminal. Unlike v1's ancestor color-ghostty we do not
# bail when there is no tty: the file side effects (the terminal's include fragment,
# the splash sink) are what the NEXT window reads, so they must still happen. Only
# the escape writes go quiet.
ct_tty_init() {
    if { exec 3>/dev/tty; } 2>/dev/null; then CT_HAVE_TTY=1; else CT_HAVE_TTY=0; fi
}

# ct_emit <osc-payload>
#
# Two deliberate differences from v1, both bug fixes:
#
#  * No tmux branch. v1 wrapped payloads in tmux's DCS passthrough
#    (\ePtmux;\e\e]…\e\e\\\e\\), but `allow-passthrough` has defaulted to OFF since
#    tmux 3.3 — so on a stock tmux that wrapper was a silent no-op. Meanwhile tmux
#    itself implements OSC 4/10/11/12/104/110/111/112 natively against the pane's own
#    palette (input.c, input_exit_osc). Plain OSC is both simpler and the thing that
#    actually works. Deleting the branch removes code and fixes behaviour.
#
#  * The screen wrapper terminates the inner string with BEL, not ESC-backslash.
#    screen's DCS parser (ansi.c, STRESC) ends its own string at the first ESC \, so
#    v1's inner ESC \ terminated screen's DCS and shipped an UNTERMINATED OSC to the
#    outer terminal, which then swallowed following output into the OSC string. BEL
#    is collected as ordinary data inside a DCS, so it survives to the far end.
ct_emit() {                                   # <osc-payload>
    [ "$CT_HAVE_TTY" = 1 ] || return 0
    if [ -n "$CT_SCREEN" ]; then
        printf '\033P\033]%s\a\033\\' "$1" >&3
    else
        printf '\033]%s\033\\' "$1" >&3
    fi
}

# True when the detected backend declared <token> in its capability list.
# CT_CAPS is a space-delimited string with sentinel spaces at both ends, so a plain
# substring test is exact and forkless.
ct_cap() { case "$CT_CAPS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Apply the currently loaded theme (CT_PAL / CT_BG / …) to the live terminal.
#
# One OSC 4 per index, never the multi-pair "4;0;#…;1;#…" form. The multi-pair form
# is legal and shorter, and it is wrong here: st reads only the first pair, zellij
# returns after the first, and foot aborts the remainder of the sequence on any
# out-of-range index. One-per-index behaves identically everywhere.
ct_apply_live() {
    local i
    if ct_cap set4; then
        i=0
        while [ "$i" -lt 16 ]; do
            [ -n "${CT_PAL[i]}" ] && ct_emit "4;$i;${CT_PAL[i]}"
            i=$((i + 1))
        done
    fi
    # wezterm permanently detaches a pane's palette from its config the first time it
    # receives a colour OSC, and only a bare OSC 104 re-attaches it. Backends that
    # need that dance declare `unfork`; nobody else pays for it.
    ct_cap unfork && ct_emit "104"
    ct_cap set10 && [ -n "$CT_FG" ]     && ct_emit "10;$CT_FG"
    ct_cap set11 && [ -n "$CT_BG" ]     && ct_emit "11;$CT_BG"
    ct_cap set12 && [ -n "$CT_CURSOR" ] && ct_emit "12;$CT_CURSOR"
    ct_cap set17 && [ -n "$CT_SEL_BG" ] && ct_emit "17;$CT_SEL_BG"
    ct_cap set19 && [ -n "$CT_SEL_FG" ] && ct_emit "19;$CT_SEL_FG"
    return 0
}

# Hand the terminal back to its *configured* colours. Called by the shell hook when
# an ssh session ends, so the local window stops wearing the remote host's theme.
#
# v1 emitted 104/110/111/112 only — but it *set* 17 and 19 on the way in, and their
# reset counterparts are 117 and 119. The selection colours therefore leaked from
# every remote host into the local window and stayed there. Fixed here, and gated on
# the same caps as the apply side so we never send a reset the terminal will log as
# unimplemented.
ct_reset_live() {
    ct_cap rst104 && ct_emit "104"
    ct_cap rst110 && ct_emit "110"
    ct_cap rst111 && ct_emit "111"
    ct_cap rst112 && ct_emit "112"
    ct_cap rst117 && ct_emit "117"
    ct_cap rst119 && ct_emit "119"
    return 0
}
