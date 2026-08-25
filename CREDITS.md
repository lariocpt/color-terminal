# Credits

color-terminal ships a corpus of 24 terminal colour schemes in [`themes/`](themes/).
None of them are ours. This file records where each one came from.

## Upstream

Every theme in `themes/` was converted from the colour-scheme corpus bundled with
[ghostty](https://ghostty.org), which lives at `/usr/share/ghostty/themes` on a
typical Linux install.

Ghostty's bundled corpus is itself a port of
**[mbadolato/iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)**,
which is distributed under the **MIT Licence**. That project is the upstream of
record: it is what every `upstream = …` key in our theme files points at, and its
MIT licence is what every `license = MIT` key refers to.

So the chain is:

```
original theme author  ->  mbadolato/iTerm2-Color-Schemes (MIT)  ->  ghostty's bundled corpus  ->  themes/*.theme
```

Our conversion is mechanical — it flattens ghostty's `palette = N=#rrggbb` lines
into `colorN = #rrggbb`, renames `cursor-color` to `cursor`, lowercases the hex,
and attaches metadata. No colour values were changed, so the MIT terms carry
through unchanged and the copyright stays with the original authors and with the
iTerm2-Color-Schemes project.

## Regenerating the corpus

The corpus is reproducible. From the repo root, with ghostty's themes installed:

```sh
tools/import-scheme.sh --all
```

That rewrites all 24 files in `themes/` from the table embedded in the script.
Re-running it on an unchanged ghostty install is a no-op — the output is
byte-identical. To convert one scheme by hand:

```sh
tools/import-scheme.sh "<Ghostty Display Name>" <our-theme-id> [key=value ...]
```

Both are dev-only tools. Neither is installed, and neither runs at runtime.
Validate the result with:

```sh
tools/validate-themes.py --report
```

## The themes

`splash` is the [splashboard](https://github.com/unhappychoice/splashboard) theme
preset the scheme maps to; `—` means no preset matches and the splash inherits the
terminal colours color-terminal just applied.

### Dark (16)

| id | name | family | original author / project | splash | pairs with |
| --- | --- | --- | --- | --- | --- |
| `atom-one-dark` | Atom One Dark | atom-one | [Atom / GitHub](https://github.com/atom/one-dark-syntax) | — | — |
| `ayu-mirage` | Ayu Mirage | ayu | [Ike Ku (dempfi)](https://github.com/dempfi/ayu) | `ayu_mirage` | — |
| `catppuccin-mocha` | Catppuccin Mocha | catppuccin | [Catppuccin](https://github.com/catppuccin/catppuccin) | `catppuccin_mocha` | — |
| `dracula` | Dracula | dracula | [Zeno Rocha](https://github.com/dracula/dracula-theme) | `dracula` | — |
| `everforest-dark` | Everforest Dark Hard | everforest | [sainnhe](https://github.com/sainnhe/everforest) | — | — |
| `github-dark` | GitHub Dark Default | github | [GitHub Primer](https://github.com/primer/primitives) | — | `github-light` |
| `gruvbox-material-dark` | Gruvbox Material Dark | gruvbox | [sainnhe](https://github.com/sainnhe/gruvbox-material) (after [Pavel Pertsev's Gruvbox](https://github.com/morhetz/gruvbox)) | `gruvbox_dark` | `gruvbox-material-light` |
| `kanagawa-wave` | Kanagawa Wave | kanagawa | [rebelot](https://github.com/rebelot/kanagawa.nvim) | — | `kanagawa-lotus` |
| `monokai-pro` | Monokai Pro | monokai | [Wimer Hazenberg](https://monokai.pro) | `monokai` | `monokai-pro-light` |
| `night-owl` | Night Owl | night-owl | [Sarah Drasner](https://github.com/sdras/night-owl-vscode-theme) | — | — |
| `nord` | Nord | nord | [Arctic Ice Studio / Nord](https://github.com/nordtheme/nord) | `nord` | — |
| `onenord` | Onenord | onenord | [rmehri01](https://github.com/rmehri01/onenord.nvim) | — | `onenord-light` |
| `oxocarbon` | Oxocarbon | oxocarbon | [Nyoom Engineering](https://github.com/nyoom-engineering/oxocarbon.nvim), after [IBM Carbon](https://carbondesignsystem.com) | — | — |
| `rose-pine-moon` | Rosé Pine Moon | rose-pine | [Rosé Pine](https://github.com/rose-pine/rose-pine-theme) | `rose_pine_moon` | — |
| `solarized-dark` | Solarized Dark | solarized | [Ethan Schoonover](https://ethanschoonover.com/solarized/) | `solarized_dark` | — |
| `tokyonight-storm` | TokyoNight Storm | tokyonight | [Folke Lemaitre](https://github.com/folke/tokyonight.nvim), after [enkia](https://github.com/enkia/tokyo-night-vscode-theme) | `tokyo_night_storm` | `tokyonight-day` |

### Light (8)

| id | name | family | original author / project | splash | pairs with |
| --- | --- | --- | --- | --- | --- |
| `alabaster` | Alabaster | alabaster | [Nikita Prokopov (tonsky)](https://github.com/tonsky/sublime-scheme-alabaster) | — | — |
| `flexoki-light` | Flexoki Light | flexoki | [Steph Ango](https://stephango.com/flexoki) | — | — |
| `github-light` | GitHub Light Default | github | [GitHub Primer](https://github.com/primer/primitives) | — | `github-dark` |
| `gruvbox-material-light` | Gruvbox Material Light | gruvbox | [sainnhe](https://github.com/sainnhe/gruvbox-material) (after [Pavel Pertsev's Gruvbox](https://github.com/morhetz/gruvbox)) | `gruvbox_light` | `gruvbox-material-dark` |
| `kanagawa-lotus` | Kanagawa Lotus | kanagawa | [rebelot](https://github.com/rebelot/kanagawa.nvim) | — | `kanagawa-wave` |
| `monokai-pro-light` | Monokai Pro Light Sun | monokai | [Wimer Hazenberg](https://monokai.pro) | — | `monokai-pro` |
| `onenord-light` | Onenord Light | onenord | [rmehri01](https://github.com/rmehri01/onenord.nvim) | — | `onenord` |
| `tokyonight-day` | TokyoNight Day | tokyonight | [Folke Lemaitre](https://github.com/folke/tokyonight.nvim), after [enkia](https://github.com/enkia/tokyo-night-vscode-theme) | — | `tokyonight-storm` |

## Licence text

From [mbadolato/iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/LICENSE):

```
The MIT License (MIT)

Copyright (c) 2016 Mark Badolato

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Individual schemes remain under their original authors' terms where those differ;
the list above is provided so those authors can be found and credited directly.
