#!/usr/bin/env python3
"""Validate the color-terminal theme corpus.

python3, stdlib only. Run from anywhere:

    tools/validate-themes.py            # validate, exit non-zero on any failure
    tools/validate-themes.py --report   # also print the contrast table

The theme format is flat "key = value", UTF-8, one theme per file, filename stem
is the theme id:

  * split on the FIRST "=", trim whitespace around key and value;
  * a line whose first non-blank character is "#" is a comment. "#" ANYWHERE ELSE
    IS DATA — it begins every colour value. This distinction is load-bearing and
    the parser below implements exactly it;
  * blank lines and unknown keys are ignored, never errors;
  * colours are "#" + 6 lowercase hex digits, nothing else;
  * keys match [a-z0-9-]+.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
THEME_DIR = REPO_ROOT / "themes"

COLOR_RE = re.compile(r"^#[0-9a-f]{6}$")

PALETTE_KEYS = [f"color{i}" for i in range(16)]
REQUIRED_KEYS = ["name", "variant", "background", "foreground"] + PALETTE_KEYS
COLOR_KEYS = ["background", "foreground"] + PALETTE_KEYS
OPTIONAL_COLOR_KEYS = [
    "cursor",
    "cursor-text",
    "selection-background",
    "selection-foreground",
]

# A background brighter than this reads as a light theme. 0.18 is roughly mid-grey
# in WCAG relative luminance and separates every published corpus cleanly.
LIGHT_LUMINANCE = 0.18

# --- contrast gate ----------------------------------------------------------------
# WCAG 2.x contrast ratios against the theme background.
MIN_FG = 4.5           # body text — the AA bar for normal text
MIN_RED = 3.0          # color1 is what errors, diffs and failing tests are painted in
MIN_REST = 2.8         # color2/4/5/6: green, blue, magenta, cyan
MIN_YELLOW = 2.0       # color3 — see below
WARN_YELLOW = 3.0
REST_KEYS = ["color2", "color4", "color5", "color6"]

# WHY YELLOW GETS A LOWER BAR (2.0 rather than the 3.0 everything else clears):
# yellow on a light background is universally poor. Saturated yellow sits at very
# high relative luminance by construction — that is what makes it read as yellow —
# so against a near-white background it lands near 1.5-2.5 in essentially every
# published theme corpus, not just ours. Holding color3 to a flat 3.0 does not
# select for good light themes; it selects for themes whose "yellow" has been
# darkened into olive or brown. Measured across the 44 candidates we screened,
# a flat 3.0 yellow bar leaves exactly 2 usable light themes. So color3 gets a
# 2.0 floor and anything between 2.0 and 3.0 prints a WARNING rather than
# failing: the reviewer sees it, the corpus stays usable, and the keys that
# actually carry meaning (foreground, and red for errors) keep their full bars.


# The parser lives in themeparse.py so the website generator reads the corpus with
# EXACTLY the same rules as this validator. Re-exported here because the report code
# below and older callers refer to them by these names.
from themeparse import KEY_RE, ThemeError, parse_theme  # noqa: E402,F401


def srgb_to_linear(channel: int) -> float:
    s = channel / 255.0
    return s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4


def luminance(color: str) -> float:
    """WCAG 2.x relative luminance of a '#rrggbb' string."""
    r = int(color[1:3], 16)
    g = int(color[3:5], 16)
    b = int(color[5:7], 16)
    return (
        0.2126 * srgb_to_linear(r)
        + 0.7152 * srgb_to_linear(g)
        + 0.0722 * srgb_to_linear(b)
    )


def contrast(a: str, b: str) -> float:
    """WCAG 2.x contrast ratio between two '#rrggbb' strings."""
    la, lb = luminance(a), luminance(b)
    lighter, darker = max(la, lb), min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)


def ratios(theme: dict[str, str]) -> dict[str, float]:
    bg = theme["background"]
    return {
        "fg": contrast(theme["foreground"], bg),
        "c1": contrast(theme["color1"], bg),
        "c3": contrast(theme["color3"], bg),
        "rest": min(contrast(theme[k], bg) for k in REST_KEYS),
    }


def check_theme(
    theme_id: str,
    theme: dict[str, str],
    corpus: dict[str, dict[str, str]],
) -> tuple[list[str], list[str]]:
    """Return (errors, warnings) for one theme."""
    errors: list[str] = []
    warnings: list[str] = []

    # (a) required keys
    missing = [k for k in REQUIRED_KEYS if k not in theme or theme[k] == ""]
    if missing:
        errors.append(f"missing required key(s): {', '.join(missing)}")

    # (b) colour syntax — required and optional colour keys alike
    for key in COLOR_KEYS + OPTIONAL_COLOR_KEYS:
        value = theme.get(key)
        if value is None:
            continue
        if not COLOR_RE.match(value):
            errors.append(
                f"{key} = {value!r} is not '#' + 6 lowercase hex digits"
            )

    # Everything below needs well-formed colours; bail rather than crash on int().
    if errors:
        return errors, warnings

    # (c) variant declared, and agreeing with the background's luminance
    variant = theme["variant"]
    if variant not in ("dark", "light"):
        errors.append(f"variant = {variant!r} is not 'dark' or 'light'")
    else:
        bg_lum = luminance(theme["background"])
        implied = "light" if bg_lum > LIGHT_LUMINANCE else "dark"
        if implied != variant:
            errors.append(
                f"variant = {variant} but background {theme['background']} has "
                f"luminance {bg_lum:.4f} ({'>' if bg_lum > LIGHT_LUMINANCE else '<='} "
                f"{LIGHT_LUMINANCE}), which implies {implied}"
            )

    # (d) pairs-with must be mutual, existing, and of the opposite variant
    partner_id = theme.get("pairs-with")
    if partner_id:
        partner = corpus.get(partner_id)
        if partner is None:
            errors.append(
                f"pairs-with = {partner_id} but themes/{partner_id}.theme does not exist"
            )
        else:
            back = partner.get("pairs-with")
            if back != theme_id:
                errors.append(
                    f"pairs-with = {partner_id}, but {partner_id} points back at "
                    f"{back!r} instead of {theme_id!r}"
                )
            if partner.get("variant") == theme.get("variant"):
                errors.append(
                    f"pairs-with = {partner_id}, but both are variant "
                    f"{theme.get('variant')!r}; a pair must be one dark and one light"
                )

    # (e) contrast gate
    r = ratios(theme)
    if r["fg"] < MIN_FG:
        errors.append(
            f"contrast(foreground, background) = {r['fg']:.2f} < {MIN_FG} "
            "(body text is unreadable)"
        )
    if r["c1"] < MIN_RED:
        errors.append(
            f"contrast(color1, background) = {r['c1']:.2f} < {MIN_RED} "
            "(red carries errors; it has to be legible)"
        )
    if r["rest"] < MIN_REST:
        worst = min(REST_KEYS, key=lambda k: contrast(theme[k], theme["background"]))
        errors.append(
            f"min contrast over color2/4/5/6 = {r['rest']:.2f} < {MIN_REST} "
            f"(worst is {worst})"
        )
    if r["c3"] < MIN_YELLOW:
        errors.append(
            f"contrast(color3, background) = {r['c3']:.2f} < {MIN_YELLOW} "
            "(yellow already has the lowest bar in the gate)"
        )
    elif r["c3"] < WARN_YELLOW:
        warnings.append(
            f"contrast(color3, background) = {r['c3']:.2f} is under {WARN_YELLOW}; "
            "yellow is dim here but above the floor"
        )

    return errors, warnings


def load_corpus(theme_dir: Path) -> tuple[dict[str, dict[str, str]], list[str]]:
    corpus: dict[str, dict[str, str]] = {}
    errors: list[str] = []
    for path in sorted(theme_dir.glob("*.theme")):
        theme_id = path.stem
        if not KEY_RE.match(theme_id):
            errors.append(f"{theme_id}: filename stem does not match [a-z0-9-]+")
            continue
        try:
            corpus[theme_id] = parse_theme(path)
        except (ThemeError, UnicodeDecodeError, OSError) as exc:
            errors.append(f"{theme_id}: {exc}")
    return corpus, errors


def print_report(corpus: dict[str, dict[str, str]]) -> None:
    rows = []
    for theme_id, theme in sorted(corpus.items()):
        try:
            r = ratios(theme)
        except (KeyError, ValueError):
            rows.append((theme_id, "?", None))
            continue
        rows.append((theme_id, theme.get("variant", "?"), r))

    width = max([len(t) for t, _, _ in rows] + [5])
    print(
        f"{'theme'.ljust(width)}  {'variant':<7}  "
        f"{'fg/bg':>6}  {'c1':>6}  {'c3':>6}  {'rest':>6}  notes"
    )
    print("-" * (width + 46))
    for theme_id, variant, r in rows:
        if r is None:
            print(f"{theme_id.ljust(width)}  {variant:<7}  {'unparsed':>6}")
            continue
        notes = []
        if r["c3"] < WARN_YELLOW:
            notes.append("dim yellow")
        print(
            f"{theme_id.ljust(width)}  {variant:<7}  "
            f"{r['fg']:>6.2f}  {r['c1']:>6.2f}  {r['c3']:>6.2f}  {r['rest']:>6.2f}  "
            f"{', '.join(notes)}"
        )
    print(
        f"\ngates: fg/bg >= {MIN_FG}   c1 >= {MIN_RED}   "
        f"rest(min of color2/4/5/6) >= {MIN_REST}   c3 >= {MIN_YELLOW} "
        f"(warn under {WARN_YELLOW})"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate every themes/*.theme file.",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help="print a table of every theme with its four contrast ratios",
    )
    parser.add_argument(
        "--themes",
        type=Path,
        default=THEME_DIR,
        help=f"theme directory (default: {THEME_DIR})",
    )
    args = parser.parse_args(argv)

    theme_dir: Path = args.themes
    if not theme_dir.is_dir():
        print(f"validate-themes: no such directory: {theme_dir}", file=sys.stderr)
        return 2

    corpus, load_errors = load_corpus(theme_dir)
    if not corpus and not load_errors:
        print(f"validate-themes: no *.theme files in {theme_dir}", file=sys.stderr)
        return 2

    failures = 0
    warned = 0
    for line in load_errors:
        print(f"FAIL {line}", file=sys.stderr)
        failures += 1

    for theme_id, theme in sorted(corpus.items()):
        errors, warnings = check_theme(theme_id, theme, corpus)
        for w in warnings:
            print(f"WARN {theme_id}: {w}", file=sys.stderr)
            warned += 1
        for e in errors:
            print(f"FAIL {theme_id}: {e}", file=sys.stderr)
        if errors:
            failures += 1

    if args.report:
        print_report(corpus)
        print()

    total = len(corpus)
    if failures:
        print(
            f"validate-themes: {failures} of {total} theme(s) FAILED"
            + (f", {warned} warning(s)" if warned else ""),
            file=sys.stderr,
        )
        return 1

    print(
        f"validate-themes: {total} theme(s) OK"
        + (f", {warned} warning(s)" if warned else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
