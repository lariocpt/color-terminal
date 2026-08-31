# color-terminal

[![ci](https://github.com/lariocpt/color-terminal/actions/workflows/ci.yml/badge.svg)](https://github.com/lariocpt/color-terminal/actions/workflows/ci.yml)
[![latest release](https://img.shields.io/github/v/release/lariocpt/color-terminal?sort=semver)](https://github.com/lariocpt/color-terminal/releases/latest)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

Recolors the terminal you are typing in. Every new terminal pane picks a theme from a
bundled corpus and applies it live, over ssh included.

```sh
curl -fsSL https://lariocpt.github.io/color-terminal/install.sh | sh
```

That downloads one file, checks it against the sha256 published with the release, and
lets it install itself. Open a new window and you are done. To stop it: `NO_COLOR=1`,
`COLOR_TERMINAL=0`, or `color-terminal --uninstall`.

[**Website**](https://lariocpt.github.io/color-terminal/) ·
[**Changelog**](CHANGELOG.md) ·
[**Theme credits**](CREDITS.md)

### Other ways in

```sh
# from a checkout
git clone https://github.com/lariocpt/color-terminal.git && cd color-terminal && ./install.sh

# onto a host with nothing on it
scp dist/color-terminal remote: && ssh remote ./color-terminal --install
```

All three run identical code, because the installer lives *inside* the artifact. The
published file is one ~90 KB bash script with the 24 themes and both shell-hook
templates appended after its final `exit` — bash never parses past that, so the payload
costs nothing at shell start and `--install` reads the file's own tail to unpack it.

**Requirements:** `bash` 3.2 or newer, plus `curl` or `wget` and one of
`sha256sum`/`shasum`/`openssl` for the installer. No runtime dependencies beyond bash
itself — no python, no package manager, nothing to keep updated.

The installer never writes into your `PATH` itself: it verifies the download against
the release's `SHA256SUMS`, then hands the file to its own `--install`. So
`--dry-run` is dry, and Ctrl-C aborts. Options, all passed through to `--install`
except these:

| | |
|---|---|
| `v2.0.1`, `--tag=v2.0.1` | one release rather than the latest (`COLOR_TERMINAL_VERSION`) |
| `--prefix=DIR` | install root; the binary goes in `DIR/bin` (`COLOR_TERMINAL_PREFIX`, default `~/.local`) |
| `--source=apps` | resolve from the LAN mirror instead of GitHub (`COLOR_TERMINAL_SOURCE`) |
| `--download-only=PATH` | fetch and verify to `PATH`, install nothing |
| `--print-url` | resolve and print the download URL, fetch nothing |
| `--dry-run` | say what `--install` would do and write nothing |

## How it works

The colors are set with OSC escape sequences written to `/dev/tty`:

```sh
printf '\033]4;1;#f38ba8\033\\'   # ANSI color 1
printf '\033]11;#1e1e2e\033\\'    # background
```

Those bytes are interpreted by whatever terminal sits at the far end of the pty, which
is why this works unchanged over ssh: the script runs on the *remote* host and
recolors your *local* window. When the session ends the hook sends the reset
counterparts (OSC 104/110/111/112, plus 117/119 where the terminal implements
selection colors) so your window goes back to its own theme instead of wearing the
remote's.

Escapes go to `/dev/tty` and never to stdout — a stray escape byte on stdout corrupts
`scp`, `rsync` and git-over-ssh. `test/run.sh` asserts stdout stays clean.

## Which terminals

**Tier 1** — live recolor, plus a palette file so new windows keep the theme:
`ghostty`, `foot`.

**Tier 2** — live recolor, no config written. One shared `generic` backend, no
per-terminal code: `kitty`, `alacritty`, `wezterm`, `xterm`, `urxvt`, `st`, `rio`,
`contour`, `iTerm2`, Windows Terminal, VS Code, the whole VTE family (gnome-terminal,
ptyxis, tilix, terminator, xfce4-terminal, guake, blackbox) — **and any terminal we
have never heard of, and any ssh session**. That last part is the point: unknown is a
supported case, not an error. The sequences tier 2 uses are implemented by every
terminal in both tiers, so no probing or handshake is needed.

`kitty`, `alacritty` and `xterm` are verified through that shared backend by
`make test-terminals`, which runs them for real in a container and asks each one back
what color it is now using. They have no per-terminal code, which is the evidence for
the claim above.

**Tier 3** — detected, declined, and told why: `konsole`, Warp, mosh, Apple Terminal.
Emitting into these is worse than doing nothing because it *looks* like it worked:
konsole parses OSC 4, stores it, answers queries about it, and never renders with it;
Warp ignores it; mosh drops it; Apple Terminal has no palette OSC at all. konsole,
Warp and Apple Terminal are recognised by the variables they export; mosh has none, so
it is recognised by `mosh-server` being an ancestor of the shell. Over ssh *from* a
tier-3 terminal none of that is visible on the far side, so the session is treated as
tier 2 and recoloured — harmlessly, since the terminal ignores it.

Run `color-terminal --doctor` to see which one you are in, what it can do, and — for
tier 3 — why it is declining.

## When colors change

Set `trigger =` in `~/.config/color-terminal/config`:

| value | meaning |
|---|---|
| `pane` (default) | the first shell in each new pane or window |
| `shell` | every interactive shell |
| `manual` | only when you run `color-terminal` yourself |

`pane` is the default because a shell cannot see its window but it *can* see its
session: every nested shell in one pane shares a session id, and a new pane gets a new
one. Without that, `su`, `:!sh` from vim, `poetry shell` and every coding-agent
subshell re-randomize the window while you are typing in it.

## Persistence

color-terminal never edits a line it did not write. It adds **one** include line to
your terminal's own config, once, and then owns a separate file you never have to look
at:

```
~/.config/ghostty/config          # >>> color-terminal >>> ... config-file = ?color-terminal.conf
~/.config/ghostty/color-terminal.conf   # ours, rewritten on every swap
```

Your own `theme =` line is left exactly as you wrote it, including the
`theme = light:X,dark:Y` form.

Because included files win, the fragment sets the palette for windows opened later. It
holds the **next** theme rather than the current one, so a new window opens already
wearing what its shell hook is about to apply — otherwise every new window would show
the previous theme and visibly swap a moment later.

## Where things go

| path | what |
|---|---|
| `~/.local/bin/color-terminal` | the one file that is the whole tool |
| `~/.config/color-terminal/config` | yours to edit; never overwritten on upgrade |
| `~/.config/color-terminal/themes/` | your own themes; searched first, never touched |
| `~/.config/color-terminal/hook.{zsh,bash}` | generated, sourced from your rc |
| `~/.local/share/color-terminal/themes/` | the bundled corpus; replaced on upgrade |
| `~/.local/state/color-terminal/` | pick history |

## Themes

24 bundled, 16 dark and 8 light, in a flat format that is parsed and never sourced:

```
name    = Catppuccin Mocha
variant = dark
splash  = catppuccin_mocha

background = #1e1e2e
foreground = #cdd6f4
color0 = #45475a
...
color15 = #bac2de
```

`colorN` is named that way because N is the OSC 4 palette index used verbatim. Drop
your own into `~/.config/color-terminal/themes/`; that directory is searched first and
an upgrade never touches it.

Every theme passes a contrast gate enforced at build time by
`tools/validate-themes.py`: foreground/background ≥ 4.5:1, red (errors) ≥ 3.0:1,
green/blue/magenta/cyan ≥ 2.8:1, yellow ≥ 2.0:1. Yellow has a lower bar because yellow
on a light background is poor in essentially every published theme corpus — a flat 3.0
bar leaves 2 usable light themes out of 44 that otherwise pass.

`color-terminal --list` shows what is installed. Every bundled theme is shown on the
[website](https://lariocpt.github.io/color-terminal/#themes).

## Turning it off

| | |
|---|---|
| `NO_COLOR=1` | the [no-color.org](https://no-color.org) convention, honoured before anything forks |
| `COLOR_TERMINAL=0` | per-shell or per-session off switch |

Both of those mean *do not recolour*. `--install`, `--uninstall` and `--doctor` work
regardless, so exporting `NO_COLOR` globally never leaves you unable to take the tool
out.

| | |
|---|---|
| `~/.config/color-terminal/hosts/<hostname>` | pin one machine to one theme forever |
| `trigger = manual` | never automatic |
| `color-terminal --uninstall` | removes the hook, the include line, and the binary |

## Splashboard

If [splashboard](https://github.com/unhappychoice/splashboard) is installed, the
matching preset is written to a managed block in `~/.splashboard/settings.toml` so the
splash animation and the terminal agree. 16 of the 24 themes map to an exact preset;
the rest write `reset` tokens, which make the splash inherit the colors just applied.
Skipped entirely over ssh — the splash is a local artifact.

## Verifying a download

Every release publishes `SHA256SUMS` beside the artifact, and the installer checks it
before writing anything. The build is reproducible, so you can also check it yourself:

```sh
git checkout v2.0.0 && make dist && sha256sum dist/color-terminal
curl -fsSL https://github.com/lariocpt/color-terminal/releases/download/v2.0.0/SHA256SUMS
```

The two must agree. The payload tar is built with normalised mtimes, ownership, file
modes and sort order precisely so that this comparison means something — a fresh
clone, a different umask or a stray executable bit on a theme file must not change a
byte. It needs GNU tar (`brew install gnu-tar` on macOS; the Makefile finds `gtar`).

## Contributing

`AGENTS.md` is the working guide: what is load-bearing, what will bite you, and how to
add a terminal. Bug reports and questions go in
[issues](https://github.com/lariocpt/color-terminal/issues); a `--doctor` dump is the
single most useful thing to include.

```sh
make dist              # amalgamate lib/*.sh into ONE self-installing file
make lint              # syntax + shellcheck + theme validation
make test              # unit, pty-level escape assertions, concurrency, latency
make test-terminals    # real terminals in podman, headless
make test-live         # real windows in whatever is installed here
make docs              # regenerate the website's generated sections
make golden            # regenerate the expected render output
make themes            # rebuild the corpus from ghostty's, via tools/import-scheme.sh
```

`lib/*.sh` is source-only and never installed. `make dist` concatenates the files
listed in `lib/manifest` into one self-contained script and appends the themes and
hook templates as a payload, which is how it stays `scp`-able to a bare host and how
it avoids fifteen `open()` calls at every shell start. `bin/color-terminal` reads the
same manifest, so the checkout and the artifact are always made of the same parts.

Adding a terminal is one file in `lib/backends/` implementing six functions, plus one
line in `CT_BACKENDS` and one in `lib/manifest`; see the contract at the top of
`lib/backend.sh`. A tier-3 terminal — one to recognise and refuse — is the same file
with three functions: `_detect`, an empty `_caps`, and `_decline` returning the reason.

Three test layers. `test/run.sh` needs no terminal emulator at all — `test/faketerm.py`
allocates a pty, becomes the terminal, and asserts the exact bytes. `test/live/run.sh`
opens real windows in whatever is installed here. `make test-terminals` brings its own
terminals in podman and currently verifies **foot, kitty, alacritty and xterm** by
asking each one back what colour it is now using; kitty is cross-checked against
`kitten @ get-colors` as an independent second oracle.

Measured here, a full swap costs ~10 ms and a nested-shell no-op ~4 ms. CI asserts
budgets of 40 ms and 15 ms, loose enough for a shared runner and tight enough that a
fork on the hot path still fails.

### bash 3.2

The tool targets bash 3.2 because that is still `/bin/bash` on macOS. If you touch
`lib/`, avoid negative array subscripts, associative arrays and `${var^^}` — none of
them exist there, and the failure mode is silent rather than loud.

### LAN mirror

Machines on the author's own network install from an internal mirror at
`apps.in.drlario.org` instead, which serves byte-identical copies of the published
release. `--source=apps` on the installer selects it. It is a cache, not a second
source of truth; nothing about it is required to use this project.
