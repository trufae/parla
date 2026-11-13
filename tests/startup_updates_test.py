#!/usr/bin/env python3
"""Check package policy and launch overrides against existing user preferences."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
update_checks, pinned_core = (v == "true" for v in sys.argv[2:])

for saved_preference in (None, True, False):
    preference = True if saved_preference is None else saved_preference
    for value, override in (
        (None, None), ("", None), ("invalid", None),
        ("1", True), ("true", True), (" YeS ", True), ("ON", True),
        ("0", False), ("false", False), (" NO ", False), ("off", False),
    ):
        with tempfile.TemporaryDirectory(prefix="parla-startup-updates-") as folder:
            settings = Path(folder) / "parla" / "settings.ini"
            if saved_preference is not None:
                settings.parent.mkdir()
                settings.write_text("[General]\nrpc_check_updates_on_startup="
                                    + str(preference).lower() + "\n")
            env = dict(os.environ, XDG_CONFIG_HOME=folder)
            env.pop("PARLA_CHECK_UPDATES", None)
            if value is not None:
                env["PARLA_CHECK_UPDATES"] = value
            expected = update_checks and preference if override is None else override
            expected_core = expected and not pinned_core
            configurable = update_checks and override is None
            subprocess.run(
                [binary, "--startup-updates", *[
                    str(v).lower() for v in
                    (preference, expected, expected_core, configurable)]],
                env=env, check=True, timeout=30,
            )
