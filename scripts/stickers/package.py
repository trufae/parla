#!/usr/bin/env python3
"""Build the public starter ZIPs from the locally downloaded, converted packs."""

import argparse
import hashlib
import json
from pathlib import Path
import zipfile


ROOT = Path(__file__).resolve().parents[2]
PACKS = (
    ("HotCherry", "hot-cherry", "Hot Cherry"),
    ("CupidKitty", "cupid-kitty", "Cupid Kitty"),
    ("VampireQueen", "marceline", "Marceline"),
    ("Radare", "radare", "Radare"),
)


def write_zip(path, files):
    # Fixed timestamps, permissions and ordering make rebuilds byte-for-byte stable.
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content, compresslevel=9)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--output", type=Path, default=ROOT / "scripts/stickers/packs")
    parser.add_argument("--starter-output", type=Path,
                        default=ROOT / "scripts/stickers/packs/parla-starter-stickers.zip",
                        help="Starter ZIP for external hosting (kept outside the website)")
    args = parser.parse_args()
    readme = (ROOT / "www/stickers/README.md").read_bytes()
    packs = []
    combined = {}
    # Read and validate every input before creating any archives.
    for directory, slug, title in PACKS:
        source = (args.source / directory).resolve()
        metadata = json.loads((source / "metadata.json").read_text())
        files = {}
        for sticker in metadata["sticker_set"]["stickers"]:
            path = (source / sticker["local_file"]).resolve()
            if not path.is_relative_to(source) or path.suffix.lower() not in {".gif", ".webp", ".png"}:
                raise ValueError(f"Unsupported or unsafe sticker path: {path}")
            content = path.read_bytes()
            if not content:
                raise ValueError(f"Empty sticker: {path}")
            emoji = sticker.get("emoji", "")
            if any(char in emoji for char in ("/", "\\", "__", "\0")):
                raise ValueError(f"Unsafe emoji: {emoji!r}")
            checksum = hashlib.sha256(content).hexdigest()
            # This is the flat filename format consumed by Dc.StickerStore.
            name = f"stickers/{title}__{emoji}__{checksum}{path.suffix.lower()}"
            if name in files:
                raise ValueError(f"Duplicate sticker: {path}")
            files[name] = content
        if not files:
            raise ValueError(f"Empty pack: {directory}")
        expected_url = f"https://t.me/addstickers/{directory}"
        if metadata["source_url"] != expected_url:
            raise ValueError(f"Unexpected source for {directory}")
        packs.append((slug, title, expected_url, files))
        combined.update(files)

    args.output.mkdir(parents=True, exist_ok=True)
    attribution = ("# Sticker artwork\n\n"
                   "Artwork belongs to its respective creators. These third-party packs\n"
                   "are not covered by Parla's software license. Source links identify\n"
                   "the downloaded sets; they are not a claim of authorship or a license grant.\n\n")
    manifest = []
    for slug, title, url, files in packs + [
            ("parla-starter-stickers", "Parla starter collection", "", combined)]:
        sources = [(title, url)] if url else [(p[1], p[2]) for p in packs]
        credits = attribution + "".join(f"- {name}: {link}\n" for name, link in sources)
        path = args.output / f"{slug}.zip" if url else args.starter_output
        path.parent.mkdir(parents=True, exist_ok=True)
        write_zip(path, {**files, "README.md": readme,
                         "ATTRIBUTION.md": credits.encode("utf-8")})
        manifest.append({"file": path.name, "title": title, "stickers": len(files),
                         "bytes": path.stat().st_size,
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                         "sources": [{"title": name, "url": link} for name, link in sources]})
        print(f"{path.name}: {len(files)} stickers, {path.stat().st_size:,} bytes")
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (args.output / "SHA256SUMS").write_text(
        "".join(f"{pack['sha256']}  {pack['file']}\n" for pack in manifest), encoding="utf-8")


if __name__ == "__main__":
    main()
