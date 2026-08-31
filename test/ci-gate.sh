#!/bin/sh
# test/ci-gate.sh — the Jenkins mirror's gate, run INSIDE a throwaway container.
#
# The Jenkinsfile copies this file (from the branch it was read from) into the
# workspace as .ci-gate.sh, copies the workspace into a debian:stable-slim container,
# and runs it there — because the Jenkins image has neither python3 nor make. It
# lives here rather than in a Groovy heredoc so `make lint` sees it: `sh -n`,
# `dash -n` and `shellcheck -s sh`, like docs/install.sh.
#
# Inputs, as environment: VERSION (bare, 2.0.0), TAG (v2.0.0), PROVENANCE (true|false).
# The workspace is at /w with the RELEASED artifact already at dist/color-terminal and
# its sha256 in /w/.released-sha. Nothing here may rebuild that file.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends python3 make curl ca-certificates >/dev/null
cd /w

released=$(cat /w/.released-sha)
want=$(ls themes/*.theme | wc -l)

# Themes are data the tool cannot run without, and a theme that fails the contrast
# gate makes somebody's terminal unreadable.
python3 tools/validate-themes.py

# NOT `make test`. That target depends on the dist rule, and a checkout whose lib/*.sh
# mtimes land after the download would rebuild over the released bytes and quietly
# destroy the point of this pipeline. test/run.sh only rebuilds dist/color-terminal
# when it is missing or non-executable, and Fetch made it executable.
./test/run.sh

[ "$(sha256sum dist/color-terminal | awk '{print $1}')" = "$released" ] \
  || { echo "FAIL: dist/color-terminal changed during the gate — something rebuilt it"; exit 1; }

got=$(./dist/color-terminal --version | tr -d '\r')
[ "$got" = "color-terminal $VERSION" ] \
  || { echo "FAIL: artifact reports '$got', expected 'color-terminal $VERSION'"; exit 1; }

# The payload must survive the round trip, or the plane serves a tool with no themes —
# which fails at first use, not at install time.
tmp=$(mktemp -d)
HOME="$tmp" XDG_RUNTIME_DIR="$tmp/run" CT_QUIET=1 ./dist/color-terminal --install --no-wire >/dev/null
n=$(ls "$tmp/.local/share/color-terminal/themes"/*.theme 2>/dev/null | wc -l)
[ "$n" -eq "$want" ] || { echo "FAIL: artifact installed $n themes, expected $want"; exit 1; }
echo "payload round-trip: $n themes"

# Provenance, and it is what makes "mirror" mean something: proof the released bytes
# came from this tag, without rebuilding what actually gets published. `make dist` is
# reproducible — the payload tar is built with normalised mtimes, ownership, modes and
# sort order — so a rebuild of this tag must match the published file byte for byte.
if [ "$PROVENANCE" = true ]; then
    rm -rf /build && mkdir -p /build
    tar -cf - --exclude=./dist --exclude=./.git . | tar -xf - -C /build
    make -s -C /build dist >/dev/null
    cmp /build/dist/color-terminal /w/dist/color-terminal \
      || { echo "FAIL: the released artifact is not what $TAG builds"; exit 1; }
    echo "provenance: released artifact is byte-identical to a rebuild of $TAG"
fi

# And nothing above touched the file that is about to be published.
[ "$(sha256sum /w/dist/color-terminal | awk '{print $1}')" = "$released" ] \
  || { echo "FAIL: dist/color-terminal changed during the gate"; exit 1; }
