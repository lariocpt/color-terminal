#!/usr/bin/env python3
"""Enforce rule 1 of docs/README.md: the website makes ZERO external requests.

The previous check was a grep for `<(link|script|img)…(src|href)="https?:` — which is
blind to single quotes, unquoted values, protocol-relative `//` URLs, srcset, iframes,
video, CSS url() and @import — and an html.parser "parses" call that cannot fail,
because html.parser never raises. This walks every start tag with the same parser and
looks at every attribute, plus the stylesheet and inline styles, and names the line.

The only thing allowed to point off-site is a plain <a href>: a link the reader
chooses to follow is not a request the page makes.

    python3 tools/check-site.py docs/index.html
"""
import re
import sys
from html.parser import HTMLParser

REMOTE = re.compile(r"^\s*(https?:|//)", re.I)
CSS_REMOTE = re.compile(r"(url\(\s*['\"]?\s*(https?:|//)|@import\b)", re.I)
# Elements that fetch by their nature, whatever their attributes say.
EMBEDDERS = {"iframe", "object", "embed", "video", "audio", "source", "track", "frame"}
URL_ATTRS = {"src", "href", "srcset", "poster", "data", "action", "formaction", "ping"}


class Check(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.problems: list[str] = []
        self.in_style = False

    def _bad(self, what: str) -> None:
        line, _ = self.getpos()
        self.problems.append(f"line {line}: {what}")

    def handle_starttag(self, tag, attrs):
        if tag == "style":
            self.in_style = True
        if tag in EMBEDDERS:
            self._bad(f"<{tag}> embeds external content")
        for name, value in attrs:
            if value is None:
                continue
            if name == "style" and CSS_REMOTE.search(value):
                self._bad(f"inline style on <{tag}> loads a remote url()")
            if tag == "a" and name == "href":
                continue                      # a link is not a request
            if name in URL_ATTRS and REMOTE.match(value):
                self._bad(f"<{tag} {name}=\"{value[:60]}\"> is a remote reference")
            if name == "srcset" and REMOTE.search(value):
                self._bad(f"<{tag} srcset> names a remote image")

    def handle_endtag(self, tag):
        if tag == "style":
            self.in_style = False

    def handle_data(self, data):
        if self.in_style and CSS_REMOTE.search(data):
            self._bad("stylesheet loads a remote url() or @import")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check-site.py docs/index.html", file=sys.stderr)
        return 2
    text = open(argv[1], encoding="utf-8").read()
    c = Check()
    c.feed(text)
    c.close()
    if c.problems:
        for p in c.problems:
            print(f"check-site: {argv[1]}: {p}")
        print(f"check-site: FAIL — {len(c.problems)} external reference(s); the page must be one self-contained file")
        return 1
    print(f"check-site: {argv[1]} makes no external requests")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
