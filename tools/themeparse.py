"""The one parser for themes/*.theme, shared by every tool that reads the corpus.

Mirrors the bash loader in lib/theme.sh: flat `key = value`, a comment only when
'#' is the FIRST non-blank character (a '#' later in the line is data — it is how
every colour starts), and a line that is neither is an error rather than something to
skip. Two tools with two parsers of different tolerance is how a theme the validator
rejects still ends up rendered on the website, so there is exactly one.
"""
import re
from pathlib import Path

KEY_RE = re.compile(r"^[a-z0-9-]+$")


class ThemeError(Exception):
    pass


def parse_theme(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    text = path.read_text(encoding="utf-8")
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        if line[0] == "#":
            continue
        if "=" not in line:
            raise ThemeError(f"{path.name} line {lineno}: not a comment and has no '=': {raw!r}")
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not KEY_RE.match(key):
            raise ThemeError(f"{path.name} line {lineno}: key {key!r} does not match [a-z0-9-]+")
        data[key] = value
    return data
