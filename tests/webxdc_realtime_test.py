#!/usr/bin/env python3
"""Isolated realtime settings test; add --ui for the sandboxed UI test.

Usage: python3 tests/webxdc_realtime_test.py builddir/core-compat-test [--ui]
The UI test needs a display and an operational WebKit process sandbox.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="parla-realtime-test-") as folder:
    env = dict(os.environ, GTK_A11Y="none")
    for name in ("CONFIG", "DATA", "CACHE", "STATE"):
        env[f"XDG_{name}_HOME"] = str(Path(folder) / name.lower())
    env["PARLA_TEST_CONFIG"] = env["XDG_CONFIG_HOME"]
    binary = str(Path(sys.argv[1]).resolve())
    subprocess.run([binary, "--realtime-settings"], env=env, check=True, timeout=30)
    if "--ui" in sys.argv[2:]:
        subprocess.run([binary, "--realtime-ui"], env=env, check=True, timeout=60)
