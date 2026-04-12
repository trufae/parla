namespace Dc {

    public delegate void SettingWriter (KeyFile kf);

    public class SettingsManager : Object {

        public int double_click_action { get; set; default = 0; }
        public bool markdown_rendering { get; set; default = false; }
        public bool shift_enter_sends { get; set; default = false; }
        public bool notifications_enabled { get; set; default = true; }

        public static string get_config_path () {
            return Path.build_filename (
                Environment.get_user_config_dir (),
                "deltachat-gnome", "settings.ini");
        }

        public void load () {
            var kf = new KeyFile ();
            try {
                kf.load_from_file (get_config_path (), KeyFileFlags.NONE);
            } catch (Error e) {
                double_click_action = 0;
                markdown_rendering = false;
                Markdown.enabled = false;
                shift_enter_sends = false;
                ComposeBar.shift_enter_sends = false;
                notifications_enabled = true;
                return;
            }
            try {
                double_click_action = kf.get_integer (
                    "General", "double_click_action");
            } catch (Error e) {
                double_click_action = 0;
            }
            try {
                markdown_rendering = kf.get_boolean (
                    "General", "markdown_rendering");
            } catch (Error e) {
                markdown_rendering = false;
            }
            Markdown.enabled = markdown_rendering;
            try {
                shift_enter_sends = kf.get_boolean (
                    "General", "shift_enter_sends");
            } catch (Error e) {
                shift_enter_sends = false;
            }
            ComposeBar.shift_enter_sends = shift_enter_sends;
            try {
                notifications_enabled = kf.get_boolean (
                    "General", "notifications_enabled");
            } catch (Error e) {
                notifications_enabled = true;
            }
        }

        public void save_double_click_action (int action) {
            double_click_action = action;
            save_to_file ((kf) => {
                kf.set_integer ("General", "double_click_action", action);
            });
        }

        public void save_markdown_rendering (bool enabled) {
            markdown_rendering = enabled;
            Markdown.enabled = enabled;
            save_to_file ((kf) => {
                kf.set_boolean ("General", "markdown_rendering", enabled);
            });
        }

        public void save_shift_enter_sends (bool enabled) {
            shift_enter_sends = enabled;
            ComposeBar.shift_enter_sends = enabled;
            save_to_file ((kf) => {
                kf.set_boolean ("General", "shift_enter_sends", enabled);
            });
        }

        public void save_notifications_enabled (bool enabled) {
            notifications_enabled = enabled;
            save_to_file ((kf) => {
                kf.set_boolean ("General", "notifications_enabled", enabled);
            });
        }

        public void save_to_file (SettingWriter writer) {
            var kf = new KeyFile ();
            try {
                kf.load_from_file (get_config_path (), KeyFileFlags.NONE);
            } catch (Error e) { /* file may not exist yet */ }
            writer (kf);
            try {
                var dir = Path.get_dirname (get_config_path ());
                DirUtils.create_with_parents (dir, 0755);
                kf.save_to_file (get_config_path ());
            } catch (Error e) {
                warning ("Failed to save settings: %s", e.message);
            }
        }
    }
}
