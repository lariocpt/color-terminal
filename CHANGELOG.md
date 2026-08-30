# Changelog

All notable changes to color-terminal are recorded here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `## [X.Y.Z]` heading shape is load-bearing, not a style choice:
`.github/workflows/release.yml` extracts everything between one such heading and the
next to use as the GitHub Release notes, and refuses to publish a tag that has no
section here. `CT_VERSION` in `lib/common.sh` must match the tag being released.

## [Unreleased]

## [2.0.0] - 2026-08-30

First public release. v1 was a personal script that recoloured ghostty; this is a
rewrite that works on any terminal, over ssh, with its own theme corpus and a real
test suite.

### Added

- **Any terminal, not just ghostty.** A three-tier model: tier 1 (`ghostty`, `foot`)
  recolours live *and* writes a palette file so new windows keep the theme; tier 2 is
  one shared backend covering every terminal that implements the universal OSC subset —
  including terminals nobody has written code for, and any ssh session; tier 3
  (konsole, Warp, mosh, Apple Terminal) is detected, declined, and told why, because
  emitting into those looks like it worked when it did not.
- **One self-installing artifact.** `make dist` amalgamates `lib/*.sh` into a single
  file and appends the 24 themes and both shell-hook templates as a payload after the
  final `exit`, so `scp color-terminal remote:` is a complete install and bash never
  parses the payload at shell start.
- **A public installer** that resolves the latest release, verifies its sha256, and
  hands over to the artifact's own `--install`.
- **Its own theme corpus** — 24 themes, 16 dark and 8 light, in a flat format that is
  parsed and never sourced. Every one clears a contrast gate enforced at build time by
  `tools/validate-themes.py`, so a random pick can never produce an unreadable
  terminal.
- **`--doctor`**, which explains what was detected, what it can do, and what will
  happen.
- **Config file** at `~/.config/color-terminal/config`: trigger, pick mode, variant,
  theme allowlist, persistence, pre-seeding, ssh behaviour, per-host pins.
- **splashboard sync**, so the splash palette and the terminal agree.
- **A three-layer test suite**: a pty harness that plays the terminal and asserts exact
  escape bytes with no emulator installed; real windows on the local machine; and real
  terminals in podman, queried over their own escape protocol, with kitty
  cross-checked against `kitten @ get-colors` as an independent second oracle.

### Changed

- **The default trigger is now `pane`, not every interactive shell.** v1 fired on every
  shell, so `su`, `:!sh` from vim, `poetry shell` and every coding-agent subshell
  re-randomised the window while you were typing in it. Panes are identified by session
  id, which every nested shell shares and every new pane changes.
- **Escapes go to `/dev/tty`, never stdout.** A stray escape byte on stdout corrupts
  `scp`, `rsync` and git-over-ssh; the test suite asserts stdout stays clean.
- **History is append-only.** v1 hardcoded one temp filename and lost every write when
  several shells started at once — measured at 0 surviving lines out of 5, four runs
  running.
- **Config wiring never edits a line it did not write.** One include line goes into the
  terminal's own config, once; everything else lives in a separate file. Your own
  `theme =` line is left exactly as written.
- **The palette fragment holds the *next* theme, not the current one**, so a new window
  opens already wearing what its shell hook is about to apply instead of visibly
  swapping a moment later.
- **screen's DCS wrapper terminates the inner string with BEL**, fixing v1's
  unterminated OSC. tmux gets plain OSC — the passthrough wrapper was a no-op.
- Rewritten for speed on the hot path, which runs at every shell start: a full swap
  costs ~10 ms and a nested-shell no-op ~4 ms, both asserted in CI. v1 burned ~150 ms
  in forks alone.

### Fixed

- `ct_self_path` used `${BASH_SOURCE[-1]}`, a negative subscript that needs bash 4.3.
  On bash 3.2 — still `/bin/bash` on macOS, which this project targets — it errored and
  left the path empty, so `--install` found no payload and installed **zero themes**,
  silently, until first use.
- The build is now reproducible: the payload tar is normalised (`--sort=name
  --mtime=@0 --owner=0 --group=0`, `gzip -n`), so anyone can rebuild a release from its
  tag and get the same sha256. Previously a fresh clone's file mtimes changed the bytes.

[Unreleased]: https://github.com/lariocpt/color-terminal/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/lariocpt/color-terminal/releases/tag/v2.0.0
