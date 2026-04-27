namespace Dc {

    public delegate void SettingWriter (KeyFile kf);

    public class SettingsManager : Object {

        public int double_click_action { get; set; default = 0; }
        public bool markdown_rendering { get; set; default = false; }
        public bool shift_enter_sends { get; set; default = false; }
        public bool notifications_enabled { get; set; default = true; }
        public string rpc_server_path { get; set; default = ""; }

        public static string get_config_path () {
            return Path.build_filename (
                Environment.get_user_config_dir (),
                "parla", "settings.ini");
        }

        public void load () {
            var kf = new KeyFile ();
            try { kf.load_from_file (get_config_path (), KeyFileFlags.NONE); }
            catch (Error e) { /* file may not exist — helpers return defaults */ }
            double_click_action = kf_int (kf, "double_click_action", 0);
            markdown_rendering = kf_bool (kf, "markdown_rendering", false);
            Markdown.enabled = markdown_rendering;
            shift_enter_sends = kf_bool (kf, "shift_enter_sends", false);
            notifications_enabled = kf_bool (kf, "notifications_enabled", true);
            rpc_server_path = kf_str (kf, "rpc_server_path", "");
        }

        private static int kf_int (KeyFile kf, string k, int d) {
            try { return kf.get_integer ("General", k); } catch { return d; }
        }

        private static bool kf_bool (KeyFile kf, string k, bool d) {
            try { return kf.get_boolean ("General", k); } catch { return d; }
        }

        private static string kf_str (KeyFile kf, string k, string d) {
            try { return kf.get_string ("General", k); } catch { return d; }
        }

        public void save_double_click_action (int v) {
            double_click_action = v;
            save_to_file ((kf) => { kf.set_integer ("General", "double_click_action", v); });
        }

        public void save_markdown_rendering (bool v) {
            markdown_rendering = v; Markdown.enabled = v;
            save_to_file ((kf) => { kf.set_boolean ("General", "markdown_rendering", v); });
        }

        public void save_shift_enter_sends (bool v) {
            shift_enter_sends = v;
            save_to_file ((kf) => { kf.set_boolean ("General", "shift_enter_sends", v); });
        }

        public void save_notifications_enabled (bool v) {
            notifications_enabled = v;
            save_to_file ((kf) => { kf.set_boolean ("General", "notifications_enabled", v); });
        }

        public void save_rpc_server_path (string v) {
            rpc_server_path = v;
            save_to_file ((kf) => { kf.set_string ("General", "rpc_server_path", v); });
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

    public class SettingsDialog : Adw.Dialog {

        private Gtk.Box content;
        private unowned Window app_window;
        private Adw.ActionRow rpc_row;
        private Gtk.Switch rpc_custom_switch;

        public SettingsDialog (Window window) {
            this.app_window = window;
            this.title = "Settings";
            this.content_width = 400;
            this.content_height = 480;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            header.show_end_title_buttons = true;
            box.append (header);

            content = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
            content.margin_start = 16;
            content.margin_end = 16;
            content.margin_top = 12;
            content.margin_bottom = 16;

            /* Behavior section */
            var behavior_label = new Gtk.Label ("Behavior");
            behavior_label.add_css_class ("title-3");
            behavior_label.halign = Gtk.Align.START;
            content.append (behavior_label);

            var behavior_list = new Gtk.ListBox ();
            behavior_list.selection_mode = Gtk.SelectionMode.NONE;
            behavior_list.add_css_class ("boxed-list");

            var dblclick_row = new Adw.ActionRow ();
            dblclick_row.title = "Double-click on message";
            dblclick_row.subtitle = "Action when a message is double-clicked";

            string[] dblclick_labels = {
                "Reply to message",
                "React with ❤️",
                "React with 👍",
                "Open user profile",
                "Do nothing"
            };

            var dblclick_combo = new Gtk.DropDown.from_strings (dblclick_labels);
            dblclick_combo.selected = app_window.settings.double_click_action;
            dblclick_combo.valign = Gtk.Align.CENTER;
            dblclick_combo.notify["selected"].connect (() => {
                app_window.settings.save_double_click_action ((int) dblclick_combo.selected);
            });
            dblclick_row.add_suffix (dblclick_combo);
            dblclick_row.activatable_widget = dblclick_combo;

            behavior_list.append (dblclick_row);

            var md_row = new Adw.ActionRow ();
            md_row.title = "Markdown rendering";
            md_row.subtitle = "Format bold, italic, code and headings";

            var md_switch = new Gtk.Switch ();
            md_switch.active = Markdown.enabled;
            md_switch.valign = Gtk.Align.CENTER;
            md_switch.notify["active"].connect (() => {
                app_window.settings.save_markdown_rendering (md_switch.active);
            });
            md_row.add_suffix (md_switch);
            md_row.activatable_widget = md_switch;

            behavior_list.append (md_row);

            var shift_row = new Adw.ActionRow ();
            shift_row.title = "Shift+Return sends message";
            shift_row.subtitle = "When on, Return inserts a newline and Shift+Return sends";

            var shift_switch = new Gtk.Switch ();
            shift_switch.active = app_window.settings.shift_enter_sends;
            shift_switch.valign = Gtk.Align.CENTER;
            shift_switch.notify["active"].connect (() => {
                app_window.settings.save_shift_enter_sends (shift_switch.active);
            });
            shift_row.add_suffix (shift_switch);
            shift_row.activatable_widget = shift_switch;

            behavior_list.append (shift_row);

            var notif_row = new Adw.ActionRow ();
            notif_row.title = "Desktop notifications";
            notif_row.subtitle = "Notify on incoming messages when the window is not focused";

            var notif_switch = new Gtk.Switch ();
            notif_switch.active = app_window.settings.notifications_enabled;
            notif_switch.valign = Gtk.Align.CENTER;
            notif_switch.notify["active"].connect (() => {
                app_window.settings.save_notifications_enabled (notif_switch.active);
            });
            notif_row.add_suffix (notif_switch);
            notif_row.activatable_widget = notif_switch;

            behavior_list.append (notif_row);
            content.append (behavior_list);

            /* Advanced section */
            var advanced_label = new Gtk.Label ("Advanced");
            advanced_label.add_css_class ("title-3");
            advanced_label.halign = Gtk.Align.START;
            content.append (advanced_label);

            var advanced_list = new Gtk.ListBox ();
            advanced_list.selection_mode = Gtk.SelectionMode.NONE;
            advanced_list.add_css_class ("boxed-list");

            rpc_row = new Adw.ActionRow ();
            rpc_row.title = "deltachat-rpc-server";

            var rpc_choose_btn = new Gtk.Button.with_label ("Choose…");
            rpc_choose_btn.valign = Gtk.Align.CENTER;
            rpc_choose_btn.add_css_class ("flat");
            rpc_choose_btn.tooltip_text = "Pick a deltachat-rpc-server binary";
            rpc_choose_btn.clicked.connect (() => { on_browse_rpc_server.begin (); });
            rpc_row.add_suffix (rpc_choose_btn);

            rpc_custom_switch = new Gtk.Switch ();
            rpc_custom_switch.valign = Gtk.Align.CENTER;
            rpc_custom_switch.tooltip_text = "Use a custom deltachat-rpc-server binary";
            rpc_custom_switch.active = app_window.settings.rpc_server_path.length > 0;
            rpc_custom_switch.notify["active"].connect (on_rpc_switch_toggled);
            rpc_custom_switch.bind_property ("active", rpc_choose_btn, "sensitive",
                                             BindingFlags.SYNC_CREATE);
            rpc_row.add_suffix (rpc_custom_switch);

            advanced_list.append (rpc_row);
            content.append (advanced_list);
            update_rpc_row ();

            var reset_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            reset_box.margin_top = 8;

            var reset_btn = new Gtk.Button.with_label ("Factory Reset");
            reset_btn.add_css_class ("destructive-action");
            reset_btn.tooltip_text = "Delete all Parla configuration and start fresh";
            reset_btn.clicked.connect (on_reset_settings);
            reset_box.append (reset_btn);

            var reset_label = new Gtk.Label ("Remove all settings and close the app");
            reset_label.add_css_class ("dim-label");
            reset_label.valign = Gtk.Align.CENTER;
            reset_box.append (reset_label);

            content.append (reset_box);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = content;
            box.append (scroll);

            this.child = box;
        }

        private void update_rpc_row () {
            string custom = app_window.settings.rpc_server_path;
            if (custom.length > 0) {
                bool ok = FileUtils.test (custom, FileTest.IS_EXECUTABLE);
                rpc_row.subtitle = ok ? "Custom" : "❌ Custom path is not executable";
                rpc_row.tooltip_text = custom;
            } else {
                string? found = AccountFinder.find_rpc_server ();
                rpc_row.subtitle = found != null ? "Auto-detected" : "❌ Not found";
                rpc_row.tooltip_text = found ?? "No deltachat-rpc-server binary in the default locations";
            }
        }

        private void on_rpc_switch_toggled () {
            if (rpc_custom_switch.active) {
                on_browse_rpc_server.begin ();
            } else if (app_window.settings.rpc_server_path.length > 0) {
                app_window.settings.save_rpc_server_path ("");
                app_window.show_toast ("Using auto-detected RPC server. Restart to apply.");
                update_rpc_row ();
            }
        }

        private async void on_browse_rpc_server () {
            var dlg = new Gtk.FileDialog ();
            dlg.title = "Locate deltachat-rpc-server";
            dlg.modal = true;

            string start = app_window.settings.rpc_server_path;
            if (start.length == 0) start = AccountFinder.find_rpc_server () ?? "";
            if (start.length > 0) dlg.initial_file = File.new_for_path (start);

            try {
                var file = yield dlg.open (app_window, null);
                if (file != null) {
                    string? path = file.get_path ();
                    if (path != null && FileUtils.test (path, FileTest.IS_EXECUTABLE)) {
                        app_window.settings.save_rpc_server_path (path);
                        app_window.show_toast ("RPC server path saved. Restart to apply.");
                    } else {
                        show_error (app_window, "Selected file is not an executable binary.");
                    }
                }
            } catch (Error e) {
                if (!(e is Gtk.DialogError) && !(e is IOError.CANCELLED))
                    show_error (app_window, e.message);
            }
            /* Sync switch to actual state — reverts the toggle if nothing was saved. */
            rpc_custom_switch.active = app_window.settings.rpc_server_path.length > 0;
            update_rpc_row ();
        }

        private void on_reset_settings () {
            confirm_action (app_window, "Factory Reset",
                "This will delete all Parla configuration files and close the application. " +
                "Your Delta Chat accounts and messages are not affected.",
                "reset", "Reset & Close", () => {
                    delete_parla_config ();
                    app_window.application.quit ();
                });
        }

        private static void delete_parla_config () {
            var dir = Path.build_filename (
                Environment.get_user_config_dir (), "parla");
            FileUtils.unlink (Path.build_filename (dir, "settings.ini"));
            DirUtils.remove (dir);
        }
    }
}
