# docs/ — the color-terminal website

`docs/index.html` is the whole site. GitHub Pages serves it from `/docs` on
`main`. There is no build step, no framework, and no package manifest: the file
that is committed is byte-for-byte the file that is served.

## Hard rules

These are not style preferences — breaking any of them breaks the page for
somebody:

1. **One file, zero external requests.** All CSS and JS are inline. No CDN, no
   webfonts, no analytics, no images. The only absolute URLs in the file are
   `<a href>` links and the `git clone` line in the install block; nothing on the
   page *loads* from a remote host.
2. **It must render with JavaScript disabled.** JS only cycles the hero demo and
   reveals the copy button. Both are progressive enhancements: the controls carry
   `hidden` in the markup and JS removes it, so a reader without JS sees no dead
   buttons, and the hero renders statically on palette 0.
3. **Theme-aware.** The complete light palette is defined on bare `:root`; the
   dark overrides live in a single `@media (prefers-color-scheme: dark)` block.
   Never give a colour its only definition inside the media query.
4. **No horizontal page scroll at 360px.** Wide content scrolls inside its own
   `overflow-x: auto` box — the terminal body, every `<pre>`, and the long
   `~/.config/...` path in the "Making it stop" list all do this already.
5. **`prefers-reduced-motion` is honoured.** Under it the hero holds on one
   palette instead of auto-advancing, the caret stops blinking, and the
   prev/next controls are the way to see the other themes.

## The hero palettes

The six palettes in the `PALETTES` array (and the `--ct-*` defaults on `:root`,
which are palette 0 and are what a JS-less reader sees) are **real theme data**,
copied verbatim from their source files. They are not hand-picked approximations
and must not be edited by hand — an invented hex value misrepresents what the
tool actually does.

Provenance, in the order the page prefers:

1. `themes/<id>.theme` in this repo, once the v2 corpus exists.
2. Otherwise `/usr/share/ghostty/themes/<Theme Name>`, converted.

Current ids, all six of which are real entries in this repo's `themes/`
corpus: `catppuccin-mocha`, `tokyonight-storm`, `gruvbox-material-dark`,
`rose-pine-moon`, `github-light`, `kanagawa-lotus`. If a theme is ever renamed
or dropped from the corpus, fix the hero too — the demo should only ever show
ids the tool can actually pick.

To re-derive a palette from a v2 theme file and eyeball it against the page:

```sh
awk -F' *= *' '
  $1 ~ /^(background|foreground|color[0-9]+)$/ { printf "%-12s %s\n", $1, $2 }
' themes/catppuccin-mocha.theme
```

`colorN` maps to `--ct-colorN` with no translation, exactly as it maps to the
OSC 4 palette index at runtime.

## Phase 2 insertion points

Three slots are reserved near the bottom of `<main>`:

```html
<!-- ct:generated:triggers BEGIN -->
<!-- ct:generated:triggers END -->

<!-- ct:generated:support BEGIN -->
<!-- ct:generated:support END -->

<!-- ct:generated:gallery BEGIN -->
<!-- ct:generated:gallery END -->
```

The contract: a generator replaces everything **between** a `BEGIN` and its
matching `END` and leaves the two marker lines in place, so the slot can be
regenerated idempotently. Each slot should be filled with a complete
`<section>` element (`<section id="..."><h2>...</h2>...</section>`) — an empty
slot renders as nothing, which is why the page looks finished today.

Generated markup should reuse the chrome that is already there rather than
inventing its own:

- `section` / `h2` — spacing, rules and the small-caps heading style are done.
- `table`, `th`, `td` — plain table styling is defined; wrap a wide table in
  `<div class="scroller">` so it scrolls instead of widening the page.
- `--ct-*` custom properties — set them inline on a swatch element to paint it
  in a theme's colours, the same way the hero does.
- `.scroller` — the generic `overflow-x: auto` box.

Remember rule 1: a generated gallery must not emit `<img>` tags pointing at
remote screenshots. Swatches are `background-color` on a `<div>`.

## Checking a change

```sh
python3 -c "import html.parser,sys; \
  p=html.parser.HTMLParser(); p.feed(open('docs/index.html').read())"   # parses
grep -nE '<(link|script|img)[^>]+(src|href)="https?:' docs/index.html   # must be empty
```

Then open it at 360px wide, with and without JS, in both colour schemes.
