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
            try { kf.load_from_file (get_config_path (), KeyFileFlags.NONE); }
            catch (Error e) { /* file may not exist — helpers return defaults */ }
            double_click_action = kf_int (kf, "double_click_action", 0);
            markdown_rendering = kf_bool (kf, "markdown_rendering", false);
            Markdown.enabled = markdown_rendering;
            shift_enter_sends = kf_bool (kf, "shift_enter_sends", false);
            ComposeBar.shift_enter_sends = shift_enter_sends;
            notifications_enabled = kf_bool (kf, "notifications_enabled", true);
        }

        private static int kf_int (KeyFile kf, string k, int d) {
            try { return kf.get_integer ("General", k); } catch { return d; }
        }

        private static bool kf_bool (KeyFile kf, string k, bool d) {
            try { return kf.get_boolean ("General", k); } catch { return d; }
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
            shift_enter_sends = v; ComposeBar.shift_enter_sends = v;
            save_to_file ((kf) => { kf.set_boolean ("General", "shift_enter_sends", v); });
        }

        public void save_notifications_enabled (bool v) {
            notifications_enabled = v;
            save_to_file ((kf) => { kf.set_boolean ("General", "notifications_enabled", v); });
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

        private RpcClient rpc;
        private Gtk.ListBox accounts_list;
        private Gtk.Box content;
        private unowned Window app_window;

        public signal void account_changed ();

        public SettingsDialog (RpcClient rpc, Window window) {
            this.rpc = rpc;
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

            /* Accounts section */
            var accounts_label = new Gtk.Label ("Accounts");
            accounts_label.add_css_class ("title-3");
            accounts_label.halign = Gtk.Align.START;
            content.append (accounts_label);

            accounts_list = new Gtk.ListBox ();
            accounts_list.selection_mode = Gtk.SelectionMode.NONE;
            accounts_list.add_css_class ("boxed-list");
            accounts_list.row_activated.connect (on_row_activated);
            content.append (accounts_list);

            /* Add account button */
            var add_btn = new Gtk.Button.with_label ("Add Account");
            add_btn.add_css_class ("suggested-action");
            add_btn.halign = Gtk.Align.START;
            add_btn.clicked.connect (on_add_account);
            content.append (add_btn);

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

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = content;
            box.append (scroll);

            this.child = box;

            load_accounts.begin ();
        }

        private async void load_accounts () {
            /* Clear list */
            Gtk.ListBoxRow? row;
            while ((row = accounts_list.get_row_at_index (0)) != null) {
                accounts_list.remove (row);
            }

            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node == null) return;

                var accounts = accounts_node.get_array ();

                for (uint i = 0; i < accounts.get_length (); i++) {
                    var acct = accounts.get_object_element (i);
                    int id = (int) acct.get_int_member ("id");
                    bool configured = yield rpc.is_configured (id);

                    string? email = null;
                    string? display_name = null;
                    if (configured) {
                        try {
                            email = yield rpc.get_config (id, "addr");
                            display_name = yield rpc.get_config (id, "displayname");
                        } catch (Error ce) { /* ignore */ }
                    }

                    var action_row = new Adw.ActionRow ();
                    action_row.title = email ?? "Unconfigured account";
                    if (display_name != null && display_name.length > 0) {
                        action_row.subtitle = display_name;
                    } else if (configured) {
                        action_row.subtitle = "Account #%d".printf (id);
                    } else {
                        action_row.subtitle = "Not configured";
                    }
                    action_row.activatable = true;

                    /* Store account id so we can switch on click */
                    int acct_id = id;
                    action_row.set_data<int> ("acct-id", acct_id);

                    if (id == rpc.account_id) {
                        var badge = new Gtk.Label ("Active");
                        badge.add_css_class ("accent");
                        badge.add_css_class ("caption");
                        badge.valign = Gtk.Align.CENTER;
                        action_row.add_suffix (badge);
                    } else if (configured) {
                        var switch_icon = new Gtk.Image.from_icon_name ("go-next-symbolic");
                        switch_icon.valign = Gtk.Align.CENTER;
                        switch_icon.opacity = 0.5;
                        action_row.add_suffix (switch_icon);
                    }

                    /* Remove button */
                    var remove_btn = new Gtk.Button.from_icon_name ("user-trash-symbolic");
                    remove_btn.valign = Gtk.Align.CENTER;
                    remove_btn.add_css_class ("flat");
                    remove_btn.add_css_class ("error");
                    remove_btn.tooltip_text = "Remove account";
                    string acct_label = email ?? "this account";
                    remove_btn.clicked.connect (() => {
                        confirm_remove_account.begin (acct_id, acct_label);
                    });
                    action_row.add_suffix (remove_btn);

                    accounts_list.append (action_row);
                }

                if (accounts.get_length () == 0) {
                    var empty = new Adw.ActionRow ();
                    empty.title = "No accounts";
                    empty.subtitle = "Add an account to get started";
                    accounts_list.append (empty);
                }
            } catch (Error e) {
                var err_row = new Adw.ActionRow ();
                err_row.title = "Error loading accounts";
                err_row.subtitle = e.message;
                accounts_list.append (err_row);
            }
        }

        private void on_row_activated (Gtk.ListBoxRow row) {
            var action_row = row as Adw.ActionRow;
            if (action_row == null) return;
            int acct_id = action_row.get_data<int> ("acct-id");
            if (acct_id <= 0 || acct_id == rpc.account_id) return;
            do_switch_account.begin (acct_id);
        }

        private async void do_switch_account (int acct_id) {
            try {
                /* Stop IO on current account if any */
                if (rpc.account_id > 0) {
                    yield rpc.stop_io (rpc.account_id);
                }
                yield rpc.select_account (acct_id);
                yield rpc.start_io (acct_id);
                rpc.account_id = acct_id;
                account_changed ();
                yield load_accounts ();
            } catch (Error e) {
                var err_dialog = new Adw.AlertDialog ("Error", e.message);
                err_dialog.add_response ("ok", "OK");
                err_dialog.present (app_window);
            }
        }

        private void on_add_account () {
            var dialog = new Adw.AlertDialog (
                "Add Account",
                "Enter your email and password."
            );

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            var email_entry = new Gtk.Entry ();
            email_entry.placeholder_text = "user@example.com";
            email_entry.input_purpose = Gtk.InputPurpose.EMAIL;
            box.append (email_entry);

            var pass_entry = new Gtk.PasswordEntry ();
            pass_entry.placeholder_text = "Password";
            pass_entry.show_peek_icon = true;
            box.append (pass_entry);

            dialog.extra_child = box;

            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("add", "Add");
            dialog.set_response_appearance ("add", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "add";

            pass_entry.activate.connect (() => {
                dialog.response ("add");
            });

            dialog.response.connect ((resp) => {
                if (resp == "add") {
                    string email = email_entry.text.strip ();
                    string password = pass_entry.text;
                    if (email.length > 0 && email.contains ("@") && password.length > 0) {
                        do_add_account.begin (email, password);
                    }
                }
            });

            dialog.present (app_window);
        }

        private async void do_add_account (string email, string password) {
            try {
                int acct_id = yield rpc.add_account ();
                yield rpc.add_or_update_transport (acct_id, email, password);
                yield rpc.select_account (acct_id);
                yield rpc.start_io (acct_id);
                rpc.account_id = acct_id;
                account_changed ();
                yield load_accounts ();
            } catch (Error e) {
                var err_dialog = new Adw.AlertDialog ("Error", e.message);
                err_dialog.add_response ("ok", "OK");
                err_dialog.present (app_window);
            }
        }

        private async void confirm_remove_account (int acct_id, string label) {
            var dialog = new Adw.AlertDialog (
                "Remove Account",
                "Remove \"%s\"? This will delete all local data for this account.".printf (label)
            );
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("remove", "Remove");
            dialog.set_response_appearance ("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";

            dialog.response.connect ((resp) => {
                if (resp == "remove") {
                    do_remove_account.begin (acct_id);
                }
            });

            dialog.present (app_window);
        }

        private async void do_remove_account (int acct_id) {
            try {
                yield rpc.remove_account (acct_id);
                if (rpc.account_id == acct_id) {
                    rpc.account_id = 0;
                }
                account_changed ();
                yield load_accounts ();
            } catch (Error e) {
                var err_dialog = new Adw.AlertDialog ("Error", e.message);
                err_dialog.add_response ("ok", "OK");
                err_dialog.present (app_window);
            }
        }
    }
}
