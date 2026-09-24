#!/usr/bin/env python3
"""Check that the real app polls setup events without a configured profile.

Run with: dbus-run-session -- xvfb-run -a python3 tests/account_setup_events_test.py builddir/parla
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def fake_server():
    events = iter([
        {"kind": "ImexProgress", "progress": 500},
        {"kind": "ConfigureProgress", "progress": 250, "comment": "Connecting…"},
    ])
    for line in sys.stdin:
        request = json.loads(line)
        method = request["method"]
        with open(os.environ["PARLA_TEST_REQUEST_LOG"], "a") as log:
            log.write(method + "\n")
        if method == "get_system_info":
            result = {}
        elif method == "get_all_accounts":
            result = []
        elif method == "get_next_event":
            event = next(events, None)
            if event is None:
                continue  # Leave the long poll pending after both setup events.
            result = {"contextId": 1, "event": event}
        else:
            raise AssertionError("Unexpected RPC method: " + method)
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}),
              flush=True)


def check_startup(binary):
    with tempfile.TemporaryDirectory(prefix="parla-account-setup-") as folder:
        root = Path(folder)
        requests_path = root / "requests.log"
        env = os.environ.copy()
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        env.update(PARLA_RPC_SERVER=str(Path(__file__).resolve()),
                   PARLA_TEST_REQUEST_LOG=str(requests_path),
                   GTK_A11Y="none", GDK_BACKEND="x11", GSK_RENDERER="cairo")
        with (root / "app.log").open("w+") as log:
            app = subprocess.Popen([str(Path(binary).resolve())], env=env,
                                   stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                while app.poll() is None and time.monotonic() < deadline:
                    requests = requests_path.read_text().splitlines() if requests_path.exists() else []
                    # Poll again after consuming both events for an unselected account.
                    if requests.count("get_next_event") >= 3:
                        print("Setup events are consumed before a profile is configured")
                        return
                    time.sleep(0.05)
                log.seek(0)
                raise AssertionError("No setup event polling without a profile:\n" + log.read())
            finally:
                app.terminate()
                try:
                    app.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait()


if __name__ == "__main__":
    if len(sys.argv) == 1:
        fake_server()
    else:
        check_startup(sys.argv[1])
