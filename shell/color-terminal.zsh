# Auto-recolor: random ghostty theme + matching splashboard palette on each new
# interactive ghostty shell. Sourced from ~/.zshrc by color-terminal's install.sh
# (or by cli-tools-installer, which vendors this snippet).
#
# Gate on $TERM, not $GHOSTTY_RESOURCES_DIR: the latter is exported by the ghostty
# process and is NOT forwarded over ssh, so gating on it would make this a silent
# no-op on every remote host. $TERM does travel with the pty.
#
# The interactive + tty conditions are load-bearing, not defensive: color-terminal
# emits escape sequences, and a stray OSC byte on a non-interactive ssh session
# corrupts scp, rsync and git-over-ssh.
#
# This must be sourced BEFORE the splashboard init block in the rc file, so the
# splash palette is synced before the splash renders.
if [[ $TERM == xterm-ghostty* && -o interactive && -t 1 ]] \
   && command -v color-terminal >/dev/null 2>&1; then
    color-terminal >/dev/null 2>&1

    # On a remote host the colours we just set belong to the *local* window, so hand
    # them back when the session ends instead of leaving it wearing the remote's theme.
    if [[ -n "$SSH_CONNECTION" ]]; then
        zshexit() { color-terminal --reset >/dev/null 2>&1 }
    fi
fi
