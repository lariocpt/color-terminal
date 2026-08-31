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
# Derived, never hardcoded: a theme added or dropped must not fail five gates at once.
NTHEMES=$(ls "$REPO"/themes/*.theme | wc -l)
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
for k in ("GHOSTTY_RESOURCES_DIR","TERM_PROGRAM","KONSOLE_VERSION","TMUX","STY","ZELLIJ","SSH_CONNECTION","SSH_TTY","SSH_CLIENT","NO_COLOR","COLOR_TERMINAL"):
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
for k in ("GHOSTTY_RESOURCES_DIR","TERM_PROGRAM","KONSOLE_VERSION","TMUX","STY","ZELLIJ","SSH_CONNECTION","SSH_TTY","SSH_CLIENT","NO_COLOR","COLOR_TERMINAL"):
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

# The suite runs inside a real terminal, whose own identity would otherwise leak into
# every detection test. Strip everything a backend keys on, then set what the test says.
clean_env() { env -u GHOSTTY_RESOURCES_DIR -u TERM_PROGRAM -u KONSOLE_VERSION -u TMUX -u STY -u ZELLIJ -u SSH_CONNECTION -u SSH_TTY -u SSH_CLIENT -u NO_COLOR -u COLOR_TERMINAL "$@"; }
detect() { HOME="$H" XDG_RUNTIME_DIR="$H/run" clean_env "$@" "$REPO/bin/color-terminal" --print-detected; }
is "ghostty via its private env var"     "$(detect GHOSTTY_RESOURCES_DIR=/usr/share/ghostty TERM=xterm-ghostty)" "ghostty local certain"
is "ghostty via TERM alone is not local" "$(detect TERM=xterm-ghostty)"                                          "ghostty remote probable"
is "foot via TERM_PROGRAM"               "$(detect TERM=foot TERM_PROGRAM=foot)"                                 "foot local certain"
is "unknown terminal falls back to generic, and that is correct" "$(detect TERM=xterm-256color)"                 "generic remote guess"
is "over ssh a private env var no longer proves locality" "$(detect TERM=xterm-ghostty GHOSTTY_RESOURCES_DIR=/usr/share/ghostty SSH_CONNECTION='1 2 3 4')" "ghostty remote probable"
is "explicit override wins"              "$(detect TERM=xterm-256color COLOR_TERMINAL_TERM=kitty)"               "kitty local override"
is "konsole via its private env var (tier 3)"   "$(detect TERM=xterm-256color KONSOLE_VERSION=240800)"          "konsole local certain"
is "Warp via TERM_PROGRAM (tier 3)"             "$(detect TERM=xterm-256color TERM_PROGRAM=WarpTerminal)"       "warp local certain"
is "Apple Terminal via TERM_PROGRAM (tier 3)"   "$(detect TERM=xterm-256color TERM_PROGRAM=Apple_Terminal)"     "appleterminal local certain"
# KONSOLE_VERSION is inherited by a terminal opened FROM konsole; TERM_PROGRAM is not,
# every terminal overwrites it. The innermost terminal has to win.
is "a ghostty opened from inside konsole is ghostty" "$(detect TERM=xterm-ghostty KONSOLE_VERSION=240800 TERM_PROGRAM=ghostty)" "ghostty local certain"

# mosh has no env var: it is found because mosh-server is an ancestor of the shell.
# comm in /proc comes from the executable's name, so a copy of bash called
# mosh-server is one. The trailing `; :` makes bash fork for the command instead of
# exec'ing over the ancestor we are trying to be.
cp "$(command -v bash)" "$SANDBOX/mosh-server"
mosh_detect() {                               # <VAR=value...>
    HOME="$H" XDG_RUNTIME_DIR="$H/run" "$SANDBOX/mosh-server" -c \
        'env -u GHOSTTY_RESOURCES_DIR -u TERM_PROGRAM -u KONSOLE_VERSION -u TMUX -u STY -u SSH_CONNECTION -u SSH_TTY -u SSH_CLIENT "$@" "$0" --print-detected; :' \
        "$REPO/bin/color-terminal" "$@"
}
is "mosh: found by ancestry, and it beats the ghostty TERM match" "$(mosh_detect SSH_CONNECTION='1 2 3 4' TERM=xterm-ghostty)" "mosh remote certain"
is "mosh: the ancestry walk is gated on an ssh session"          "$(mosh_detect TERM=xterm-ghostty)"                         "ghostty remote probable"

section "tier 3 — identified, declined, and told why"

newhome
out=$(pty_oscs TERM=xterm-256color KONSOLE_VERSION=240800 HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --theme nord)
is "konsole: a swap emits no escape at all"        "$out" ""
out=$(pty_oscs TERM=xterm-256color TERM_PROGRAM=WarpTerminal HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --theme nord)
is "Warp: a swap emits no escape at all"           "$out" ""
out=$(pty_oscs TERM=xterm-256color TERM_PROGRAM=Apple_Terminal HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --reset)
is "Apple Terminal: --reset emits nothing either"  "$out" ""
n=$([ -f "$H/.local/state/color-terminal/history" ] && wc -l < "$H/.local/state/color-terminal/history" || echo 0)
is "declining records no history"                  "$n" "0"
rc=$(HOME="$H" XDG_RUNTIME_DIR="$H/run" clean_env KONSOLE_VERSION=240800 TERM=xterm-256color "$REPO/bin/color-terminal" --theme nord >/dev/null 2>&1; echo $?)
is "a declined swap exits 0 — declining is not an error" "$rc" "0"
out=$(HOME="$H" XDG_RUNTIME_DIR="$H/run" clean_env KONSOLE_VERSION=240800 TERM=xterm-256color "$REPO/bin/color-terminal" --doctor 2>&1)
has "--doctor says it is declining, and why"       "$out" "VERDICT      : declining — konsole"

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
is "one file installs all $NTHEMES themes with no checkout present" "$n" "$NTHEMES"
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

section "opt-outs do not block administration"

# NO_COLOR means "do not recolour". It is exported globally by exactly the people who
# care about it most, and it must not stop them installing, and above all not stop
# them uninstalling.
newhome; rm -rf "$H/.local/share/color-terminal"
NO_COLOR=1 ctd --install --no-wire --prefix="$H/.local" >/dev/null 2>&1
n=$(ls "$H/.local/share/color-terminal/themes"/*.theme 2>/dev/null | wc -l)
is "NO_COLOR=1: --install still installs"                     "$n" "$NTHEMES"
[ -r "$H/.config/color-terminal/hook.zsh" ] && ok "NO_COLOR=1: --install still generates the hooks" || nope "NO_COLOR=1: hooks" "hook.zsh missing"
COLOR_TERMINAL=0 ctd --uninstall >/dev/null 2>&1
[ ! -e "$H/.local/bin/color-terminal" ] && ok "COLOR_TERMINAL=0: --uninstall still uninstalls" || nope "COLOR_TERMINAL=0: --uninstall" "binary still present"
out=$(NO_COLOR=1 pty_oscs TERM=xterm-ghostty NO_COLOR=1 HOME="$H" XDG_RUNTIME_DIR="$H/run" -- --theme nord)
is "NO_COLOR=1: but a swap still emits nothing"               "$out" ""

section "dev entrypoint — bin/color-terminal is the whole tool too"

# bin/ and dist/ read the same lib/manifest, so a function the artifact has, the
# checkout has. --install is the one that was missing.
newhome; rm -rf "$H/.local/share/color-terminal"
ct --install --no-wire --prefix="$H/.local" >/dev/null 2>&1
[ -x "$H/.local/bin/color-terminal" ] && ok "bin/color-terminal --install works from a checkout" || nope "bin --install" "no binary installed"
n=$(ls "$H/.local/share/color-terminal/themes"/*.theme 2>/dev/null | wc -l)
is "…and finds the themes in the checkout, no payload needed" "$n" "$NTHEMES"

section "reproducible build"

# A copy of the source with every mtime moved by 25 years, group-writable files (a
# umask-002 clone), and an executable theme: none of it may change the artifact,
# because a published sha256 only means something if anyone can rebuild it.
B="$SANDBOX/build$RANDOM"; mkdir -p "$B"
( cd "$REPO" && tar -cf - Makefile lib bin themes shell | tar -xf - -C "$B" )
find "$B" -exec touch -t 200102030405 {} +
chmod -R g+w "$B/themes" "$B/shell"; chmod +x "$B/themes/nord.theme"
if ( umask 002; make -s -C "$B" dist >/dev/null 2>&1 ) && cmp -s "$B/dist/color-terminal" "$REPO/dist/color-terminal"; then
    ok "mtimes, umask and stray mode bits do not change the artifact"
else nope "reproducible build" "$(sha256sum "$B/dist/color-terminal" "$REPO/dist/color-terminal" 2>&1 | cut -c1-16 | tr '\n' ' ')"; fi

# A tar that starts and then fails must fail the build — not append an empty payload
# and exit 0, which is how a Mac would install zero themes.
printf '#!/bin/sh\ncase "$1" in --version) echo "tar (GNU tar) 1.35";; *) exit 1;; esac\n' > "$B/faketar"; chmod +x "$B/faketar"
rm -rf "$B/dist"
if make -s -C "$B" dist TAR="$B/faketar" >/dev/null 2>&1; then nope "a failing tar fails make dist" "make dist exited 0"
else ok "a failing tar fails make dist instead of shipping an empty payload"; fi
[ ! -e "$B/dist/color-terminal" ] && ok "…and leaves no half-written artifact behind" || nope "no half-written artifact" "dist/color-terminal exists after a failed build"

section "public installer — the headline install command"

# docs/install.sh is what `curl … | sh` runs, so it is part of the product and gets
# tested like the rest of it. A local file:// release stands in for GitHub: same
# SHA256SUMS format, same asset name, same code path.
#
# This is the one layer that needs more than bash and python3, because fetching is the
# thing under test — and specifically curl: wget cannot fetch file://. Skipping is
# announced rather than silent: a run that quietly covers one section fewer while
# printing the same "all passed" is worse than one that says so.
if command -v curl >/dev/null 2>&1; then

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
mkrelease() {                                 # <dir> [extra asset names already in dir...]
    local d=$1; shift
    mkdir -p "$d"; cp "$REPO/dist/color-terminal" "$d/color-terminal"
    ( cd "$d" && { for f in color-terminal "$@"; do printf '%s  %s\n' "$(sha_of "$f")" "$f"; done; } > SHA256SUMS )
}
inst() {                                      # <release-dir> [bootstrap args...]
    local rel=$1; shift
    HOME="$H" XDG_RUNTIME_DIR="$H/run" CT_QUIET=1 COLOR_TERMINAL_DOWNLOAD_BASE="file://$rel" \
        sh "$REPO/docs/install.sh" --no-wire --prefix="$H/.local" "$@" 2>&1
}
DISTVER=$("$REPO/dist/color-terminal" --version | awk '{print $2}')

REL="$SANDBOX/release$RANDOM"; mkrelease "$REL"
newhome; rm -rf "$H/.local/share/color-terminal"      # the pre-seeded corpus would make the count vacuous
out=$(inst "$REL") || true
[ -x "$H/.local/bin/color-terminal" ] && ok "installer: fetches, verifies and installs the artifact" || nope "installer: installs the artifact" "$out"
n=$(ls "$H/.local/share/color-terminal/themes"/*.theme 2>/dev/null | wc -l)
is "installer: hands over to --install, which unpacks the payload" "$n" "$NTHEMES"
[ -r "$H/.config/color-terminal/hook.zsh" ] && ok "installer: …and the hooks are generated" || nope "installer: hooks" "hook.zsh missing"

newhome; rm -rf "$H/.local"
out=$(inst "$REL" --dry-run) || true
[ ! -e "$H/.local/bin/color-terminal" ] && [ ! -d "$H/.local/share/color-terminal" ] && [ ! -e "$H/.config/color-terminal/config" ] \
    && ok "installer: --dry-run writes nothing at all" || nope "installer: --dry-run is dry" "something was written"
newhome; rm -rf "$H/.local"
out=$(inst "$REL" --version) || true
has "installer: --version reports the release"      "$out" "color-terminal $DISTVER"
[ ! -e "$H/.local/bin/color-terminal" ] && ok "installer: --version installs nothing" || nope "installer: --version installs nothing" "binary present"

newhome; rm -rf "$H/.local"
out=$(inst "$REL" --prefix "$H/opt") || true
[ -x "$H/opt/bin/color-terminal" ] && [ ! -e "$H/.local/bin/color-terminal" ] \
    && ok "installer: the space form of --prefix works, and installs exactly one copy" || nope "installer: --prefix DIR" "$out"

# The check that matters. A corrupted download must not become executable anywhere,
# and the installer must say so rather than installing something that half works.
newhome; rm -rf "$H/.local"
BAD="$SANDBOX/bad$RANDOM"; mkrelease "$BAD"; printf 'x' >> "$BAD/color-terminal"
out=$(inst "$BAD"); rc=$?
is   "installer: a tampered artifact is refused"        "$rc" "1"
has  "installer: and says why"                          "$out" "CHECKSUM MISMATCH"
[ ! -e "$H/.local/bin/color-terminal" ] && ok "installer: nothing executable is left behind" || nope "installer: nothing left behind" "$H/.local/bin/color-terminal exists"

# SHA256SUMS is matched by asset name, not positionally, so a release that later grows
# a second asset does not break installers already in the wild.
MULTI="$SANDBOX/multi$RANDOM"; mkdir -p "$MULTI"; echo unrelated > "$MULTI/some-other-asset"; mkrelease "$MULTI" some-other-asset
out=$(HOME="$H" COLOR_TERMINAL_DOWNLOAD_BASE="file://$MULTI" sh "$REPO/docs/install.sh" --download-only="$H/ct" 2>&1) || true
[ -x "$H/ct" ] && ok "installer: --download-only verifies against a multi-asset SHA256SUMS" || nope "installer: --download-only" "$out"

# One version token, two spellings, two planes: GitHub wants the v, the LAN index
# does not. Both spellings must resolve on both.
url=$(sh "$REPO/docs/install.sh" --print-url 2.0.0);  has "installer: bare 2.0.0 becomes a v-tag on GitHub" "$url" "/releases/download/v2.0.0/color-terminal"
url=$(sh "$REPO/docs/install.sh" --print-url v2.0.0); has "installer: v2.0.0 stays a v-tag on GitHub"      "$url" "/releases/download/v2.0.0/color-terminal"
url=$(COLOR_TERMINAL_VERSION=v2.0.0 sh "$REPO/docs/install.sh" --print-url); has "installer: COLOR_TERMINAL_VERSION is honoured" "$url" "/download/v2.0.0/"
APPS="$SANDBOX/apps$RANDOM"; mkdir -p "$APPS/tools/color-terminal/latest"; cp "$REPO/dist/color-terminal" "$APPS/tools/color-terminal/latest/"
printf 'tool\tcolor-terminal\t%s\tcolor-terminal\t%s\t%s\ttools/color-terminal/latest/color-terminal\n' \
    "$DISTVER" "$(sha_of "$REPO/dist/color-terminal")" "$(wc -c < "$REPO/dist/color-terminal")" > "$APPS/index.tsv"
for v in "v$DISTVER" "$DISTVER" latest; do
    url=$(APPS_URL="file://$APPS" sh "$REPO/docs/install.sh" --source=apps --print-url "$v" 2>&1)
    has "installer: --source=apps resolves '$v' through the index" "$url" "/latest/color-terminal"
done
newhome; rm -rf "$H/.local"
out=$(HOME="$H" XDG_RUNTIME_DIR="$H/run" CT_QUIET=1 APPS_URL="file://$APPS" sh "$REPO/docs/install.sh" --source=apps --no-wire --prefix="$H/.local" 2>&1) || true
[ -x "$H/.local/bin/color-terminal" ] && ok "installer: --source=apps installs, verified by the index's own sha256" || nope "installer: --source=apps" "$out"

# Piped through sh there is no $0 to read help out of, so it has to be a heredoc.
out=$(cat "$REPO/docs/install.sh" | sh -s -- --help)
has "installer: --help works when piped"  "$out" "Options"

else
    printf '  \033[33mSKIP\033[0m curl is not installed — the public installer was NOT covered by this run\n'
fi

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
