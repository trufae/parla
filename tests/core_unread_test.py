#!/usr/bin/env python3
"""Exercise native unread state in an isolated, offline account store.

Run with: python3 tests/core_unread_test.py /path/to/deltachat-rpc-server
"""

import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile


class Core:
    def __init__(self, binary, folder):
        self.process = subprocess.Popen(
            [binary], env=dict(os.environ, DC_ACCOUNTS_PATH=str(folder)),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.sequence = 0

    def call(self, method, *params):
        self.sequence += 1
        self.process.stdin.write(json.dumps(dict(
            jsonrpc="2.0", id=self.sequence, method=method, params=params)) + "\n")
        self.process.stdin.flush()
        assert self.selector.select(15), f"Timed out waiting for {method}"
        response = json.loads(self.process.stdout.readline())
        assert response["id"] == self.sequence, response
        assert "error" not in response, response
        return response["result"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()
        self.selector.close()


def check_unread(binary):
    with tempfile.TemporaryDirectory(prefix="parla-native-unread-") as folder:
        core = Core(binary, folder)
        try:
            account = core.call("add_account")
            message = core.call("add_device_message", account, "unread-test",
                                {"text": "Native unread test"})
            chat = core.call("get_message", account, message)["chatId"]
            ids = core.call("get_message_ids", account, chat, False, False)
            core.call("markseen_msgs", account, ids)
            assert core.call("get_first_unread_message_of_chat", account, chat) is None
            core.call("markfresh_chat", account, chat)
            assert core.call("get_fresh_msg_cnt", account, chat) == 1
            assert core.call("get_first_unread_message_of_chat", account, chat) == message
        finally:
            core.close()

        # The reminder must survive an engine/app restart without local UI flags.
        core = Core(binary, folder)
        try:
            assert core.call("get_fresh_msg_cnt", account, chat) == 1
            assert core.call("get_first_unread_message_of_chat", account, chat) == message
            core.call("marknoticed_chat", account, chat)
            assert core.call("get_fresh_msg_cnt", account, chat) == 0
            assert core.call("get_first_unread_message_of_chat", account, chat) == message
            assert core.call("get_message", account, message)["state"] == 13
            core.call("markseen_msgs", account, [message])
            assert core.call("get_first_unread_message_of_chat", account, chat) is None
            assert core.call("get_message", account, message)["state"] == 16
        finally:
            core.close()
    print("Native unread state, restart persistence, noticed/seen distinction: PASS")


if __name__ == "__main__":
    check_unread(str(Path(sys.argv[1]).resolve()))
