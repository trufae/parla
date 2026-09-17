#!/usr/bin/env python3
"""Exercise trust boundaries of the prebuilt Sailfish package downloader."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fetch_packages", Path(__file__).resolve().parents[1] / "dist/sailfishos/fetch-packages.py")
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)


class PackageDownloadTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "RPMS"
        self.cache = self.root / "cache"
        self.names = [f"sailfish-gnome-{kind}0.1.0-1.sfos5.1.0.11.aarch64.rpm" for kind in ["", "devel-"]]

    def bundle(self, extra=None):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name in self.names + ["BUILDINFO.json"]:
                data = b"test payload"
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            if extra:
                archive.addfile(extra)
        return stream.getvalue()

    def lock(self, data):
        self.sha = hashlib.sha256(data).hexdigest()
        path = self.root / "lock.json"
        path.write_text(json.dumps({"schema": 1, "targets": {"5.1.0.11/aarch64": {
            "sha256": self.sha, "url": "https://github.com/trufae/sailfishos-gnome/releases/download/v0.1.0/bundle.tar.gz", "rpms": self.names}}}))
        return path

    def fetch(self, lock):
        fetcher.fetch_packages(lock, "5.1.0.11/aarch64", self.output, self.cache)

    def test_verified_bundle_is_cached_and_removes_stale_library_versions(self):
        data = self.bundle()
        lock = self.lock(data)
        self.output.mkdir()
        (self.output / "sailfish-gnome-9.0-1.aarch64.rpm").write_bytes(b"stale")
        with patch.object(fetcher, "urlopen", return_value=io.BytesIO(data)) as download:
            self.fetch(lock)
            self.fetch(lock)
            self.assertEqual(download.call_count, 1)
        self.assertEqual({p.name for p in self.output.iterdir()}, set(self.names))
        self.assertTrue(all(p.read_bytes() == b"test payload" for p in self.output.iterdir()))

    def test_wrong_checksum_leaves_existing_packages_untouched(self):
        lock = self.lock(self.bundle())
        self.output.mkdir()
        existing = self.output / self.names[0]
        existing.write_bytes(b"existing")
        with patch.object(fetcher, "urlopen", return_value=io.BytesIO(b"corrupt")):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                self.fetch(lock)
        self.assertEqual(existing.read_bytes(), b"existing")

    def test_archive_paths_and_links_are_rejected_even_with_valid_checksum(self):
        traversal = tarfile.TarInfo("../outside")
        symlink = tarfile.TarInfo("link")
        symlink.type = tarfile.SYMTYPE
        symlink.linkname = "/etc/passwd"
        for extra in [traversal, symlink]:
            with self.subTest(extra=extra.name):
                data = self.bundle(extra)
                lock = self.lock(data)
                with patch.object(fetcher, "urlopen", return_value=io.BytesIO(data)):
                    with self.assertRaisesRegex(ValueError, "Unexpected file"):
                        self.fetch(lock)
                self.assertFalse(self.output.exists())
                self.assertFalse((self.root / "outside").exists())

    def test_another_sdk_target_is_not_silently_accepted(self):
        lock = self.lock(self.bundle())
        with patch.object(fetcher, "urlopen") as download:
            with self.assertRaisesRegex(ValueError, "No pinned"):
                fetcher.fetch_packages(lock, "5.0.0.43/aarch64", self.output, self.cache)
            download.assert_not_called()


if __name__ == "__main__":
    unittest.main()
