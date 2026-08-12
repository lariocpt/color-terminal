# color-terminal

Randomizes the terminal color theme **and** the [splashboard](https://github.com/unhappychoice/splashboard)
splash palette together on every new shell, so the splash animation always matches
the terminal it renders in.

Successor to `color-ghostty` (whose ghostty logic it vendors): where that tool only
recolored the terminal, this one also rewrites the splashboard theme so the two
never clash.

## How it works

1. **Pick** — a random theme from a curated list of 24 Ghostty built-in themes,
   with an anti-repeat window (last 5 picks excluded, shared history file with
   color-ghostty at `~/.cache/ghostty_theme_history`).
2. **Terminal (ghostty backend)** — the theme is applied *live* via OSC escape
   sequences written to `/dev/tty` (works unchanged over ssh; tmux/screen get DCS
   passthrough), and persisted to the `theme =` line of `~/.config/ghostty/config`
   so future local windows start on it. Persistence is skipped over ssh.
3. **Splash (splashboard backend)** — the pick is mapped to the splashboard theme
   preset of the same family (`Dracula → dracula`, `Gruvbox Dark → gruvbox_dark`,
   `TokyoNight → tokyo_night`, …). Themes with no matching preset (`C64`,
   `Hot Dog Stand`, `Matrix`, …) fall back to `reset` tokens, which make the splash
   inherit the terminal colors that were just applied. The result is written to a
   managed block in `~/.splashboard/settings.toml`:

   ```toml
   # >>> color-terminal >>>
   # Managed by color-terminal — rewritten on every run; do not edit inside the
   # markers. ...
   [theme]
   preset = "nord"
   # <<< color-terminal <<<
   ```

   Everything outside the markers is never touched. The block owns the file's only
   `[theme]` table (TOML forbids duplicate tables) — to take manual control of the
   splash theme, delete the block and stop running color-terminal.

## Install

```sh
./install.sh
```

Installs the script to `~/.local/bin`, the shell snippets to
`~/.config/color-terminal/`, and wires `~/.zshrc` / `~/.bashrc` to run it on every
new interactive ghostty shell — *before* splashboard renders, replacing the legacy
cli-tools-installer `color-ghostty` hook in place if present.

## Usage

```sh
color-terminal          # randomize terminal + splash now
color-terminal --reset  # restore the terminal's configured colors (palette + fg/bg/cursor)
```

`--reset` is what the shell hook calls when an ssh session ends, so your local
window gets its own theme back instead of keeping the remote's.

## Roadmap

- **kitty backend** — the logic already exists in `color-kitty`
  (`kitty @ set-colors -a -c <theme.conf>`); slot it in as a second terminal
  backend selected by `$TERM`.
- Other terminals: alacritty, wezterm.
- `--terminal-only` / `--splash-only` flags.
- Independent-random mode (`--clash`) for people who like chaos.
- User-editable theme↔preset mapping file instead of the built-in table.
