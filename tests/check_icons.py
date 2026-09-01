#!/usr/bin/env python3
"""Ensure every symbolic icon referenced from src/ is accounted for
(issue #61).

An icon name is acceptable when it is either listed in a
data/*.gresource.xml (Parla's own icons, or the Adwaita copies compiled in
with -Dbundle_icons=true) or shipped inside GTK4/libadwaita's own
resources. Anything else would render as a broken "image-missing" glyph
on desktops whose icon theme lacks it, and would escape the runtime
Adwaita fallback's -Dbundle_icons=true counterpart.
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
    names = set()
    for xml in ("parla.gresource.xml", "parla-fallback-icons.gresource.xml"):
        tree = ET.parse(os.path.join(ROOT, "data", xml))
        for node in tree.iter("file"):
            rel = node.text.strip()
            base = os.path.basename(rel)
            names.add(base[:-4] if base.endswith(".svg") else base)
            if not os.path.exists(os.path.join(ROOT, "data", "icons",
                                               "hicolor", rel)):
                print(f"{xml} lists missing file: {rel}")
                return None
    return names


def core_icons():
    tree = ET.parse(os.path.join(ROOT, "data", "parla.gresource.xml"))
    return {
        os.path.splitext(os.path.basename(node.text.strip()))[0]
        for node in tree.iter("file")
    }


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
    appdata = ET.parse(os.path.join(
        ROOT, "data", "io.github.trufae.Parla.appdata.xml"))
    app_id = appdata.getroot().findtext("id")
    if app_id not in core_icons():
        print(f"application icon {app_id} is not embedded in "
              "data/parla.gresource.xml")
        return 1
    missing = sorted(referenced_icons() - bundled - BUILTIN)
    if missing:
        print("symbolic icons used in src/ but neither bundled in a "
              "data/*.gresource.xml nor built into GTK4/libadwaita:")
        for name in missing:
            print("  " + name)
        print("copy the SVG from adwaita-icon-theme into data/icons/hicolor/"
              "scalable/<context>/ and list it in data/parla-fallback-icons.gresource.xml")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
