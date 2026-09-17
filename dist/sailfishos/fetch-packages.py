#!/usr/bin/env python3
"""Download an explicitly pinned Sailfish GNOME release into mb2's RPMS/."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
from urllib.parse import urlparse
from urllib.request import urlopen


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def fetch_packages(lock_path, target, output, cache):
    lock = json.loads(lock_path.read_text())
    if lock.get("schema") != 1 or target not in lock.get("targets", {}):
        raise ValueError(f"No pinned Sailfish GNOME release for {target}")
    entry = lock["targets"][target]
    sha, url, names = entry["sha256"], entry["url"], entry["rpms"]
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise ValueError("Invalid bundle SHA-256")
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "github.com" or "/releases/download/" not in parsed.path:
        raise ValueError("Expected a versioned HTTPS GitHub Release URL")
    if (len(names) != 2 or len(set(names)) != 2 or
        any(not re.fullmatch(r"sailfish-gnome-(?:devel-)?[0-9][A-Za-z0-9_.+-]*\.rpm", n) for n in names)):
        raise ValueError("Expected two plain runtime/devel RPM filenames")
    if sum(n.startswith("sailfish-gnome-devel-") for n in names) != 1:
        raise ValueError("Expected one runtime RPM and one development RPM")
    if any(not n.endswith(f".{target.split('/')[-1]}.rpm") for n in names):
        raise ValueError("RPM architecture does not match the selected SDK target")
    cache.mkdir(parents=True, exist_ok=True)
    bundle = cache / f"{sha}.tar.gz"
    if not bundle.exists() or digest(bundle) != sha:
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            downloaded = Path(temporary) / "bundle.tar.gz"
            with urlopen(url, timeout=120) as response, downloaded.open("wb") as stream:
                shutil.copyfileobj(response, stream)
            if digest(downloaded) != sha:
                raise ValueError("Sailfish GNOME bundle checksum mismatch")
            downloaded.replace(bundle)
    # Never use extractall: only copy the two expected regular files. Validate
    # the full archive before changing the output directory, even on cache hits.
    with tarfile.open(bundle, "r:gz") as archive:
        members = archive.getmembers()
        if (len({m.name for m in members}) != len(members) or
            {m.name for m in members} != set(names) | {"BUILDINFO.json"} or
            any(not m.isfile() for m in members)):
            raise ValueError("Unexpected file, link or path in Sailfish GNOME bundle")
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            for name in names:
                with archive.extractfile(name) as source, (Path(temporary) / name).open("wb") as dest:
                    shutil.copyfileobj(source, dest)
            output.mkdir(parents=True, exist_ok=True)
            # mb2 must not select a stale, higher-version package from an
            # earlier build instead of the release explicitly pinned here.
            for old in output.glob("sailfish-gnome-*.rpm"):
                old.unlink()
            for name in names:
                shutil.copyfile(Path(temporary) / name, output / name)
                print(f"Verified {name}")


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", nargs="?", default="5.1.0.11")
    parser.add_argument("arch", nargs="?", default="aarch64")
    parser.add_argument("--lock", type=Path, default=root / "dist/sailfishos/sailfish-gnome.lock")
    parser.add_argument("--output", type=Path, default=root / "RPMS")
    parser.add_argument("--cache", type=Path, default=root / ".cache/sailfish-gnome-bundles")
    args = parser.parse_args()
    try:
        fetch_packages(args.lock, f"{args.release}/{args.arch}", args.output, args.cache)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        parser.exit(1, f"Cannot fetch Sailfish libraries: {error}\n")


if __name__ == "__main__":
    main()
