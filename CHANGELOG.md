# Changelog

All notable changes to color-terminal are recorded here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `## [X.Y.Z]` heading shape is load-bearing, not a style choice:
`.github/workflows/release.yml` extracts everything between one such heading and the
next to use as the GitHub Release notes, and refuses to publish a tag that has no
section here. `CT_VERSION` in `lib/common.sh` must match the tag being released.

## [Unreleased]

## [2.0.1] - 2026-08-31

A review release: everything below came out of a full pass over 2.0.0 the day after
it shipped. Nothing here changes what the tool does to a terminal that already worked;
all of it is about the cases where it said one thing and did another.

### Added

- **Tier 3 exists now.** 2.0.0 advertised konsole, Warp, mosh and Apple Terminal as
  "detected, declined, and told why" — and shipped no backend for any of them, so a
  konsole user got exactly the looks-like-it-worked failure the docs promised to
  prevent. Four backends, each one file: konsole and Warp and Apple Terminal by their
  own environment variables, mosh by finding `mosh-server` among the shell's
  ancestors (there is no variable to test; the walk reads `/proc` with builtins and
  only runs inside an ssh session). `--doctor` prints the reason. The website's
  terminal table is now generated from the backend registry, so the claim and the
  code cannot drift apart again.
- `lib/manifest`: one list of source files, read by both `make dist` and the dev
  entrypoint. `bin/color-terminal --install` used to die with `ct_install: command
  not found` because the two lists had drifted.
- The installer grew `--tag=`, `--prefix DIR` (space form), `--print-url`, and a
  `--help` that works when piped.

### Fixed

- **`NO_COLOR` and `COLOR_TERMINAL=0` no longer block `--install` and `--uninstall`.**
  They mean "do not recolour", and were exported globally by exactly the people who
  then could not uninstall. Only a swap and a reset honour them now.
- **The installer wrote before it was asked to.** It copied the binary into
  `$PREFIX/bin` and only then handed over to `--install`, so `--dry-run` left a 90 KB
  executable behind, `--version` installed a hookless binary, and Ctrl-C after the
  download fell through to a completed install. It now hands the verified temp file
  to the artifact's own `--install`, which does the copy with `install(1)` — a new
  inode, so a shell hook mid-execution never reads a half-written script — and
  signals are re-raised after cleanup.
- **The installer pins the release tag once** and fetches both the checksum and the
  artifact from that tag's directory. Two separate trips through `latest` could
  straddle a release, pair the old checksum with the new file, and accuse the user
  of tampering.
- **Version spellings.** `v2.0.0` and `2.0.0` both work on both planes; GitHub wants
  the `v`, the LAN index does not, and only `latest` used to work on both.
- **The release goes live only after its assets have been verified.** 2.0.0's
  workflow flipped the draft first and tested second, so a bad upload would have been
  `latest` for everyone the moment the workflow went red. Re-publishing an older tag
  can no longer demote the current release, a failed publish re-drafts itself, and
  `vX.Y.Z-rc.N` tags actually work as the rehearsal they were documented to be.
- **`make dist` cannot silently produce an empty payload.** The tar pipeline had no
  pipefail, so on macOS — where bsdtar rejects the normalisation flags — it built a
  hollow artifact that installed zero themes. GNU tar is now checked for, and a
  failed build leaves no half-written file behind.
- **The build is reproducible across umasks.** File mode was the one thing the
  payload did not normalise, so a group-writable clone changed the sha256 and the
  Jenkins provenance gate would have rejected a genuine release.
- The website is gated by its own checks before it deploys; it used to deploy on any
  push while CI went red afterwards. The self-containment check now walks every tag
  and attribute instead of a grep that missed single quotes, `srcset`, `url()` and
  `<iframe>`.
- The LAN mirror's gate script is a real, linted file; the mirror job no longer fails
  every fifteen minutes when GitHub is unreachable or there is nothing to mirror, no
  longer interpolates the tag name into a shell string, and cleans up its container on
  abort. A second release asset no longer breaks it.
- A test that could not fail (the installer hand-over counted pre-seeded themes), a
  test layer that failed instead of skipping on wget-only hosts, a live-terminal probe
  whose corpus error was blamed on the terminal, an f-string that needed Python 3.12,
  and the README's claims of bash 4.0 and of CI asserting 10 ms/4 ms budgets (it
  asserts 40/15) — all corrected.

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

[Unreleased]: https://github.com/lariocpt/color-terminal/compare/v2.0.1...HEAD
[2.0.1]: https://github.com/lariocpt/color-terminal/releases/tag/v2.0.1
[2.0.0]: https://github.com/lariocpt/color-terminal/releases/tag/v2.0.0
