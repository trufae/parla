#!/usr/bin/env python3
"""Display test: python3 tests/message_retry_ui_test.py builddir/core-compat-test.

Requires a GTK display. Runs with an isolated profile and an offline fake core.
"""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def check_ui(binary):
    binary = str(Path(binary).resolve())
    with tempfile.TemporaryDirectory(prefix="parla-retry-ui-") as folder:
        root = Path(folder)
        wrapper = root / "fake-core"
        log = root / "core-stderr"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.join(
            [binary, "--fake-retry"]) + " 2>" + shlex.quote(str(log)) + "\n")
        wrapper.chmod(0o700)
        env = dict(os.environ, PARLA_RPC_SERVER=str(wrapper), GTK_A11Y="none")
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        try:
            subprocess.run([binary, "--retry-ui"], env=env, check=True, timeout=30)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            if log.exists():
                print(log.read_text(), file=sys.stderr)
            raise


if __name__ == "__main__":
    check_ui(sys.argv[1])
