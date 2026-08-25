# color-terminal

Recolors the terminal you are typing in. Every new terminal pane picks a theme from a
bundled corpus and applies it live, over ssh included.

```sh
git clone https://github.com/lariocpt/color-terminal && cd color-terminal
./install.sh
```

Open a new window. To stop it: `NO_COLOR=1`, `COLOR_TERMINAL=0`, or `./install.sh --uninstall`.

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
`ghostty`, `foot`. (`kitty` and `alacritty` are phase 2.)

**Tier 2** — live recolor, no config written. One shared `generic` backend, no
per-terminal code: `wezterm`, `xterm`, `urxvt`, `st`, `rio`, `contour`, `iTerm2`,
Windows Terminal, VS Code, the whole VTE family (gnome-terminal, ptyxis, tilix,
terminator, xfce4-terminal, guake, blackbox) — **and any terminal we have never heard
of, and any ssh session**. That last part is the point: unknown is a supported case,
not an error. The sequences tier 2 uses are implemented by every terminal in both
tiers, so no probing or handshake is needed.

**Tier 3** — detected, declined, and told why. Emitting into these is worse than doing
nothing because it *looks* like it worked: konsole parses OSC 4, stores it, answers
queries about it, and never renders with it; Warp ignores it; mosh drops it; Apple
Terminal has no palette OSC at all.

Run `color-terminal --doctor` to see which one you are in and what it can do.

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

Because included files win, the fragment sets the palette for windows opened later.
It holds the **next** theme rather than the current one, so a new window opens already
wearing what its shell hook is about to apply — otherwise every new window would show
the previous theme and visibly swap a moment later.

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

`colorN` is named that way because N is the OSC 4 palette index used verbatim.
Drop your own into `~/.config/color-terminal/themes/`; that directory is searched
first and an upgrade never touches it.

Every theme passes a contrast gate enforced at build time by
`tools/validate-themes.py`: foreground/background ≥ 4.5:1, red (errors) ≥ 3.0:1,
green/blue/magenta/cyan ≥ 2.8:1, yellow ≥ 2.0:1. Yellow has a lower bar because
yellow on a light background is poor in essentially every published theme corpus — a
flat 3.0 bar leaves 2 usable light themes out of 44 that otherwise pass.

`color-terminal --list` shows what is installed.

## Turning it off

| | |
|---|---|
| `NO_COLOR=1` | the [no-color.org](https://no-color.org) convention, honoured before anything forks |
| `COLOR_TERMINAL=0` | per-shell or per-session off switch |
| `~/.config/color-terminal/hosts/<hostname>` | pin one machine to one theme forever |
| `trigger = manual` | never automatic |
| `./install.sh --uninstall` | removes the hook, the include line, and the binary |

## Splashboard

If [splashboard](https://github.com/unhappychoice/splashboard) is installed, the
matching preset is written to a managed block in `~/.splashboard/settings.toml` so the
splash animation and the terminal agree. 16 of the 24 themes map to an exact preset;
the rest write `reset` tokens, which make the splash inherit the colors just applied.
Skipped entirely over ssh — the splash is a local artifact.

## Development

```sh
make dist              # amalgamate lib/*.sh into ONE file: dist/color-terminal
make lint              # syntax + shellcheck + theme validation
make test              # unit, pty-level escape assertions, concurrency, latency
make test-terminals    # real terminals in podman, headless
make golden            # regenerate the expected render output
make themes            # rebuild the corpus from ghostty's, via tools/import-scheme.sh
```

`lib/*.sh` is source-only and never installed. `make dist` concatenates it into one
self-contained script, which is both how it stays `scp`-able to a bare remote host and
how it avoids fifteen `open()` calls at every shell start.

Adding a terminal is one file in `lib/backends/` implementing six functions, plus one
line in `CT_BACKENDS`; see the contract at the top of `lib/backend.sh`.

The tests do not require a single terminal emulator to be installed: `test/faketerm.py`
allocates a pty, becomes the terminal, and asserts the exact bytes.

Budget: a full swap costs ~20 ms and a nested-shell no-op ~8 ms, both asserted in CI.
