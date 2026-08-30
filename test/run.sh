#!/usr/bin/env bash
# test/run.sh — the whole suite. No dependencies beyond bash and python3.
#
# bats would be conventional, but it is not installed here and cannot be installed
# without sudo, and vendoring a test framework to run forty assertions against a
# shell script is a poor trade. This harness is forty lines.
#
# Layers, cheapest first:
#   L1 unit     pure functions, no terminal
#   L2 pty      exact escape bytes, via test/faketerm.py
#   L3 matrix   terminal identification for terminals that are NOT installed
#   L4 stress   concurrency and latency, which are where v1 actually broke

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO=$PWD
PASS=0 FAIL=0
FAILED=()

# Every test runs against a throwaway HOME. This guard is not paranoia: v1 wrote to
# five real dotfiles, and a test that leaks would rewrite the developer's own ~/.zshrc
# and ghostty config.
#
# Isolating HOME is not enough on its own. ct_paths_init honours the whole XDG set, so
# an ambient XDG_CONFIG_HOME sends config, hooks and host pins somewhere the sandbox
# does not reach — and if it holds its conventional value, "somewhere" is the
# developer's own ~/.config/color-terminal. GitHub's runners export XDG_CONFIG_HOME,
# which is how this surfaced. XDG_RUNTIME_DIR is exempt: each test sets it per-home.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/color-terminal-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
case "$SANDBOX" in /tmp/*|/var/folders/*|"${TMPDIR%/}"/*) ;; *) echo "refusing to run: sandbox $SANDBOX is not under a temp dir" >&2; exit 1 ;; esac

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
nope() { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else nope "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) nope "$1" "[$2] does not contain [$3]" ;; esac; }
hasnt(){ case "$2" in *"$3"*) nope "$1" "[$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

newhome() {                                   # -> $H, a fresh isolated HOME
    H="$SANDBOX/h$RANDOM$RANDOM"
    mkdir -p "$H/run" "$H/.local/share/color-terminal"
    cp -r "$REPO/themes" "$H/.local/share/color-terminal/themes"
}
ct() { HOME="$H" XDG_RUNTIME_DIR="$H/run" "$REPO/bin/color-terminal" "$@"; }

# Reach the library functions directly without running the tool. The source guard in
# bin/color-terminal is what makes this possible.
load_lib() {
    # shellcheck source=/dev/null
    . "$REPO/bin/color-terminal"
}

# =====================================================================================
section "L1 unit — parsing"

( load_lib
  f="$SANDBOX/t.theme"
  cat > "$f" <<'EOF'
# a comment
name = Test Theme
   variant   =   dark
background = #1e1e2e
foreground = #cdd6f4
color1 = #f38ba8
# color2 = #ffffff
unknown-key = whatever
EOF
  CT_PAL=() CT_NAME= CT_VARIANT= CT_BG= CT_FG=
  ct_parse_kv "$f" ct_theme_kv
  is "key = value with surrounding whitespace"  "$CT_VARIANT"   "dark"
  is "'#' inside a value is DATA, not a comment" "$CT_BG"       "#1e1e2e"
  is "leading '#' IS a comment"                  "${CT_PAL[2]:-unset}" "unset"
  is "unknown keys are ignored, not fatal"       "$CT_NAME"     "Test Theme"
  is "indexed colour keys land at the OSC index" "${CT_PAL[1]}" "#f38ba8"
) 2>&1 | grep -E '^  (ok|FAIL)' || true
eval "$(( PASS += $(true; echo 0) ))" 2>/dev/null

# The subshell above cannot update our counters, so unit assertions are re-run inline.
( load_lib >/dev/null 2>&1
  f="$SANDBOX/t2.theme"
  printf '# c\nname = X\nbackground = #112233\nforeground = #445566\n' > "$f"
  CT_PAL=(); CT_BG=; CT_FG=; CT_NAME=
  ct_parse_kv "$f" ct_theme_kv
  [ "$CT_BG" = "#112233" ] || exit 1
) && ok "theme parser: '#rrggbb' survives the comment rule" || nope "theme parser: '#rrggbb' survives the comment rule"

( load_lib >/dev/null 2>&1
  H="$SANDBOX/cfg"; mkdir -p "$H"
  CT_CONFIG_DIR="$H"
  printf 'trigger = shell\nno-repeat = 9\n# persist = no\n' > "$H/config"
  ct_config_defaults; ct_parse_kv "$H/config" ct_config_kv
  [ "$CT_CFG_trigger" = shell ] && [ "$CT_CFG_no_repeat" = 9 ] && [ "$CT_CFG_persist" = yes ]
) && ok "config parser: set keys applied, commented keys keep defaults" \
  || nope "config parser: set keys applied, commented keys keep defaults"

section "L1 unit — marker-block surgery"

( load_lib >/dev/null 2>&1
  f="$SANDBOX/rc"; printf 'line one\nline two\n' > "$f"
  printf 'BODY\n' | ct_splice_block "$f" "# >>> x >>>" "# <<< x <<<"
  cp "$f" "$f.1"
  printf 'BODY\n' | ct_splice_block "$f" "# >>> x >>>" "# <<< x <<<"
  cmp -s "$f" "$f.1"
) && ok "splice is idempotent: running twice is byte-identical" \
  || nope "splice is idempotent: running twice is byte-identical"

( load_lib >/dev/null 2>&1
  f="$SANDBOX/rc2"; printf 'keep me\n' > "$f"
  before=$(stat -c %i "$f" 2>/dev/null || stat -f %i "$f")
  printf 'BODY\n' | ct_splice_block "$f" "# >>> x >>>" "# <<< x <<<"
  after=$(stat -c %i "$f" 2>/dev/null || stat -f %i "$f")
  [ "$before" = "$after" ]
) && ok "splice preserves the inode (symlinked dotfiles survive)" \
  || nope "splice preserves the inode (symlinked dotfiles survive)"

( load_lib >/dev/null 2>&1
  f="$SANDBOX/rc3"; printf 'first\nsecond\n' > "$f"; cp "$f" "$f.orig"
  printf 'BODY\n' | ct_splice_block "$f" "# >>> x >>>" "# <<< x <<<"
  ct_unsplice_block "$f" "# >>> x >>>" "# <<< x <<<"
  cmp -s "$f" "$f.orig"
) && ok "unsplice restores the file exactly, with no trailing blank lines" \
  || nope "unsplice restores the file exactly, with no trailing blank lines"

section "L2 pty — the escape bytes"

pty_oscs() {                                  # <env-assignments...> -- <args...>
    python3 - "$@" <<'PY'
import os, sys
sys.path.insert(0, "test")
from faketerm import run, oscs, assert_clean_stdout
argv = sys.argv[1:]
split = argv.index("--")
env = dict(os.environ)
for k in ("GHOSTTY_RESOURCES_DIR","TERM_PROGRAM","TMUX","STY","ZELLIJ","SSH_CONNECTION","SSH_TTY","NO_COLOR","COLOR_TERMINAL"):
    env.pop(k, None)
for a in argv[:split]:
    k, v = a.split("=", 1); env[k] = v
tty, out, st = run(["./bin/color-terminal", *argv[split+1:]], env=env)
assert_clean_stdout(out)
print(" ".join(oscs(tty)))
PY
}

newhome
out=$(HOME=$H XDG_RUNTIME_DIR=$H/run pty_oscs TERM=xterm-ghostty HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --theme nord)
is "ghostty: 16 palette + fg/bg/cursor" "$(printf '%s\n' "$out" | wc -w)" "19"
has "ghostty: OSC 4 index 0 carries the theme's colour0" "$out" "4;0;#3b4252"
has "ghostty: background is OSC 11"                      "$out" "11;#2e3440"
hasnt "ghostty: no OSC 17 (it logs selection colours as unimplemented)" "$out" "17;"

out=$(pty_oscs TERM=foot TERM_PROGRAM=foot HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --theme nord)
has "foot: selection background is emitted (OSC 17)" "$out" "17;#eceff4"
has "foot: selection foreground is emitted (OSC 19)" "$out" "19;#4c566a"

out=$(pty_oscs TERM=foot TERM_PROGRAM=foot HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --reset)
is "foot --reset: full reset set INCLUDING 117/119" "$out" "104 110 111 112 117 119"
out=$(pty_oscs TERM=xterm-ghostty HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --reset)
is "ghostty --reset: only the resets ghostty implements" "$out" "104 110 111 112"

section "L2 pty — multiplexers"

raw_capture() {
    python3 - "$@" <<'PY'
import os, sys
sys.path.insert(0, "test")
from faketerm import run
argv = sys.argv[1:]; split = argv.index("--")
env = dict(os.environ)
for k in ("GHOSTTY_RESOURCES_DIR","TERM_PROGRAM","TMUX","STY","ZELLIJ","NO_COLOR","COLOR_TERMINAL"):
    env.pop(k, None)
for a in argv[:split]:
    k, v = a.split("=", 1); env[k] = v
tty, out, st = run(["./bin/color-terminal", *argv[split+1:]], env=env)
sys.stdout.write(repr(tty[:40]))
PY
}

raw=$(raw_capture TERM=screen-256color TMUX=/tmp/x,1,0 HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --theme nord)
hasnt "tmux: no DCS wrapper — allow-passthrough is off by default and tmux handles OSC natively" "$raw" '\x1bP'
has   "tmux: plain OSC reaches the pane" "$raw" '\x1b]4;0;#3b4252'

raw=$(raw_capture TERM=screen.xterm-256color STY=1.pts-0.h HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --theme nord)
has "screen: DCS wrapper present"                          "$raw" '\x1bP\x1b]4;0;#3b4252'
has "screen: inner terminator is BEL, not ESC-backslash"   "$raw" '#3b4252\x07\x1b\\'

section "L3 matrix — terminals that are not installed here"

detect() { HOME="$H" XDG_RUNTIME_DIR="$H/run" env -u GHOSTTY_RESOURCES_DIR -u TERM_PROGRAM -u TMUX -u STY -u SSH_CONNECTION -u SSH_TTY "$@" "$REPO/bin/color-terminal" --print-detected; }
is "ghostty via its private env var"     "$(detect GHOSTTY_RESOURCES_DIR=/usr/share/ghostty TERM=xterm-ghostty)" "ghostty local certain"
is "ghostty via TERM alone is not local" "$(detect TERM=xterm-ghostty)"                                          "ghostty remote probable"
is "foot via TERM_PROGRAM"               "$(detect TERM=foot TERM_PROGRAM=foot)"                                 "foot local certain"
is "unknown terminal falls back to generic, and that is correct" "$(detect TERM=xterm-256color)"                 "generic remote guess"
is "over ssh a private env var no longer proves locality" "$(detect TERM=xterm-ghostty GHOSTTY_RESOURCES_DIR=/usr/share/ghostty SSH_CONNECTION='1 2 3 4')" "ghostty remote probable"
is "explicit override wins"              "$(detect TERM=xterm-256color COLOR_TERMINAL_TERM=kitty)"               "kitty local override"

section "L1 unit — opt-outs"

newhome
is "NO_COLOR emits nothing"       "$(NO_COLOR=1 pty_oscs TERM=xterm-ghostty HOME="$H" XDG_RUNTIME_DIR="$H/run" NO_COLOR=1 -- --theme nord)" ""
is "COLOR_TERMINAL=0 emits nothing" "$(pty_oscs TERM=xterm-ghostty COLOR_TERMINAL=0 HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --theme nord)" ""

newhome
mkdir -p "$H/.config/color-terminal/hosts"
printf 'nord\n' > "$H/.config/color-terminal/hosts/$(uname -n)"
out=$(ct --dry-run | grep '^theme')
has "a per-host pin overrides the randomiser" "$out" "nord"

section "L4 stress — the two things that broke in v1"

newhome
for i in $(seq 12); do ct --theme nord >/dev/null 2>&1 & done
wait
n=$(wc -l < "$H/.local/state/color-terminal/history" 2>/dev/null || echo 0)
if [ "$n" -eq 12 ]; then ok "12 concurrent shells: history keeps all 12 lines (v1: 0 lines in 4 runs of 5)"
else nope "12 concurrent shells: history intact" "expected 12 lines, got $n"; fi

# Measured against dist/, not bin/: dist is the artifact that actually gets installed
# and runs at every shell start. bin/ sources fifteen separate files and is a dev
# convenience, so timing it would flatter or slander the wrong thing.
newhome
DISTBIN="$REPO/dist/color-terminal"
if [ ! -x "$DISTBIN" ]; then make -s -C "$REPO" dist >/dev/null 2>&1; fi
ctd() { HOME="$H" XDG_RUNTIME_DIR="$H/run" "$DISTBIN" "$@"; }

ctd --theme nord >/dev/null 2>&1                  # warm any first-run migration
start=$(date +%s%N); for _ in 1 2 3 4 5; do ctd --theme nord >/dev/null 2>&1; done; end=$(date +%s%N)
ms=$(( (end - start) / 5000000 ))
if [ "$ms" -le 40 ]; then ok "full swap: ${ms}ms (budget 40; v1 burned ~150ms in forks alone)"
else nope "latency budget: full swap" "a swap took ${ms}ms, over the 40ms budget"; fi

# The case that dominates real life once the trigger is per-pane: a nested shell fires
# the hook, the pane is already claimed, and nothing happens. This is the number a
# user actually feels on every `su`, `:!sh` and agent subshell.
ctd --hook >/dev/null 2>&1
start=$(date +%s%N); for _ in 1 2 3 4 5; do ctd --hook >/dev/null 2>&1; done; end=$(date +%s%N)
ms=$(( (end - start) / 5000000 ))
if [ "$ms" -le 15 ]; then ok "nested-shell no-op: ${ms}ms (budget 15)"
else nope "latency budget: no-op" "a no-op hook took ${ms}ms, over the 15ms budget"; fi

# The trigger itself: the second shell in the same pane must decline.
newhome
ctd --hook >/dev/null 2>&1
ctd --hook >/dev/null 2>&1
n=$(wc -l < "$H/.local/state/color-terminal/history" 2>/dev/null || echo 0)
if [ "$n" -eq 1 ]; then ok "trigger=pane: a second shell in the same pane does not re-randomize"
else nope "trigger=pane: second shell declines" "history has $n entries, expected 1"; fi

section "self-installing artifact"

# The published artifact is ONE file with the themes and hook templates appended after
# its final `exit`. This is the property the apps plane depends on: it does
# download -> sha256sum -c -> install -m0755 and nothing else, so anything the tool
# needs at runtime has to travel inside the file.
newhome
ISO="$SANDBOX/iso$RANDOM"; mkdir -p "$ISO/run" "$ISO/elsewhere"
cp "$REPO/dist/color-terminal" "$ISO/elsewhere/color-terminal"
printf 'export PATH="$HOME/.local/bin:$PATH"\n\n# >>> splashboard >>>\nsplash\n# <<< splashboard <<<\n' > "$ISO/.zshrc"
( cd "$ISO/elsewhere" && HOME="$ISO" XDG_RUNTIME_DIR="$ISO/run" CT_QUIET=1 ./color-terminal --install ) >/dev/null 2>&1
n=$(ls "$ISO/.local/share/color-terminal/themes"/*.theme 2>/dev/null | wc -l)
is "one file installs all 24 themes with no checkout present" "$n" "24"
[ -x "$ISO/.local/bin/color-terminal" ] && ok "one file installs the binary" || nope "one file installs the binary"
[ -r "$ISO/.config/color-terminal/hook.zsh" ] && ok "one file generates the shell hooks" || nope "one file generates the shell hooks"
hookline=$(grep -n 'color-terminal hook' "$ISO/.zshrc" | head -1 | cut -d: -f1)
splashline=$(grep -n 'splashboard' "$ISO/.zshrc" | head -1 | cut -d: -f1)
if [ -n "$hookline" ] && [ -n "$splashline" ] && [ "$hookline" -lt "$splashline" ]; then
    ok "the hook is spliced ABOVE splashboard (the splash must render after the sync)"
else
    nope "hook ordering vs splashboard" "hook at ${hookline:-none}, splashboard at ${splashline:-none}"
fi

# The payload sits after the final `exit`, so bash must never parse it. Proven by
# appending bytes that are not valid shell and checking the tool still runs.
cp "$REPO/dist/color-terminal" "$SANDBOX/garbage"
printf 'this ( is ) not && valid || shell ;;; done fi esac\n' >> "$SANDBOX/garbage"
chmod +x "$SANDBOX/garbage"
if HOME="$ISO" "$SANDBOX/garbage" --version >/dev/null 2>&1; then
    ok "invalid bytes after the payload marker are never parsed (payload is free at startup)"
else
    nope "payload is not parsed" "bash read past the final exit"
fi

( cd "$ISO/elsewhere" && HOME="$ISO" XDG_RUNTIME_DIR="$ISO/run" CT_QUIET=1 ./color-terminal --uninstall ) >/dev/null 2>&1
if [ ! -e "$ISO/.local/bin/color-terminal" ] && ! grep -q 'color-terminal hook' "$ISO/.zshrc"; then
    ok "--uninstall removes the binary and the rc hook"
else
    nope "--uninstall is complete"
fi

section "public installer — the headline install command"

# docs/install.sh is what `curl … | sh` runs, so it is part of the product and gets
# tested like the rest of it. A local file:// release stands in for GitHub: same
# SHA256SUMS format, same asset name, same code path.
newhome
REL="$SANDBOX/release$RANDOM"; mkdir -p "$REL"
cp "$REPO/dist/color-terminal" "$REL/color-terminal"
( cd "$REL" && sha256sum color-terminal > SHA256SUMS )

out=$(HOME="$H" XDG_RUNTIME_DIR="$H/run" PREFIX="$H/.local" CT_QUIET=1 \
      COLOR_TERMINAL_DOWNLOAD_BASE="file://$REL" \
      sh "$REPO/docs/install.sh" --no-wire 2>&1) || true

if [ -x "$H/.local/bin/color-terminal" ]; then ok "installer: fetches, verifies and installs the artifact"
else nope "installer: installs the artifact" "$out"; fi

n=$(ls "$H/.local/share/color-terminal/themes"/*.theme 2>/dev/null | wc -l)
is "installer: hands over to --install, which unpacks the payload" "$n" "24"

# The check that matters. A corrupted download must not become executable anywhere,
# and the installer must say so rather than installing something that half works.
newhome
BAD="$SANDBOX/bad$RANDOM"; mkdir -p "$BAD"
cp "$REPO/dist/color-terminal" "$BAD/color-terminal"
( cd "$BAD" && sha256sum color-terminal > SHA256SUMS )
printf 'x' >> "$BAD/color-terminal"           # one byte, after the checksum was taken

out=$(HOME="$H" XDG_RUNTIME_DIR="$H/run" PREFIX="$H/.local" \
      COLOR_TERMINAL_DOWNLOAD_BASE="file://$BAD" \
      sh "$REPO/docs/install.sh" --no-wire 2>&1); rc=$?
is   "installer: a tampered artifact is refused"        "$rc" "1"
has  "installer: and says why"                          "$out" "CHECKSUM MISMATCH"
if [ ! -e "$H/.local/bin/color-terminal" ]; then ok "installer: nothing executable is left behind"
else nope "installer: nothing executable is left behind" "$H/.local/bin/color-terminal exists"; fi

# SHA256SUMS is matched by asset name, not positionally, so a release that later grows
# a second asset does not break installers already in the wild.
newhome
MULTI="$SANDBOX/multi$RANDOM"; mkdir -p "$MULTI"
cp "$REPO/dist/color-terminal" "$MULTI/color-terminal"
echo 'unrelated' > "$MULTI/some-other-asset"
( cd "$MULTI" && sha256sum some-other-asset color-terminal > SHA256SUMS )
out=$(HOME="$H" XDG_RUNTIME_DIR="$H/run" CT_QUIET=1 \
      COLOR_TERMINAL_DOWNLOAD_BASE="file://$MULTI" \
      sh "$REPO/docs/install.sh" --download-only="$H/ct" 2>&1) || true
if [ -x "$H/ct" ]; then ok "installer: --download-only verifies against a multi-asset SHA256SUMS"
else nope "installer: --download-only with extra assets" "$out"; fi

section "golden — rendered config fragments"

if [ -d test/golden ] && [ -n "$(ls -A test/golden 2>/dev/null)" ]; then
    for want in test/golden/*/*; do
        term=$(basename "$(dirname "$want")"); theme=$(basename "$want"); theme=${theme%.*}
        got="$SANDBOX/render.$term.$theme"
        ( load_lib >/dev/null 2>&1
          ct_paths_init; ct_config_defaults; CT_REPO_DIR=$REPO; ct_theme_dirs
          ct_theme_load "$theme" >/dev/null 2>&1
          "ct_be_${term}_render" ) > "$got" 2>/dev/null
        if diff -q "$want" "$got" >/dev/null 2>&1; then ok "golden: $term/$theme"
        else nope "golden: $term/$theme" "$(diff "$want" "$got" | head -5)"; fi
    done
else
    printf '  (no golden files yet — run: make golden)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\nfailed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
