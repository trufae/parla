#!/usr/bin/env python3
"""Session detection and explicit overrides, each with isolated settings."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
for current, session, desktop, expected in (
    ("", "", "", False),
    ("GNOME", "gnome", "gnome", False),
    ("Phosh:GNOME", "", "", True),
    ("GNOME:pHoSh", "", "", True),
    ("GNOME", "phosh", "", True),
    ("", "", "phosh", True),
    ("notphosh:GNOME", "phosh-test", "", False),
):
    with tempfile.TemporaryDirectory(prefix="parla-long-press-") as folder:
        env = dict(os.environ, XDG_CONFIG_HOME=folder,
                   XDG_CURRENT_DESKTOP=current, XDG_SESSION_DESKTOP=session,
                   DESKTOP_SESSION=desktop)
        subprocess.run([binary, "--long-press-settings", str(expected).lower()],
                       env=env, check=True, timeout=30)
