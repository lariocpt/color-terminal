# Auto-recolor: random ghostty theme + matching splashboard palette on each new
# interactive ghostty shell. Sourced from ~/.bashrc by color-terminal's install.sh
# (or by cli-tools-installer, which vendors this snippet). See the .zsh twin for
# why each condition exists.
case "$TERM" in
    xterm-ghostty*)
        if [[ $- == *i* && -t 1 ]] && command -v color-terminal >/dev/null 2>&1; then
            color-terminal >/dev/null 2>&1
            if [ -n "${SSH_CONNECTION:-}" ]; then
                trap 'color-terminal --reset >/dev/null 2>&1' EXIT
            fi
        fi
        ;;
esac
