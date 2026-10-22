#!/bin/sh
# Query or update every packaged Chatmail Core pin. Requires Python 3.
set -eu
cd "$(dirname "$0")"
exec python3 - "$@" <<'PY'
import argparse
import json
import re
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

API = "https://api.github.com/repos/chatmail/core"
DOWNLOAD = "https://github.com/chatmail/core/releases/download"
ANDROID = Path("scripts/android/versions.env")
FLATPAK = Path("dist/flatpak/io.github.trufae.Parla.json")
SAILFISH = Path("dist/sailfishos/fetch-sources.sh")
SPEC = Path("rpm/harbour-parla.spec")


def api(path):
    request = Request(f"{API}/{path}", headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "parla-version-chatmail",
    })
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def one(pattern, text):
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"expected one match for {pattern!r}, found {len(matches)}")
    return matches[0]


def replace(pattern, value, text):
    one(pattern, text)
    return re.sub(pattern, lambda match: value, text, flags=re.MULTILINE)


def main():
    parser = argparse.ArgumentParser(
        prog="version-chatmail.sh",
        description="Show packaged Chatmail Core versions and query the latest stable release.",
    )
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--check", action="store_true", help="query without changing files (default)")
    action.add_argument("--update", nargs="?", const="latest", metavar="VERSION",
                        help="update all pins to VERSION (e.g. 2.64.0), or latest if omitted")
    args = parser.parse_args()
    requested = args.update or "latest"
    if requested != "latest" and not re.fullmatch(r"v?\d+\.\d+\.\d+", requested):
        parser.error("VERSION must be X.Y.Z, vX.Y.Z, or latest")

    contents = {path: path.read_text() for path in (ANDROID, FLATPAK, SAILFISH, SPEC)}
    manifest = json.loads(contents[FLATPAK])
    modules = [module for module in manifest["modules"] if module["name"] == "deltachat-rpc-server"]
    if len(modules) != 1:
        raise ValueError("expected one Flatpak deltachat-rpc-server module")
    sources = modules[0]["sources"]
    if sorted(source["only-arches"] for source in sources) != [["aarch64"], ["x86_64"]]:
        raise ValueError("unexpected Flatpak core architectures")

    print("Current Chatmail Core pins:", flush=True)
    print("  Android:", one(r"^CHATMAIL_VERSION=(\S+)$", contents[ANDROID]))
    for source in sources:
        version = one(r"/download/v([^/]+)/", source["url"])
        print(f"  Flatpak {source['only-arches'][0]}: {version}")
    print("  Sailfish:", one(r"^DCRPC_VERSION=(\S+)$", contents[SAILFISH]))
    print("  RPM spec:", one(r"^%global dcrpc_version (\S+)$", contents[SPEC]), flush=True)

    endpoint = "latest" if requested == "latest" else f"tags/v{requested.lstrip('v')}"
    release = api(f"releases/{endpoint}")
    tag = release["tag_name"]
    if release["draft"] or release["prerelease"] or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("expected a stable vX.Y.Z release")
    if requested != "latest" and tag != f"v{requested.lstrip('v')}":
        raise ValueError("release tag does not match the requested version")
    version = tag[1:]
    print(f"{'Latest' if requested == 'latest' else 'Requested'} release: {version}", flush=True)
    if args.update is None:
        return

    # Tags may be lightweight or annotated; Android needs the commit itself.
    obj = api(f"git/ref/tags/{tag}")["object"]
    for _ in range(8):
        if obj["type"] != "tag":
            break
        obj = api(f"git/tags/{obj['sha']}")["object"]
    if obj["type"] != "commit" or not re.fullmatch(r"[0-9a-f]{40}", obj["sha"]):
        raise ValueError("release tag does not resolve to a commit")
    commit = obj["sha"]

    # Require published SHA-256 digests for every packaged Linux architecture.
    checksums = {}
    for arch in ("x86_64", "aarch64", "armv7l", "i686"):
        name = f"deltachat-rpc-server-{arch}-linux"
        assets = [asset for asset in release["assets"] if asset["name"] == name]
        if len(assets) != 1 or assets[0]["state"] != "uploaded":
            raise ValueError(f"missing release asset: {name}")
        asset = assets[0]
        digest = asset.get("digest") or ""
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise ValueError(f"missing published SHA-256 digest: {name}")
        if asset["browser_download_url"] != f"{DOWNLOAD}/{tag}/{name}":
            raise ValueError(f"unexpected download URL: {name}")
        checksums[arch] = digest[7:]

    updated = dict(contents)
    updated[ANDROID] = replace(r"^CHATMAIL_VERSION=\S+$", f"CHATMAIL_VERSION={version}", contents[ANDROID])
    updated[ANDROID] = replace(r"^CHATMAIL_COMMIT=[0-9a-f]{40}$", f"CHATMAIL_COMMIT={commit}", updated[ANDROID])
    for source in sources:
        arch = source["only-arches"][0]
        source["url"] = f"{DOWNLOAD}/{tag}/deltachat-rpc-server-{arch}-linux"
        source["sha256"] = checksums[arch]
    updated[FLATPAK] = json.dumps(manifest, indent=4) + "\n"
    updated[SAILFISH] = replace(r"^DCRPC_VERSION=\S+$", f"DCRPC_VERSION={version}", contents[SAILFISH])
    for arch in ("aarch64", "armv7l", "i686"):
        pattern = rf"^        dcarch={arch}\n        dcsha=[0-9a-f]{{64}}$"
        value = f"        dcarch={arch}\n        dcsha={checksums[arch]}"
        updated[SAILFISH] = replace(pattern, value, updated[SAILFISH])
    updated[SPEC] = replace(r"^%global dcrpc_version \S+$", f"%global dcrpc_version {version}", contents[SPEC])

    # Validate and prepare every replacement before writing any file.
    changed = [path for path in contents if contents[path] != updated[path]]
    for path in changed:
        path.write_text(updated[path])
        print(f"Updated {path}")
    print(f"Android source commit: {commit}")
    if not changed:
        print("All pins are already up to date.")


try:
    main()
except (OSError, URLError, ValueError, KeyError, TypeError) as error:
    sys.exit(f"version-chatmail.sh: {error}")
PY
