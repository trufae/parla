#!/usr/bin/env python3
"""Display integration: GDK_BACKEND=broadway python3 tests/search_ui_test.py builddir/core-compat-test.

Uses isolated settings and an offline core with 2,000 messages per chat.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def fake_core(variable_heights=False):
    seen = set()
    deleted = set()
    batches = []
    hold = False
    held = None

    def message(i):
        text = f"Message {i}\nContext around the search result."
        if variable_heights:
            text = f"Message {i}" + "\nA line of message text for scrolling." * (45 if i % 9 == 0 else i % 5)
        return dict(kind="message", id=i, chatId=20 if i >= 20000 else 10,
                    fromId=42, state=16 if i in seen else 13, viewType="Text",
                    text=text,
                    timestamp=1700000000 + i,
                    sender=dict(id=42, displayName="Sender"))

    for line in sys.stdin:
        request = json.loads(line)
        method, params = request["method"], request["params"]
        result = None
        failure = None
        if method == "get_next_event":
            continue
        if method == "get_system_info":
            result = {}
        elif method == "get_all_accounts":
            result = [{"id": 1}, {"id": 2}]
        elif method == "is_configured":
            result = True
        elif method == "get_chatlist_entries":
            result = [20] if params[1] == 1 else [10]
        elif method == "get_chatlist_items_by_entries":
            result = {str(i): dict(id=i, name=f"Chat {i}", chatType="Single") for i in params[1]}
        elif method == "get_full_chat_by_id":
            result = dict(id=params[1], name=f"Chat {params[1]}", chatType="Single", contactIds=[])
        elif method in ("get_fresh_msgs", "list_transports", "get_pinned_messages"):
            result = []
        elif method == "get_connectivity":
            result = 1000
        elif method == "get_config":
            result = "Search profile" if params[1] == "displayname" else None
        elif method == "get_message_ids":
            start = 20000 if params[1] == 20 else 10
            result = [i for i in range(start, start + 2000) if i not in deleted]
        elif method == "get_messages":
            batches.append(params[1])
            result = {str(i): message(i) for i in params[1] if i not in deleted}
        elif method == "get_message":
            result = message(params[1]) if params[1] not in deleted else None
        elif method == "search_messages":
            query, chat = params[1:]
            result = [] if query == "empty" else [20, 50] if chat else [20020, 20]
            if query == "far":
                result = [800]
            if query == "same-chat":
                result = [1000, 1020]
            if query == "many":
                result = list(range(2009, 1009, -1))
            if query == "deleted":
                result = [25] if chat else [25, 20]
                deleted.add(25)
        elif method == "message_ids_to_search_results":
            result = {}
            for i in params[1]:
                if i in deleted:
                    failure = "Message not found"
                    break
                result[str(i)] = dict(id=i, chatId=20 if i >= 20000 else 10,
                    chatName="Archived chat" if i >= 20000 else "Chat 10",
                    authorName="Sender", message=f"Match <{i}> & context",
                    isChatArchived=i >= 20000, timestamp=1700000000 + i)
        elif method == "markseen_msgs":
            seen.update(params[1])
        elif method == "test_hold":
            hold = True
        elif method == "test_release":
            assert held is not None
            print(json.dumps(held), flush=True)
            held = None
            hold = False
        elif method == "test_seen":
            result = params[0] in seen
        elif method == "test_batches":
            result = batches
        elif method not in ("get_blob_dir", "get_draft", "select_account", "get_first_unread_message_of_chat",
                             "start_io_for_all_accounts", "batch_set_config", "marknoticed_chat"):
            raise AssertionError(f"Unexpected RPC: {method}")
        response = dict(jsonrpc="2.0", id=request["id"])
        if failure:
            response["error"] = dict(code=-32000, message=failure)
        else:
            response["result"] = result
        if hold and method == "get_messages":
            held = response
        else:
            print(json.dumps(response), flush=True)


def check_ui(binary):
    with tempfile.TemporaryDirectory(prefix="parla-search-ui-") as folder:
        root = Path(folder)
        wrapper = root / "fake-core"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join(
            [sys.executable, str(Path(__file__).resolve()), "--fake-core"]) + "\n")
        wrapper.chmod(0o700)
        env = dict(os.environ, PARLA_RPC_SERVER=str(wrapper), GTK_A11Y="none")
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        subprocess.run([str(Path(binary).resolve()), "--search-ui"], env=env,
                       check=True, timeout=60)


if __name__ == "__main__":
    if sys.argv[1] in ("--fake-core", "--fake-scroll-core"):
        fake_core(sys.argv[1] == "--fake-scroll-core")
    else:
        check_ui(sys.argv[1])
