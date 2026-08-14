namespace Dc {

    private Gtk.Label heading_label (string text) {
        var label = new Gtk.Label (text);
        label.add_css_class ("heading");
        label.halign = Gtk.Align.START;
        return label;
    }

    private Gtk.Label dim_label (string text, bool hexpand = false) {
        var label = new Gtk.Label (text);
        label.add_css_class ("dim-label");
        label.halign = Gtk.Align.START;
        label.xalign = 0;
        label.wrap = true;
        label.hexpand = hexpand;
        return label;
    }

    private Gtk.Box content_box (int side_margin = 16) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.margin_start = side_margin;
        box.margin_end = side_margin;
        box.margin_top = 12;
        box.margin_bottom = side_margin;
        return box;
    }

    private Gtk.Box end_actions_box () {
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        actions.halign = Gtk.Align.END;
        actions.margin_top = 6;
        return actions;
    }

    private Gtk.Box setup_qr_dialog (Adw.Dialog dialog, QrCodeView qr_view) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.append (new Adw.HeaderBar ());
        var content = content_box (18);
        content.append (qr_view);
        var actions = end_actions_box ();
        content.append (actions);
        box.append (content);
        dialog.child = box;
        return actions;
    }

    private Gtk.Button close_button (Adw.Dialog dialog) {
        var button = new Gtk.Button.with_label ("Close");
        button.clicked.connect (() => { dialog.close (); });
        return button;
    }

    public class ProfileDialog : Adw.Dialog {

        private RpcClient rpc;
        private SettingsManager settings;
        private EventHandler events;
        private int account_id;
        private Adw.Avatar avatar_widget;
        private Gtk.Entry name_entry;
        private Gtk.Entry status_entry;
        private Gtk.Label email_label;
        private Gtk.Label default_caption_label;
        private Gtk.Button default_make_button;
        private string? account_addr = null;
        private Gtk.Label connectivity_status_label;
        private Gtk.Label storage_summary_label;
        private Gtk.ProgressBar storage_progress;
        private Gtk.Switch read_receipts_switch;
        private Gtk.Label read_receipts_caption_label;
        private string? avatar_path = null;
        private bool avatar_changed = false;
        private bool loading_read_receipts = false;
        private bool saving_read_receipts = false;
        private bool saved_read_receipts_enabled = true;

        public signal void profile_updated ();
        public signal void account_deleted (int acct_id);

        public ProfileDialog (RpcClient rpc, SettingsManager settings,
                              EventHandler events, int acct_id = 0) {
            this.rpc = rpc;
            this.settings = settings;
            this.events = events;
            this.account_id = acct_id > 0 ? acct_id : rpc.account_id;
            this.title = "My Profile";
            this.content_width = 420;
            this.content_height = 560;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            var save_btn = new Gtk.Button.with_label ("Save");
            save_btn.add_css_class ("suggested-action");
            save_btn.clicked.connect (() => {
                do_save.begin ();
            });
            header.pack_end (save_btn);
            box.append (header);

            var content = content_box ();

            /* Avatar */
            avatar_widget = new Adw.Avatar (96, "", true);
            avatar_widget.halign = Gtk.Align.CENTER;
            content.append (avatar_widget);

            var avatar_btn = new Gtk.Button.with_label ("Change Avatar");
            avatar_btn.halign = Gtk.Align.CENTER;
            avatar_btn.add_css_class ("flat");
            avatar_btn.clicked.connect (() => {
                pick_avatar.begin ();
            });
            content.append (avatar_btn);

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var fields_grid = new Gtk.Grid ();
            fields_grid.column_spacing = 12;
            fields_grid.row_spacing = 12;

            var name_heading = heading_label ("Name");
            name_heading.valign = Gtk.Align.CENTER;
            fields_grid.attach (name_heading, 0, 0, 1, 1);

            name_entry = new Gtk.Entry ();
            name_entry.hexpand = true;
            name_entry.placeholder_text = "Your name";
            name_entry.changed.connect (() => {
                avatar_widget.text = name_entry.text.length > 0
                    ? name_entry.text : "";
            });
            fields_grid.attach (name_entry, 1, 0, 1, 1);

            var status_heading = heading_label ("Status");
            status_heading.valign = Gtk.Align.CENTER;
            fields_grid.attach (status_heading, 0, 1, 1, 1);

            status_entry = new Gtk.Entry ();
            status_entry.hexpand = true;
            status_entry.placeholder_text = "Your status message";
            fields_grid.attach (status_entry, 1, 1, 1, 1);

            var email_heading = heading_label ("Email");
            email_heading.valign = Gtk.Align.CENTER;
            fields_grid.attach (email_heading, 0, 2, 1, 1);

            email_label = dim_label ("");
            email_label.selectable = true;
            email_label.hexpand = true;
            email_label.valign = Gtk.Align.CENTER;
            fields_grid.attach (email_label, 1, 2, 1, 1);

            content.append (fields_grid);

            var invite_button = append_profile_action_row (content, "Invite Code",
                "Show a contact invite QR code", "Share your contact");
            invite_button.clicked.connect (show_invite_code_dialog);

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            content.append (build_read_receipts_row ());

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            content.append (build_connectivity_storage_section ());

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var relays_button = append_profile_action_row (content, "Relays...",
                "Manage chatmail relays for this profile", "Manage transports");
            relays_button.clicked.connect (show_relays_dialog);
            var second_device_button = append_profile_action_row (
                content, "Add Second Device",
                "Show a setup QR code for another device",
                "Transfer to another device");
            second_device_button.clicked.connect (show_second_device_dialog);

            content.append (build_default_account_row ());

            var delete_button = append_profile_action_row (content,
                "Delete Profile",
                "Delete local profile data", "Delete local profile data",
                "destructive-action");
            delete_button.clicked.connect (() => confirm_delete_account.begin ());

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = content;
            box.append (scroll);

            this.child = box;

            load_profile.begin ();
            load_read_receipt_settings.begin ();
            load_connectivity_summary.begin ();
        }

        private Gtk.Button append_profile_action_row (Gtk.Box content,
                                                      string button_label,
                                                      string tooltip,
                                                      string caption_text,
                                                      string? css_class = null) {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.margin_top = 4;

            var caption = dim_label (caption_text, true);
            caption.valign = Gtk.Align.CENTER;
            box.append (caption);

            var button = new Gtk.Button.with_label (button_label);
            button.halign = Gtk.Align.END;
            if (css_class != null) button.add_css_class (css_class);
            button.tooltip_text = tooltip;
            box.append (button);
            content.append (box);

            return button;
        }

        private Gtk.Widget build_default_account_row () {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.margin_top = 4;

            default_caption_label = dim_label ("", true);
            default_caption_label.valign = Gtk.Align.CENTER;
            box.append (default_caption_label);

            default_make_button = new Gtk.Button.with_label ("Make Default");
            default_make_button.halign = Gtk.Align.END;
            default_make_button.valign = Gtk.Align.CENTER;
            default_make_button.tooltip_text = "Open this account when Parla starts";
            default_make_button.clicked.connect (make_account_default);
            box.append (default_make_button);

            update_default_account_row ();
            return box;
        }

        private Gtk.Widget build_read_receipts_row () {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.margin_top = 4;

            var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            labels.hexpand = true;

            var title = heading_label ("Read Receipts");
            labels.append (title);

            read_receipts_caption_label = dim_label (
                "This affects this profile in every Delta Chat client, not only Parla.",
                true);
            labels.append (read_receipts_caption_label);
            box.append (labels);

            read_receipts_switch = new Gtk.Switch ();
            read_receipts_switch.active = true;
            read_receipts_switch.sensitive = false;
            read_receipts_switch.valign = Gtk.Align.CENTER;
            read_receipts_switch.notify["active"].connect (() => {
                if (!loading_read_receipts) save_read_receipt_settings.begin ();
            });
            box.append (read_receipts_switch);

            return box;
        }

        private async void load_read_receipt_settings () {
            if (!rpc.is_connected || account_id <= 0) {
                set_read_receipt_controls_sensitive (false);
                read_receipts_caption_label.label = "No active profile";
                return;
            }

            loading_read_receipts = true;
            set_read_receipt_controls_sensitive (false);

            try {
                string? enabled = yield rpc.get_config ("mdns_enabled", account_id);
                read_receipts_switch.active = enabled == null || enabled != "0";
                saved_read_receipts_enabled = read_receipts_switch.active;
                update_read_receipts_caption (read_receipts_switch.active);
            } catch (Error e) {
                read_receipts_caption_label.label =
                    "Unable to read read receipt setting";
                read_receipts_caption_label.tooltip_text = e.message;
            } finally {
                loading_read_receipts = false;
                set_read_receipt_controls_sensitive (true);
            }
        }

        private void set_read_receipt_controls_sensitive (bool sensitive) {
            read_receipts_switch.sensitive =
                sensitive && rpc.is_connected && account_id > 0;
        }

        private void update_read_receipts_caption (bool enabled) {
            read_receipts_caption_label.label = enabled
                ? "Enabled. This affects this profile in every Delta Chat client, not only Parla."
                : "Disabled. This affects this profile in every Delta Chat client, not only Parla.";
            read_receipts_caption_label.tooltip_text = null;
        }

        private async void save_read_receipt_settings () {
            if (loading_read_receipts || saving_read_receipts) return;

            if (!rpc.is_connected || account_id <= 0) {
                show_error (this, "No active profile");
                return;
            }

            bool enabled = read_receipts_switch.active;
            if (enabled == saved_read_receipts_enabled) return;

            saving_read_receipts = true;
            set_read_receipt_controls_sensitive (false);

            try {
                yield rpc.batch_set_config ("mdns_enabled",
                                            enabled ? "1" : "0",
                                            account_id);
                saved_read_receipts_enabled = enabled;
                update_read_receipts_caption (enabled);
            } catch (Error e) {
                show_error (this, "Failed to save read receipt setting: "
                    + e.message);
                loading_read_receipts = true;
                read_receipts_switch.active = saved_read_receipts_enabled;
                loading_read_receipts = false;
            } finally {
                saving_read_receipts = false;
                set_read_receipt_controls_sensitive (true);
            }
        }

        /* Applies immediately: making an account the default is an explicit
           action, so it persists without waiting for the Save button (which
           commits the editable profile fields). */
        private void make_account_default () {
            if (account_addr == null || account_addr.length == 0) return;
            settings.save_default_account_addr (account_addr);
            update_default_account_row ();
        }

        private void update_default_account_row () {
            bool loaded = account_addr != null && account_addr.length > 0;
            bool is_default = loaded
                && settings.default_account_addr.down ().strip ()
                    == account_addr.down ().strip ();
            default_caption_label.label = is_default
                ? "This is your default account, opened when Parla starts"
                : "Open this account automatically when Parla starts";
            default_make_button.visible = loaded && !is_default;
        }

        private Gtk.Widget build_connectivity_storage_section () {
            var section = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            section.append (heading_label ("Storage & Connectivity"));

            var conn_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            var conn_icon = new Gtk.Image.from_icon_name ("network-transmit-receive-symbolic");
            conn_icon.valign = Gtk.Align.CENTER;
            conn_row.append (conn_icon);

            connectivity_status_label = dim_label ("Checking connection…", true);
            conn_row.append (connectivity_status_label);
            section.append (conn_row);

            storage_progress = new Gtk.ProgressBar ();
            storage_progress.add_css_class ("storage-quota-bar");
            storage_progress.fraction = 0.0;
            section.append (storage_progress);

            storage_summary_label = dim_label ("Loading server quota…");
            section.append (storage_summary_label);

            var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            actions.halign = Gtk.Align.END;

            var refresh_btn = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
            refresh_btn.tooltip_text = "Refresh storage and connectivity";
            refresh_btn.add_css_class ("flat");
            refresh_btn.clicked.connect (() => {
                load_connectivity_summary.begin ();
            });
            actions.append (refresh_btn);

            var details_btn = new Gtk.Button.with_label ("Details…");
            details_btn.tooltip_text = "Show storage by conversation";
            details_btn.clicked.connect (() => {
                var dialog = new StorageDetailsDialog (rpc, account_id);
                dialog.present (this);
            });
            actions.append (details_btn);
            section.append (actions);

            return section;
        }

        private async void load_profile () {
            try {
                string? name = yield rpc.get_config ("displayname", account_id);
                string? status = yield rpc.get_config ("selfstatus", account_id);
                string? email = yield rpc.get_config ("addr", account_id);
                string? avatar = yield rpc.get_config ("selfavatar", account_id);

                if (name != null) {
                    name_entry.text = name;
                    avatar_widget.text = name;
                }
                if (status != null) status_entry.text = status;
                if (email != null) {
                    email_label.label = email;
                    account_addr = email;
                    update_default_account_row ();
                }
                if (avatar != null && avatar.length > 0 &&
                    FileUtils.test (avatar, FileTest.EXISTS)) {
                    avatar_path = avatar;
                }
                avatar_widget.custom_image = load_avatar (avatar);
            } catch (Error e) {
                /* ignore */
            }
        }

        private async void load_connectivity_summary () {
            try {
                int connectivity = yield rpc.get_connectivity (account_id);
                connectivity_status_label.label =
                    connection_label_for_state (connectivity);

                string html = yield rpc.get_connectivity_html (account_id);
                var quota = StorageQuota.parse_connectivity_report (html);
                apply_quota_progress (storage_progress, quota);
                storage_summary_label.label = quota.summary_text ();
            } catch (Error e) {
                connectivity_status_label.label = "Connection details unavailable";
                storage_summary_label.label = e.message;
                storage_progress.fraction = 0.0;
            }
        }

        private static string connection_label_for_state (int state) {
            if (state >= 4000) return "Connected; all background work is done";
            if (state >= 3000) return "Connected; sending or syncing messages";
            if (state >= 2000) return "Connecting to the server";
            if (state >= 1000) return "Not connected";
            return "Connection state unknown";
        }

        private async void do_save () {
            try {
                yield rpc.batch_set_config ("displayname", name_entry.text.strip (), account_id);
                yield rpc.batch_set_config ("selfstatus", status_entry.text.strip (), account_id);
                if (avatar_changed && avatar_path != null) {
                    yield rpc.batch_set_config ("selfavatar", avatar_path, account_id);
                }
                profile_updated ();
                this.close ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private void show_invite_code_dialog () {
            var dialog = new InviteCodeDialog (rpc, account_id);
            dialog.present (this);
        }

        private void show_second_device_dialog () {
            var dialog = new SecondDeviceDialog (rpc, account_id);
            dialog.present (this);
        }

        private void show_relays_dialog () {
            var dialog = new RelaysDialog (rpc, events, account_id);
            dialog.present (this);
        }

        private async void confirm_delete_account () {
            string label = email_label.label.strip ();
            if (label.length == 0) {
                label = name_entry.text.strip ();
            }
            if (label.length == 0) {
                label = "this account";
            }

            if (yield confirm_action (this, "Delete Profile",
                "Delete \"%s\"? This will remove all local data for this profile.".printf (label),
                "delete", "Delete Profile"))
                do_delete_account.begin ();
        }

        private async void do_delete_account () {
            try {
                yield rpc.remove_account (account_id);
                if (rpc.account_id == account_id) {
                    rpc.account_id = 0;
                }
                account_deleted (account_id);
                this.close ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void pick_avatar () {
            string? path = yield pick_image_file (
                (Gtk.Window) this.get_root (), "Select Avatar");
            if (path != null) {
                avatar_path = path;
                avatar_changed = true;
                avatar_widget.custom_image = load_avatar (path);
            }
        }
    }

    private class ChatStorageUsage : Object {
        public int chat_id;
        public string name;
        public int message_count = 0;
        public int local_file_count = 0;
        public int64 remote_bytes = 0;
        public int64 local_bytes = 0;
        private HashTable<string,string> local_paths =
            new HashTable<string,string> (str_hash, str_equal);

        public ChatStorageUsage (int chat_id, string name) {
            this.chat_id = chat_id;
            this.name = name;
        }

        public bool add_local_file (string path, int64 bytes) {
            if (local_paths.contains (path)) return false;
            local_paths.insert (path, "1");
            local_bytes += bytes;
            local_file_count++;
            return true;
        }

        public int64 total_bytes () {
            return local_bytes > remote_bytes ? local_bytes : remote_bytes;
        }
    }

    public class StorageDetailsDialog : Adw.Dialog {
        private RpcClient rpc;
        private int account_id;
        private Gtk.ProgressBar quota_progress;
        private Gtk.Label quota_label;
        private Gtk.Label local_total_label;
        private Gtk.Label scan_status_label;
        private Gtk.ListBox chat_usage_list;
        private Gtk.Button refresh_btn;
        private Gtk.Button clear_cache_btn;
        private string? blob_dir = null;
        private int64 known_attachment_bytes = 0;
        private int64 unique_local_file_bytes = 0;
        private HashTable<string,string> global_local_paths =
            new HashTable<string,string> (str_hash, str_equal);

        public StorageDetailsDialog (RpcClient rpc, int acct_id) {
            this.rpc = rpc;
            this.account_id = acct_id;
            this.title = "Storage Details";
            this.content_width = 560;
            this.content_height = 680;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            refresh_btn = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
            refresh_btn.tooltip_text = "Rescan storage usage";
            refresh_btn.clicked.connect (() => { load_details.begin (); });
            header.pack_end (refresh_btn);
            box.append (header);

            var content = content_box ();

            content.append (heading_label ("Server Quota"));

            quota_progress = new Gtk.ProgressBar ();
            quota_progress.add_css_class ("storage-quota-bar");
            content.append (quota_progress);

            quota_label = dim_label ("Loading quota…");
            content.append (quota_label);

            content.append (heading_label ("Local Copies"));

            local_total_label = dim_label ("Scanning local files…");
            content.append (local_total_label);

            clear_cache_btn = new Gtk.Button.with_label ("Clear Local Cache…");
            clear_cache_btn.halign = Gtk.Align.START;
            clear_cache_btn.tooltip_text = "Explain what can be safely cleared";
            clear_cache_btn.clicked.connect (show_clear_cache_info);
            content.append (clear_cache_btn);

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            content.append (heading_label ("Conversations by Storage Size"));

            scan_status_label = dim_label ("Preparing scan…");
            content.append (scan_status_label);

            chat_usage_list = new Gtk.ListBox ();
            chat_usage_list.selection_mode = Gtk.SelectionMode.NONE;
            chat_usage_list.add_css_class ("boxed-list");
            content.append (chat_usage_list);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = content;
            box.append (scroll);

            this.child = box;
            install_escape_close (this);
            load_details.begin ();
        }

        private async void load_details () {
            refresh_btn.sensitive = false;
            clear_listbox (chat_usage_list);
            known_attachment_bytes = 0;
            unique_local_file_bytes = 0;
            global_local_paths.remove_all ();
            scan_status_label.label = "Scanning conversations…";
            local_total_label.label = "Scanning local files…";

            try {
                int64 account_bytes = 0;
                try {
                    account_bytes = yield rpc.get_account_file_size (account_id);
                } catch (Error e) { /* optional in older RPC servers */ }

                try {
                    blob_dir = yield rpc.get_blob_dir (account_id);
                } catch (Error e) {
                    blob_dir = null;
                }

                try {
                    string html = yield rpc.get_connectivity_html (account_id);
                    var quota = StorageQuota.parse_connectivity_report (html);
                    apply_quota_progress (quota_progress, quota);
                    quota_label.label = quota.summary_text ();
                } catch (Error e) {
                    quota_progress.fraction = 0.0;
                    quota_label.label = "Server quota unavailable: " + e.message;
                }

                var usages = yield scan_all_chats ();
                sort_usages (usages);
                populate_chat_usage_list (usages);

                string file_summary =
                    "%s downloaded message files · %s known attachment payload".printf (
                        StorageQuota.format_mb (unique_local_file_bytes),
                        StorageQuota.format_mb (known_attachment_bytes));
                local_total_label.label = account_bytes > 0
                    ? "%s local account data · %s".printf (
                        StorageQuota.format_mb (account_bytes), file_summary)
                    : file_summary;

                scan_status_label.label = usages.length == 0
                    ? "No downloaded message files found in conversations."
                    : "%d conversations with local or attached files.".printf (usages.length);
            } catch (Error e) {
                scan_status_label.label = "Storage scan failed: " + e.message;
            }

            refresh_btn.sensitive = true;
        }

        private async ChatStorageUsage[] scan_all_chats () throws Error {
            ChatStorageUsage[] usages = {};
            var entries = yield rpc.get_chatlist_entries_for (account_id);
            if (entries == null) return usages;

            Json.Object? items = null;
            try {
                items = yield rpc.get_chatlist_items_by_entries_for (account_id, entries);
            } catch (Error e) { /* names fall back to ids */ }

            for (uint i = 0; i < entries.get_length (); i++) {
                int chat_id = (int) entries.get_int_element (i);
                string name = get_chat_name (items, chat_id);
                scan_status_label.label = "Scanning %s…".printf (name);

                var usage = yield scan_chat (chat_id, name);
                if (usage.remote_bytes > 0 || usage.local_bytes > 0) {
                    usages += usage;
                }
            }
            return usages;
        }

        private string get_chat_name (Json.Object? items, int chat_id) {
            if (items != null) {
                string key = chat_id.to_string ();
                if (items.has_member (key)) {
                    var entry = RpcParsers.parse_chat_item (
                        chat_id, items.get_object_member (key));
                    if (entry.name.length > 0) return entry.name;
                }
            }
            return "Chat #%d".printf (chat_id);
        }

        private async ChatStorageUsage scan_chat (int chat_id,
                                                   string name) throws Error {
            var usage = new ChatStorageUsage (chat_id, name);
            var ids = yield rpc.get_message_ids_for (account_id, chat_id);
            if (ids == null) return usage;
            int len = (int) ids.get_length ();
            usage.message_count = len;
            for (int start = 0; start < len; start += 200) {
                int end = start + 200;
                if (end > len) end = len;
                int count = end - start;
                int[] batch = new int[count];
                for (int i = 0; i < count; i++) {
                    batch[i] = (int) ids.get_int_element ((uint) (start + i));
                }

                var messages = yield rpc.get_messages_for (account_id, batch);
                if (messages == null) continue;

                for (int i = 0; i < count; i++) {
                    string key = batch[i].to_string ();
                    if (!messages.has_member (key)) continue;

                    var node = messages.get_member (key);
                    if (node == null || node.get_node_type () != Json.NodeType.OBJECT)
                        continue;

                    var msg = RpcParsers.parse_message (node.get_object ());
                    add_message_usage (usage, msg);
                }
            }
            return usage;
        }

        private void add_message_usage (ChatStorageUsage usage, Message msg) {
            if (msg.file_bytes > 0) {
                usage.remote_bytes += msg.file_bytes;
                known_attachment_bytes += msg.file_bytes;
            }

            string? local_path = resolve_local_path (msg.file_path);
            if (local_path == null) return;

            int64 bytes = file_size (local_path);
            if (bytes <= 0) return;

            usage.add_local_file (local_path, bytes);
            if (!global_local_paths.contains (local_path)) {
                global_local_paths.insert (local_path, "1");
                unique_local_file_bytes += bytes;
            }
        }

        private string? resolve_local_path (string? path) {
            if (path == null || path.length == 0) return null;
            if (path.has_prefix ("$BLOBDIR/")) {
                if (blob_dir == null || blob_dir.length == 0) return null;
                return Path.build_filename (blob_dir, path.substring (9));
            }
            if (Path.is_absolute (path)) return path;
            return null;
        }

        private static int64 file_size (string path) {
            if (!FileUtils.test (path, FileTest.IS_REGULAR)) return 0;
            try {
                var info = File.new_for_path (path).query_info (
                    "standard::size", FileQueryInfoFlags.NONE);
                return info.get_size ();
            } catch (Error e) {
                return 0;
            }
        }

        private void sort_usages (ChatStorageUsage[] usages) {
            for (int i = 0; i < usages.length; i++) {
                for (int j = i + 1; j < usages.length; j++) {
                    if (usages[j].total_bytes () > usages[i].total_bytes ()) {
                        var tmp = usages[i];
                        usages[i] = usages[j];
                        usages[j] = tmp;
                    }
                }
            }
        }

        private void populate_chat_usage_list (ChatStorageUsage[] usages) {
            clear_listbox (chat_usage_list);
            int64 max = 1;
            foreach (var usage in usages) {
                if (usage.total_bytes () > max) max = usage.total_bytes ();
            }

            foreach (var usage in usages) {
                chat_usage_list.append (build_chat_usage_row (usage, max));
            }
        }

        private Gtk.Widget build_chat_usage_row (ChatStorageUsage usage,
                                                  int64 max_bytes) {
            var row = new Gtk.ListBoxRow ();
            row.activatable = false;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);
            box.margin_start = 12;
            box.margin_end = 12;
            box.margin_top = 8;
            box.margin_bottom = 8;

            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            var title = new Gtk.Label (usage.name);
            title.halign = Gtk.Align.START;
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.hexpand = true;
            top.append (title);

            var amount = new Gtk.Label (StorageQuota.format_mb (usage.total_bytes ()));
            amount.add_css_class ("numeric");
            amount.halign = Gtk.Align.END;
            top.append (amount);
            box.append (top);

            var subtitle = dim_label (
                "%s local · %s attached · %d files · %d messages".printf (
                    StorageQuota.format_mb (usage.local_bytes),
                    StorageQuota.format_mb (usage.remote_bytes),
                    usage.local_file_count,
                    usage.message_count));
            subtitle.add_css_class ("caption");
            box.append (subtitle);

            var bar = new Gtk.ProgressBar ();
            bar.add_css_class ("storage-chat-bar");
            bar.fraction = (double) usage.total_bytes () / (double) max_bytes;
            box.append (bar);

            row.child = box;
            return row;
        }

        private void show_clear_cache_info () {
            var dialog = new Adw.AlertDialog (
                "Clear Local Cache",
                "Parla can show downloaded local files, but Delta Chat does not expose a safe cache-only purge for message blobs through this RPC server. Deleting those files directly can break attachments and forwarded messages.\n\nUse the conversation list above to decide which chats or messages to remove. Delta Chat housekeeping then cleans unused local files."
            );
            dialog.add_response ("ok", "OK");
            dialog.present (this);
        }
    }

    private static void apply_quota_progress (Gtk.ProgressBar progress,
                                              StorageQuota quota) {
        progress.remove_css_class ("storage-quota-warning");
        progress.remove_css_class ("storage-quota-error");
        progress.fraction = quota.used_fraction ();
        if (quota.is_error ()) {
            progress.add_css_class ("storage-quota-error");
        } else if (quota.is_warning ()) {
            progress.add_css_class ("storage-quota-warning");
        }
    }

    public class InviteCodeDialog : Adw.Dialog {

        private RpcClient rpc;
        private int account_id;
        private int chat_id;
        private QrCodeView qr_view;
        private Gtk.Button? toggle_btn = null;
        private bool closing = false;
        private bool link_active = true;
        private bool toggle_busy = false;

        public InviteCodeDialog (RpcClient rpc, int acct_id, int chat_id = 0) {
            this.rpc = rpc;
            this.account_id = acct_id;
            this.chat_id = chat_id;
            this.title = chat_id > 0 ? "Invite Link" : "Invite Code";
            this.content_width = 480;
            this.content_height = 560;
            this.can_close = true;

            qr_view = new QrCodeView ("Preparing invite code…");
            var actions = setup_qr_dialog (this, qr_view);

            /* Group/channel invite links can be deactivated (withdrawn) and
               reactivated (revived) by their owner — see set_config_from_qr.
               Personal contact codes have no such toggle. */
            if (chat_id > 0) {
                toggle_btn = new Gtk.Button.with_label ("Deactivate Link");
                toggle_btn.sensitive = false;
                toggle_btn.clicked.connect (() => { toggle_link.begin (); });
                actions.append (toggle_btn);
            }

            actions.append (qr_view.make_copy_button ("Copy Link"));
            actions.append (close_button (this));

            install_escape_close (this);
            this.closed.connect (() => { closing = true; });
            load_invite_code.begin ();
        }

        private async void load_invite_code () {
            try {
                string text = yield rpc.get_chat_securejoin_qr_code (account_id, chat_id);
                string svg = yield rpc.create_qr_svg (text);
                if (!closing) show_qr (text, svg);
            } catch (Error e) {
                if (!closing) show_invite_error (e.message);
            }
        }

        private void show_qr (string text, string svg) {
            string ready_status = chat_id > 0
                ? "Share this QR code or invite link to let others join."
                : "Share this QR code with another user, or copy the invite link below.";
            qr_view.show_code (text, svg, ready_status,
                "Invite link is ready, but the QR image could not be rendered: ");

            if (chat_id > 0) refresh_link_state.begin ();
        }

        /* Ask the core what state our own invite link is in. Checking our own
           QR returns a "withdraw…" kind while it is active and a "revive…" kind
           once it has been withdrawn, so the prefix tells us which way the
           toggle should act. */
        private async void refresh_link_state () {
            string text = qr_view.code_text ?? "";
            if (text.length == 0 || toggle_btn == null) return;
            try {
                var qr = yield rpc.check_qr (account_id, text);
                if (closing || qr == null || !qr.has_member ("kind")) return;
                string kind = qr.get_string_member ("kind");
                if (kind.has_prefix ("withdraw") || kind.has_prefix ("revive")) {
                    link_active = kind.has_prefix ("withdraw");
                    apply_link_state ();
                } else {
                    /* Not a self-link state we can toggle — hide the control. */
                    toggle_btn.visible = false;
                }
            } catch (Error e) {
                /* Leave the toggle disabled; sharing/copying still works. */
            }
        }

        private void apply_link_state () {
            if (toggle_btn == null) return;
            toggle_btn.sensitive = true;
            if (link_active) {
                toggle_btn.label = "Deactivate Link";
                toggle_btn.remove_css_class ("suggested-action");
                qr_view.set_qr_opacity (1.0);
                qr_view.set_status (
                    "Share this QR code or invite link to let others join.");
            } else {
                toggle_btn.label = "Activate Link";
                toggle_btn.add_css_class ("suggested-action");
                qr_view.set_qr_opacity (0.35);
                qr_view.set_status (
                    "This invite link is deactivated — activate it to let others join.");
            }
        }

        private async void toggle_link () {
            string text = qr_view.code_text ?? "";
            if (text.length == 0 || toggle_btn == null || toggle_busy) return;
            toggle_busy = true;
            toggle_btn.sensitive = false;
            toggle_btn.label = link_active ? "Deactivating…" : "Activating…";
            try {
                yield rpc.set_config_from_qr (account_id, text);
                yield refresh_link_state ();
            } catch (Error e) {
                if (!closing) {
                    qr_view.set_status (
                        "Could not update the invite link: " + e.message);
                    apply_link_state ();
                }
            } finally {
                toggle_busy = false;
            }
        }

        private void show_invite_error (string message) {
            qr_view.set_status ("Invite code creation failed: " + message);
            qr_view.set_copy_sensitive (false);
            if (toggle_btn != null) toggle_btn.visible = false;
        }
    }

    public class SecondDeviceDialog : Adw.Dialog {

        private RpcClient rpc;
        private int account_id;
        private QrCodeView qr_view;
        private bool closing = false;
        private bool provider_running = false;

        public SecondDeviceDialog (RpcClient rpc, int acct_id) {
            this.rpc = rpc;
            this.account_id = acct_id;
            this.title = "Add Second Device";
            this.content_width = 480;
            this.content_height = 560;
            this.can_close = true;

            qr_view = new QrCodeView ("Preparing account…");
            var actions = setup_qr_dialog (this, qr_view);
            actions.append (qr_view.make_copy_button ("Copy Text"));
            actions.append (close_button (this));

            install_escape_close (this);
            this.closed.connect (on_closed);
            start_transfer.begin ();
        }

        private async void start_transfer () {
            provider_running = true;
            rpc.provide_backup.begin (account_id, (obj, res) => {
                provider_running = false;
                try {
                    rpc.provide_backup.end (res);
                    if (!closing) this.close ();
                } catch (Error e) {
                    if (!closing) show_transfer_error (e.message);
                }
            });

            try {
                string text = yield rpc.get_backup_qr (account_id);
                string svg = yield rpc.create_qr_svg (text);
                if (!closing) show_qr (text, svg);
            } catch (Error e) {
                if (!closing) {
                    show_transfer_error (e.message);
                    stop_provider ();
                }
            }
        }

        private void show_qr (string text, string svg) {
            qr_view.show_code (text, svg,
                "Scan this QR code with the second device, or copy the text below.",
                "QR text is ready, but the image could not be rendered: ");
        }

        private void show_transfer_error (string message) {
            qr_view.set_status ("Second-device setup failed: " + message);
            qr_view.set_copy_sensitive (false);
        }

        private void on_closed () {
            closing = true;
            stop_provider ();
        }

        private void stop_provider () {
            if (provider_running) {
                rpc.stop_ongoing_process.begin (account_id, (obj, res) => {
                    try { rpc.stop_ongoing_process.end (res); }
                    catch (Error e) { /* ignore */ }
                });
            }
        }
    }
}
