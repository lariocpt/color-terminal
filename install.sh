#!/usr/bin/env bash
# install.sh — build the single-file artifact, then let it install itself.
#
# This is the CHECKOUT entrypoint and it is deliberately thin. The real installer
# lives in lib/install.sh and is compiled into dist/color-terminal, because that is
# the artifact everything else consumes:
#
#   from the estate's apps plane (what every other machine should use):
#       curl -fsSL https://apps.in.drlario.org/install.sh | bash -s -- color-terminal
#       color-terminal --install
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

make -s -C "$HERE" dist >/dev/null || { echo "make dist failed" >&2; exit 1; }
exec "$HERE/dist/color-terminal" --install "$@"
