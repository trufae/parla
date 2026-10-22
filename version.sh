#!/bin/sh
# Query or update Parla's release version. Requires Python 3.
set -eu
cd "$(dirname "$0")"
exec python3 - "$@" <<'PY'
import argparse
import re
import sys
from pathlib import Path

MESON = Path("meson.build")
PATTERNS = {
    MESON: r"^  version: '(?P<version>[^']+)',",
    Path("data/io.github.trufae.Parla.appdata.xml"):
        r'<releases>\s*<release\b[^>]*\bversion="(?P<version>[^"]+)"',
    Path("rpm/harbour-parla.spec"): r"^Version:[ \t]*(?P<version>\S+)[ \t]*$",
}


def read_version(path):
    text = path.read_text()
    matches = list(re.finditer(PATTERNS[path], text, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(f"expected one current version in {path}, found {len(matches)}")
    return text, matches[0]


def main():
    parser = argparse.ArgumentParser(
        prog="version.sh", description="Print Parla's version, or update its release metadata."
    )
    parser.add_argument("version", nargs="?", metavar="VERSION",
                        help="set the version in Meson, AppStream and the RPM spec (X.Y.Z or vX.Y.Z)")
    args = parser.parse_args()
    if args.version is None:
        print(read_version(MESON)[1]["version"])
        return
    if not re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+", args.version):
        parser.error("VERSION must be X.Y.Z or vX.Y.Z")
    version = args.version.lstrip("v")

    # Prepare every replacement before writing; only the newest AppStream
    # release is updated, preserving its notes/date and the release history.
    updated = {}
    for path in PATTERNS:
        text, match = read_version(path)
        start, end = match.span("version")
        replacement = text[:start] + version + text[end:]
        if text != replacement:
            updated[path] = replacement
    for path, text in updated.items():
        path.write_text(text)
        print(f"Updated {path}")
    print(version)


try:
    main()
except (OSError, ValueError) as error:
    sys.exit(f"version.sh: {error}")
PY
