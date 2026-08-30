# Working on color-terminal

The guide for anyone — human or agent — changing this repo. `CLAUDE.md` is a symlink to
this file. The README explains what the tool does; this explains what will bite you.

## Shape of the thing

`lib/*.sh` is the source and is **never installed**. `make dist` concatenates it into
one file, `dist/color-terminal`, and appends `themes/` and `shell/` as a base64 tar
**after the final `exit`**. That single file is the entire product: it is what the
release publishes, what `scp color-terminal remote:` delivers, and what installs
itself.

`bin/color-terminal` sources `lib/*.sh` and exists only for development and for tests,
which source it to reach the functions directly. It is not what ships.

## Rules that are load-bearing

**Nothing on the hot path may fork.** The tool runs at every new shell. v1 spent
~105 ms per run on `$(printf … | tr …)` inside a parse loop — 523 ms for five
iterations against 4 ms for the same work in parameter expansion. Every helper in
`lib/common.sh` is a bash builtin except where a comment says otherwise and explains
why. CI asserts a ~40 ms swap and ~15 ms no-op budget; if you add a fork, you will find
out there.

**`LIBS` order in `Makefile` is load-bearing** and must match the source order in
`bin/color-terminal`: definitions before use, backends before `main` dispatches to
them. Adding a file means editing both.

**Themes are parsed, never sourced.** A theme is data from the internet. `ct_parse_kv`
in `lib/config.sh` reads it; nothing ever executes it.

**Escape bytes leave through exactly one place** — `lib/emit.sh`, on fd 3, which is
`/dev/tty`. Never stdout: a stray escape byte there corrupts `scp`, `rsync` and
git-over-ssh, and `test/run.sh` asserts stdout stays clean. stdout belongs to
`--list` and `--print-detected`; diagnostics go to stderr.

**Target bash 3.2.** It is still `/bin/bash` on macOS. No negative array subscripts
(`${BASH_SOURCE[-1]}` needs 4.3 and fails *silently*, which is how the installer once
shipped zero themes), no associative arrays, no `${var^^}`. Parallel indexed arrays are
the idiom here — see `lib/theme.sh`.

**Never edit a line you did not write.** The tool touches other people's rc files and
terminal configs. All of it goes through marker blocks in `lib/rcsplice.sh`, which is
idempotent and uses `cat` rather than `mv` so inodes and symlinked dotfiles survive.

**The build is reproducible and must stay that way.** The payload tar is normalised
(`--sort=name --mtime=@0 --owner=0 --group=0`, `gzip -n`) so anyone can rebuild a
release from its tag and get the published sha256. A convenience change that
reintroduces mtimes silently breaks that promise.

## Before you push

```sh
make lint     # WITH shellcheck installed — see below
make test
```

**Install shellcheck** (`pacman -S shellcheck`). Without it `make lint` degrades to a
syntax-only check, passes locally, and then fails in CI, which runs the strong gate.
That exact gap turned the CI gate red once already.

`lib/*.sh` files carry a `# shellcheck shell=bash` header — they are sourced fragments
with no shebang. Some also carry a narrow `disable=` line with the reason. `SC2034` and
`SC2154` are unavoidable at file scope here: globals are written in one fragment and
read in another, which shellcheck cannot see one file at a time. Keep those disables as
narrow as the file allows, and never add one without saying why on the line above.

## Adding a terminal

One file in `lib/backends/` implementing six functions, plus one line in
`CT_BACKENDS`. The contract is at the top of `lib/backend.sh`. Most terminals need
nothing: `generic.sh` already covers anything that implements the universal OSC subset,
and "unknown" is a supported case rather than an error.

Add a tier-3 entry instead when a terminal *accepts* the sequences and does not render
them — konsole does exactly that. Declining loudly is correct; emitting into it looks
like it worked.

## Tests

| layer | needs | covers |
|---|---|---|
| `test/run.sh` | nothing | exact escape bytes via a pty that plays the terminal, marker-block surgery, detection matrix, concurrency, latency, self-install, the public installer |
| `test/live/run.sh` | a display | real windows in terminals installed here |
| `test/containers/run.sh` | podman | real terminals installed nowhere, queried over their own escape protocol |

`test/faketerm.py` allocates a pty, becomes the terminal, and asserts exact bytes.
Every test runs against a throwaway `HOME` behind a guard that refuses to run if the
sandbox is not under a temp dir — v1 wrote to five real dotfiles and a leaking test
would rewrite your own `~/.zshrc`.

## The website

`docs/index.html` is the whole site, served by Pages with no build step. Its five hard
rules are in `docs/README.md` and CI enforces two of them. Three sections are generated
from the theme corpus by `tools/gen-site.py` (`make docs`) — CI fails if regenerating
changes the file, so a theme added without `make docs` is caught at review.

`docs/install.sh` is the public installer and is **POSIX sh**, not bash: it is piped to
`sh` by strangers. `make lint` checks it with `sh -n`, `dash -n` and
`shellcheck -s sh`. Do not add it to the bash shellcheck list — that would accept every
bashism.

Note there are two files named `install.sh`. The root one is the checkout entrypoint
and runs `make dist`; `docs/install.sh` downloads a release. Each header says so.

## Releasing

`CT_VERSION` in `lib/common.sh` is the only version string in the project.

```
1. bump CT_VERSION in lib/common.sh
2. add a '## [X.Y.Z]' section to CHANGELOG.md   <- release notes come from here
3. PR into main, CI green
4. git tag -a vX.Y.Z -m 'color-terminal X.Y.Z' && git push origin vX.Y.Z
```

`.github/workflows/release.yml` takes it from there: it refuses a tag that disagrees
with `CT_VERSION`, refuses a tag with no changelog section, runs the full gate, and
publishes as a **draft** before flipping it live — because `gh release create` uploads
assets *after* creating the release, and for those seconds `latest` exists with no
assets and every install one-liner in flight fails.

Tag `vX.Y.Z-rc.N` to rehearse: it publishes as a prerelease, never becomes `latest`,
and leaves the public one-liner untouched.

The LAN Jenkins job mirrors the released bytes to an internal plane. It never builds —
byte identity with the release is the whole point, and it asserts it.

## Personal-repo convention

Branch and open a PR into `main`. Never commit straight to `main`.
