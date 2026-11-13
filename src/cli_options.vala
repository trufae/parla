using Parla.Terminal;

/** TUI preferences are separate from the GUI's settings file. */
internal class CliOptions : Object {
    public const string[] NAMES = { "timestamps",
        "time_format", "message_layout", "markdown", "nick_colors", "chat_info", "theme", "contacts_grouped", "contacts_sort" };
    private KeyFile values = new KeyFile ();
    private string path = Path.build_filename (Environment.get_user_config_dir (), "parla", "terminal.ini");

    public CliOptions () {
        string[] defaults = { "on", "%H:%M", "compact", "on", "on", "off", "default", "off", "recent" };
        for (int i = 0; i < NAMES.length; i++) values.set_string ("Terminal", NAMES[i], defaults[i]);
        try {
            var saved = new KeyFile ();
            saved.load_from_file (path, KeyFileFlags.NONE);
            foreach (var name in NAMES) {
                try { values.set_string ("Terminal", name, validate (name, saved.get_string ("Terminal", name))); }
                catch (Error e) { /* Keep the default for absent/invalid entries. */ }
            }
            foreach (var role in Theme.ROLES) {
                string key = "color_" + role;
                try { values.set_string ("Terminal", key, validate (key, saved.get_string ("Terminal", key))); }
                catch (Error e) { }
            }
        } catch (Error e) { /* First launch uses defaults. */ }
    }

    public string value (string name) {
        try { return values.get_string ("Terminal", name); }
        catch (Error e) {
            if (name.has_prefix ("color_")) foreach (var role in Theme.ROLES)
                if (name == "color_" + role) return "inherit";
            return "";
        }
    }

    public bool enabled (string name) { return value (name) == "on"; }

    private string validate (string name, string value) throws Error {
        if (name.has_prefix ("color_") && this.value (name) != "") {
            if (value == "inherit" || Theme.valid_color (value)) return value.down ();
            throw new IOError.INVALID_ARGUMENT ("Expected an ANSI color or #RRGGBB, optionally foreground:background");
        }
        switch (name) {
        case "chat_info": case "timestamps": case "markdown": case "nick_colors": case "contacts_grouped":
            if (value == "on" || value == "off") return value;
            break;
        case "contacts_sort":
            if (value == "recent" || value == "alphabetical") return value;
            break;
        case "time_format":
            if (value == "%H:%M" || value == "%H:%M:%S") return value;
            break;
        case "message_layout":
            if (value == "compact" || value == "stacked") return value;
            break;
        case "theme":
            if (value == "default" || value == "light" || value == "ocean") return value;
            break;
        default: throw new IOError.INVALID_ARGUMENT ("Unknown setting: " + name);
        }
        throw new IOError.INVALID_ARGUMENT ("Invalid value for " + name + ": " + value);
    }

    public void change (string name, string value, bool persist = true) throws Error {
        string checked = validate (name, value);
        string old = this.value (name);
        values.set_string ("Terminal", name, checked);
        if (!persist) return;
        try {
            save ();
        } catch (Error e) {
            values.set_string ("Terminal", name, old);
            throw e;
        }
    }

    public void save () throws Error {
        if (DirUtils.create_with_parents (Path.get_dirname (path), 0700) != 0)
            throw new IOError.FAILED ("Cannot create terminal settings directory");
        FileUtils.set_contents (path, values.to_data ());
    }

    public Theme theme () {
        var result = new Theme (value ("theme"));
        foreach (var role in Theme.ROLES) {
            string color = value ("color_" + role);
            if (color != "inherit") result.set_color (role, color);
        }
        return result;
    }

    public void apply (View view) {
        view.set_contacts_grouped (enabled ("contacts_grouped"));
        view.set_contacts_sort (value ("contacts_sort") == "alphabetical" ? ContactSort.ALPHABETICAL : ContactSort.RECENT);
        view.set_info_visible (enabled ("chat_info"));
    }
}
