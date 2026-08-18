#!/usr/bin/env python3
"""Ensure every symbolic icon referenced from src/ resolves without relying
on a system icon theme (issue #61).

An icon name is acceptable when it is either compiled into the binary via
data/parla.gresource.xml or shipped inside GTK4/libadwaita's own resources.
Anything else would render as a broken "image-missing" glyph on desktops
whose icon theme lacks Adwaita's symbolic set (XFCE, LXQt, ...).
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Icons GTK4 (/org/gtk/libgtk/icons) and libadwaita (/org/gnome/Adwaita/icons)
# embed themselves, so they resolve on any platform without an icon theme.
BUILTIN = {
    # gtk4
    "application-x-executable-symbolic", "dialog-error-symbolic",
    "dialog-information-symbolic", "document-save-symbolic",
    "edit-clear-symbolic", "edit-copy-symbolic", "edit-delete-symbolic",
    "edit-find-symbolic", "face-smile-symbolic", "folder-download-symbolic",
    "folder-symbolic", "go-down-symbolic", "go-next-symbolic",
    "go-previous-symbolic", "go-up-symbolic", "list-add-symbolic",
    "list-remove-symbolic", "media-playback-pause-symbolic",
    "media-playback-start-symbolic", "media-playback-stop-symbolic",
    "open-menu-symbolic", "text-x-generic-symbolic", "user-trash-symbolic",
    "view-grid-symbolic", "view-more-symbolic", "view-refresh-symbolic",
    "window-close-symbolic", "window-minimize-symbolic",
    # libadwaita
    "adw-external-link-symbolic", "avatar-default-symbolic",
}


def bundled_icons():
    tree = ET.parse(os.path.join(ROOT, "data", "parla.gresource.xml"))
    names = set()
    for node in tree.iter("file"):
        base = os.path.basename(node.text.strip())
        names.add(base[:-4] if base.endswith(".svg") else base)
        path = os.path.join(ROOT, "data", "icons", "hicolor", node.text.strip())
        if not os.path.exists(path):
            print(f"gresource lists missing file: {node.text}")
            return None
    return names


def referenced_icons():
    pat = re.compile(r'"([A-Za-z0-9._-]+-symbolic)"')
    names = set()
    src = os.path.join(ROOT, "src")
    for fn in os.listdir(src):
        if fn.endswith(".vala"):
            with open(os.path.join(src, fn), encoding="utf-8") as fh:
                names.update(pat.findall(fh.read()))
    return names


def main():
    bundled = bundled_icons()
    if bundled is None:
        return 1
    missing = sorted(referenced_icons() - bundled - BUILTIN)
    if missing:
        print("symbolic icons used in src/ but neither bundled in "
              "data/parla.gresource.xml nor built into GTK4/libadwaita:")
        for name in missing:
            print("  " + name)
        print("copy the SVG from adwaita-icon-theme into data/icons/hicolor/"
              "scalable/<context>/ and list it in data/parla.gresource.xml")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
