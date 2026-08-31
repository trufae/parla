#!/usr/bin/env python3
"""Print the latest AppStream release description as Markdown."""

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_APPDATA = Path("data/io.github.trufae.Parla.appdata.xml")


def latest_release_items(appdata: Path) -> list[str]:
    try:
        root = ET.parse(appdata).getroot()
    except (OSError, ET.ParseError) as error:
        raise ValueError(f"cannot read {appdata}: {error}") from error

    release = root.find("./releases/release")
    if release is None:
        raise ValueError(f"no releases found in {appdata}")

    items = []
    for item in release.findall("./description//li"):
        text = " ".join("".join(item.itertext()).split())
        if text:
            items.append(text)

    if not items:
        version = release.get("version", "unknown")
        raise ValueError(f"release {version} has no description items")
    return items


def main() -> int:
    parser = argparse.ArgumentParser(
        description="print the latest AppStream release notes as Markdown"
    )
    parser.add_argument(
        "appdata",
        nargs="?",
        type=Path,
        default=DEFAULT_APPDATA,
        help=f"path to the AppStream XML file (default: {DEFAULT_APPDATA})",
    )
    args = parser.parse_args()

    try:
        items = latest_release_items(args.appdata)
    except ValueError as error:
        parser.error(str(error))

    for item in items:
        print(f"- {item}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
