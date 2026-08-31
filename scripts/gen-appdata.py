#!/usr/bin/env python3
import html
import sys
import xml.etree.ElementTree as ET


def text(root, path, default=""):
    node = root.find(path)
    if node is None or node.text is None:
        return default
    return node.text.strip()


def vala_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def inner_xml(node):
    return "".join(ET.tostring(child, encoding="unicode", short_empty_elements=False) for child in node)


def release_notes(root):
    parts = []
    releases = root.find("releases")
    if releases is None:
        return ""
    for index, release in enumerate(releases):
        version = release.get("version", "").strip()
        desc = release.find("description")
        if not version or desc is None:
            continue
        if index > 0:
            parts.append("<p>Version %s</p>" % html.escape(version))
        parts.append(inner_xml(desc))
    return "".join(parts)


def url(root, kind):
    for node in root.findall("url"):
        if node.get("type") == kind and node.text:
            return node.text.strip()
    return ""


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: gen-appdata.py INPUT.xml OUTPUT.vala")

    root = ET.parse(sys.argv[1]).getroot()
    app_id = text(root, "id")
    developer = text(root, "developer/name")

    values = {
        "ID": app_id,
        "NAME": text(root, "name"),
        "DEVELOPER": developer,
        "WEBSITE": url(root, "homepage"),
        "ISSUE_URL": url(root, "bugtracker"),
        "COMMENTS": text(root, "summary"),
        "RELEASE_NOTES": release_notes(root),
    }

    with open(sys.argv[2], "w", encoding="utf-8") as f:
        f.write("namespace Parla.AppData {\n")
        for name, value in values.items():
            f.write("    public const string %s = %s;\n" % (name, vala_string(value)))
        f.write("\n")
        f.write("    public string[] developers () {\n")
        f.write("        return { DEVELOPER };\n")
        f.write("    }\n")
        f.write("\n")
        f.write("    public string release_notes () {\n")
        f.write("        return RELEASE_NOTES;\n")
        f.write("    }\n")
        f.write("}\n")


if __name__ == "__main__":
    main()
