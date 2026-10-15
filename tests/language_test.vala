using Dc;

public int run_language_settings_test () {
    assert (Environment.get_variable ("PARLA_TEST_CONFIG") == Environment.get_user_config_dir ());
    var settings = new SettingsManager ();
    settings.load ();
    assert (settings.language == "");
    assert (SettingsManager.load_language () == "");
    foreach (string language in Localization.languages ()) {
        settings.save_language (language);
        var restored = new SettingsManager ();
        restored.load ();
        assert (restored.language == language);
        assert (SettingsManager.load_language () == language);
    }
    settings.save_to_file ((kf) => { kf.set_string ("General", "language", "unknown"); });
    settings.load ();
    assert (settings.language == "");
    assert (SettingsManager.load_language () == "");

    Intl.setlocale (LocaleCategory.ALL, "");
    string numeric = Intl.setlocale (LocaleCategory.NUMERIC, null);
    string dates = Intl.setlocale (LocaleCategory.TIME, null);
    Localization.initialize ("ca");
    assert (Environment.get_variable ("LANGUAGE") == "ca");
    assert (Intl.setlocale (LocaleCategory.NUMERIC, null) == numeric);
    assert (Intl.setlocale (LocaleCategory.TIME, null) == dates);
    return 0;
}
