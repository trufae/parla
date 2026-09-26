#!/usr/bin/env python3
"""Native retry failure test with an isolated, offline core account.

Run: python3 tests/core_retry_test.py /path/to/deltachat-rpc-server
No transport is configured and network I/O is never started.
"""

from pathlib import Path
import sys
import tempfile

from core_unread_test import Core


def expect_no_transport(core, method, *params):
    try:
        core.call(method, *params)
    except AssertionError as error:
        assert "No self addr configured" in str(error), error
    else:
        raise AssertionError(f"{method} unexpectedly succeeded without a transport")


def check_retry(binary):
    with tempfile.TemporaryDirectory(prefix="parla-native-retry-") as folder:
        attachment = Path(folder) / "attachment.txt"
        attachment.write_text("Original attachment contents")
        core = Core(binary, Path(folder) / "accounts")
        try:
            account = core.call("add_account")
            contact = core.call("create_contact", account, "recipient@example.org", "Recipient")
            chat = core.call("create_chat_by_contact_id", account, contact)
            for data in (dict(text="Original text"),
                         dict(text="Original caption", file=str(attachment))):
                expect_no_transport(core, "send_msg", account, chat, data)
            ids = core.call("get_message_ids", account, chat, False, False)
            assert len(ids) == 2
            original = [core.call("get_message", account, i) for i in ids]
            # Retrying must use core's stored blob, not the file selected earlier.
            attachment.unlink()
            for message in original:
                assert message["state"] == 24 and message["error"]
                expect_no_transport(core, "resend_messages", account, [message["id"]])
                updated = core.call("get_message", account, message["id"])
                for field in ("id", "chatId", "text", "file", "state", "error"):
                    assert updated.get(field) == message.get(field), field
                if updated.get("file"):
                    assert Path(updated["file"]).read_text() == "Original attachment contents"
            assert core.call("get_message_ids", account, chat, False, False) == ids
        finally:
            core.close()
    print("Native retry of text/attachments, original IDs/blobs, persistent failure reason: PASS")


if __name__ == "__main__":
    check_retry(str(Path(sys.argv[1]).resolve()))
