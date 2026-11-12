#!/usr/bin/env python3
"""GTK lifetime regression and optional Heaptrack workload (requires a display).

    python3 tests/chat_lifetime_test.py builddir/core-compat-test
    python3 tests/chat_lifetime_test.py builddir/core-compat-test \
        --switching --refreshes 60 --heaptrack /tmp/parla-chat-switches

Uses synthetic account data in temporary XDG directories.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import tempfile
import zlib


def fake_core():
    revision = 0
    for line in sys.stdin:
        request = json.loads(line)
        method, params = request["method"], request["params"]
        result = None
        if method == "get_next_event":
            continue
        if method == "get_system_info":
            result = {}
        elif method == "get_all_accounts":
            result = [{"id": 1}]
        elif method == "is_configured":
            result = True
        elif method == "get_chatlist_entries":
            result = [] if params[1] == 1 else list(range(10, 22))
        elif method == "get_chatlist_items_by_entries":
            revision += 1
            result = {str(i): dict(id=i, name=f"Chat {i}", chatType="Single",
                                  summaryText2=f"Message {revision}",
                                  avatarPath=os.environ["PARLA_TEST_AVATAR"])
                      for i in params[1]}
        elif method in ("get_fresh_msgs", "list_transports", "get_pinned_messages"):
            result = []
        elif method == "get_full_chat_by_id":
            result = dict(id=params[1], name=f"Chat {params[1]}", chatType="Group", contactIds=[])
        elif method == "get_message_ids":
            result = list(range(params[1] * 100, params[1] * 100 + 30))
        elif method == "get_messages":
            result = {str(i): dict(id=i, chatId=i // 100, text=f"Message {i}",
                                  timestamp=1700000000 + i, state=16, viewType="Image",
                                  file=os.environ["PARLA_TEST_AVATAR"], fileMime="image/png",
                                  sender=dict(id=42, displayName="Sender"))
                      for i in params[1]}
        elif method == "get_connectivity":
            result = 1000
        elif method == "get_config":
            result = "Lifetime profile" if params[1] == "displayname" else None
        elif method not in ("get_blob_dir", "select_account", "start_io_for_all_accounts", "batch_set_config",
                             "get_draft", "misc_set_draft", "marknoticed_chat", "markseen_msgs",
                             "get_first_unread_message_of_chat"):
            raise AssertionError(f"Unexpected RPC: {method}")
        print(json.dumps(dict(jsonrpc="2.0", id=request["id"], result=result)), flush=True)


def check_ui(args):
    with tempfile.TemporaryDirectory(prefix="parla-chat-lifetime-") as folder:
        root = Path(folder)
        wrapper = root / "fake-core"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join(
            [sys.executable, str(Path(__file__).resolve()), "--fake-core"]) + "\n")
        wrapper.chmod(0o700)
        # A synthetic avatar makes retained pixel memory obvious in profiles.
        def chunk(kind, data):
            return (struct.pack(">I", len(data)) + kind + data
                    + struct.pack(">I", zlib.crc32(kind + data)))

        avatar = root / "avatar.png"
        avatar.write_bytes(b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">2I5B", 256, 256, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + bytes((40, 90, 160)) * 256) * 256))
            + chunk(b"IEND", b""))
        env = dict(os.environ, PARLA_RPC_SERVER=str(wrapper), GTK_A11Y="none",
                   PARLA_TEST_AVATAR=str(avatar))
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        mode = "--chat-switch-lifetime-ui" if args.switching else "--chat-lifetime-ui"
        if args.navigation:
            mode = "--chat-navigation-window-ui"
        command = [str(Path(args.binary).resolve()), mode, str(args.refreshes)]
        if args.heaptrack:
            command = ["heaptrack", "--record-only", "-o", args.heaptrack] + command
        subprocess.run(command, env=env, check=True, timeout=180)


if __name__ == "__main__":
    if sys.argv[1:] == ["--fake-core"]:
        fake_core()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("binary")
        parser.add_argument("--refreshes", type=int, default=10,
                            help="number of sidebar refreshes or chat switches")
        parser.add_argument("--heaptrack", metavar="OUTPUT")
        parser.add_argument("--switching", action="store_true")
        parser.add_argument("--navigation", action="store_true",
                            help="check narrow-window chat navigation and desktop restoration")
        check_ui(parser.parse_args())
