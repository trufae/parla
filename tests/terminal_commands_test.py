#!/usr/bin/env python3
"""Exercise TUI commands and persisted settings through real PTY/RPC IO."""
import codecs
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata

cli, backend = (str(Path(arg).resolve()) for arg in sys.argv[1:])


class Terminal:
    def __init__(self, env):
        self.master, self.slave = pty.openpty()
        self.width, self.height = 120, 42
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", self.height, self.width, 0, 0))
        self.process = subprocess.Popen([cli], stdin=self.slave, stdout=self.slave,
                                        stderr=subprocess.PIPE, env=env)
        self.decoder = codecs.getincrementaldecoder("utf-8")()
        self.pending = ""
        self.raw = b""
        self.x = self.y = 0
        self.cells = [[" "] * self.width for _ in range(self.height)]

    @property
    def lines(self):
        return ["".join(row) for row in self.cells]

    @property
    def screen(self):
        return "\n".join(self.lines)

    def pump(self, delay=0.1):
        if not select.select([self.master], [], [], delay)[0]:
            return False
        data = os.read(self.master, 65536)
        self.raw += data
        self.pending += self.decoder.decode(data)
        while self.pending:
            if self.pending.startswith("\x1b]8;;"):
                end = self.pending.find("\x1b\\", 5)
                if end < 0: break
                self.pending = self.pending[end + 2:]
                continue
            if self.pending.startswith("\x1b"):
                match = re.match(r"\x1b\[([0-9;?]*)([A-Za-z~])", self.pending)
                if not match:
                    break
                args, command = match.groups()
                self.pending = self.pending[match.end():]
                if command in "Hf":
                    coords = [int(n or 1) for n in args.split(";")]
                    self.y, self.x = coords[0] - 1, (coords[1] if len(coords) > 1 else 1) - 1
                elif command == "J" and args == "2":
                    self.cells = [[" "] * self.width for _ in range(self.height)]
                continue
            char, self.pending = self.pending[0], self.pending[1:]
            if char == "\r":
                self.x = 0
            elif char == "\n":
                self.y += 1
            elif char >= " ":
                width = 2 if unicodedata.east_asian_width(char) in "WF" else 1
                if self.x >= self.width:
                    self.x = 0
                    self.y += 1
                if 0 <= self.y < self.height:
                    self.cells[self.y][self.x] = char
                    if width == 2 and self.x + 1 < self.width:
                        self.cells[self.y][self.x + 1] = ""
                self.x += width
        return True

    def until(self, text):
        deadline = time.monotonic() + 5
        while text not in self.screen and time.monotonic() < deadline:
            self.pump()
        assert text in self.screen, (text, self.screen)

    def send(self, data):
        os.write(self.master, data.encode() if isinstance(data, str) else data)
        while self.pump(0.18):
            pass

    def command(self, text):
        self.send("\x15" + text + "\r")

    def close(self):
        try:
            if self.process.poll() is None:
                self.send("\x15/quit\r")
            status = self.process.wait(timeout=5)
            errors = self.process.stderr.read()
            assert status == 0 and errors == b"", (status, errors)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            os.close(self.master)
            os.close(self.slave)


with tempfile.TemporaryDirectory(prefix="parla-commands-") as folder:
    log = Path(folder) / "rpc.log"
    env = dict(os.environ, TERM="xterm-256color", TZ="UTC", G_DEBUG="fatal-warnings",
               XDG_CONFIG_HOME=folder, XDG_DATA_HOME=folder + "/data",
               XDG_CACHE_HOME=folder + "/cache", PARLA_CHECK_UPDATES="0",
               PARLA_RPC_SERVER=backend, PARLA_TEST_SERVER="terminal",
               PARLA_TEST_LOG=str(log),
               PARLA_TEST_QR_SVG=str(Path(__file__).parent / "fixtures/terminal-qr.svg"))
    env.pop("DC_ACCOUNTS_PATH", None)
    attachment = Path(folder) / "test image.png"
    attachment.write_bytes(b"\x89PNG\r\n\x1a\n")
    env["PARLA_TEST_ATTACHMENT"] = str(attachment)

    def requests(method):
        return [call for line in log.read_text().splitlines() if line.startswith("{")
                if (call := json.loads(line))["method"] == method]

    terminal = Terminal(env)
    try:
        terminal.until("Contacts (2)")
        terminal.send("\x1b2")
        terminal.until("Profile 1 chat")
        assert "[focus]" not in terminal.screen
        assert "22:13" in terminal.lines[2] and "Latest message preview" in terminal.lines[2]
        terminal.command("/query #Profile 1 chat")
        terminal.until("My own text")
        assert "--:-- <Me> My own text" in terminal.screen
        assert "[pending]" not in terminal.screen
        assert any(line.startswith("              second line") for line in terminal.lines)
        assert requests("markseen_msgs")[-1]["params"] == [1, [42]]
        assert requests("marknoticed_chat")[-1]["params"] == [1, 10]
        assert "0 unread" in terminal.lines[-2]

        terminal.command("/refresh")
        terminal.until("22:13 <Me> My own text")
        terminal.command("/version")
        assert "Parla 0." not in "\n".join(terminal.lines[1:-2])
        assert "1:Parla (1)" in terminal.lines[0]
        terminal.send("\x1b1")
        terminal.until("Parla 0.")
        terminal.send("\x1b3\x10")
        assert terminal.lines[-1].startswith("> /version")  # Shared recall.
        terminal.send("\x15hello world\x17")
        assert terminal.lines[-1].rstrip() == "> hello"
        assert "3:#Profile 1 chat" in terminal.lines[0]
        terminal.send("\x15/vers\t")
        assert terminal.lines[-1].startswith("> /version ")
        terminal.send("\x15hello @al\t")
        assert terminal.lines[-1].startswith("> hello @Alice ")
        terminal.send("\x15@\t")
        assert "@Alice" in terminal.screen and "@Me" in terminal.screen
        terminal.send("\t")
        assert terminal.lines[-1].startswith("> @Me ")

        assert (b"\x1b]8;;" + attachment.as_uri().encode() + b"\x1b\\") in terminal.raw
        stored_attachment = attachment.with_suffix(".stored")
        attachment.rename(stored_attachment)
        terminal.command("/refresh")
        terminal.until("(not downloaded)")
        stored_attachment.rename(attachment)
        restored_output = len(terminal.raw)
        terminal.command("/refresh")
        terminal.until("[Image: test image.png] /")
        assert "(not downloaded)" not in terminal.screen
        assert (b"\x1b]8;;" + attachment.as_uri().encode() + b"\x1b\\") in terminal.raw[restored_output:]
        terminal.send("\x15\x1b[<0;20;2M")
        assert "Selected #42" in terminal.lines[-2]
        terminal.command("/reply clicked reply")
        assert requests("send_msg")[-1]["params"][2]["quotedMessageId"] == 42
        terminal.command("/reply latest incoming")
        assert requests("send_msg")[-1]["params"][2]["quotedMessageId"] == 42
        terminal.command("/reply @Me own reply")
        assert requests("send_msg")[-1]["params"][2]["quotedMessageId"] == 44
        terminal.command("/reply @Alice named reply")
        assert requests("send_msg")[-1]["params"][2]["quotedMessageId"] == 42
        terminal.command("/reply")
        assert "Selecting #44" in terminal.lines[-2]
        terminal.send("k\r")
        assert terminal.lines[-1].startswith("> /reply ")
        terminal.send("selected reply\r")
        assert requests("send_msg")[-1]["params"][2]["quotedMessageId"] == 42
        terminal.command("/react #44 👍")
        assert requests("send_reaction")[-1]["params"] == [1, 44, ["❤", "👍"]]
        terminal.command("/react #44 😃")
        assert requests("send_reaction")[-1]["params"] == [1, 44, ["❤", "👍", "😃"]]
        terminal.command("/unreact #44 👍")
        assert requests("send_reaction")[-1]["params"] == [1, 44, ["❤", "😃"]]
        terminal.command("/unreact #44")
        assert requests("send_reaction")[-1]["params"] == [1, 44, []]
        sent = len(requests("send_msg"))
        terminal.command("/reply #999 unavailable")
        assert len(requests("send_msg")) == sent
        terminal.send("\x15")

        terminal.send("\x1b2")
        assert "2:Contacts" in terminal.lines[0]
        assert "[focus]" not in terminal.lines[1]
        terminal.send("gap")
        assert "Pinned" in terminal.screen
        assert requests("set_chat_visibility")[-1]["params"] == [1, 10, "Pinned"]
        terminal.send("p")
        assert requests("set_chat_visibility")[-1]["params"] == [1, 10, "Normal"]
        terminal.send("\r")
        terminal.until("Account 1 history")
        terminal.command("/set chat_info=on")
        terminal.until("Disappearing messages")
        assert "Members (2)" in terminal.screen and "Alice" in terminal.screen
        terminal.command("/color theme=ocean")
        terminal.command("/color status=#123456:#abcdef")
        assert b"38;2;18;52;86;48;2;171;205;239" in terminal.raw

        terminal.command("/account 2")
        terminal.until("Account 2 user2@example.org")
        terminal.send("\x10")
        assert terminal.lines[-1].startswith("> /account 2")
        terminal.command("/query 10")
        terminal.until("Account 2 history")
        assert "Account 1 history" not in terminal.screen
        terminal.command("/msg 10 from account two")
        assert requests("send_msg")[-1]["params"][0:2] == [2, 10]
        terminal.command("/account 1")
        terminal.until("Account 1 history")
        terminal.command("/query Alice")
        assert requests("get_chat_id_by_contact_id")[-1]["params"] == [1, 2]
        terminal.command("/query @Alice")
        assert requests("get_chat_id_by_contact_id")[-1]["params"] == [1, 2]
        terminal.command("/query alice@example.org")
        assert requests("lookup_contact_id_by_addr")[-1]["params"] == [1, "alice@example.org"]
        assert not requests("create_contact")
        lookups = len(requests("get_contact_ids"))
        terminal.command("/query #missing")
        assert len(requests("get_contact_ids")) == lookups
        terminal.command("/query new@example.org")
        assert requests("create_contact")[-1]["params"][:2] == [1, "new@example.org"]
        assert requests("create_chat_by_contact_id")[-1]["params"] == [1, 3]
        assert "4:@Alice" in terminal.lines[0]
        terminal.send("\x1bx")
        assert "4:@Alice" not in terminal.lines[0]
        terminal.send("\x1b3")
        terminal.command("/invite")
        assert requests("get_chat_securejoin_qr_code")[-1]["params"] == [1, 10]
        terminal.send("\x1b1")
        terminal.until("https://i.delta.chat/#example")
        assert "QR code (37 columns × 19 rows" in terminal.screen
        assert "▄" in terminal.screen and "▀" in terminal.screen
        assert b"38;2;0;0;0;48;2;255;255;255" in terminal.raw
        # Round-trip the displayed half blocks back to Core's module grid,
        # including its quiet zone; catches clipping, wrapping and polarity.
        qr_lines = terminal.lines[-21:-2]
        actual = set()
        for row, line in enumerate(qr_lines):
            for x, char in enumerate(line[:37]):
                if char in "█▀": actual.add((x - 4, row * 2 - 4))
                if char in "█▄": actual.add((x - 4, row * 2 - 3))
        expected = {(int(x), int(y)) for x, y in re.findall(r"M(\d+),(\d+)h1v1h-1z",
                    Path(env["PARLA_TEST_QR_SVG"]).read_text())}
        assert actual == expected, (actual ^ expected)
        terminal.command("/invite self")
        assert requests("get_chat_securejoin_qr_code")[-1]["params"] == [1, None]
        terminal.send("\x1b3")
        terminal.command("/close")
        assert "Profile 1 chat" not in terminal.lines[0]
        terminal.send("\x1b1")
        terminal.send("\x02")
        assert "[scroll " in terminal.lines[-2]
        terminal.send("\x06")
        assert "[scroll " not in terminal.lines[-2]
    finally:
        terminal.close()

    saved = (Path(folder) / "parla/terminal.ini").read_text()
    for setting in ("contacts_grouped=on", "contacts_sort=alphabetical", "chat_info=on", "theme=ocean", "color_status=#123456:#abcdef"):
        assert setting in saved, saved
    terminal = Terminal(env)
    try:
        terminal.until("2:Contacts")
        terminal.until("Account 1 user1@example.org")
        assert "Contacts" not in terminal.lines[1]  # Contacts only appears in its own tab.
        assert b"38;2;18;52;86;48;2;171;205;239" in terminal.raw
        terminal.command("/query 10")
        terminal.until("Disappearing messages")
        terminal.send("\x1b2")
        assert "Group chats" in terminal.screen and "A–Z" in terminal.lines[1]
    finally:
        terminal.close()
    saved = (Path(folder) / "parla/terminal.ini").read_text()
    assert "contacts_side" not in saved and "contacts_width" not in saved and "contacts=" not in saved, saved
    terminal = Terminal(env)
    try:
        terminal.until("Account 1 user1@example.org")
        assert "Contacts" not in terminal.lines[1]
        terminal.until("1 conversations")  # Wait for the startup chat-list RPC.
        assert not terminal.pump(0.3), "idle refresh after restoring settings"
    finally:
        terminal.close()
