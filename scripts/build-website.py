#!/usr/bin/env python3
"""Package the buildless Pages site and optionally resolve current release assets."""

import argparse
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import shutil
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "www"
RELEASES = {
    "parla": "https://github.com/trufae/parla/releases/latest",
    "haiku": "https://github.com/trufae/parla-haiku/releases/latest",
}
ASSETS = {
    "appimage-x64": ("parla", r"parla-x86_64-[0-9].*\.AppImage"),
    "appimage-arm64": ("parla", r"parla-aarch64-[0-9].*\.AppImage"),
    "flatpak-x64": ("parla", r"parla-x86_64-[0-9].*\.flatpak"),
    "flatpak-arm64": ("parla", r"parla-aarch64-[0-9].*\.flatpak"),
    "deb-x64": ("parla", r"parla-amd64-[0-9].*\.deb"),
    "windows-x64": ("parla", r"parla-x86_64-[0-9].*\.zip"),
    "macos-arm64": ("parla", r"parla-arm64-[0-9].*\.dmg"),
    "macos-intel": ("parla", r"parla-x86_64-[0-9].*\.dmg"),
    "haiku-x64": ("haiku", r"parla-.*-x86_64\.hpkg"),
    "haiku-x86": ("haiku", r"parla_x86-.*-x86_gcc2\.hpkg"),
}


def download_url(key, releases):
    project, pattern = ASSETS[key]
    release = releases.get(project, {})
    for asset in release.get("assets", []):
        if re.fullmatch(pattern, asset["name"]):
            url = asset["browser_download_url"]
            repository = "parla-haiku" if project == "haiku" else "parla"
            if not url.startswith(f"https://github.com/trufae/{repository}/releases/download/"):
                raise ValueError(f"Unexpected download host/path: {url}")
            return url
    print(f"  {key}: using release-page fallback")
    return RELEASES[project]


class SiteLinks(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.urls = []
        self.downloads = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            if attrs["id"] in self.ids:
                raise ValueError(f"Duplicate HTML id: {attrs['id']}")
            self.ids.add(attrs["id"])
        for name in ("href", "src"):
            if attrs.get(name):
                self.urls.append(attrs[name])
        if "data-download" in attrs:
            self.downloads.add(attrs["data-download"])
        if tag == "img" and "alt" not in attrs:
            raise ValueError("Image missing its alt attribute")


def validate(index, directory):
    links = SiteLinks()
    links.feed(index)
    if links.downloads != ASSETS.keys():
        raise ValueError("Download markup and asset mappings disagree")
    for url in links.urls:
        parsed = urlsplit(url)
        if parsed.scheme or parsed.netloc:
            continue
        if parsed.path:
            target = (directory / unquote(parsed.path)).resolve()
            if not target.is_relative_to(directory.resolve()) or not target.is_file():
                raise ValueError(f"Missing or out-of-site asset: {url}")
        elif parsed.fragment and unquote(parsed.fragment) not in links.ids:
            raise ValueError(f"Missing fragment: {url}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New output directory")
    parser.add_argument("--release", type=Path, help="Parla releases/latest API JSON")
    parser.add_argument("--haiku-release", type=Path, help="Haiku releases/latest API JSON")
    args = parser.parse_args()
    if args.output.resolve().is_relative_to(SOURCE):
        parser.error("Output must be outside www/")
    releases = {}
    for name, path in (("parla", args.release), ("haiku", args.haiku_release)):
        if path:
            releases[name] = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(releases[name].get("assets"), list):
                raise ValueError(f"{name}: release JSON has no assets list")
    index = (SOURCE / "index.html").read_text(encoding="utf-8")
    # Attribute order is intentional in the source: data-download, then href.
    # Keeping release-page hrefs in www makes the source usable without a build.
    pattern = r'(<a data-download="([^"]+)" href=")[^"]*(")'
    index, count = re.subn(pattern, lambda match: match[1] + html.escape(
        download_url(match[2], releases), quote=True) + match[3], index)
    if count != len(ASSETS):
        raise ValueError("Expected exactly one link for each download")
    validate(index, SOURCE)
    # Never overwrite an existing output tree or touch the source checkout.
    shutil.copytree(SOURCE, args.output)
    (args.output / "index.html").write_text(index, encoding="utf-8")
    validate(index, args.output)
    print(f"Website verified and packaged at {args.output}")


if __name__ == "__main__":
    main()
