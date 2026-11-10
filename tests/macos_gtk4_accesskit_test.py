#!/usr/bin/env python3
"""Check cached GTK deployment with real dylibs in an isolated Homebrew layout."""
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/macos/gtk4-accesskit.sh"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS dylibs")
class GtkDeploymentTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="parla-gtk-deploy-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.prefix = self.root / "brew"
        self.keg = self.prefix / "Cellar/gtk4/4.24.1"
        self.cache = self.root / "cache"
        self.stage = self.cache / "gtk4-4.24.1/lib"
        for directory in [self.prefix / "bin", self.prefix / "lib",
                          self.prefix / "opt", self.keg / "lib", self.stage]:
            directory.mkdir(parents=True)
        (self.prefix / "opt/gtk4").symlink_to(self.keg)
        brew = self.prefix / "bin/brew"
        brew.write_text('''#!/bin/sh
case "$*" in
    "--prefix gtk4") printf '%s\\n' "$BREW_PREFIX/opt/gtk4" ;;
    "list --versions gtk4") echo 'gtk4 4.24.1' ;;
    *) exit 1 ;;
esac
''')
        brew.chmod(0o755)
        self.env = dict(os.environ, BREW_PREFIX=str(self.prefix),
                        A11Y_CACHE_DIR=str(self.cache),
                        WORK_DIR=str(self.root / "work"),
                        PATH=f"{self.prefix / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin")
        # Only Homebrew discovery is stubbed; otool, rsync and dyld see real
        # libraries, including the AccessKit load command used by the script.
        accesskit = self.stage / "libaccesskit.dylib"
        self.build_library(accesskit, "int accesskit_fixture(void) { return 1; }")
        gtk = self.stage / "libgtk-4.1.dylib"
        self.build_library(gtk, "extern int accesskit_fixture(void);\n"
                           "int gtk_fixture(void) { return accesskit_fixture(); }",
                           str(accesskit))
        (self.stage / "libgtk-4.dylib").symlink_to(gtk.name)

    def build_library(self, output, source, *dependencies):
        subprocess.run(["cc", "-dynamiclib", *dependencies, "-x", "c", "-",
                        "-install_name", str(self.prefix / "lib" / output.name),
                        "-o", str(output)], input=source, text=True, check=True)

    def deploy(self):
        result = subprocess.run(["bash", str(SCRIPT)], env=self.env,
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def check_single_gtk(self):
        for name in ["libgtk-4.1.dylib", "libgtk-4.dylib"]:
            self.assertTrue((self.prefix / "lib" / name).samefile(self.keg / "lib" / name))
        # The app loads GTK through the prefix; libadwaita uses the opt path.
        direct = ctypes.CDLL(str(self.prefix / "lib/libgtk-4.1.dylib"))
        indirect = ctypes.CDLL(str(self.prefix / "opt/gtk4/lib/libgtk-4.1.dylib"))
        self.assertEqual(direct.gtk_fixture(), 1)
        self.assertEqual(ctypes.cast(direct.gtk_fixture, ctypes.c_void_p).value,
                         ctypes.cast(indirect.gtk_fixture, ctypes.c_void_p).value)

    def test_cache_install_preserves_one_gtk_and_is_idempotent(self):
        (self.keg / "lib/libgtk-4.1.dylib").write_text("stock GTK placeholder")
        (self.keg / "lib/libgtk-4.dylib").symlink_to("libgtk-4.1.dylib")
        for name in ["libgtk-4.1.dylib", "libgtk-4.dylib"]:
            (self.prefix / "lib" / name).symlink_to(self.keg / "lib" / name)
        self.assertIn("done (from cache)", self.deploy())
        self.check_single_gtk()
        self.assertIn("nothing to do", self.deploy())
        self.check_single_gtk()

    def test_cache_repairs_separate_accesskit_enabled_copies(self):
        for library in self.stage.iterdir():
            shutil.copy2(library, self.prefix / "lib" / library.name, follow_symlinks=False)
            if library.name.startswith("libgtk-"):
                shutil.copy2(library, self.keg / "lib" / library.name, follow_symlinks=False)
        self.assertIn("done (from cache)", self.deploy())
        self.check_single_gtk()


if __name__ == "__main__":
    unittest.main()
