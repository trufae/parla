#!/usr/bin/env python3
"""Derive Android metadata from the existing release metadata."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[2]
version = re.search(r"version:\s*'([^']+)'", (root / 'meson.build').read_text())[1]
if '--version' in sys.argv:
    print(version)
    sys.exit()

if '--package' not in sys.argv:
    # Pixiewood requires namespaced AppStream; leave desktop consumers alone.
    meta = ET.parse(root / 'data/io.github.trufae.Parla.appdata.xml')
    ns = 'https://specifications.freedesktop.org/metainfo/1.0'
    for element in meta.iter():
        element.tag = f'{{{ns}}}{element.tag}'
    ET.register_namespace('', ns)
    requires = meta.find(f'{{{ns}}}requires')
    ET.SubElement(requires, f'{{{ns}}}internet').text = 'always'
    meta.write(root / '.cache/android/metainfo.xml', encoding='utf-8', xml_declaration=True)
    (root / '.cache/android/extra.cross').write_text("""[binaries]
pkg-config = 'pkg-config'
vala = 'valac'

[properties]
pkg_config_libdir = ['/nonexistent']
""")
else:
    android = root / '.pixiewood/android/app'
    ns = 'http://schemas.android.com/apk/res/android'
    ET.register_namespace('android', ns)
    manifest = ET.parse(android / 'src/main/AndroidManifest.xml')
    app = manifest.find('application')
    app.set(f'{{{ns}}}name', 'io.github.trufae.parla.ParlaApplication')
    app.set(f'{{{ns}}}allowBackup', 'false')
    manifest.write(android / 'src/main/AndroidManifest.xml', encoding='utf-8', xml_declaration=True)
    java = android / 'src/main/java/io/github/trufae/parla'
    java.mkdir(parents=True, exist_ok=True)
    (java / 'ParlaApplication.java').write_text((root / 'dist/android/ParlaApplication.java').read_text())
    gradle = android / 'build.gradle'
    content = gradle.read_text().replace('enable = true', 'enable = false')
    # AGP sets extractNativeLibs in the merged manifest: the RPC executable
    # must be extracted into nativeLibraryDir, not writable app storage.
    content += '\nandroid { packaging { jniLibs { useLegacyPackaging = true } }; buildTypes { debug { applicationIdSuffix = ".debug" } } }\n'
    gradle.write_text(content)
