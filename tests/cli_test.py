#!/usr/bin/env python3
"""Exercise the linked backend and REPL without GTK, network or real accounts."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cli, backend = (str(Path(arg).resolve()) for arg in sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="parla-cli-") as folder:
    root = Path(folder)
    settings = root / "config/parla/settings.ini"
    settings.parent.mkdir(parents=True)
    store = root / "shared-accounts"
    original = ("[General]\ndefault_account_addr=user2@example.org\n"
                "auto_download_limit=262144\nfuture_setting=preserved\n"
                f"accounts_path={store}\n")
    settings.write_text(original)
    log = root / "rpc.log"
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / "config"),
               XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"),
               PARLA_RPC_SERVER=backend, PARLA_CHECK_UPDATES="0", LANGUAGE="C",
               PARLA_TEST_LOG=str(log))
    env.pop("DC_ACCOUNTS_PATH", None)
    env.pop("PARLA_TEST_SERVER", None)
    subprocess.run([backend], env=env, check=True, timeout=15)
    settings.write_text(original)
    env["PARLA_TEST_SERVER"] = "normal"

    def run(commands, **changes):
        result = subprocess.run([cli], input=commands, text=True, capture_output=True,
                                env=dict(env, **changes), timeout=15)
        assert result.returncode == 0, result.stderr
        assert not result.stderr, result.stderr
        return result.stdout

    assert subprocess.run([cli, "--help"], env=env, capture_output=True,
                          timeout=5).returncode == 0
    text = "hello \"world\" \\ café " + "x" * 12000
    output = run("settings\naccounts\nchats\nmessages 10\nsend 10 " + text +
                 '\nrpc test_echo ["quoted text", 42]\naccount 1\nquit\n')
    assert "account 2" in output and "Account 1" in output, output
    assert str(store) in output and "Startup updates: false" in output, output
    assert "10\tShared chat\t2 unread" in output, output
    assert "Alice: Shared history" in output and "Sent 43" in output, output
    assert '["quoted text",42]' in output, output
    lines = log.read_text().splitlines()
    assert lines[0] == str(store) and lines[-1] == "EOF", lines
    calls = [json.loads(line) for line in lines[1:-1]]
    assert [c["params"] for c in calls if c["method"] == "select_account"] == [[2], [1]]
    downloads = [c["params"] for c in calls if c["method"] == "batch_set_config"]
    assert downloads == [[1, {"download_limit": "262144"}], [2, {"download_limit": "262144"}]] * 2
    sent = next(c["params"] for c in calls if c["method"] == "send_msg")
    assert sent[0:2] == [2, 10] and sent[2]["text"] == text, sent
    assert settings.read_text() == original  # Reading never rewrites GUI preferences.

    # EOF, a fresh store, environment path precedence, and repeat launches.
    run("")
    output = run("settings\nquit\n", DC_ACCOUNTS_PATH=str(root / "override"))
    assert str(root / "override") in output
    assert log.read_text().splitlines()[0] == str(root / "override")
    assert "No profiles configured" in run("quit\n", PARLA_TEST_SERVER="empty")

    result = subprocess.run([cli], input="", text=True, capture_output=True,
                            env=dict(env, PARLA_RPC_SERVER=str(root / "missing")), timeout=5)
    assert result.returncode != 0 and "RPC server not found" in result.stderr, result
    result = subprocess.run([cli], input="", text=True, capture_output=True,
                            env=dict(env, PARLA_TEST_SERVER="locked"), timeout=5)
    assert result.returncode != 0 and "accounts.lock" in result.stderr, result

    # A disconnected core must wake the main loop even with stdin still open.
    with subprocess.Popen([cli], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, env=env) as process:
        process.stdin.write("rpc test_disconnect\n")
        process.stdin.flush()
        assert process.wait(timeout=5) != 0
        assert "Disconnected" in process.stderr.read()
