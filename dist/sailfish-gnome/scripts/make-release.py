#!/usr/bin/env python3
"""Collect RPMs and corresponding sources; generate an exact consumer lock."""
import hashlib
import json
import os
from pathlib import Path
import re
import tarfile

root = Path(__file__).resolve().parent.parent
os.chdir(root)
version = re.search(r"^Version:\s+(\S+)", Path("rpm/sailfish-gnome.spec").read_text(), re.M)[1]
release, arch = "5.1.0.11", "aarch64"
stem = f"sailfish-gnome-{version}-sfos{release}-{arch}"
out = Path("out")
out.mkdir(exist_ok=True)
rpms = sorted(Path("RPMS").glob("*.rpm"))
expected = {f"sailfish-gnome-{version}-1.sfos{release}.{arch}.rpm",
            f"sailfish-gnome-devel-{version}-1.sfos{release}.{arch}.rpm"}
if {p.name for p in rpms} != expected:
    raise SystemExit(f"Expected runtime and devel RPMs: {expected}; found {rpms}")

# Verify every source again before making the corresponding-source archive.
for line in Path("sources.lock").read_text().splitlines():
    if not line or line.startswith("#"):
        continue
    sha, filename, _url = line.split()
    if hashlib.sha256((Path("rpm") / filename).read_bytes()).hexdigest() != sha:
        raise SystemExit(f"Source checksum mismatch: {filename}")

info = out / "BUILDINFO.json"
info.write_text(json.dumps({"version": version, "sailfish_release": release,
    "architecture": arch, "commit": os.environ.get("GITHUB_SHA", "local"),
    "sdk_image": os.environ.get("SFOS_IMAGE", "local"),
    "workflow_run": os.environ.get("GITHUB_RUN_ID", "local")}, indent=2) + "\n")
bundle = out / f"{stem}.tar.gz"
with tarfile.open(bundle, "w:gz") as tar:
    for rpm in rpms:
        tar.add(rpm, arcname=rpm.name)
    tar.add(info, arcname=info.name)
with tarfile.open(out / f"{stem}-sources.tar.xz", "w:xz") as tar:
    for name in ["COPYING", "README.md", "sources.lock", "scripts", "rpm", "vapi"]:
        tar.add(name, arcname=f"sailfish-gnome-{version}/{name}")
    tar.add(info, arcname=f"sailfish-gnome-{version}/BUILDINFO.json")

# This lock can be committed to consuming apps after publishing this release.
url = f"https://github.com/trufae/sailfish-gnome/releases/download/v{version}/{bundle.name}"
lock = {"schema": 1, "targets": {f"{release}/{arch}": {
    "url": url, "sha256": hashlib.sha256(bundle.read_bytes()).hexdigest(),
    "rpms": sorted(expected)}}}
(out / "sailfish-gnome.lock").write_text(json.dumps(lock, indent=2) + "\n")
for rpm in rpms:
    (out / rpm.name).write_bytes(rpm.read_bytes())
with (out / "SHA256SUMS").open("w") as sums:
    for path in sorted(out.iterdir()):
        if path.name != "SHA256SUMS" and path.is_file():
            sums.write(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
print(f"Release assets in {out.resolve()}; copy sailfish-gnome.lock to consumers after publication.")
