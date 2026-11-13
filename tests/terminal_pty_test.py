#!/usr/bin/env python3
"""Exercise real terminal IO, idle output, resize and termios restoration."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

cli, backend = (str(Path(arg).resolve()) for arg in sys.argv[1:])


def read_until_quiet(fd, duration=0.12, deadline=3):
    result = b""
    end = time.monotonic() + deadline
    while time.monotonic() < end and select.select([fd], [], [], duration)[0]:
        result += os.read(fd, 65536)
    return result


with tempfile.TemporaryDirectory(prefix="parla-terminal-") as folder:
    env = dict(os.environ, TERM="xterm-256color", XDG_CONFIG_HOME=folder,
               XDG_DATA_HOME=folder + "/data", XDG_CACHE_HOME=folder + "/cache",
               PARLA_CHECK_UPDATES="0", G_DEBUG="fatal-warnings",
               PARLA_RPC_SERVER=backend, PARLA_TEST_SERVER="normal",
               PARLA_TEST_LOG=folder + "/rpc.log")
    env.pop("DC_ACCOUNTS_PATH", None)
    for quit_signal in (None, signal.SIGTERM, signal.SIGHUP):
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
            before = termios.tcgetattr(slave)
            process = subprocess.Popen([cli], stdin=slave, stdout=slave,
                                       stderr=subprocess.PIPE, env=env)
            try:
                assert select.select([master], [], [], 5)[0], "no initial frame"
                initial = read_until_quiet(master)
                deadline = time.monotonic() + 5
                while b"Contacts (2)" not in initial and time.monotonic() < deadline:
                    initial += read_until_quiet(master)
                assert b"\x1b[?1049h" in initial and b"Contacts" in initial, initial
                assert b"Contacts (2)" in initial and b"\x1b[?1006h" in initial, initial
                # Populate scrollback through the normal command path.
                os.write(master, b"/help\r/help\r/help\r")
                read_until_quiet(master, 0.2)
                assert not select.select([master], [], [], 0.25)[0], "idle terminal redraw"
                os.write(master, b"hello")
                edit = read_until_quiet(master, 0.2)
                assert b"hello" in edit and len(edit) < 100, edit
                assert b"\x1b[2J" not in edit
                os.write(master, b"\x1b[200~first\nsecond\x1b[201~")
                pasted = read_until_quiet(master, 0.2)
                assert b"first" in pasted and b"second" in pasted, pasted
                os.write(master, b"\x1b[<64;40;8M")  # Wheel up over history.
                assert b"[scroll 1]" in read_until_quiet(master, 0.2)
                os.write(master, b"\x07")  # Focus the Contacts tab.
                focused = read_until_quiet(master, 0.2)
                assert b"input inactive" in focused and not focused.endswith(b"\x1b[?25h"), focused
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 18, 70, 0, 0))
                os.kill(process.pid, signal.SIGWINCH)
                resized = read_until_quiet(master, 0.2)
                assert b"\x1b[2J" in resized and b"Contacts" in resized, resized
                if quit_signal is None:
                    os.write(master, b"\x03")
                else:
                    os.kill(process.pid, quit_signal)
                assert process.wait(timeout=5) == 0
                tail = read_until_quiet(master)
                assert b"\x1b[?1049l" in tail and b"\x1b[?2004l" in tail, tail
                assert b"\x1b[?1000l" in tail and b"\x1b[?1006l" in tail, tail
                after = termios.tcgetattr(slave)
                # macOS sets this kernel-managed bit when switching back to
                # canonical input, including a plain tty.setraw round trip.
                pendin = getattr(termios, "PENDIN", 0)
                after[3] &= ~pendin
                before[3] &= ~pendin
                assert after == before, "termios was not restored"
                assert process.stderr.read() == b""
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        finally:
            os.close(master)
            os.close(slave)
    result = subprocess.run([cli], input=b"quit\n", capture_output=True, env=env, timeout=5)
    assert result.returncode == 0 and b"\x1b[" not in result.stdout
    # Startup can fail before the first asynchronous yield; do not enter a
    # fresh main loop after the terminal has already closed.
    master, slave = pty.openpty()
    try:
        result = subprocess.run([cli], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                                env=dict(env, PARLA_RPC_SERVER=folder + "/missing"), timeout=5)
        assert result.returncode != 0 and b"RPC server not found" in result.stderr
        assert b"\x1b[?1049l" in read_until_quiet(master)
        assert termios.tcgetattr(slave)[3] & termios.ICANON
    finally:
        os.close(master)
        os.close(slave)
