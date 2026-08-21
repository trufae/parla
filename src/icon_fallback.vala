namespace Dc {
    /* Makes the stock symbolic icons resolve on desktops whose icon theme
       does not inherit Adwaita (issue #61).

       GTK only consults the current icon theme, its `Inherits` chain and
       `hicolor`; it never falls back to Adwaita by itself, and Adwaita is
       marked Hidden so users of XFCE, LXQt, ... cannot select it even
       though GTK4 depends on it being installed. At startup we prepend a
       private search path whose
       `hicolor/index.theme` is a copy of the system one with the fallback
       themes appended to `Inherits`. Because GTK loads hicolor's directories
       from *every* search path, nothing is lost, and the fallback themes are
       consulted after the user's theme and hicolor, as proper themes: the
       symbolic recolouring keeps working, unlike unthemed search-path
       icons, which GTK < 4.20 renders without recolouring.

       The fallback is always present so partially complete themes and theme
       changes made while Parla is running remain covered. GNOME, Breeze,
       Papirus, Yaru or a bundled Adwaita still take precedence whenever
       they provide an icon. */
    namespace IconFallback {
        /* Themes tried, in order, after the user's chain and hicolor. */
        private const string[] FALLBACK_THEMES = { "Adwaita" };

        public void install (Gtk.IconTheme theme) {
            apply (theme);
        }

        private void apply (Gtk.IconTheme theme) {
            string[] search_path = theme.get_search_path ();
            var kf = load_hicolor_index (search_path);
            if (kf == null) {
                return;
            }
            string[] inherits = {};
            try {
                inherits = kf.get_string_list ("Icon Theme", "Inherits");
            } catch (KeyFileError e) {
                /* hicolor normally has no Inherits key. */
            }
            foreach (unowned string t in FALLBACK_THEMES) {
                if (!(t in inherits)) {
                    inherits += t;
                }
            }
            kf.set_string_list ("Icon Theme", "Inherits", inherits);

            string dir = Path.build_filename (Environment.get_user_cache_dir (),
                                              "parla", "icon-fallback");
            string hicolor_dir = Path.build_filename (dir, "hicolor");
            string index = Path.build_filename (hicolor_dir, "index.theme");
            string data = kf.to_data ();
            try {
                string old;
                if (!FileUtils.get_contents (index, out old) || old != data) {
                    DirUtils.create_with_parents (hicolor_dir, 0755);
                    FileUtils.set_contents (index, data);
                }
            } catch (FileError e) {
                try {
                    DirUtils.create_with_parents (hicolor_dir, 0755);
                    FileUtils.set_contents (index, data);
                } catch (FileError e2) {
                    debug ("icon fallback: cannot write %s: %s", index, e2.message);
                    return;
                }
            }
            string[] path = { dir };
            foreach (unowned string p in search_path) {
                path += p;
            }
            theme.set_search_path (path);
            debug ("icon fallback: inheriting %s via %s",
                   string.joinv (",", FALLBACK_THEMES), index);
        }

        /* The system hicolor index (first hit wins, like GTK), falling
           back to the copy GTK embeds for systems without one. */
        private KeyFile? load_hicolor_index (string[] search_path) {
            var kf = new KeyFile ();
            kf.set_list_separator (',');
            foreach (unowned string p in search_path) {
                string f = Path.build_filename (p, "hicolor", "index.theme");
                if (!FileUtils.test (f, FileTest.IS_REGULAR)) {
                    continue;
                }
                try {
                    kf.load_from_file (f, KeyFileFlags.KEEP_COMMENTS);
                    return kf;
                } catch (Error e) {
                    debug ("icon fallback: ignoring %s: %s", f, e.message);
                }
            }
            try {
                var bytes = resources_lookup_data (
                    "/org/gtk/libgtk/icons/hicolor.index.theme",
                    ResourceLookupFlags.NONE);
                kf.load_from_bytes (bytes, KeyFileFlags.NONE);
                return kf;
            } catch (Error e) {
                debug ("icon fallback: no hicolor index: %s", e.message);
                return null;
            }
        }
    }
}
