#!/usr/bin/env bash
# install.sh — build the single-file artifact, then let it install itself.
#
# THIS IS THE CHECKOUT ENTRYPOINT, not the one you curl. There are two files named
# install.sh in this repo and they do different jobs:
#
#   this one          you have a clone; it runs `make dist` and installs what it built
#   docs/install.sh   the public bootstrap; POSIX sh, downloads a release and verifies
#                     its sha256. That is what the website serves.
#
# It is deliberately thin. The real installer lives in lib/install.sh and is compiled
# into dist/color-terminal, because that is the artifact everything else consumes:
#
#   the published release (what a stranger runs):
#       curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh
#
#   from a checkout (what you are doing now):
#       ./install.sh
#
#   from nothing at all:
#       scp dist/color-terminal remote: && ssh remote ./color-terminal --install
#
# All three run the same code. Keeping the installer inside the artifact instead of
# beside it is what makes the last two possible.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Piped from curl, $HERE is the caller's cwd and there is no Makefile in it. Without
# this the failure is `make dist failed`, which tells you nothing about the fact that
# you fetched the wrong install.sh.
if [ ! -f "$HERE/Makefile" ]; then
    cat >&2 <<'EOF'
install.sh: this is the checkout entrypoint and needs a clone to build from.

To install color-terminal without cloning, use the published release:

    curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh

To build from source instead:

    git clone https://github.com/lariocpt/color-terminal.git
    cd color-terminal && ./install.sh
EOF
    exit 1
fi

make -s -C "$HERE" dist >/dev/null || { echo "make dist failed" >&2; exit 1; }
exec "$HERE/dist/color-terminal" --install "$@"
