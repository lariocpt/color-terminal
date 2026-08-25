#!/usr/bin/env bash
# Regenerate test/golden/ — the committed expected output of every backend's render().
#
# Goldens are compared against OUR OWN previous output, never against an upstream
# project's port of the same theme. Upstream ports differ in comment headers, key
# ordering and extra sections; diffing against them produces benign failures on every
# run, and a test that cries wolf is a test people stop reading.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=/dev/null
. ./bin/color-terminal

# One dark and one light theme is enough to catch a format regression; the palette
# loop is the same for all 24.
THEMES=(catppuccin-mocha github-light)
TERMS=(ghostty foot)

ct_paths_init; ct_config_defaults; ct_theme_dirs
for term in "${TERMS[@]}"; do
    mkdir -p "test/golden/$term"
    for theme in "${THEMES[@]}"; do
        ct_theme_load "$theme" || { echo "cannot load $theme" >&2; exit 1; }
        case "$term" in ghostty) ext=conf ;; foot) ext=ini ;; *) ext=txt ;; esac
        "ct_be_${term}_render" > "test/golden/$term/$theme.$ext"
        echo "  test/golden/$term/$theme.$ext"
    done
done
echo "golden files regenerated"
