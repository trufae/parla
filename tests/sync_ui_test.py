#!/usr/bin/env python3
"""Offline startup-sync UI regression; run with a GTK display (e.g. Broadway).

python3 tests/sync_ui_test.py builddir/core-compat-test
"""
from collections import Counter, deque
import json
import os
from pathlib import Path
from queue import Empty, Queue
import shlex
import subprocess
import sys
import tempfile
from threading import Thread
import time


def fake_core():
    requests = Queue()

    def read_requests():
        for line in sys.stdin:
            requests.put(json.loads(line))
        requests.put(None)

    Thread(target=read_requests, daemon=True).start()
    events = deque()
    pending_event = None
    calls = Counter()
    syncing = True
    bursting = False
    revision = 0
    next_tick = 0
    hold = False
    held = None
    chats = [10, 20, 30]

    def reply(request, result):
        print(json.dumps(dict(jsonrpc="2.0", id=request["id"], result=result)), flush=True)

    def event(kind, account=1, **fields):
        events.append(dict(contextId=account, event=dict(kind=kind, **fields)))

    def message(i):
        chat = i // 100
        return dict(id=i, chatId=chat, fromId=42, state=16, viewType="Text",
                    text=f"History {revision}" if chat == 10 else "Unchanged",
                    timestamp=1700000000 + i,
                    sender=dict(id=42, displayName="Sender"))

    while True:
        if bursting and time.monotonic() >= next_tick:
            next_tick = time.monotonic() + .02
            revision += 1
            event("MsgsChanged", chatId=10, msgId=1000)
            event("ChatlistItemChanged", chatId=10)
            event("ChatlistChanged")
            event("MsgsChanged", account=2, chatId=40, msgId=4000)
        if pending_event and events:
            reply(pending_event, events.popleft())
            pending_event = None
        try:
            request = requests.get(timeout=.005)
        except Empty:
            continue
        if request is None:
            return
        method, params = request["method"], request["params"]
        calls[method] += 1
        result = None
        if method == "get_next_event":
            assert pending_event is None
            pending_event = request
            continue
        if method == "get_system_info":
            result = {}
        elif method == "get_all_accounts":
            result = [{"id": 1}, {"id": 2}]
        elif method == "is_configured":
            result = True
        elif method == "get_connectivity":
            result = 3000 if syncing else 4000
        elif method == "get_chatlist_entries":
            result = [] if params[1] == 1 else chats
        elif method == "get_chatlist_items_by_entries":
            result = {str(i): dict(id=i, name=f"Chat {i}", chatType="Single",
                                  lastMessageId=i * 100,
                                  summaryText1="", summaryText2=f"History {revision}" if i == 10 else "Unchanged")
                      for i in params[1]}
        elif method == "get_full_chat_by_id":
            result = dict(id=params[1], name=f"Chat {params[1]}", chatType="Single", contactIds=[])
        elif method in ("get_fresh_msgs", "list_transports", "get_pinned_messages"):
            result = []
        elif method == "get_message_ids":
            result = [params[1] * 100]
        elif method == "get_messages":
            result = {str(i): message(i) for i in params[1]}
        elif method == "get_message":
            result = message(params[1])
        elif method == "test_burst":
            calls.clear()
            bursting = True
        elif method == "test_finish":
            bursting = syncing = False
            chats = [30, 10, 20]
            revision += 1
            event("IncomingMsgBunch")
            event("ConnectivityChanged")
            result = revision
        elif method == "test_calls":
            result = dict(calls)
        elif method == "test_hold":
            revision += 1
            hold = True
        elif method == "test_held":
            result = held is not None
        elif method == "test_release":
            assert held is not None
            reply(*held)
            held = None
        elif method == "test_remove":
            chats = [10, 20]
            event("ChatDeleted", chatId=30)
        elif method not in ("get_blob_dir", "get_config", "get_draft", "select_account",
                             "start_io_for_all_accounts", "batch_set_config",
                             "get_first_unread_message_of_chat", "marknoticed_chat", "markseen_msgs"):
            raise AssertionError(f"Unexpected RPC: {method}")
        if hold and method == "get_messages":
            held = (request, result)
            hold = False
        else:
            reply(request, result)


def check_ui(binary):
    with tempfile.TemporaryDirectory(prefix="parla-sync-ui-") as folder:
        root = Path(folder)
        wrapper = root / "fake-core"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join(
            [sys.executable, str(Path(__file__).resolve()), "--fake-core"]) + "\n")
        wrapper.chmod(0o700)
        env = dict(os.environ, PARLA_RPC_SERVER=str(wrapper), GTK_A11Y="none")
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        subprocess.run([str(Path(binary).resolve()), "--sync-ui"], env=env,
                       check=True, timeout=30)


if __name__ == "__main__":
    if sys.argv[1] == "--fake-core":
        fake_core()
    else:
        check_ui(sys.argv[1])
