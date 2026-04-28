namespace Dc {

    public class Window : Adw.ApplicationWindow {

        /* Layout */
        private Adw.ToastOverlay toast_overlay;
        private Adw.NavigationSplitView split_view;
        private Adw.HeaderBar sidebar_header;
        private Adw.HeaderBar content_header;
        private Gtk.Label content_title_label;
        private Gtk.SearchEntry search_entry;

        /* Chat list */
        private Gtk.ListBox chat_listbox;
        public GLib.ListStore chat_store { get; private set; }

        /* Per-chat cached views */
        private HashTable<int, ConversationView> views;

        /* Status */
        private Adw.StatusPage empty_status;
        private Gtk.Stack content_stack;

        /* Floating connection-status banner (revealed when RPC is down) */
        private Gtk.Revealer connection_banner;
        private Gtk.Label connection_banner_label;

        /* Profile avatar */
        private Adw.Avatar profile_avatar;
        private Gtk.Popover account_popover;
        private Gtk.ListBox account_menu_list;

        /* State */
        private unowned RpcClient rpc;
        private int _current_chat_id = 0;
        private bool suppress_reselect_scroll = false;
        public int current_chat_id {
            get { return _current_chat_id; }
            private set {
                _current_chat_id = value;
                if (events != null) events.active_chat_id = value;
            }
        }

        /* Extracted managers */
        public SettingsManager settings;
        private ImageViewer image_viewer;
        private EventHandler events;
        private ChatContextMenu chat_menu;

        /* Modal dialog guard – only one at a time */
        private Adw.Dialog? active_modal = null;

        public Window (Dc.Application app) {
            Object (
                application: app,
                default_width: 920,
                default_height: 640,
                title: "Parla"
            );
        }

        construct {
            chat_store = new GLib.ListStore (typeof (ChatEntry));
            views = new HashTable<int, ConversationView> (direct_hash, direct_equal);
            settings = new SettingsManager ();
            image_viewer = new ImageViewer ();
            image_viewer.set_window (this);
            build_ui ();
            settings.load ();

            /* Defer connection until main loop — application property
               may not be available during construct. */
            Idle.add (() => {
                try_connect.begin ();
                return Source.REMOVE;
            });
        }

        /* ================================================================
         *  UI Construction
         * ================================================================ */

        private void build_ui () {
            /* ---- Sidebar ---- */
            var sidebar_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            sidebar_header = new Adw.HeaderBar ();
            var title_widget = new Adw.WindowTitle ("Parla", "");
            sidebar_header.title_widget = title_widget;

            /* Profile/account menu button in header */
            profile_avatar = new Adw.Avatar (24, "", true);
            account_popover = build_account_popover ();
            account_popover.map.connect (() => {
                load_account_menu.begin ();
            });

            var avatar_button = new Gtk.MenuButton ();
            avatar_button.child = profile_avatar;
            avatar_button.add_css_class ("flat");
            avatar_button.add_css_class ("circular");
            avatar_button.tooltip_text = "Account Menu";
            avatar_button.popover = account_popover;
            sidebar_header.pack_start (avatar_button);

            /* Hamburger menu button on the right */
            var menu_button = new Gtk.MenuButton ();
            menu_button.icon_name = "open-menu-symbolic";
            menu_button.tooltip_text = "Main Menu";
            menu_button.add_css_class ("flat");
            menu_button.menu_model = build_app_menu ();
            sidebar_header.pack_end (menu_button);


            sidebar_box.append (sidebar_header);

            /* Search */
            search_entry = new Gtk.SearchEntry ();
            search_entry.placeholder_text = "Search chats…";
            search_entry.margin_start = 8;
            search_entry.margin_end = 8;
            search_entry.margin_top = 4;
            search_entry.margin_bottom = 4;
            search_entry.search_changed.connect (() => {
                chat_listbox.invalidate_filter ();
            });
            sidebar_box.append (search_entry);

            /* Chat list */
            var chat_scroll = new Gtk.ScrolledWindow ();
            chat_scroll.vexpand = true;
            chat_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            chat_listbox = new Gtk.ListBox ();
            chat_listbox.selection_mode = Gtk.SelectionMode.SINGLE;
            chat_listbox.add_css_class ("navigation-sidebar");
            chat_listbox.set_filter_func (filter_chats);
            chat_listbox.row_selected.connect (on_chat_selected);

            /* Right-click context menu */
            var right_click = new Gtk.GestureClick ();
            right_click.button = 3; /* secondary button */
            right_click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            right_click.pressed.connect ((n, x, y) => {
                var row = chat_listbox.get_row_at_y ((int) y);
                if (row == null) return;
                var chat_row = row.child as ChatRow;
                if (chat_row == null) return;
                right_click.set_state (Gtk.EventSequenceState.CLAIMED);
                if (chat_menu != null)
                    chat_menu.show (chat_row.chat_id, x, y, chat_listbox);
            });
            chat_listbox.add_controller (right_click);

            chat_scroll.child = chat_listbox;
            sidebar_box.append (chat_scroll);

            var sidebar_page = new Adw.NavigationPage (sidebar_box, "Chats");

            /* ---- Content area ---- */
            var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            content_header = new Adw.HeaderBar ();
            content_title_label = new Gtk.Label ("Select a chat");
            content_title_label.add_css_class ("heading");
            content_header.title_widget = content_title_label;

            /* Show sidebar on mobile */
            content_header.show_back_button = true;

            /* Search/filter button on the right side */
            var search_btn = new Gtk.Button.from_icon_name ("edit-find-symbolic");
            search_btn.tooltip_text = "Search in conversation (Ctrl+F)";
            search_btn.clicked.connect (() => { toggle_message_search (); });
            content_header.pack_end (search_btn);

            content_box.append (content_header);

            /* Stack: empty status + one child per chat view (added lazily) */
            content_stack = new Gtk.Stack ();
            content_stack.vexpand = true;

            empty_status = new Adw.StatusPage ();
            empty_status.icon_name = "mail-send-receive-symbolic";
            empty_status.title = "Parla";
            empty_status.description = "Select a chat to start messaging,\nor wait for the connection…";
            content_stack.add_named (empty_status, "empty");
            content_stack.visible_child_name = "empty";
            content_box.append (content_stack);

            var content_page = new Adw.NavigationPage (content_box, "Messages");

            /* ---- Split view ---- */
            split_view = new Adw.NavigationSplitView ();
            split_view.sidebar = sidebar_page;
            split_view.content = content_page;
            split_view.max_sidebar_width = 340;
            split_view.min_sidebar_width = 260;

            toast_overlay = new Adw.ToastOverlay ();
            toast_overlay.child = split_view;

            /* Fullscreen image viewer overlay */
            var image_overlay = new Gtk.Overlay ();
            image_overlay.child = toast_overlay;
            image_overlay.add_overlay (image_viewer.widget);
            image_overlay.add_overlay (build_connection_banner ());

            this.content = image_overlay;

            /* Global keyboard shortcuts */
            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            key_ctrl.key_pressed.connect (on_window_key_pressed);
            ((Gtk.Widget) this).add_controller (key_ctrl);
        }

        private Gtk.Popover build_account_popover () {
            var popover = new Gtk.Popover ();
            popover.has_arrow = true;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            box.margin_start = 10;
            box.margin_end = 10;
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.width_request = 300;

            var title = new Gtk.Label ("Profiles");
            title.add_css_class ("heading");
            title.halign = Gtk.Align.START;
            title.xalign = 0;
            box.append (title);

            account_menu_list = new Gtk.ListBox ();
            account_menu_list.selection_mode = Gtk.SelectionMode.NONE;
            account_menu_list.add_css_class ("boxed-list");
            account_menu_list.row_activated.connect (on_account_menu_row_activated);
            box.append (account_menu_list);

            popover.child = box;
            return popover;
        }

        /* ================================================================
         *  Connection & Profile Setup
         * ================================================================ */

        private async void try_connect () {
            rpc = ((Dc.Application) this.application).rpc;

            /* Reset any error widget left from a previous failed attempt. */
            empty_status.child = null;
            empty_status.icon_name = "mail-send-receive-symbolic";
            empty_status.title = "Parla";
            empty_status.description = "Select a chat to start messaging,\nor wait for the connection…";

            /* Find the RPC server binary — user override then auto-scan. */
            string? rpc_path = AccountFinder.find_rpc_server (settings.rpc_server_path);
            if (rpc_path == null) {
                set_connection_status (false, "RPC server not found");
                show_rpc_not_found ();
                return;
            }

            /* Determine data directory and accounts path */
            string data_dir = AccountFinder.get_data_dir ();
            string accounts_path = Path.build_filename (data_dir, "accounts");

            /* Try to connect */
            try {
                yield rpc.start ({ rpc_path }, data_dir, accounts_path);
            } catch (Error e) {
                string msg = e.message;
                if ("already running" in msg.down () || "accounts.lock" in msg.down ()) {
                    show_toast ("Cannot connect — Delta Chat Desktop is already running");
                    empty_status.description =
                        "Delta Chat Desktop is already running.\n\n" +
                        "Close it first, then restart this app.";
                    set_connection_status (false, "Delta Chat Desktop is already running");
                } else {
                    show_toast ("RPC server error: " + msg);
                    empty_status.description = "Failed to start RPC server:\n\n" + Markup.escape_text (msg);
                    set_connection_status (false, "Cannot reach RPC server");
                }
                return;
            }

            /* Connected — hide any banner from a prior failure and register
               a handler in case the server goes away later. */
            set_connection_status (true);
            rpc.disconnected.connect ((reason) => {
                set_connection_status (false, "Disconnected — " + reason);
            });

            /* Ensure we have an account */
            string? acct_desc, acct_toast;
            yield AccountFinder.ensure_configured (rpc, out acct_desc, out acct_toast);
            if (acct_toast != null) show_toast (acct_toast);
            if (acct_desc != null) empty_status.description = acct_desc;

            /* Create event handler and message actions now that rpc is ready */
            events = new EventHandler (rpc);
            events.set_app (this.application);
            events.chats_reload_fired.connect (() => { load_chats.begin (); });
            events.messages_reload_fired.connect (() => {
                var v = current_view ();
                if (v != null) v.reload_messages.begin ();
            });
            events.incoming_msg_received.connect ((chat_id, msg_id) => {
                on_incoming_msg.begin (chat_id, msg_id);
            });

            chat_menu = new ChatContextMenu (this, rpc, chat_store);
            if (rpc.account_id > 0) {
                try {
                    rpc.self_email = yield rpc.get_config ("addr");
                } catch (Error ce) {
                    rpc.self_email = null;
                }
                yield load_chats ();
                yield load_profile_avatar ();
                events.start.begin ();
            }
        }

        private void show_rpc_not_found () {
            empty_status.icon_name = "dialog-error-symbolic";
            empty_status.title = "RPC server not found";
            empty_status.description = settings.rpc_server_path.length > 0
                ? "Configured path is missing or not executable:\n" + Markup.escape_text (settings.rpc_server_path)
                : "deltachat-rpc-server was not found.\nOpen Settings to locate it, or install it.";

            var btn = new Gtk.Button.with_label ("Open Settings…");
            btn.add_css_class ("suggested-action");
            btn.add_css_class ("pill");
            btn.halign = Gtk.Align.CENTER;
            btn.clicked.connect (show_settings_dialog);
            empty_status.child = btn;

            content_stack.visible_child_name = "empty";
            show_toast ("deltachat-rpc-server not found");
        }

        /* ================================================================
         *  Chat List
         * ================================================================ */

        public void clear_chat_view () {
            current_chat_id = 0;
            content_stack.visible_child_name = "empty";
        }

        private ConversationView? current_view () {
            if (current_chat_id <= 0) return null;
            return views.lookup (current_chat_id);
        }

        private ConversationView get_or_create_view (int chat_id) {
            var v = views.lookup (chat_id);
            if (v != null) return v;
            v = new ConversationView (chat_id, this, rpc, settings);
            views.insert (chat_id, v);
            content_stack.add_named (v, "chat_%d".printf (chat_id));
            return v;
        }

        public void request_messages_reload () {
            if (events != null) events.schedule_messages_reload ();
        }

        public async void load_chats () {
            if (rpc.account_id <= 0) return;

            try {
                var entries = yield rpc.get_chatlist_entries ();
                if (entries == null) return;

                var items = yield rpc.get_chatlist_items_by_entries (entries);

                chat_store.remove_all ();
                clear_listbox (chat_listbox);

                Gtk.ListBoxRow? reselect_row = null;
                for (uint i = 0; i < entries.get_length (); i++) {
                    int chat_id = (int) entries.get_int_element (i);
                    string id_str = chat_id.to_string ();

                    if (items != null && items.has_member (id_str)) {
                        var item = items.get_object_member (id_str);
                        var entry = RpcClient.parse_chat_item (chat_id, item);
                        chat_store.append (entry);

                        var chat_row = new ChatRow (entry);
                        chat_listbox.append (chat_row);

                        if (chat_id == current_chat_id) {
                            reselect_row = chat_listbox.get_row_at_index ((int) i);
                        }
                    }
                }

                if (reselect_row != null) {
                    suppress_reselect_scroll = true;
                    chat_listbox.select_row (reselect_row);
                    suppress_reselect_scroll = false;
                }
            } catch (Error e) {
                show_toast ("Failed to load chats: " + e.message);
            }
        }

        private bool filter_chats (Gtk.ListBoxRow row) {
            string query = search_entry.text.strip ().down ();
            if (query.length == 0) return true;

            var chat_row = row.child as ChatRow;
            if (chat_row == null) return true;

            var entry = find_chat_entry (chat_store, chat_row.chat_id);
            if (entry != null) {
                return entry.name.down ().contains (query);
            }
            return true;
        }

        private void on_chat_selected (Gtk.ListBoxRow? row) {
            if (row == null) return;

            var chat_row = row.child as ChatRow;
            if (chat_row == null) return;

            int chat_id = chat_row.chat_id;

            if (chat_id == current_chat_id) {
                if (suppress_reselect_scroll) return;
                var v = current_view ();
                if (v != null) v.on_reselected ();
                return;
            }

            var view = get_or_create_view (chat_id);
            current_chat_id = chat_id;

            var entry = find_chat_entry (chat_store, current_chat_id);
            if (entry != null) {
                content_title_label.label = entry.name;
            }

            content_stack.visible_child_name = "chat_%d".printf (chat_id);
            view.on_activated ();

            notice_chat.begin (current_chat_id);

            split_view.show_content = true;
        }

        private async void notice_chat (int chat_id) {
            try {
                yield rpc.marknoticed_chat (chat_id);
            } catch (Error e) {
                /* non-critical */
            }
        }

        /* ================================================================
         *  Attachments (save / image viewer)
         * ================================================================ */

        public void show_image (string path) {
            image_viewer.show (path);
        }

        public async void save_attachment (string src_path, string? name) {
            var dialog = new Gtk.FileDialog ();
            dialog.initial_name = name ?? Path.get_basename (src_path);
            try {
                var dest = yield dialog.save (this, null);
                if (dest == null) return;
                var src_file = File.new_for_path (src_path);
                yield src_file.copy_async (dest, FileCopyFlags.OVERWRITE,
                                           Priority.DEFAULT, null, null);
                show_toast ("File saved");
            } catch (Error e) {
                if (e is IOError.CANCELLED) return;
                show_toast ("Save failed: " + e.message);
            }
        }

        /* ================================================================
         *  Event Loop (delegates to EventHandler)
         * ================================================================ */

        public void request_reload_chats () {
            if (events != null) events.schedule_chats_reload ();
        }


        private async void on_incoming_msg (int chat_id, int msg_id) {
            var view = views.lookup (chat_id);
            if (view != null) {
                yield view.handle_incoming_msg (msg_id);
            }
            if (settings.notifications_enabled && !this.is_active) {
                yield events.send_notification (chat_id, msg_id);
            }
            request_reload_chats ();
        }

        /* ================================================================
         *  Actions
         * ================================================================ */

        private async void load_account_menu () {
            clear_listbox (account_menu_list);

            if (rpc == null || !rpc.is_connected) {
                var row = new Adw.ActionRow ();
                row.title = "Not connected";
                row.subtitle = "Open Settings to configure the RPC server";
                account_menu_list.append (row);
                return;
            }

            try {
                var accounts_node = yield rpc.get_all_accounts ();
                clear_listbox (account_menu_list);

                if (accounts_node == null) return;
                var accounts = accounts_node.get_array ();

                for (uint i = 0; i < accounts.get_length (); i++) {
                    var acct = accounts.get_object_element (i);
                    int id = (int) acct.get_int_member ("id");
                    account_menu_list.append (yield build_account_menu_row_for_id (
                        id, id == rpc.account_id));
                }

                if (accounts.get_length () == 0) {
                    var empty = new Adw.ActionRow ();
                    empty.title = "No accounts";
                    empty.subtitle = "Add an account to get started";
                    account_menu_list.append (empty);
                }
                account_menu_list.append (build_add_account_row ());
            } catch (Error e) {
                clear_listbox (account_menu_list);
                var err_row = new Adw.ActionRow ();
                err_row.use_markup = false;
                err_row.title = "Error loading accounts";
                err_row.subtitle = e.message;
                account_menu_list.append (err_row);
            }
        }

        private Adw.ActionRow build_add_account_row () {
            var row = new Adw.ActionRow ();
            row.title = "Add Profile";
            row.activatable = true;
            row.set_data<int> ("acct-id", -1);

            var icon = new Gtk.Image.from_icon_name ("list-add-symbolic");
            icon.valign = Gtk.Align.CENTER;
            row.add_prefix (icon);

            return row;
        }

        private async Adw.ActionRow build_account_menu_row_for_id (int id,
                                                                   bool current) throws Error {
            bool configured = yield rpc.is_configured (id);

            string? email = null;
            string? display_name = null;
            string? avatar = null;
            if (configured) {
                try {
                    email = yield rpc.get_config ("addr", id);
                    display_name = yield rpc.get_config ("displayname", id);
                    avatar = yield rpc.get_config ("selfavatar", id);
                } catch (Error ce) { /* ignore */ }
            }

            return build_account_menu_row (id, configured, current,
                email, display_name, avatar);
        }

        private Adw.ActionRow build_account_menu_row (int id, bool configured,
                                                       bool current,
                                                       string? email,
                                                       string? display_name,
                                                       string? avatar) {
            string title;
            if (display_name != null && display_name.length > 0) {
                title = display_name;
            } else if (configured) {
                title = email ?? "Account #%d".printf (id);
            } else {
                title = "Unconfigured account";
            }

            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = title;
            row.subtitle = email ?? "";
            row.activatable = configured && !current;
            row.set_data<int> ("acct-id", id);
            if (current) row.add_css_class ("current-account-row");

            var avatar_widget = new Adw.Avatar (32, title, true);
            avatar_widget.custom_image = load_avatar (avatar);
            row.add_prefix (avatar_widget);

            var edit_btn = new Gtk.Button.from_icon_name ("preferences-system-symbolic");
            edit_btn.valign = Gtk.Align.CENTER;
            edit_btn.add_css_class ("flat");
            edit_btn.tooltip_text = "Edit profile";
            edit_btn.sensitive = configured;
            edit_btn.clicked.connect (() => {
                account_popover.popdown ();
                show_profile_for_account (id);
            });
            row.add_suffix (edit_btn);

            if (!configured) {
                var status = new Gtk.Label ("Not configured");
                status.add_css_class ("caption");
                status.add_css_class ("dim-label");
                status.valign = Gtk.Align.CENTER;
                row.add_suffix (status);
            }

            return row;
        }

        private void on_account_menu_row_activated (Gtk.ListBoxRow row) {
            var action_row = row as Adw.ActionRow;
            if (action_row == null) return;
            int acct_id = action_row.get_data<int> ("acct-id");
            if (acct_id == -1) {
                account_popover.popdown ();
                on_add_account ();
                return;
            }
            if (!action_row.activatable || acct_id <= 0 || acct_id == rpc.account_id) return;

            account_popover.popdown ();
            switch_account_from_menu.begin (acct_id);
        }

        private void on_add_account () {
            if (active_modal != null) return;

            var dialog = new Adw.Dialog ();
            dialog.title = "Add Profile";
            dialog.content_width = 460;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

            var intro = new Gtk.Label ("Choose how you want to add an account.");
            intro.halign = Gtk.Align.START;
            intro.margin_start = intro.margin_end = 12;
            intro.margin_top = 12;
            intro.add_css_class ("dim-label");
            box.append (intro);

            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.margin_start = list.margin_end = 12;
            list.margin_top = 8;
            list.margin_bottom = 12;

            list.append (build_add_method_row (
                "contact-new-symbolic",
                "Create new profile",
                "Pick a chatmail relay and create a new account"));
            list.append (build_add_method_row (
                "phone-symbolic",
                "Add as secondary device",
                "Synchronize from another device on the same network"));
            list.append (build_add_method_row (
                "mail-message-new-symbolic",
                "Use classic email address",
                "Sign in with an existing email account"));
            list.append (build_add_method_row (
                "mail-attachment-symbolic",
                "Use invitation code",
                "Join via a dcaccount: link or QR code"));

            list.row_activated.connect ((row) => {
                string method = row.get_data<string> ("add-method");
                dialog.close ();
                on_add_account_method_selected (method);
            });

            box.append (list);
            dialog.child = box;
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.present (this);
        }

        private Adw.ActionRow build_add_method_row (string icon_name,
                                                     string title,
                                                     string subtitle) {
            var row = new Adw.ActionRow ();
            row.title = title;
            row.subtitle = subtitle;
            row.activatable = true;
            row.set_data<string> ("add-method", title);

            var icon = new Gtk.Image.from_icon_name (icon_name);
            icon.valign = Gtk.Align.CENTER;
            row.add_prefix (icon);

            var chevron = new Gtk.Image.from_icon_name ("go-next-symbolic");
            chevron.valign = Gtk.Align.CENTER;
            chevron.add_css_class ("dim-label");
            row.add_suffix (chevron);

            return row;
        }

        private void on_add_account_method_selected (string method) {
            if (method == "Use classic email address") {
                show_classic_email_dialog ();
            } else if (method == "Add as secondary device") {
                show_secondary_device_dialog ();
            } else if (method == "Create new profile") {
                show_create_profile_dialog ();
            } else {
                show_toast (method + ": not yet implemented");
            }
        }

        private void show_create_profile_dialog () {
            if (active_modal != null) return;
            if (events == null) {
                show_toast ("RPC not ready");
                return;
            }

            var dialog = new CreateProfileDialog (rpc, events);
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.account_created.connect ((new_id) => {
                after_profile_created.begin (new_id);
            });
            dialog.present (this);
        }

        private async void after_profile_created (int new_id) {
            bool changed = yield switch_account (new_id);
            if (changed) {
                show_toast ("Profile created");
                yield load_account_menu ();
            }
        }

        private void show_secondary_device_dialog () {
            if (active_modal != null) return;
            if (events == null) {
                show_toast ("RPC not ready");
                return;
            }

            var dialog = new ReceiveBackupDialog (rpc, events);
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.account_imported.connect ((new_id) => {
                after_secondary_device_imported.begin (new_id);
            });
            dialog.present (this);
        }

        private async void after_secondary_device_imported (int new_id) {
            bool changed = yield switch_account (new_id);
            if (changed) {
                show_toast ("Profile imported");
                yield load_account_menu ();
            }
        }

        private void show_classic_email_dialog () {
            var dialog = new Adw.AlertDialog (
                "Use classic email address",
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

            dialog.present (this);
        }

        private async void do_add_account (string email, string password) {
            try {
                int acct_id = yield rpc.add_account ();
                yield rpc.add_or_update_transport (acct_id, email, password);
                if (rpc.account_id > 0) {
                    yield rpc.stop_io ();
                }
                yield rpc.select_account (acct_id);
                yield rpc.start_io (acct_id);
                rpc.account_id = acct_id;
                yield reload_active_account ();
                yield load_account_menu ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void switch_account_from_menu (int acct_id) {
            bool changed = yield switch_account (acct_id);
            if (changed) yield load_account_menu ();
        }

        public async bool switch_account (int acct_id) {
            if (acct_id <= 0 || acct_id == rpc.account_id) return false;

            try {
                if (rpc.account_id > 0) {
                    yield rpc.stop_io ();
                }
                yield rpc.select_account (acct_id);
                yield rpc.start_io (acct_id);
                rpc.account_id = acct_id;
                yield reload_active_account ();
                return true;
            } catch (Error e) {
                show_error (this, e.message);
                return false;
            }
        }

        private void show_profile_for_account (int acct_id) {
            if (acct_id <= 0) return;

            bool edits_current_account = acct_id == rpc.account_id;
            var dialog = new ProfileDialog (rpc, acct_id);
            dialog.profile_updated.connect (() => {
                if (edits_current_account) {
                    load_profile_avatar.begin ();
                }
                load_account_menu.begin ();
            });
            dialog.account_deleted.connect ((deleted_id) => {
                after_profile_deleted.begin (deleted_id, edits_current_account);
            });
            dialog.present (this);
        }

        private async void after_profile_deleted (int deleted_id,
                                                  bool was_current_account) {
            bool switched_account = false;

            if (was_current_account) {
                switched_account = yield switch_to_first_configured_account (
                    deleted_id);
                if (!switched_account) {
                    rpc.account_id = 0;
                    yield reload_active_account ();
                }
            }

            yield load_account_menu ();
            show_toast (switched_account
                ? "Profile deleted; switched profile"
                : "Profile deleted");
        }

        private async bool switch_to_first_configured_account (int skip_id) {
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node == null) return false;

                var accounts = accounts_node.get_array ();
                for (uint i = 0; i < accounts.get_length (); i++) {
                    var acct = accounts.get_object_element (i);
                    int id = (int) acct.get_int_member ("id");
                    if (id <= 0 || id == skip_id) continue;

                    bool configured = false;
                    try {
                        configured = yield rpc.is_configured (id);
                    } catch (Error e) {
                        continue;
                    }
                    if (configured && yield switch_account (id)) {
                        return true;
                    }
                }
            } catch (Error e) {
                show_toast ("Failed to select another profile: " + e.message);
            }
            return false;
        }

        private async void load_profile_avatar () {
            if (rpc.account_id <= 0) return;

            try {
                string? name = yield rpc.get_config ("displayname");
                string? avatar = yield rpc.get_config ("selfavatar");

                profile_avatar.text = name ?? "";
                profile_avatar.custom_image = load_avatar (avatar);
            } catch (Error e) {
                /* ignore */
            }
        }

        private void on_new_chat () {
            if (rpc.account_id <= 0) return;
            if (active_modal != null) return;

            var picker = new ContactPickerDialog (rpc);
            active_modal = picker;
            picker.closed.connect (() => { active_modal = null; });
            picker.contact_picked.connect ((contact_id, email) => {
                create_chat_by_email.begin (email);
            });
            picker.present (this);
        }

        private async void create_chat_by_email (string email) {
            if (rpc.account_id <= 0) return;

            try {
                int contact_id = yield rpc.get_or_create_contact (email);
                int chat_id = yield rpc.get_or_create_chat_by_contact (contact_id);

                yield load_chats ();
                select_chat_by_id (chat_id);

                show_toast ("Chat created with " + email);
            } catch (Error e) {
                show_toast ("Failed to create chat: " + e.message);
            }
        }

        private void on_new_group () {
            if (rpc.account_id <= 0) return;
            if (active_modal != null) return;

            var dialog = new NewGroupDialog (rpc);
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.group_created.connect ((chat_id) => {
                after_group_created.begin (chat_id);
            });
            dialog.present (this);
        }

        private async void after_group_created (int chat_id) {
            yield load_chats ();
            select_chat_by_id (chat_id);
            show_toast ("Group created");
        }

        public void scroll_to_message (int msg_id) {
            var v = current_view ();
            if (v != null) v.scroll_to_message (msg_id);
        }

        /* ================================================================
         *  App Menu (Settings / About)
         * ================================================================ */

        private GLib.MenuModel build_app_menu () {
            SimpleAction a;
            a = new SimpleAction ("new-chat", null);
            a.activate.connect (() => { on_new_chat (); }); add_action (a);
            a = new SimpleAction ("new-group", null);
            a.activate.connect (() => { on_new_group (); }); add_action (a);
            a = new SimpleAction ("use-invite-link", null);
            a.activate.connect (() => { show_use_invite_link_dialog (); }); add_action (a);
            a = new SimpleAction ("refresh", null);
            a.activate.connect (() => { load_chats.begin (); }); add_action (a);
            a = new SimpleAction ("settings", null);
            a.activate.connect (() => { show_settings_dialog (); }); add_action (a);
            a = new SimpleAction ("shortcuts", null);
            a.activate.connect (() => { show_keyboard_shortcuts_dialog (); }); add_action (a);
            a = new SimpleAction ("about", null);
            a.activate.connect (() => { show_about_dialog (); }); add_action (a);

            var s1 = new GLib.Menu ();
            s1.append ("New Chat", "win.new-chat");
            s1.append ("New Group", "win.new-group");
            s1.append ("Use Invite Link", "win.use-invite-link");
            var s2 = new GLib.Menu ();
            s2.append ("Settings", "win.settings");
            var s3 = new GLib.Menu ();
            s3.append ("Shortcuts", "win.shortcuts");
            s3.append ("About", "win.about");

            var menu = new GLib.Menu ();
            menu.append_section (null, s1);
            menu.append_section (null, s2);
            menu.append_section (null, s3);
            return menu;
        }

        private void show_about_dialog () {
            var about = new Adw.AboutDialog ();
            about.application_name = "Parla";
            about.application_icon = "io.github.trufae.Parla";
            about.version = Parla.VERSION;
            about.developer_name = "pancake";
            about.developers = { "pancake" };
            about.license_type = Gtk.License.GPL_3_0;
            about.website = "https://github.com/trufae/parla";
            about.issue_url = "https://github.com/trufae/parla/issues";
            about.comments = "A Delta Chat client for GNOME";
            about.release_notes_version = Parla.VERSION;
            about.release_notes =
                "<p>What's New in Parla</p>" +
                "<ul>" +
                "<li>Focusable conversation list</li>" +
                "<li>Paste images from clipboard</li>" +
                "<li>Add delivery indicators</li>" +
                "<li>Add forward message action</li>" +
                "<li>Improve delete experience</li>" +
                "<li>Composebar with emoji-picker</li>" +
                "</ul>" +
                "<p>Previously in 0.2.1</p>" +
                "<ul>" +
                "<li>Add factory reset option in settings</li>" +
                "<li>Custom path to the JSONRPC server</li>" +
                "<li>Use ESC to focus the composebar</li>" +
                "<li>Faster conversation loads</li>" +
                "</ul>";
            about.present (this);
        }

        private void show_use_invite_link_dialog () {
            if (active_modal != null) return;
            if (rpc.account_id <= 0) {
                show_toast ("No active profile");
                return;
            }

            var dialog = new Adw.Dialog ();
            dialog.title = "Use Invite Link";
            dialog.content_width = 460;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
            content.margin_start = 18;
            content.margin_end = 18;
            content.margin_top = 12;
            content.margin_bottom = 18;

            var label = new Gtk.Label ("Paste a Delta Chat invite link.");
            label.halign = Gtk.Align.START;
            label.xalign = 0;
            label.wrap = true;
            label.add_css_class ("dim-label");
            content.append (label);

            var entry = new Gtk.Entry ();
            entry.placeholder_text = "https://i.delta.chat/#...";
            entry.input_purpose = Gtk.InputPurpose.URL;
            entry.hexpand = true;
            content.append (entry);

            var status = new Gtk.Label ("");
            status.halign = Gtk.Align.START;
            status.xalign = 0;
            status.wrap = true;
            status.add_css_class ("dim-label");
            content.append (status);

            var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            actions.halign = Gtk.Align.END;
            actions.margin_top = 6;

            var cancel_btn = new Gtk.Button.with_label ("Cancel");
            cancel_btn.clicked.connect (() => { dialog.close (); });
            actions.append (cancel_btn);

            var add_btn = new Gtk.Button.with_label ("Add");
            add_btn.add_css_class ("suggested-action");
            add_btn.sensitive = false;
            add_btn.clicked.connect (() => {
                use_invite_link.begin (dialog, entry, status, add_btn);
            });
            actions.append (add_btn);
            content.append (actions);

            entry.changed.connect (() => {
                add_btn.sensitive = entry.text.strip ().length > 0;
                status.label = "";
            });
            entry.activate.connect (() => {
                if (add_btn.sensitive) {
                    use_invite_link.begin (dialog, entry, status, add_btn);
                }
            });

            box.append (content);
            dialog.child = box;
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.present (this);
            entry.grab_focus ();
        }

        private async void use_invite_link (Adw.Dialog dialog,
                                            Gtk.Entry entry,
                                            Gtk.Label status,
                                            Gtk.Button add_btn) {
            string invite_link = entry.text.strip ();
            if (invite_link.length == 0) return;

            add_btn.sensitive = false;
            entry.sensitive = false;
            status.label = "Checking invite link…";

            try {
                var qr = yield rpc.check_qr (rpc.account_id, invite_link);
                if (qr == null || !qr.has_member ("kind")) {
                    status.label = "This is not a valid invite link.";
                    return;
                }

                string kind = qr.get_string_member ("kind");
                if (kind != "askVerifyContact" &&
                    kind != "askVerifyGroup" &&
                    kind != "askJoinBroadcast") {
                    status.label = "This is not a contact, group, or channel invite link.";
                    return;
                }

                status.label = "Accepting invite link…";
                int chat_id = yield rpc.secure_join (rpc.account_id, invite_link);
                yield load_chats ();
                select_chat_by_id (chat_id);
                dialog.close ();
                show_toast ("Invite link accepted");
            } catch (Error e) {
                status.label = "Invite link failed: " + e.message;
            } finally {
                if (active_modal == dialog) {
                    entry.sensitive = true;
                    add_btn.sensitive = entry.text.strip ().length > 0;
                }
            }
        }

        private void show_settings_dialog () {
            if (active_modal != null) return;

            var dialog = new SettingsDialog (this);
            active_modal = dialog;
            dialog.closed.connect (() => {
                active_modal = null;
                if (!rpc.is_connected && settings.rpc_server_path.length > 0) {
                    try_connect.begin ();
                }
            });
            dialog.present (this);
        }

        public async void reload_active_account () {
            discard_all_views ();
            chat_store.remove_all ();
            clear_listbox (chat_listbox);
            search_entry.text = "";
            content_title_label.label = "Select a chat";
            empty_status.child = null;

            if (rpc.account_id <= 0) {
                rpc.self_email = null;
                profile_avatar.text = "";
                profile_avatar.custom_image = null;
                empty_status.icon_name = "avatar-default-symbolic";
                empty_status.title = "No Profile Loaded";
                empty_status.description =
                    "Add or select a profile from the profile menu.";
                content_stack.visible_child_name = "empty";
                current_chat_id = 0;
                return;
            }

            empty_status.icon_name = "mail-send-receive-symbolic";
            empty_status.title = "Parla";
            empty_status.description = "Select a chat to start messaging.";
            try {
                rpc.self_email = yield rpc.get_config ("addr");
            } catch (Error e) {
                rpc.self_email = null;
            }
            current_chat_id = 0;
            content_stack.visible_child_name = "empty";
            yield load_chats ();
            yield load_profile_avatar ();
            if (events != null && !events.is_listening) {
                events.start.begin ();
            }
        }

        private void discard_all_views () {
            var iter = HashTableIter<int, ConversationView> (views);
            int k;
            ConversationView v;
            while (iter.next (out k, out v)) {
                content_stack.remove (v);
            }
            views.remove_all ();
        }

        /* ================================================================
         *  Keyboard Shortcuts
         * ================================================================ */

        private bool on_window_key_pressed (uint keyval, uint keycode,
                                            Gdk.ModifierType state) {
            /* Close fullscreen image viewer on any key */
            if (image_viewer.visible) {
                image_viewer.hide ();
                return true;
            }

            /* Escape: close any open dialog, then focus input entry */
            if (keyval == Gdk.Key.Escape) {
                for (var w = this.focus_widget; w != null; w = w.get_parent ()) {
                    if (w is Adw.Dialog) { ((Adw.Dialog) w).close (); break; }
                }
                var v = current_view ();
                if (v != null) {
                    v.close_search_if_active ();
                    v.focus_entry ();
                }
                return true;
            }

            /* All other shortcuts require Ctrl */
            if ((state & Gdk.ModifierType.CONTROL_MASK) == 0) return false;

            switch (keyval) {
            case Gdk.Key.n:
            case Gdk.Key.N:
                on_new_chat ();
                return true;
            case Gdk.Key.g:
            case Gdk.Key.G:
                on_new_group ();
                return true;
            case Gdk.Key.comma:
                show_settings_dialog ();
                return true;
            case Gdk.Key.f:
            case Gdk.Key.F:
                toggle_message_search ();
                return true;
            case Gdk.Key.k:
            case Gdk.Key.K:
                show_quick_switch_dialog ();
                return true;
            case Gdk.Key.r:
            case Gdk.Key.R:
                refresh_current_chat ();
                return true;
            case Gdk.Key.w:
            case Gdk.Key.W:
                this.close ();
                return true;
            case Gdk.Key.q:
            case Gdk.Key.Q:
                this.application.quit ();
                return true;
            }
            return false;
        }

        private void toggle_message_search () {
            var v = current_view ();
            if (v != null) v.toggle_search ();
        }

        private void refresh_current_chat () {
            request_reload_chats ();
            if (current_chat_id > 0) {
                request_messages_reload ();
            }
        }

        private void show_quick_switch_dialog () {
            if (rpc.account_id <= 0) return;
            if (chat_store.get_n_items () == 0) return;
            if (active_modal != null) return;

            var dialog = new QuickSwitchDialog (chat_store);
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.chat_selected.connect ((chat_id) => {
                select_chat_by_id (chat_id);
            });
            dialog.present (this);
            dialog.focus_entry ();
        }

        public void select_chat_by_id (int chat_id) {
            int idx = 0;
            Gtk.ListBoxRow? row;
            while ((row = chat_listbox.get_row_at_index (idx)) != null) {
                var chat_row = row.child as ChatRow;
                if (chat_row != null && chat_row.chat_id == chat_id) {
                    chat_listbox.select_row (row);
                    on_chat_selected (row);
                    return;
                }
                idx++;
            }
        }

        private const string[] SHORTCUTS = {
            "New chat",              "<Control>n",
            "New group",             "<Control>g",
            "Open settings",         "<Control>comma",
            "Search in conversation","<Control>f",
            "Quick switch chat",     "<Control>k",
            "Refresh messages",      "<Control>r",
            "Focus message entry",   "Escape",
            "Close window",          "<Control>w",
            "Quit application",      "<Control>q",
        };

        private void show_keyboard_shortcuts_dialog () {
            if (active_modal != null) return;

            var dialog = new Adw.Dialog ();
            dialog.title = "Shortcuts";
            dialog.content_width = 400;
            dialog.content_height = 380;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.margin_start = list.margin_end = list.margin_top = list.margin_bottom = 12;

            for (int i = 0; i + 1 < SHORTCUTS.length; i += 2) {
                var row = new Adw.ActionRow ();
                row.title = SHORTCUTS[i];
                var lbl = new Gtk.ShortcutLabel (SHORTCUTS[i + 1]);
                lbl.valign = Gtk.Align.CENTER;
                row.add_suffix (lbl);
                list.append (row);
            }

            box.append (list);
            dialog.child = box;
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.present (this);
        }

        /* ================================================================
         *  Utilities
         * ================================================================ */

        public void show_toast (string message) {
            var toast = new Adw.Toast (message);
            toast.timeout = 4;

            /* Find or create toast overlay */
            /* For simplicity, use the application window's built-in toast support */
            toast_overlay.add_toast (toast);
        }

        /**
         * Build the floating "disconnected" banner that slides in from the
         * top when the RPC server can't be reached. Non-interactive so it
         * never intercepts clicks meant for the chat below.
         */
        private Gtk.Revealer build_connection_banner () {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.add_css_class ("connection-banner");

            var icon = new Gtk.Image.from_icon_name ("network-offline-symbolic");
            icon.pixel_size = 14;
            box.append (icon);

            connection_banner_label = new Gtk.Label ("Not connected");
            connection_banner_label.add_css_class ("connection-banner-label");
            box.append (connection_banner_label);

            connection_banner = new Gtk.Revealer ();
            connection_banner.child = box;
            connection_banner.reveal_child = false;
            connection_banner.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
            connection_banner.transition_duration = 200;
            connection_banner.halign = Gtk.Align.CENTER;
            connection_banner.valign = Gtk.Align.START;
            connection_banner.margin_top = 8;
            connection_banner.can_target = false;   /* clicks pass through */
            return connection_banner;
        }

        /**
         * Show/hide the floating network banner. Pass null reason to hide.
         */
        public void set_connection_status (bool connected, string? reason = null) {
            if (connection_banner == null) return;
            if (connected) {
                connection_banner.reveal_child = false;
            } else {
                connection_banner_label.label = reason ?? "Not connected";
                connection_banner.reveal_child = true;
            }
        }

    }
}
