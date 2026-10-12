#!/usr/bin/env python3
"""Run with xvfb-run -a python3 tests/audio_player_ui_test.py builddir/core-compat-test.

Uses the real GTK player and a silent WAV with an isolated offline account.
Set PARLA_TEST_SCREENSHOTS to an existing directory to save rendered windows.
Requires the GstPlay runtime (libgstreamer-plugins-bad1.0-0 on Debian/Ubuntu).
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import wave


def fake_core():
    def message(i):
        return dict(id=i, chatId=10, text="" if i < 1003 else
                    "The player, message text and composer stay inside the phone screen.",
                    timestamp=1791790200 + i, state=16,
                    viewType="Voice" if i < 1003 else "Text",
                    file=os.environ["PARLA_TEST_AUDIO"] if i < 1003 else None,
                    fileMime="audio/wav", sender=dict(id=42,
                    displayName="Enrico — a sender with a very long display name"))

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
            result = {"10": dict(id=10, name="Enrico", chatType="Single")}
        elif method == "get_full_chat_by_id":
            result = dict(id=10, name="Enrico", chatType="Single", contactIds=[])
        elif method in ("get_fresh_msgs", "list_transports", "get_pinned_messages"):
            result = []
        elif method == "get_message_ids":
            result = [1001, 1002, 1003]
        elif method == "get_messages":
            result = {str(i): message(i) for i in params[1]}
        elif method == "get_message":
            result = message(params[1])
        elif method == "get_connectivity":
            result = 1000
        elif method == "get_config":
            result = "Audio test" if params[1] == "displayname" else None
        elif method not in ("select_account", "start_io_for_all_accounts", "batch_set_config",
                             "get_draft", "marknoticed_chat", "markseen_msgs",
                             "get_first_unread_message_of_chat"):
            raise AssertionError(f"Unexpected RPC: {method}")
        print(json.dumps(dict(jsonrpc="2.0", id=request["id"], result=result)), flush=True)


def check_ui(binary):
    with tempfile.TemporaryDirectory(prefix="parla-audio-ui-") as folder:
        root = Path(folder)
        wrapper = root / "fake-core"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join(
            [sys.executable, str(Path(__file__).resolve()), "--fake-core"]) + "\n")
        wrapper.chmod(0o700)
        audio = root / "voice.wav"
        with wave.open(str(audio), "wb") as wav:
            wav.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\0\0" * 8000 * 60)
        env = dict(os.environ, PARLA_RPC_SERVER=str(wrapper), GTK_A11Y="none",
                   PARLA_TEST_AUDIO=str(audio))
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        command = [str(Path(binary).resolve()), "--audio-player-ui"]
        subprocess.run(command, env=env, check=True, timeout=60)


if __name__ == "__main__":
    if sys.argv[1:] == ["--fake-core"]:
        fake_core()
    else:
        check_ui(sys.argv[1])
