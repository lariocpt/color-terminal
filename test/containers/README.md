# Real terminals, headless, in a container

```sh
make test-terminals            # or: test/containers/run.sh
CT_TERMINALS="kitty foot" test/containers/run.sh
```

Launches real terminal emulators with no display attached and proves color-terminal
actually changed their colors. Skips cleanly (exit 0) if podman is not installed.

## What it proves

Each terminal is asked, over its own escape protocol, what color it is *currently
using*:

```
printf '\033]11;?\033\\'      what is your background?
printf '\033]4;1;?\033\\'     what is ANSI color 1?
```

The reply comes from the same table the renderer reads, so a PASS means the pixels are
right without looking at one. That is better than a screenshot in every way that
matters here: exact rather than tolerance-based, textual rather than pixel, and it
needs no fonts, no compositor geometry and no image library.

Replies come back in whatever X11 color syntax the terminal prefers
(`rgb:1e1e/1e1e/2e2e`, `rgb:1e/1e/2e`, `#1e1e2e`, `rgba:…`); `probe.sh` normalizes all
of them to one 8-bit triple before comparing. Expected values are read out of
`themes/<theme>.theme` at run time, so the test cannot drift from the corpus.

**kitty gets a second, independent oracle**: `kitten @ get-colors` reads kitty's own
color table over its remote-control protocol, sharing no code with the escape parser.
When the two disagree the run fails. That is not redundancy — it is the check that
catches a terminal which stores a color, answers queries about it, and never renders
with it. konsole genuinely behaves that way, which is why it is tier 3.

## Current coverage

| terminal | display | oracle | notes |
|---|---|---|---|
| foot | cage (wlroots, pixman) | OSC query | Wayland-only, needs no GL |
| kitty | Xvfb + llvmpipe | OSC query **and** `kitten @ get-colors` | both must agree |
| alacritty | Xvfb + llvmpipe | OSC query | |
| xterm | Xvfb | OSC query | the reference OSC implementation |
| wezterm | Xvfb + llvmpipe | — | **BROKEN** in the Arch package: `libgit2.so.1.9` missing |

kitty, alacritty and xterm have no backend of their own — they are handled by
`lib/backends/generic.sh`. Their passing is the evidence for the tier-2 claim that one
shared backend correctly recolors terminals we have written no code for.

A terminal that will not launch is reported as **BROKEN**, with the reason, and does
not fail the run — a distro packaging break is not a regression in this tool. It is
still printed loudly, because a rig that silently tests four terminals while appearing
to test five is worse than one that tests four and says so.

## Why two display strategies

`cage` is a one-application wlroots compositor, but inside a container wlroots can only
use its pixman software renderer: `WLR_RENDERER=gles2` dies with *"no DRM FD
available"* because there is no `/dev/dri`. A pixman-only compositor advertises neither
`wl_drm` nor `linux-dmabuf`, which is exactly what mesa's Wayland EGL needs — so every
GPU-accelerated terminal gets no context and never draws.

Xvfb has no such problem: GLX over llvmpipe is fully software and needs no DRM node. So
anything wanting GL goes through X11, and cage is reserved for foot, which is
Wayland-only and needs no GL at all.

## Layout

| file | role |
|---|---|
| `Containerfile` | the terminal zoo. Contains no color-terminal and no themes — those are bind-mounted, so editing `lib/*.sh` never needs a rebuild |
| `run.sh` | host side: builds once, runs each terminal, asserts, prints the table |
| `launch.sh` | in-container: brings up a display and starts one terminal, per-terminal quirks live here |
| `probe.sh` | inside the terminal: applies a theme, queries the colors back, writes the verdict |

Adding a terminal is one arm in `launch.sh`'s `case` and one entry in `TERMINALS`.

## The other two test layers

| | needs | covers |
|---|---|---|
| `test/run.sh` | nothing | the exact escape bytes, via a pty that plays the terminal. Every tier-2 terminal, none installed |
| `test/live/run.sh` | a display | real windows in terminals installed on *this* machine |
| this | podman | real windows in terminals installed *nowhere* |
