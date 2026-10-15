namespace Dc.Localization {
    /* Keep the selector in sync with the catalogs built from po/LINGUAS.
       English is the source language; the empty code follows the system. */
    public string[] languages () {
        string[] result = { "", "en" };
        foreach (string code in Parla.TRANSLATION_LANGUAGES.split (" ")) {
            if (code.length > 0 && !(code in result)) result += code;
        }
        return result;
    }

    public string normalize_language (string code) {
        return code in languages () ? code : "";
    }

    public string language_name (string code) {
        /* Autonyms stay recognizable even when the current UI language is
           unfamiliar. Future catalogs still appear under their locale code. */
        switch (code) {
        case "": return _("System Language");
        case "en": return "English";
        case "ca": return "Català";
        case "nl": return "Nederlands";
        default: return code;
        }
    }

    public void initialize (string language) {
        string? preferred = null;
        if (language.length > 0) {
            preferred = language;
        } else if (!has_locale_environment ()) {
            /* Finder launches do not normally supply POSIX locale variables. */
            preferred = Platform.get_system_languages ();
        }
        if (preferred != null && preferred.length > 0) {
            Environment.set_variable ("LANGUAGE", preferred, true);
        }

        Intl.setlocale (LocaleCategory.ALL, "");
        string? messages = Intl.setlocale (LocaleCategory.MESSAGES, null);
        if (preferred != null && (messages == null || messages == "C" ||
                                  messages.has_prefix ("C.") || messages == "POSIX")) {
            /* Gettext ignores LANGUAGE in the C locale. Only change message
               locale data, leaving number/date formatting alone. macOS ships
               en_US.UTF-8; Linux commonly also provides C.UTF-8. */
            if (Intl.setlocale (LocaleCategory.MESSAGES, "en_US.UTF-8") == null)
                Intl.setlocale (LocaleCategory.MESSAGES, "C.UTF-8");
            /* macOS libintl also reads the environment directly. Expand
               LC_ALL into the other categories before overriding messages,
               so child processes keep the same formatting as this process. */
            string? all = Environment.get_variable ("LC_ALL");
            if (all != null && all.length > 0) {
                foreach (string category in new string[] {
                    "LC_CTYPE", "LC_NUMERIC", "LC_TIME", "LC_COLLATE", "LC_MONETARY",
                    "LC_PAPER", "LC_NAME", "LC_ADDRESS", "LC_TELEPHONE",
                    "LC_MEASUREMENT", "LC_IDENTIFICATION"
                }) Environment.set_variable (category, all, true);
            }
            Environment.unset_variable ("LC_ALL");
            Environment.set_variable ("LC_MESSAGES", "en_US.UTF-8", true);
        }
        Intl.bindtextdomain (Parla.GETTEXT_PACKAGE, Platform.get_locale_dir ());
        Intl.bind_textdomain_codeset (Parla.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Parla.GETTEXT_PACKAGE);
    }

    private bool has_locale_environment () {
        foreach (string name in new string[] { "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG" }) {
            string? value = Environment.get_variable (name);
            if (value != null && value.length > 0) return true;
        }
        return false;
    }
}
