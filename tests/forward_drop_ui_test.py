#!/usr/bin/env python3
"""Offline display regression: python3 tests/forward_drop_ui_test.py builddir/core-compat-test."""

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
    calls = []
    fail = False
    for line in sys.stdin:
        request = json.loads(line)
        method, params = request["method"], request["params"]
        result = None
        if method == "get_next_event":
            continue
        if method in ("forward_messages", "get_message", "send_msg"):
            calls.append(request)
        if method == "forward_messages" and fail:
            fail = False
            print(json.dumps(dict(jsonrpc="2.0", id=request["id"],
                                  error=dict(code=-32000, message="offline"))), flush=True)
            continue
        if method == "test_calls":
            result = calls
        elif method == "test_fail":
            fail = True
        elif method == "get_system_info":
            result = {}
        elif method == "get_all_accounts":
            result = [dict(id=1)]
        elif method == "is_configured":
            result = True
        elif method == "get_chatlist_entries":
            result = [] if params[1] == 1 else [10, 11, 12]
        elif method == "get_chatlist_items_by_entries":
            result = {str(i): dict(id=i, name=f"Contact {i}", chatType="Single",
                                  isContactRequest=i == 12) for i in params[1]}
        elif method in ("get_fresh_msgs", "list_transports", "get_pinned_messages"):
            result = []
        elif method == "get_full_chat_by_id":
            result = dict(id=params[1], name=f"Contact {params[1]}",
                          chatType="Single", contactIds=[])
        elif method == "get_message_ids":
            result = [42] if params[1] == 10 else []
        elif method in ("get_messages", "get_message"):
            def message(i):
                return dict(id=i, chatId=10, text="Picture caption",
                            timestamp=1700000000, state=16, viewType="Image",
                            file=os.environ["PARLA_TEST_IMAGE"], fileName="picture.png",
                            fileMime="image/png", sender=dict(id=42, displayName="Sender"))
            result = ({str(i): message(i) for i in params[1]}
                      if method == "get_messages" else message(params[1]))
        elif method == "send_msg":
            result = 100
        elif method == "get_connectivity":
            result = 1000
        elif method == "get_config":
            result = "Forwarding test" if params[1] == "displayname" else None
        elif method not in ("select_account", "start_io_for_all_accounts", "batch_set_config",
                            "get_draft", "misc_set_draft", "marknoticed_chat", "markseen_msgs",
                            "get_first_unread_message_of_chat", "forward_messages"):
            raise AssertionError(f"Unexpected RPC: {method}")
        print(json.dumps(dict(jsonrpc="2.0", id=request["id"], result=result)), flush=True)


def check_ui(binary):
    with tempfile.TemporaryDirectory(prefix="parla-forward-drop-") as folder:
        root = Path(folder)
        wrapper = root / "fake-core"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join(
            [sys.executable, str(Path(__file__).resolve()), "--fake-core"]) + "\n")
        wrapper.chmod(0o700)

        def chunk(kind, data):
            return (struct.pack(">I", len(data)) + kind + data
                    + struct.pack(">I", zlib.crc32(kind + data)))

        image = root / "picture.png"
        image.write_bytes(b"\x89PNG\r\n\x1a\n"
                          + chunk(b"IHDR", struct.pack(">2I5B", 64, 64, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress((b"\0" + bytes((40, 90, 160)) * 64) * 64))
                          + chunk(b"IEND", b""))
        env = dict(os.environ, PARLA_RPC_SERVER=str(wrapper), GTK_A11Y="none",
                   PARLA_TEST_IMAGE=str(image))
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        subprocess.run([str(Path(binary).resolve()), "--forward-drop-ui"],
                       env=env, check=True, timeout=30)


if __name__ == "__main__":
    if sys.argv[1:] == ["--fake-core"]:
        fake_core()
    else:
        check_ui(sys.argv[1])
