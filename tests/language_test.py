#!/usr/bin/env python3
"""Exercise saved language selection and relocated catalogs without a display."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

app, core = (Path(arg).resolve() for arg in sys.argv[1:])
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="parla-language-") as folder:
    folder = Path(folder)
    config = folder / "config"
    env = dict(os.environ, XDG_CONFIG_HOME=str(config), PARLA_TEST_CONFIG=str(config),
               LC_ALL="C", LANG="C")
    for language in (None, "nl"):
        shutil.rmtree(config, ignore_errors=True)
        if language is None:
            env.pop("LANGUAGE", None)
        else:
            env["LANGUAGE"] = language
        subprocess.run([str(core), "--language-settings"], env=env, check=True, timeout=30)

    # An app bundle path takes precedence on macOS, even with no installed
    # ca_ES/nl_NL locale. Other platforms use the relocatable ../share path.
    if sys.platform == "darwin":
        binary = folder / "Parla.app/Contents/MacOS/parla"
        locales = folder / "Parla.app/Contents/Resources/share/locale"
    else:
        binary = folder / "bin" / app.name
        locales = folder / "share/locale"
    binary.parent.mkdir(parents=True)
    shutil.copy2(app, binary)
    for code in ("ca", "nl"):
        catalog = locales / code / "LC_MESSAGES/parla.mo"
        catalog.parent.mkdir(parents=True)
        subprocess.run(["msgfmt", "-c", str(root / "po" / (code + ".po")),
                        "-o", str(catalog)], check=True)

    settings = config / "parla/settings.ini"
    settings.parent.mkdir(parents=True, exist_ok=True)
    for language, inherited, locale, expected in (
        ("ca", "nl", "C", "Mostra la finestra principal"),
        ("nl", "ca", "C", "Hoofdvenster tonen"),
        ("en", "ca", "C", "Show the main window"),
        ("", "nl", "en_US.UTF-8", "Hoofdvenster tonen"),
        ("unsupported", "ca", "en_US.UTF-8", "Mostra la finestra principal"),
        ("", "", "C", "Show the main window"),
    ):
        settings.write_text("[General]\nlanguage=" + language + "\n")
        env.update(LC_ALL=locale, LANG=locale, LANGUAGE=inherited)
        result = subprocess.run([str(binary), "--help"], env=env, check=True,
                                capture_output=True, text=True, timeout=30)
        assert expected in result.stdout, (language, inherited, result.stdout)
    if sys.platform == "darwin":
        settings.write_text("[General]\nlanguage=\n")
        for name in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
            env.pop(name, None)
        # NSArgumentDomain supplies native preferences without changing the
        # user's system settings. --help exits before GLib parses the rest.
        for languages, expected in (("(ca)", "Mostra la finestra principal"),
                                    ("(en, ca)", "Show the main window"),
                                    ("(nl-NL, en)", "Hoofdvenster tonen")):
            result = subprocess.run([str(binary), "--help", "-AppleLanguages", languages],
                                    env=env, check=True, capture_output=True,
                                    text=True, timeout=30)
            assert expected in result.stdout, (languages, result.stdout)
    print("Language persistence, environment overrides, C locale and relocated catalogs: PASS")
