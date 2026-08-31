"""Runs INSIDE a real terminal window. Applies a theme, then asks the terminal what
colour it is now actually using.

This is the acceptance oracle, and it is better than a screenshot: it is exact,
textual, needs no pixels, no fonts, no tolerance value, and no compositor. If the
terminal's own answer matches the theme file, the entire chain is proven end to end —
emit -> fd 3 -> pty -> the terminal's parser -> its renderer state.

Launched by test/live/run.sh, which opens a real window per terminal.
"""
import os, sys, termios, tty, select, subprocess, re

OUT = sys.argv[1]
THEME = "catppuccin-mocha"

# Read the expected colours out of the corpus rather than hardcoding them. The
# container layer already does this; hardcoding here meant a retuned theme would leave
# this oracle asserting a colour the tool no longer ships — a test that fails for the
# wrong reason, or worse, passes for one.
_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_THEME_FILE = os.path.join(_REPO, "themes", THEME + ".theme")


def _theme_colour(key):
    with open(_THEME_FILE) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == key:
                return v.strip()
    raise KeyError("%s has no '%s'" % (_THEME_FILE, key))


# A corpus problem is reported THROUGH the reply file, not on stderr: run.sh discards
# this process's stderr and reads only the file, so an exit here would be reported as
# "the window did not run the probe" — blaming the terminal for a broken theme.
try:
    THEME_BG = _theme_colour("background")
    THEME_C1 = _theme_colour("color1")
except (OSError, KeyError) as e:
    with open(OUT, "w") as fh:
        fh.write("VERDICT=ERROR\nerror=probe could not read the expected colours: %s\n" % e)
    sys.exit(1)

CT = os.environ.get("CT_BIN", os.path.expanduser("~/.local/bin/color-terminal"))
subprocess.run([CT, "--theme", THEME], check=False)

fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
answers = {}
try:
    tty.setraw(fd)
    # DA1 after the queries is the sentinel: it tells "answered nothing" apart from
    # "still thinking", because every terminal answers DA1 even if it ignores the rest.
    os.write(1, b"\x1b]11;?\x1b\\\x1b]4;1;?\x1b\\\x1b[c")
    buf = b""
    while select.select([fd], [], [], 1.0)[0]:
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        buf += chunk
        if re.search(rb"\x1b\[\?[0-9;]*c", buf):   # DA1 arrived: everything is in
            break
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)

def norm(spec):
    """rgb:RRRR/GGGG/BBBB, rgb:RR/GG/BB, #rrggbb and #rrrrggggbbbb -> one 8-bit triple."""
    spec = spec.strip()
    m = re.match(r"rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+)$", spec)
    if m:
        return "#" + "".join(f"{int(p[:2], 16):02x}" for p in m.groups())
    m = re.match(r"#([0-9a-fA-F]{6})$", spec)
    if m:
        return "#" + m.group(1).lower()
    m = re.match(r"#([0-9a-fA-F]{12})$", spec)
    if m:
        h = m.group(1)
        return "#" + "".join(h[i:i+2] for i in (0, 4, 8)).lower()
    return spec

for payload in re.findall(rb"\x1b\](.*?)(?:\x1b\\|\x07)", buf, re.S):
    p = payload.decode("latin-1")
    if p.startswith("11;"):
        answers["background"] = norm(p[3:])
    elif p.startswith("4;1;"):
        answers["color1"] = norm(p[4:])

with open(OUT, "w") as fh:
    fh.write(f"raw={buf!r}\n")
    fh.write(f"background={answers.get('background','NO-REPLY')} expected={THEME_BG}\n")
    fh.write(f"color1={answers.get('color1','NO-REPLY')} expected={THEME_C1}\n")
    ok = answers.get("background") == THEME_BG and answers.get("color1") == THEME_C1
    fh.write(f"VERDICT={'PASS' if ok else 'FAIL'}\n")
