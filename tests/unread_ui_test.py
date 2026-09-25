#!/usr/bin/env python3
"""Display integration test: python3 tests/unread_ui_test.py builddir/core-compat-test.

Requires a GTK display, e.g. run under xvfb-run or with GDK_BACKEND=broadway.
Uses a temporary profile and an offline fake core; no real accounts are opened.
"""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def fake_core():
    states = {i: 16 if i < 20 else 10 for i in range(10, 110)}

    def message(i):
        return dict(id=i, chatId=10, fromId=42, state=states[i], viewType="Text",
                    text=f"Message {i}\nA second line to exercise scrolling.",
                    timestamp=1700000000 + i,
                    sender=dict(id=42, displayName="Test sender"))

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
            result = [] if params[1] == 1 else [10]
        elif method == "get_chatlist_items_by_entries":
            result = {"10": dict(id=10, name="Unread test", chatType="Single",
                                  freshMessageCounter=90)}
        elif method == "get_full_chat_by_id":
            result = dict(id=10, name="Unread test", chatType="Single", contactIds=[])
        elif method in ("get_fresh_msgs", "list_transports", "get_pinned_messages"):
            result = []
        elif method == "get_connectivity":
            result = 1000
        elif method == "get_message_ids":
            result = list(states)
        elif method == "get_messages":
            result = {str(i): message(i) for i in params[1]}
        elif method == "get_message":
            result = message(params[1])
        elif method == "get_first_unread_message_of_chat":
            for i in reversed(states):
                if states[i] == 16:
                    break
                result = i
        elif method == "markseen_msgs":
            for i in params[1]:
                states[i] = 16
        elif method == "marknoticed_chat":
            states = {i: 13 if state == 10 else state for i, state in states.items()}
        elif method == "markfresh_chat":
            states[max(states)] = 10
        elif method == "test_seen":
            result = states[params[0]] == 16
        elif method == "test_incoming":
            states[params[0]] = 10
        elif method not in ("get_config", "get_draft", "select_account",
                             "start_io_for_all_accounts", "batch_set_config"):
            raise AssertionError(f"Unexpected RPC: {method}")
        print(json.dumps(dict(jsonrpc="2.0", id=request["id"], result=result)), flush=True)


def check_ui(binary):
    with tempfile.TemporaryDirectory(prefix="parla-unread-ui-") as folder:
        root = Path(folder)
        wrapper = root / "fake-core"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join(
            [sys.executable, str(Path(__file__).resolve()), "--fake-core"]) + "\n")
        wrapper.chmod(0o700)
        env = dict(os.environ, PARLA_RPC_SERVER=str(wrapper), GTK_A11Y="none")
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        subprocess.run([str(Path(binary).resolve()), "--unread-ui"], env=env,
                       check=True, timeout=30)


if __name__ == "__main__":
    if sys.argv[1] == "--fake-core":
        fake_core()
    else:
        check_ui(sys.argv[1])
