#!/usr/bin/env python3
"""A fake terminal, in about a hundred lines of stdlib.

Named faketerm and not pty: a module called pty.py would shadow the standard
library's pty on sys.path and this file imports it, so the collision is silent and
self-inflicted.

This is the load-bearing piece of the test suite. color-terminal's entire job is to
write specific bytes to a tty, so the only honest way to test it without installing
fifteen terminal emulators is to *be* one: allocate a pty, make it the child's
controlling terminal, and read what arrives.

Two things it does that a naive harness would get wrong:

1. The child's stdout goes to a PIPE, not to the pty. color-terminal writes escapes
   to fd 3 (/dev/tty) precisely so that stdout stays clean for pipelines — a stray
   escape byte on stdout corrupts scp, rsync and git-over-ssh. Splitting the two
   streams is what lets assert_clean_stdout() mean anything.

2. ECHO, ECHOCTL and ECHONL are cleared on the pty before the child starts. Without
   that, anything the harness writes toward the child (a canned reply to a terminal
   identification query) is echoed straight back into the capture, and every
   assertion downstream is reading its own input.
"""

import os, pty, select, signal, termios, fcntl, struct, sys, time

ESC = b"\x1b"
ST = b"\x1b\\"


def _disable_echo(fd):
    a = termios.tcgetattr(fd)
    a[3] &= ~(termios.ECHO | termios.ECHOCTL | termios.ECHONL)
    termios.tcsetattr(fd, termios.TCSANOW, a)


def run(argv, env=None, reply=None, timeout=10.0, cwd=None):
    """Run argv with a pty as its controlling terminal.

    reply: optional dict {trigger_bytes: response_bytes}. When the trigger appears in
    what the child has written so far, the response is written back — this is how a
    terminal's answer to an identification query is simulated for a terminal that is
    not installed, or does not exist on this platform at all.

    Returns (tty_bytes, stdout_bytes, exit_status).
    """
    master, slave = pty.openpty()
    _disable_echo(slave)
    out_r, out_w = os.pipe()

    pid = os.fork()
    if pid == 0:                                     # child
        try:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)  # claim it as the controlling tty
            os.dup2(slave, 0)
            os.dup2(out_w, 1)                         # stdout -> pipe, NOT the pty
            os.dup2(out_w, 2)
            for fd in (master, slave, out_r, out_w):
                try:
                    os.close(fd)
                except OSError:
                    pass
            if cwd:
                os.chdir(cwd)
            os.execvpe(argv[0], argv, env if env is not None else os.environ)
        except Exception as exc:                      # pragma: no cover
            os.write(2, f"harness: {exc}\n".encode())
        finally:
            os._exit(127)

    os.close(slave)
    os.close(out_w)

    tty_buf, out_buf = bytearray(), bytearray()
    fired = set()
    deadline = time.time() + timeout
    open_fds = {master, out_r}
    while open_fds and time.time() < deadline:
        r, _, _ = select.select(list(open_fds), [], [], 0.2)
        for fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                open_fds.discard(fd)
                continue
            if fd == master:
                tty_buf += chunk
            else:
                out_buf += chunk
        if reply:
            for trigger, response in reply.items():
                if trigger not in fired and trigger in bytes(tty_buf):
                    os.write(master, response)
                    fired.add(trigger)
        if not open_fds:
            break
        try:
            done, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if done:
            # Drain whatever is still buffered before giving up the loop.
            for fd in list(open_fds):
                try:
                    while True:
                        chunk = os.read(fd, 65536)
                        if not chunk:
                            open_fds.discard(fd)
                            break
                        (tty_buf if fd == master else out_buf).extend(chunk)
                except (OSError, BlockingIOError):
                    pass
            break

    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    except Exception:
        os.kill(pid, signal.SIGKILL)
        status = -1
    for fd in (master, out_r):
        try:
            os.close(fd)
        except OSError:
            pass
    return bytes(tty_buf), bytes(out_buf), status


# --- assertions -------------------------------------------------------------------

def oscs(tty_bytes):
    """Split a capture into its OSC payloads, in order.

    Accepts both terminators: ESC \\ (ST) and BEL. Screen's DCS wrapper uses BEL for
    the INNER terminator specifically because screen's own DCS parser ends at the
    first ESC \\ — so a harness that only understood ST would report the screen path
    as broken when it is the one that is correct.
    """
    out, i, n = [], 0, len(tty_bytes)
    while i < n:
        j = tty_bytes.find(b"\x1b]", i)
        if j < 0:
            break
        k = j + 2
        end = None
        while k < n:
            if tty_bytes[k:k + 2] == ST:
                end = (k, k + 2); break
            if tty_bytes[k:k + 1] == b"\x07":
                end = (k, k + 1); break
            k += 1
        if end is None:
            break
        out.append(tty_bytes[j + 2:end[0]].decode("latin-1"))
        i = end[1]
    return out


def assert_clean_stdout(out_bytes):
    if b"\x1b" in out_bytes:
        raise AssertionError(
            "escape byte on stdout — this is what corrupts scp/rsync/git-over-ssh:\n"
            + repr(out_bytes[:400]))


if __name__ == "__main__":
    tty, out, status = run(sys.argv[1:])
    print(f"exit={status >> 8} tty={len(tty)}B stdout={len(out)}B")
    for payload in oscs(tty):
        print("  OSC", payload)
    assert_clean_stdout(out)
