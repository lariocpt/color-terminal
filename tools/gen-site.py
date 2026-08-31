#!/usr/bin/env python3
"""Fill the generated sections of docs/index.html from the code, not from memory.

docs/README.md reserves three slots in the page and defines the contract: replace
everything BETWEEN a `<!-- ct:generated:NAME BEGIN -->` marker and its matching END,
leave both markers in place, and emit one complete <section>.

Two of the three sections are derived from the repository so they cannot drift from
what ships:

  gallery  — every swatch is painted with values read out of themes/*.theme by the
             same parser the validator uses. docs/README.md forbids invented hex on
             the page, because a swatch that is not real theme data misrepresents
             what the tool does.
  support  — the tier-1 and tier-3 terminal lists come from CT_BACKENDS in
             lib/backend.sh and the `# tier:` / `# name:` header of each backend file.
             The site once advertised a tier 3 that no backend implemented; CI could
             not catch it because the table was a string constant. Now it can.

Idempotent by construction: CI runs this and fails if the page changes.

    make docs        # or: python3 tools/gen-site.py
"""
import html
import pathlib
import re
import sys

from themeparse import ThemeError, parse_theme

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "index.html"
THEMES = ROOT / "themes"
BACKENDS = ROOT / "lib" / "backends"


def esc(s):
    return html.escape(str(s), quote=True)


def read_backends():
    """[(id, tier, display name)] in CT_BACKENDS order, from the backend files."""
    src = (ROOT / "lib" / "backend.sh").read_text()
    m = re.search(r"^CT_BACKENDS=\(([^)]*)\)", src, re.M)
    if not m:
        sys.exit("gen-site: cannot find CT_BACKENDS=(...) in lib/backend.sh")
    out = []
    for bid in m.group(1).split():
        path = BACKENDS / f"{bid}.sh"
        if not path.exists():
            sys.exit(f"gen-site: CT_BACKENDS names '{bid}' but {path} does not exist")
        text = path.read_text()
        tier = re.search(r"^# tier: ([123])\s*$", text, re.M)
        name = re.search(r"^# name: (.+?)\s*$", text, re.M)
        if not tier or not name:
            sys.exit(f"gen-site: {path} needs '# tier: N' and '# name: ...' header lines")
        out.append((bid, int(tier.group(1)), name.group(1)))
    return out


def gen_triggers():
    return """<section id="triggers">
      <h2>When the colours change</h2>
      <p>
        Set <code>trigger</code> in <code>~/.config/color-terminal/config</code>.
      </p>
      <div class="scroller">
        <table>
          <thead><tr><th>value</th><th>what fires a new colour</th></tr></thead>
          <tbody>
            <tr><td><code>pane</code> <em>(default)</em></td>
                <td>the first shell in each new pane or window</td></tr>
            <tr><td><code>shell</code></td>
                <td>every interactive shell</td></tr>
            <tr><td><code>manual</code></td>
                <td>only when you run <code>color-terminal</code> yourself</td></tr>
          </tbody>
        </table>
      </div>
      <p>
        <code>pane</code> is the default because it is the only one that matches what
        you actually mean by &ldquo;a terminal&rdquo;. A shell cannot see its window,
        but it can see its <em>session</em>: every nested shell in one pane shares a
        session id, and a new pane gets a new one. Without that,
        <code>su</code>, <code>:!sh</code> from vim, <code>poetry shell</code> and every
        coding-agent subshell would re-randomise the window while you are typing in it.
      </p>
    </section>"""


def gen_support():
    backends = read_backends()
    tier1 = [n for _, t, n in backends if t == 1]
    tier3 = [n for _, t, n in backends if t == 3]
    if not tier1 or not tier3 or sum(1 for _, t, _ in backends if t == 2) != 1:
        sys.exit("gen-site: expected tier-1 backends, tier-3 backends and exactly one tier-2 (generic)")
    t1 = ", ".join(f"<code>{esc(n)}</code>" for n in tier1)
    t3 = ", ".join(esc(n) for n in tier3)
    return f"""<section id="support">
      <h2>Which terminals</h2>
      <p>
        There are three tiers, and the third one is a feature rather than a gap.
      </p>
      <div class="scroller">
        <table>
          <thead><tr><th>tier</th><th>what happens</th><th>which</th></tr></thead>
          <tbody>
            <tr>
              <td><strong>1</strong></td>
              <td>live recolour, plus a palette file so new windows keep the theme</td>
              <td>{t1}</td>
            </tr>
            <tr>
              <td><strong>2</strong></td>
              <td>live recolour, no config written &mdash; one shared backend, no
                  per-terminal code</td>
              <td><code>kitty</code>, <code>alacritty</code>, <code>wezterm</code>,
                  <code>xterm</code>, <code>urxvt</code>, <code>st</code>,
                  <code>rio</code>, <code>contour</code>, iTerm2, Windows Terminal,
                  VS Code, the whole VTE family &mdash; <strong>and any terminal we
                  have never heard of, and any ssh session</strong></td>
            </tr>
            <tr>
              <td><strong>3</strong></td>
              <td>detected, declined, and told why</td>
              <td>{t3}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p>
        Tier 2 is the point: unknown is a supported case, not an error. The sequences it
        uses are implemented by every terminal in both tiers, so nothing has to be
        probed or negotiated first.
      </p>
      <p>
        Tier 3 is declined on purpose, because emitting into those is worse than doing
        nothing &mdash; it <em>looks</em> like it worked. konsole parses the palette
        sequence, stores it, answers queries about it, and never renders with it; Warp
        ignores it; mosh drops it; Apple Terminal has no palette sequence at all.
        Run <code>color-terminal --doctor</code> to see which one you are in, and why.
      </p>
    </section>"""


def gen_gallery():
    themes = []
    for path in sorted(THEMES.glob("*.theme")):
        try:
            t = parse_theme(path)
        except ThemeError as e:
            sys.exit(f"gen-site: {e}")
        need = ["name", "variant", "background", "foreground"]
        missing = [k for k in need if k not in t]
        if missing:
            sys.exit(f"gen-site: {path.name} is missing {missing}")
        themes.append((path.stem, t))

    dark = sum(1 for _, t in themes if t["variant"] == "dark")
    light = len(themes) - dark

    cards = []
    for tid, t in themes:
        # Six swatches: the ANSI colours a prompt and a diff actually use. Values come
        # straight from the theme file — see the module docstring.
        chips = "".join(
            f'<i style="background:{esc(t.get("color%d" % n, t["foreground"]))}"></i>'
            for n in range(1, 7)
        )
        cards.append(
            f'<figure class="swatch" style="background:{esc(t["background"])};'
            f'color:{esc(t["foreground"])}">\n'
            f'            <div class="chips">{chips}</div>\n'
            f'            <figcaption>{esc(t["name"])}<span>{esc(tid)}</span></figcaption>\n'
            f"          </figure>"
        )

    # Joined outside the f-string: a backslash inside an f-string expression is a
    # SyntaxError before Python 3.12, and CI's 3.12 would hide that from everyone
    # on Debian 12 or Ubuntu 22.04.
    sep = "\n          "
    body = sep.join(cards)
    return f"""<section id="themes">
      <h2>The corpus</h2>
      <p>
        {len(themes)} themes ship with the tool &mdash; {dark} dark, {light} light.
        Every one of them clears a contrast gate enforced at build time, so a random
        pick can never hand you an unreadable terminal. Drop your own into
        <code>~/.config/color-terminal/themes/</code>; that directory is searched first
        and an upgrade never touches it.
      </p>
      <div class="gallery">
          {body}
      </div>
    </section>"""


SLOTS = {"triggers": gen_triggers, "support": gen_support, "gallery": gen_gallery}


def main():
    page = PAGE.read_text()
    for name, gen in SLOTS.items():
        begin = f"<!-- ct:generated:{name} BEGIN -->"
        end = f"<!-- ct:generated:{name} END -->"
        pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
        if not pattern.search(page):
            sys.exit(f"gen-site: no {name} slot in {PAGE}")
        body = gen()
        page = pattern.sub(lambda _m, b=body: f"{begin}\n    {b}\n    {end}", page, count=1)
    PAGE.write_text(page)
    print(f"gen-site: filled {', '.join(SLOTS)} in docs/index.html")


if __name__ == "__main__":
    main()
