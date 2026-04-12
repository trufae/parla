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
        private GLib.ListStore chat_store;

        /* Message view */
        private Gtk.ListView message_listview;
        private Gtk.ScrolledWindow message_scroll;
        private GLib.ListStore message_store;
        private Gtk.FilterListModel filtered_message_store;
        private Gtk.CustomFilter message_filter;
        private ComposeBar compose_bar;
        private Gtk.Button scroll_down_btn;

        /* Message search */
        private Gtk.Revealer message_search_revealer;
        private Gtk.SearchEntry message_search_entry;

        /* Status */
        private Adw.StatusPage empty_status;
        private Gtk.Stack content_stack;

        /* Profile avatar */
        private Adw.Avatar profile_avatar;

        /* State */
        private unowned RpcClient rpc;
        private int current_chat_id = 0;
        private string? self_email = null;
        private bool listening = false;
        private uint chats_reload_timer = 0;
        private uint messages_reload_timer = 0;
        private bool stick_to_bottom = true;
        private Json.Array? all_msg_ids = null;
        private uint loaded_start_index = 0;
        private bool loading_more = false;
        private bool loading_chat = false;
        public int double_click_action { get; set; default = 0; }
        public bool markdown_rendering { get; set; default = false; }
        public bool shift_enter_sends { get; set; default = false; }
        public bool notifications_enabled { get; set; default = true; }

        /* Pinned messages */
        private Gtk.Revealer pinned_revealer;
        private Gtk.Box pinned_bar_content;
        private int[] pinned_msg_ids = {};

        /* Fullscreen image viewer */
        private Gtk.Overlay image_viewer_overlay;
        private Gtk.Picture image_viewer_picture;
        private Gtk.Box image_viewer_box;

        public Window (Dc.Application app) {
            Object (
                application: app,
                default_width: 920,
                default_height: 640,
                title: "Delta Chat"
            );
        }

        construct {
            chat_store = new GLib.ListStore (typeof (ChatEntry));
            message_store = new GLib.ListStore (typeof (Message));
            build_ui ();
            load_settings ();

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
            var title_widget = new Adw.WindowTitle ("Delta Chat", "");
            sidebar_header.title_widget = title_widget;

            /* Profile avatar button in header */
            profile_avatar = new Adw.Avatar (24, "", true);
            var avatar_button = new Gtk.Button ();
            avatar_button.child = profile_avatar;
            avatar_button.add_css_class ("flat");
            avatar_button.add_css_class ("circular");
            avatar_button.tooltip_text = "My profile";
            avatar_button.clicked.connect (on_show_profile);
            sidebar_header.pack_start (avatar_button);

            /* Hamburger menu button on the right */
            var menu_button = new Gtk.MenuButton ();
            menu_button.icon_name = "open-menu-symbolic";
            menu_button.tooltip_text = "Main Menu";
            menu_button.add_css_class ("flat");
            menu_button.popover = build_app_menu_popover ();
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
            right_click.pressed.connect ((n, x, y) => {
                var row = chat_listbox.get_row_at_y ((int) y);
                if (row == null) return;
                var chat_row = row.child as ChatRow;
                if (chat_row == null) return;
                show_chat_context_menu (chat_row.chat_id, x, y);
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

            /* Stack: empty status vs message view */
            content_stack = new Gtk.Stack ();
            content_stack.vexpand = true;

            /* Empty state */
            empty_status = new Adw.StatusPage ();
            empty_status.icon_name = "mail-send-receive-symbolic";
            empty_status.title = "Delta Chat";
            empty_status.description = "Select a chat to start messaging,\nor wait for the connection…";
            content_stack.add_named (empty_status, "empty");

            /* Message view */
            var msg_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            message_scroll = new Gtk.ScrolledWindow ();
            message_scroll.vexpand = true;
            message_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            /* Auto-scroll: keep the user at the bottom when content or
               viewport size changes, using non-deprecated notify signals. */
            message_scroll.vadjustment.notify["upper"].connect (() => {
                if (loading_chat) return;
                maybe_autoscroll ();
                scroll_down_btn.visible = !is_near_bottom ();
            });
            message_scroll.vadjustment.notify["page-size"].connect (() => {
                if (loading_chat) return;
                maybe_autoscroll ();
                scroll_down_btn.visible = !is_near_bottom ();
            });
            message_scroll.vadjustment.notify["value"].connect (() => {
                if (loading_chat) return;
                stick_to_bottom = is_near_bottom ();
                scroll_down_btn.visible = !stick_to_bottom;
                if (is_near_top () && !loading_more && loaded_start_index > 0) {
                    load_earlier_messages.begin ();
                }
            });

            /* Filter for message search */
            message_filter = new Gtk.CustomFilter ((item) => {
                if (!message_search_revealer.reveal_child) return true;
                string query = message_search_entry.text.strip ().down ();
                if (query.length == 0) return true;
                var msg = (Message) item;
                return msg.text != null && msg.text.down ().contains (query);
            });
            filtered_message_store = new Gtk.FilterListModel (message_store, message_filter);

            var factory = new Gtk.SignalListItemFactory ();
            factory.bind.connect ((obj) => {
                var li = (Gtk.ListItem) obj;
                var msg = (Message) li.item;
                var row = new MessageRow (msg);
                row.quote_clicked.connect ((qid) => { scroll_to_message (qid); });

                /* Right-click context menu */
                var rc = new Gtk.GestureClick ();
                rc.button = 3;
                rc.pressed.connect ((n, x, y) => {
                    show_message_context_menu (msg.id, msg.is_outgoing, x, y);
                });
                row.add_controller (rc);

                /* Double-click and single-click activation */
                var dc = new Gtk.GestureClick ();
                dc.button = 1;
                dc.pressed.connect ((n, x, y) => {
                    if (n == 2) handle_message_double_click_id (msg.id);
                    else if (n == 1) on_message_activated (msg);
                });
                row.add_controller (dc);

                /* Highlight for newly arrived messages */
                if (msg.highlighted) {
                    msg.highlighted = false;
                    row.highlight ();
                }

                li.child = row;
            });

            var selection = new Gtk.NoSelection (filtered_message_store);
            message_listview = new Gtk.ListView (selection, factory);
            message_listview.add_css_class ("boxed-list-separate");
            message_scroll.child = message_listview;

            /* Message search bar (toggled by Ctrl+F) */
            message_search_entry = new Gtk.SearchEntry ();
            message_search_entry.placeholder_text = "Search in conversation\u2026";
            message_search_entry.hexpand = true;
            message_search_entry.margin_start = 8;
            message_search_entry.margin_end = 8;
            message_search_entry.margin_top = 4;
            message_search_entry.margin_bottom = 4;
            message_search_entry.search_changed.connect (() => {
                message_filter.changed (Gtk.FilterChange.DIFFERENT);
            });
            message_search_revealer = new Gtk.Revealer ();
            message_search_revealer.child = message_search_entry;
            message_search_revealer.reveal_child = false;
            message_search_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
            msg_box.append (message_search_revealer);

            /* Pinned messages bar */
            pinned_bar_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            pinned_bar_content.add_css_class ("pinned-bar");
            pinned_revealer = new Gtk.Revealer ();
            pinned_revealer.child = pinned_bar_content;
            pinned_revealer.reveal_child = false;
            pinned_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
            msg_box.append (pinned_revealer);

            scroll_down_btn = new Gtk.Button ();
            scroll_down_btn.icon_name = "go-down-symbolic";
            scroll_down_btn.add_css_class ("circular");
            scroll_down_btn.add_css_class ("osd");
            scroll_down_btn.add_css_class ("scroll-down-btn");
            scroll_down_btn.halign = Gtk.Align.CENTER;
            scroll_down_btn.valign = Gtk.Align.END;
            scroll_down_btn.margin_bottom = 12;
            scroll_down_btn.visible = false;
            scroll_down_btn.clicked.connect (() => { scroll_to_bottom (); });

            var scroll_overlay = new Gtk.Overlay ();
            scroll_overlay.child = message_scroll;
            scroll_overlay.vexpand = true;
            scroll_overlay.add_overlay (scroll_down_btn);

            msg_box.append (scroll_overlay);

            compose_bar = new ComposeBar ();
            compose_bar.send_message.connect (on_send_message);
            compose_bar.edit_message.connect (on_edit_message);
            msg_box.append (compose_bar);
            install_drop_target (msg_box);

            content_stack.add_named (msg_box, "messages");
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
            image_viewer_picture = new Gtk.Picture ();
            image_viewer_picture.content_fit = Gtk.ContentFit.CONTAIN;
            image_viewer_picture.hexpand = true;
            image_viewer_picture.vexpand = true;

            image_viewer_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            image_viewer_box.add_css_class ("image-viewer-overlay");
            image_viewer_box.hexpand = true;
            image_viewer_box.vexpand = true;
            image_viewer_box.append (image_viewer_picture);
            image_viewer_box.visible = false;

            var viewer_click = new Gtk.GestureClick ();
            viewer_click.button = 1;
            viewer_click.pressed.connect (() => { hide_image_viewer (); });
            image_viewer_box.add_controller (viewer_click);

            var viewer_right_click = new Gtk.GestureClick ();
            viewer_right_click.button = 3;
            viewer_right_click.pressed.connect ((n, x, y) => {
                show_image_viewer_menu (x, y);
            });
            image_viewer_box.add_controller (viewer_right_click);

            image_viewer_overlay = new Gtk.Overlay ();
            image_viewer_overlay.child = toast_overlay;
            image_viewer_overlay.add_overlay (image_viewer_box);

            this.content = image_viewer_overlay;

            /* Global keyboard shortcuts */
            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            key_ctrl.key_pressed.connect (on_window_key_pressed);
            ((Gtk.Widget) this).add_controller (key_ctrl);
        }

        /* ================================================================
         *  Connection & Account Setup
         * ================================================================ */

        private async void try_connect () {
            rpc = ((Dc.Application) this.application).rpc;

            /* Find the RPC server binary */
            string[]? rpc_cmd = AccountFinder.find_rpc_server ();
            if (rpc_cmd == null) {
                show_toast ("Delta Chat RPC server not found. Install deltachat-rpc-server.");
                empty_status.description = "deltachat-rpc-server not found.\nInstall it with: pip install deltachat-rpc-server";
                return;
            }

            /* Determine data directory and accounts path */
            string data_dir = AccountFinder.get_default_data_dir ();
            string accounts_path = Path.build_filename (data_dir, "accounts");

            /* Try to connect */
            try {
                yield rpc.start (rpc_cmd, data_dir, accounts_path);
            } catch (Error e) {
                string msg = e.message;
                if ("already running" in msg.down () || "accounts.lock" in msg.down ()) {
                    show_toast ("Cannot connect — Delta Chat Desktop is running");
                    empty_status.description =
                        "Delta Chat Desktop is already running.\n\n" +
                        "Close it first, then restart this app.";
                } else {
                    show_toast ("RPC server error: " + msg);
                    empty_status.description = "Failed to start RPC server:\n\n" + msg;
                }
                return;
            }

            /* Ensure we have an account */
            yield ensure_account (rpc);

            if (rpc.account_id > 0) {
                try {
                    self_email = yield rpc.get_config (rpc.account_id, "addr");
                } catch (Error ce) {
                    self_email = null;
                }
                yield load_chats ();
                yield load_profile_avatar ();
                start_listener.begin ();
            }
        }

        private async void ensure_account (RpcClient rpc) {
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node == null) return;

                var accounts = accounts_node.get_array ();

                /* Look for an already configured account */
                for (uint i = 0; i < accounts.get_length (); i++) {
                    var acct = accounts.get_object_element (i);
                    int id = (int) acct.get_int_member ("id");
                    bool configured = yield rpc.is_configured (id);
                    if (configured) {
                        rpc.account_id = id;
                        yield rpc.select_account (id);
                        yield rpc.start_io (id);
                        return;
                    }
                }

                /* No configured account — try to get credentials from openclaw config */
                var creds = AccountFinder.get_credentials_from_config ();
                if (creds != null && creds.email.length > 0 && creds.password.length > 0) {
                    int acct_id = yield rpc.add_account ();
                    yield rpc.add_or_update_transport (acct_id, creds.email, creds.password);
                    yield rpc.select_account (acct_id);
                    yield rpc.start_io (acct_id);
                    rpc.account_id = acct_id;
                    show_toast ("Configured account: " + creds.email);
                    return;
                }

                /* No credentials found — show available installations */
                var installations = AccountFinder.find_installations ();
                if (installations.length > 0) {
                    var sb = new StringBuilder ("Found installations:\n");
                    for (int j = 0; j < installations.length; j++) {
                        var inst = installations[j];
                        sb.append ("• %s".printf (inst.label));
                        if (inst.email != null) sb.append (" (%s)".printf (inst.email));
                        sb.append ("\n");
                    }
                    empty_status.description = sb.str +
                        "\nCreate a deltachat-config.json with email/password to connect.";
                } else {
                    empty_status.description =
                        "No Delta Chat accounts found.\n" +
                        "Create deltachat-config.json with your credentials.";
                }
            } catch (Error e) {
                show_toast ("Account setup error: " + e.message);
            }
        }

        /* ================================================================
         *  Chat List
         * ================================================================ */

        private async void load_chats () {
            if (rpc.account_id <= 0) return;

            try {
                var entries = yield rpc.get_chatlist_entries (rpc.account_id);
                if (entries == null) return;

                var items = yield rpc.get_chatlist_items_by_entries (rpc.account_id, entries);

                chat_store.remove_all ();
                Gtk.ListBoxRow? row;
                while ((row = chat_listbox.get_row_at_index (0)) != null) {
                    chat_listbox.remove (row);
                }

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
                    chat_listbox.select_row (reselect_row);
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

            /* Already viewing this chat — just scroll to bottom and focus input. */
            if (chat_id == current_chat_id
                && content_stack.visible_child_name == "messages") {
                scroll_to_bottom ();
                compose_bar.grab_entry_focus ();
                return;
            }

            current_chat_id = chat_id;

            /* Find name */
            var entry = find_chat_entry (chat_store, current_chat_id);
            if (entry != null) {
                content_title_label.label = entry.name;
            }

            content_stack.visible_child_name = "messages";
            load_messages.begin (current_chat_id);
            compose_bar.grab_entry_focus ();

            /* Mark chat as noticed (clears fresh counter without sending read receipts) */
            notice_chat.begin (current_chat_id);

            /* On narrow layout, navigate to content */
            split_view.show_content = true;
        }

        private async void notice_chat (int chat_id) {
            try {
                yield rpc.marknoticed_chat (rpc.account_id, chat_id);
            } catch (Error e) {
                /* non-critical */
            }
        }

        /* ================================================================
         *  Messages
         * ================================================================ */

        private async void load_messages (int chat_id) {
            if (rpc.account_id <= 0) return;

            try {
                all_msg_ids = yield rpc.get_message_ids (rpc.account_id, chat_id);
                if (all_msg_ids == null) return;

                loaded_start_index = all_msg_ids.get_length () > 100
                    ? all_msg_ids.get_length () - 100 : 0;

                var messages = yield fetch_messages_batch (
                    loaded_start_index, all_msg_ids.get_length ());

                if (chat_id != current_chat_id) return;

                pinned_msg_ids = load_pinned_for_chat (chat_id);

                loading_chat = true;
                stick_to_bottom = true;
                message_store.remove_all ();

                for (uint i = 0; i < messages.length; i++) {
                    var msg = messages[i];
                    msg.is_pinned = is_msg_pinned (msg.id);
                    message_store.append (msg);
                }

                Idle.add (() => {
                    scroll_to_bottom ();
                    Timeout.add (50, () => {
                        scroll_to_bottom ();
                        loading_chat = false;
                        scroll_down_btn.visible = !is_near_bottom ();
                        return Source.REMOVE;
                    });
                    return Source.REMOVE;
                });

                update_pinned_bar ();
            } catch (Error e) {
                show_toast ("Failed to load messages: " + e.message);
            }
        }

        private bool is_near_bottom () {
            var adj = message_scroll.vadjustment;
            if (adj.upper <= adj.page_size) return true;
            return (adj.upper - adj.value - adj.page_size) < 80;
        }

        private bool is_near_top () {
            var adj = message_scroll.vadjustment;
            return adj.value < 80;
        }

        private async GLib.GenericArray<Message> fetch_messages_batch (
                uint start, uint end) throws Error {
            int[] ids = {};
            for (uint i = start; i < end; i++) {
                ids += (int) all_msg_ids.get_int_element (i);
            }
            var map = yield rpc.get_messages (rpc.account_id, ids);
            var result = new GLib.GenericArray<Message> ();
            if (map != null) {
                foreach (int mid in ids) {
                    string k = mid.to_string ();
                    if (map.has_member (k)) {
                        result.add (RpcClient.parse_message (
                            map.get_object_member (k), self_email));
                    }
                }
            }
            return result;
        }

        private async void load_earlier_messages () {
            if (loading_more || all_msg_ids == null || loaded_start_index == 0) return;
            loading_more = true;
            int chat_id = current_chat_id;

            uint new_start = loaded_start_index > 100
                ? loaded_start_index - 100 : 0;

            try {
                var messages = yield fetch_messages_batch (new_start, loaded_start_index);
                if (chat_id != current_chat_id) { loading_more = false; return; }

                var adj = message_scroll.vadjustment;
                double old_upper = adj.upper;
                double old_value = adj.value;

                for (uint i = 0; i < messages.length; i++) {
                    var msg = messages[i];
                    msg.is_pinned = is_msg_pinned (msg.id);
                    message_store.insert ((int) i, msg);
                }

                loaded_start_index = new_start;

                Idle.add (() => {
                    var a = message_scroll.vadjustment;
                    a.value = old_value + (a.upper - old_upper);
                    loading_more = false;
                    return Source.REMOVE;
                });
            } catch (Error e) {
                loading_more = false;
                show_toast ("Failed to load earlier messages: " + e.message);
            }
        }

        private void maybe_autoscroll () {
            if (!stick_to_bottom) return;
            var adj = message_scroll.vadjustment;
            if (adj.upper > adj.page_size) {
                adj.value = adj.upper - adj.page_size;
            }
        }

        private void scroll_to_bottom () {
            stick_to_bottom = true;
            maybe_autoscroll ();
        }

        /* Insert a message into the store at the correct chronological position. */
        private void insert_message_sorted (Message msg) {
            int count = (int) message_store.get_n_items ();
            /* Fast path: new message is newest. */
            if (count > 0) {
                var last = (Message) message_store.get_item (count - 1);
                if (msg.timestamp > last.timestamp ||
                    (msg.timestamp == last.timestamp && msg.id >= last.id)) {
                    message_store.append (msg);
                    return;
                }
            }
            /* Slow path: find the correct position. */
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var m = (Message) message_store.get_item (i);
                if (m.timestamp > msg.timestamp ||
                    (m.timestamp == msg.timestamp && m.id > msg.id)) {
                    message_store.insert ((int) i, msg);
                    return;
                }
            }
            message_store.append (msg);
        }

        /* ================================================================
         *  Attachments (drag-and-drop)
         * ================================================================ */

        private void install_drop_target (Gtk.Widget target_widget) {
            var drop = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
            drop.accept.connect (() => {
                return current_chat_id > 0 && compose_bar.can_accept_attachment ();
            });
            drop.enter.connect ((x, y) => {
                target_widget.add_css_class ("chat-drop-active");
                return Gdk.DragAction.COPY;
            });
            drop.leave.connect (() => {
                target_widget.remove_css_class ("chat-drop-active");
            });
            drop.drop.connect ((value, x, y) => {
                target_widget.remove_css_class ("chat-drop-active");
                if (current_chat_id <= 0 || !compose_bar.can_accept_attachment ())
                    return false;
                var fl = (Gdk.FileList?) value.get_boxed ();
                if (fl == null) return false;
                var files = fl.get_files ();
                if (files == null || files.data == null) return false;
                attach_dropped_file.begin (files.data);
                return true;
            });
            target_widget.add_controller (drop);
        }

        private async void attach_dropped_file (GLib.File file) {
            try {
                string? path = file.get_path ();
                string name = file.get_basename () ?? "attachment";
                if (path == null) {
                    GLib.FileIOStream stream;
                    var tmp = GLib.File.new_tmp ("deltachat-gnome-XXXXXX", out stream);
                    stream.close ();
                    yield file.copy_async (tmp, FileCopyFlags.OVERWRITE,
                                           Priority.DEFAULT, null, null);
                    path = tmp.get_path ();
                }
                compose_bar.set_pending_attachment (path, name);
                compose_bar.grab_entry_focus ();
            } catch (Error e) {
                show_toast ("Attach failed: " + e.message);
            }
        }

        /* ================================================================
         *  Sending
         * ================================================================ */

        private void on_send_message (string text, string? file_path, string? file_name, int quote_msg_id) {
            if (current_chat_id <= 0) return;
            do_send.begin (text, file_path, file_name, quote_msg_id);
        }

        private async void do_send (string text, string? file_path, string? file_name, int quote_msg_id) {
            try {
                string? send_text = text.length > 0 ? text : null;
                string? send_file = file_path;
                string? send_name = file_name;

                int msg_id = yield rpc.send_msg (rpc.account_id, current_chat_id,
                                                  send_text, send_file, send_name,
                                                  quote_msg_id);

                /* Append the sent message directly instead of reloading all */
                if (msg_id > 0) {
                    var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                    if (msg_obj != null) {
                        var msg = RpcClient.parse_message (msg_obj, self_email);
                        insert_message_sorted (msg);
                        scroll_to_bottom ();
                    }
                }
            } catch (Error e) {
                show_toast ("Send failed: " + e.message);
            }
        }

        /* ================================================================
         *  Save attachment
         * ================================================================ */

        private void on_message_activated (Message msg) {
            if (msg.file_path == null || msg.file_path.length == 0) return;
            if (!FileUtils.test (msg.file_path, FileTest.EXISTS)) {
                show_toast ("File not available");
                return;
            }
            bool is_img = (msg.file_mime != null && msg.file_mime.has_prefix ("image/"));
            if (!is_img && msg.view_type != null) {
                var vt = msg.view_type.down ();
                is_img = (vt == "image" || vt == "gif" || vt == "sticker");
            }
            if (is_img) {
                show_image_viewer (msg.file_path);
            } else {
                save_attachment.begin (msg.file_path, msg.file_name);
            }
        }

        private async void save_attachment (string src_path, string? name) {
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
         *  Fullscreen image viewer
         * ================================================================ */

        private string? image_viewer_path = null;

        private void show_image_viewer (string path) {
            try {
                var texture = Gdk.Texture.from_filename (path);
                image_viewer_picture.paintable = texture;
                image_viewer_path = path;
                image_viewer_box.visible = true;
                image_viewer_box.grab_focus ();
            } catch (Error e) {
                show_toast ("Cannot open image: " + e.message);
            }
        }

        private void hide_image_viewer () {
            image_viewer_box.visible = false;
            image_viewer_picture.paintable = null;
            image_viewer_path = null;
        }

        private void show_image_viewer_menu (double x, double y) {
            if (image_viewer_path == null) return;
            string path = image_viewer_path;

            var popover = new Gtk.Popover ();
            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            vbox.margin_start = 4;
            vbox.margin_end = 4;
            vbox.margin_top = 4;
            vbox.margin_bottom = 4;

            var save_btn = new Gtk.Button.with_label ("Save image");
            save_btn.add_css_class ("flat");
            save_btn.clicked.connect (() => {
                popover.popdown ();
                save_attachment.begin (path, Path.get_basename (path));
            });
            vbox.append (save_btn);

            popover.child = vbox;
            popover.set_parent (image_viewer_box);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
        }

        /* ================================================================
         *  Event Loop
         * ================================================================ */

        private async void start_listener () {
            if (listening) return;
            listening = true;


            while (rpc.is_connected) {
                try {
                    var ev = yield rpc.get_next_event ();
                    if (ev == null) continue;

                    int ctx = (int) ev.get_int_member ("contextId");
                    if (ctx != rpc.account_id) continue;

                    var event = ev.get_object_member ("event");
                    if (event == null) continue;

                    string kind = event.get_string_member ("kind");
                    handle_event (kind, event);
                } catch (Error e) {
                    if (rpc.is_connected) {
                        warning ("Event loop error: %s", e.message);
                        yield nap (1000);
                    }
                }
            }

            listening = false;
        }

        private void reload_chats () {
            if (chats_reload_timer > 0) return;
            chats_reload_timer = Timeout.add (150, () => {
                chats_reload_timer = 0;
                load_chats.begin ();
                return Source.REMOVE;
            });
        }

        private void reload_messages () {
            if (messages_reload_timer > 0 || current_chat_id <= 0) return;
            messages_reload_timer = Timeout.add (150, () => {
                messages_reload_timer = 0;
                if (current_chat_id > 0) load_messages.begin (current_chat_id);
                return Source.REMOVE;
            });
        }

        private void handle_event (string kind, Json.Object event) {
            switch (kind) {
            case "IncomingMsg":
                int chat_id = (int) event.get_int_member ("chatId");
                int msg_id = (int) event.get_int_member ("msgId");
                on_incoming_msg.begin (chat_id, msg_id);
                break;

            case "MsgsChanged":
                int changed_chat = (int) event.get_int_member ("chatId");
                if (changed_chat == 0 || changed_chat == current_chat_id) {
                    reload_messages ();
                }
                break;

            case "MsgDelivered":
            case "MsgRead":
            case "MsgFailed":
            case "MsgDeleted":
            case "ReactionsChanged":
                int msg_chat = (int) event.get_int_member ("chatId");
                if (msg_chat == current_chat_id) {
                    reload_messages ();
                }
                break;

            case "ChatlistChanged":
            case "ChatlistItemChanged":
            case "MsgsNoticed":
            case "ChatModified":
            case "ChatDeleted":
                reload_chats ();
                break;

            default:
                break;
            }
        }

        private async void on_incoming_msg (int chat_id, int msg_id) {

            if (chat_id == current_chat_id && current_chat_id > 0) {
                /* Message is in the active chat — show it and mark seen */
                try {
                    var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                    if (msg_obj != null) {
                        var msg = RpcClient.parse_message (msg_obj, self_email);
                        msg.highlighted = true;
                        insert_message_sorted (msg);
                    }
                    if (this.is_active) {
                        yield rpc.mark_seen_msgs (rpc.account_id, new int[] { msg_id });
                    }
                } catch (Error e) {
                    warning ("Failed to handle incoming msg: %s", e.message);
                }
            }
            if (notifications_enabled && !this.is_active) {
                /* App is in background — send a desktop notification */
                yield notify_incoming_msg (chat_id, msg_id);
            }
            /* Refresh chat list to update preview text and unread counters. */
            reload_chats ();
        }

        private async void notify_incoming_msg (int chat_id, int msg_id) {
            try {
                var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                if (msg_obj == null) return;
                var msg = RpcClient.parse_message (msg_obj, self_email);
                if (msg.is_outgoing || msg.is_info) return;

                string title = msg.sender_name ?? msg.sender_address ?? "New message";
                try {
                    var chat_obj = yield rpc.get_full_chat_by_id (rpc.account_id, chat_id);
                    if (chat_obj != null && chat_obj.has_member ("name")) {
                        string chat_name = chat_obj.get_string_member ("name");
                        if (chat_name != null && chat_name.length > 0
                            && chat_name != title) {
                            title = "%s (%s)".printf (title, chat_name);
                        }
                    }
                } catch (Error e) { /* ignore — fall back to sender */ }

                string body;
                if (msg.text != null && msg.text.length > 0) {
                    body = msg.text;
                } else if (msg.file_name != null && msg.file_name.length > 0) {
                    body = msg.file_name;
                } else {
                    body = "New message";
                }

                var n = new GLib.Notification (title);
                n.set_body (body);
                n.set_priority (GLib.NotificationPriority.NORMAL);
                this.application.send_notification (
                    "dc-msg-%d".printf (msg_id), n);
            } catch (Error e) {
                warning ("Failed to send notification: %s", e.message);
            }
        }

        /* ================================================================
         *  Actions
         * ================================================================ */

        private void on_show_profile () {
            if (rpc.account_id <= 0) return;

            var dialog = new ProfileDialog (rpc, rpc.account_id);
            dialog.profile_updated.connect (() => {
                load_profile_avatar.begin ();
            });
            dialog.present (this);
        }

        private async void load_profile_avatar () {
            if (rpc.account_id <= 0) return;

            try {
                string? name = yield rpc.get_config (rpc.account_id, "displayname");
                string? avatar = yield rpc.get_config (rpc.account_id, "selfavatar");

                profile_avatar.text = name ?? "";
                if (avatar != null && avatar.length > 0 &&
                    FileUtils.test (avatar, FileTest.EXISTS)) {
                    try {
                        var texture = Gdk.Texture.from_filename (avatar);
                        profile_avatar.custom_image = texture;
                    } catch (Error e) {
                        profile_avatar.custom_image = null;
                    }
                } else {
                    profile_avatar.custom_image = null;
                }
            } catch (Error e) {
                /* ignore */
            }
        }

        private void on_new_chat () {
            if (rpc.account_id <= 0) return;

            var picker = new ContactPickerDialog (rpc, rpc.account_id);
            picker.contact_picked.connect ((contact_id, email) => {
                create_chat_by_email.begin (email);
            });
            picker.present (this);
        }

        private async void create_chat_by_email (string email) {
            if (rpc.account_id <= 0) return;

            try {
                int contact_id = yield rpc.lookup_contact (rpc.account_id, email);
                if (contact_id == 0) {
                    contact_id = yield rpc.create_contact (rpc.account_id, email);
                }
                int chat_id = yield rpc.get_or_create_chat_by_contact (
                    rpc.account_id, contact_id);

                yield load_chats ();

                /* Select the new chat */
                current_chat_id = chat_id;
                content_stack.visible_child_name = "messages";
                yield load_messages (chat_id);

                show_toast ("Chat created with " + email);
            } catch (Error e) {
                show_toast ("Failed to create chat: " + e.message);
            }
        }

        private void on_new_group () {
            if (rpc.account_id <= 0) return;

            var dialog = new NewGroupDialog (rpc, rpc.account_id);
            dialog.group_created.connect ((chat_id) => {
                after_group_created.begin (chat_id);
            });
            dialog.present (this);
        }

        private async void after_group_created (int chat_id) {
            yield load_chats ();
            current_chat_id = chat_id;
            content_stack.visible_child_name = "messages";
            yield load_messages (chat_id);
            show_toast ("Group created");
        }

        /* ================================================================
         *  Chat Context Menu
         * ================================================================ */

        private void show_chat_context_menu (int chat_id, double x, double y) {
            /* Look up pinned state from chat_store */
            bool is_pinned = false;
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) {
                is_pinned = entry.is_pinned;
            }

            var menu = new GLib.Menu ();
            menu.append (is_pinned ? "Unpin" : "Pin", "win.chat-pin");
            menu.append ("Chat Info", "win.chat-info");
            menu.append ("Delete for Me", "win.chat-delete");

            /* Set up actions with the chat_id */
            var pin_action = new SimpleAction ("chat-pin", null);
            pin_action.activate.connect (() => {
                toggle_chat_pin.begin (chat_id, is_pinned);
            });

            var info_action = new SimpleAction ("chat-info", null);
            info_action.activate.connect (() => {
                show_chat_info.begin (chat_id);
            });

            var delete_action = new SimpleAction ("chat-delete", null);
            delete_action.activate.connect (() => {
                confirm_delete_chat.begin (chat_id);
            });

            /* Replace actions each time (context changes) */
            var group = new SimpleActionGroup ();
            group.add_action (pin_action);
            group.add_action (info_action);
            group.add_action (delete_action);
            this.insert_action_group ("win", group);

            var popover = new Gtk.PopoverMenu.from_model (menu);
            popover.set_parent (chat_listbox);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
        }

        private async void toggle_chat_pin (int chat_id, bool currently_pinned) {
            try {
                string visibility = currently_pinned ? "Normal" : "Pinned";
                yield rpc.set_chat_visibility (rpc.account_id, chat_id, visibility);
                yield load_chats ();
            } catch (Error e) {
                show_toast ("Failed to update pin: " + e.message);
            }
        }

        /* ================================================================
         *  Message Context Menu (Reactions)
         * ================================================================ */

        private void show_message_context_menu (int msg_id, bool is_outgoing,
                                                  double x, double y) {
            var popover = new Gtk.Popover ();

            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            vbox.margin_start = 4;
            vbox.margin_end = 4;
            vbox.margin_top = 4;
            vbox.margin_bottom = 4;

            /* Reply button (for all messages) */
            var reply_btn = new Gtk.Button.with_label ("Reply");
            reply_btn.add_css_class ("flat");
            reply_btn.clicked.connect (() => {
                popover.popdown ();
                start_replying_message (msg_id);
            });
            vbox.append (reply_btn);

            /* Pin / Unpin */
            bool msg_is_pinned = is_msg_pinned (msg_id);
            var pin_btn = new Gtk.Button.with_label (msg_is_pinned ? "Unpin" : "Pin");
            pin_btn.add_css_class ("flat");
            pin_btn.clicked.connect (() => {
                popover.popdown ();
                toggle_message_pin (msg_id);
            });
            vbox.append (pin_btn);

            /* Save file (for messages with attachments) */
            var m_save = find_message (message_store, msg_id);
            if (m_save != null && m_save.file_path != null && m_save.file_path.length > 0) {
                string fpath = m_save.file_path;
                string? fname = m_save.file_name;
                var save_btn = new Gtk.Button.with_label ("Save file");
                save_btn.add_css_class ("flat");
                save_btn.clicked.connect (() => {
                    popover.popdown ();
                    save_attachment.begin (fpath, fname);
                });
                vbox.append (save_btn);
            }

            if (is_outgoing) {
                /* Allow editing only if the message has text */
                bool has_text = false;
                var m_edit = find_message (message_store, msg_id);
                if (m_edit != null) {
                    has_text = (m_edit.text != null && m_edit.text.strip ().length > 0);
                }
                if (has_text) {
                    var edit_btn = new Gtk.Button.with_label ("Edit");
                    edit_btn.add_css_class ("flat");
                    edit_btn.clicked.connect (() => {
                        popover.popdown ();
                        start_editing_message (msg_id);
                    });
                    vbox.append (edit_btn);
                }
            }


            string[] emojis = { "👍", "❤️", "😂", "😮", "😢", "👎" };
            var emoji_row1 = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            var emoji_row2 = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            for (int i = 0; i < emojis.length; i++) {
                string emoji = emojis[i];
                var btn = new Gtk.Button.with_label (emoji);
                btn.add_css_class ("flat");
                btn.clicked.connect (() => {
                    popover.popdown ();
                    do_send_reaction.begin (msg_id, emoji);
                });
                if (i < 3) emoji_row1.append (btn);
                else emoji_row2.append (btn);
            }
            vbox.append (emoji_row1);
            vbox.append (emoji_row2);

            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var del_me_btn = new Gtk.Button.with_label ("Delete for me");
            del_me_btn.add_css_class ("flat");
            del_me_btn.clicked.connect (() => {
                popover.popdown ();
                do_delete_message.begin (msg_id, false);
            });
            vbox.append (del_me_btn);

            if (is_outgoing) {
                var del_all_btn = new Gtk.Button.with_label ("Delete for everyone");
                del_all_btn.add_css_class ("flat");
                del_all_btn.clicked.connect (() => {
                    popover.popdown ();
                    do_delete_message.begin (msg_id, true);
                });
                vbox.append (del_all_btn);
            }

            popover.child = vbox;
            popover.set_parent (message_listview);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
        }

        private async void do_send_reaction (int msg_id, string emoji) {
            try {
                yield rpc.send_reaction (rpc.account_id, msg_id,
                                          new string[] { emoji });
                yield update_message_row (msg_id);
            } catch (Error e) {
                show_toast ("Reaction failed: " + e.message);
            }
        }

        private async void do_delete_message (int msg_id, bool for_all) {
            try {
                if (for_all) {
                    yield rpc.delete_messages_for_all (rpc.account_id, new int[] { msg_id });
                } else {
                    yield rpc.delete_messages (rpc.account_id, new int[] { msg_id });
                }
                int idx = find_message_index (message_store, msg_id);
                if (idx >= 0) message_store.remove (idx);
            } catch (Error e) {
                show_toast ("Delete failed: " + e.message);
            }
        }

        /* ================================================================
         *  Pinned Messages
         * ================================================================ */

        private bool is_msg_pinned (int msg_id) {
            foreach (int id in pinned_msg_ids) {
                if (id == msg_id) return true;
            }
            return false;
        }

        private void toggle_message_pin (int msg_id) {
            if (is_msg_pinned (msg_id)) {
                int[] new_ids = {};
                foreach (int id in pinned_msg_ids) {
                    if (id != msg_id) new_ids += id;
                }
                pinned_msg_ids = new_ids;
            } else {
                pinned_msg_ids += msg_id;
            }
            save_pinned_for_chat (current_chat_id, pinned_msg_ids);

            var m = find_message (message_store, msg_id);
            if (m != null) {
                m.is_pinned = is_msg_pinned (msg_id);
                refresh_message_in_store (msg_id);
            }
            update_pinned_bar ();
        }

        private void update_pinned_bar () {
            /* Clear existing pinned entries */
            Gtk.Widget? child;
            while ((child = pinned_bar_content.get_first_child ()) != null) {
                pinned_bar_content.remove (child);
            }

            if (pinned_msg_ids.length == 0) {
                pinned_revealer.reveal_child = false;
                return;
            }

            foreach (int pin_id in pinned_msg_ids) {
                string? text = null;
                string? sender = null;

                /* Find the message in the backing store */
                var m = find_message (message_store, pin_id);
                if (m != null) {
                    text = m.text;
                    sender = m.is_outgoing ? "You" : (m.sender_name ?? "");
                }

                if (text == null && sender == null) continue;

                var row_btn = new Gtk.Button ();
                row_btn.add_css_class ("flat");

                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

                var pin_icon = new Gtk.Label ("📌");
                row_box.append (pin_icon);

                var text_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                text_box.hexpand = true;

                if (sender != null && sender.length > 0) {
                    var sender_lbl = new Gtk.Label (sender);
                    sender_lbl.add_css_class ("caption");
                    sender_lbl.add_css_class ("dim-label");
                    sender_lbl.halign = Gtk.Align.START;
                    text_box.append (sender_lbl);
                }

                var text_lbl = new Gtk.Label (text ?? "(attachment)");
                text_lbl.halign = Gtk.Align.START;
                text_lbl.ellipsize = Pango.EllipsizeMode.END;
                text_lbl.max_width_chars = 50;
                text_lbl.lines = 1;
                text_box.append (text_lbl);

                row_box.append (text_box);
                row_btn.child = row_box;

                int captured_id = pin_id;
                row_btn.clicked.connect (() => {
                    scroll_to_message (captured_id);
                });

                var outer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                outer.append (row_btn);
                row_btn.hexpand = true;

                var unpin_btn = new Gtk.Button.from_icon_name ("window-close-symbolic");
                unpin_btn.add_css_class ("flat");
                unpin_btn.add_css_class ("circular");
                unpin_btn.valign = Gtk.Align.CENTER;
                unpin_btn.tooltip_text = "Unpin";
                unpin_btn.clicked.connect (() => {
                    toggle_message_pin (captured_id);
                });
                outer.append (unpin_btn);

                pinned_bar_content.append (outer);
            }

            pinned_revealer.reveal_child = pinned_bar_content.get_first_child () != null;
        }

        private int[] load_pinned_for_chat (int chat_id) {
            int[] ids = {};
            var kf = new KeyFile ();
            try {
                kf.load_from_file (get_config_path (), KeyFileFlags.NONE);
                string key = "chat_%d".printf (chat_id);
                string val = kf.get_string ("PinnedMessages", key);
                foreach (string s in val.split (",")) {
                    string trimmed = s.strip ();
                    if (trimmed.length > 0) {
                        ids += int.parse (trimmed);
                    }
                }
            } catch (Error e) { /* no pinned messages for this chat */ }
            return ids;
        }

        private void save_pinned_for_chat (int chat_id, int[] ids) {
            string key = "chat_%d".printf (chat_id);
            save_setting_to_file ((kf) => {
                if (ids.length > 0) {
                    var sb = new StringBuilder ();
                    foreach (int id in ids) {
                        if (sb.len > 0) sb.append (",");
                        sb.append (id.to_string ());
                    }
                    kf.set_string ("PinnedMessages", key, sb.str);
                } else {
                    try {
                        kf.remove_key ("PinnedMessages", key);
                    } catch (Error e) { }
                }
            });
        }

        private void start_editing_message (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m != null) {
                compose_bar.begin_edit (msg_id, m.text ?? "");
            }
        }

        private void start_replying_message (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m != null) {
                string sender = m.is_outgoing ? "You" : (m.sender_name ?? "");
                string preview = m.text ?? "(attachment)";
                compose_bar.begin_reply (msg_id, sender, preview);
            }
        }

        private void scroll_to_message (int msg_id) {
            /* Find position in the filtered model */
            int pos = -1;
            for (uint i = 0; i < filtered_message_store.get_n_items (); i++) {
                var m = (Message) filtered_message_store.get_item (i);
                if (m.id == msg_id) { pos = (int) i; break; }
            }
            if (pos < 0) return;

            var msg = (Message) filtered_message_store.get_item (pos);
            msg.highlighted = true;
            message_listview.scroll_to (pos, Gtk.ListScrollFlags.FOCUS, null);
            stick_to_bottom = is_near_bottom ();
        }

        private void on_edit_message (int msg_id, string new_text) {
            do_edit_message.begin (msg_id, new_text);
        }

        private async void do_edit_message (int msg_id, string new_text) {
            try {
                yield rpc.send_edit_request (rpc.account_id, msg_id, new_text);
                yield update_message_row (msg_id);
            } catch (Error e) {
                show_toast ("Edit failed: " + e.message);
            }
        }

        private async void update_message_row (int msg_id) {
            try {
                var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                if (msg_obj == null) return;
                var msg = RpcClient.parse_message (msg_obj, self_email);
                int idx = find_message_index (message_store, msg_id);
                if (idx >= 0) {
                    message_store.remove (idx);
                    message_store.insert (idx, msg);
                }
            } catch (Error e) {
                /* Reaction will appear on next message reload */
            }
        }

        /* Notify the ListView to rebind a message by removing and reinserting it. */
        private void refresh_message_in_store (int msg_id) {
            int idx = find_message_index (message_store, msg_id);
            if (idx < 0) return;
            var m = (Message) message_store.get_item (idx);
            message_store.remove (idx);
            message_store.insert (idx, m);
        }

        private async void show_chat_info (int chat_id) {
            var dialog = new ChatInfoDialog (rpc, rpc.account_id, chat_id);

            dialog.chat_deleted.connect ((cid) => {
                show_toast ("Chat deleted");
                if (current_chat_id == cid) {
                    current_chat_id = 0;
                    content_stack.visible_child_name = "empty";
                }
                reload_chats ();
            });

            dialog.chat_changed.connect (() => {
                reload_chats ();
                if (current_chat_id == chat_id) {
                    reload_messages ();
                }
            });

            dialog.present (this);
        }

        private async void confirm_delete_chat (int chat_id) {
            /* Find chat name */
            string chat_name = "this chat";
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) {
                chat_name = entry.name;
            }

            var dialog = new Adw.AlertDialog (
                "Delete for Me",
                "Remove \"%s\" from your chat list? You may still receive messages if you are a group member.".printf (chat_name)
            );
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("delete", "Delete for Me");
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";

            dialog.response.connect ((resp) => {
                if (resp == "delete") {
                    do_delete_chat.begin (chat_id);
                }
            });

            dialog.present (this);
        }

        private async void do_delete_chat (int chat_id) {
            try {
                yield rpc.delete_chat (rpc.account_id, chat_id);
                show_toast ("Chat deleted");

                if (current_chat_id == chat_id) {
                    current_chat_id = 0;
                    content_stack.visible_child_name = "empty";
                }

                yield load_chats ();
            } catch (Error e) {
                show_toast ("Delete failed: " + e.message);
            }
        }

        /* ================================================================
         *  App Menu (Settings / About)
         * ================================================================ */

        private Gtk.Popover build_app_menu_popover () {
            var popover = new Gtk.Popover ();

            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            vbox.margin_start = 4;
            vbox.margin_end = 4;
            vbox.margin_top = 4;
            vbox.margin_bottom = 4;

            var new_chat_btn = new Gtk.Button.with_label ("New Chat");
            new_chat_btn.add_css_class ("flat");
            new_chat_btn.clicked.connect (() => {
                popover.popdown ();
                on_new_chat ();
            });
            vbox.append (new_chat_btn);

            var new_group_btn = new Gtk.Button.with_label ("New Group");
            new_group_btn.add_css_class ("flat");
            new_group_btn.clicked.connect (() => {
                popover.popdown ();
                on_new_group ();
            });
            vbox.append (new_group_btn);

            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var refresh_btn = new Gtk.Button.with_label ("Refresh");
            refresh_btn.add_css_class ("flat");
            refresh_btn.clicked.connect (() => {
                popover.popdown ();
                load_chats.begin ();
            });
            vbox.append (refresh_btn);

            var settings_btn = new Gtk.Button.with_label ("Settings");
            settings_btn.add_css_class ("flat");
            settings_btn.clicked.connect (() => {
                popover.popdown ();
                show_settings_dialog ();
            });
            vbox.append (settings_btn);

            var shortcuts_btn = new Gtk.Button.with_label ("Shortcuts");
            shortcuts_btn.add_css_class ("flat");
            shortcuts_btn.clicked.connect (() => {
                popover.popdown ();
                show_keyboard_shortcuts_dialog ();
            });
            vbox.append (shortcuts_btn);

            var about_btn = new Gtk.Button.with_label ("About");
            about_btn.add_css_class ("flat");
            about_btn.clicked.connect (() => {
                popover.popdown ();
                show_about_dialog ();
            });
            vbox.append (about_btn);

            popover.child = vbox;
            return popover;
        }

        private void show_about_dialog () {
            var about = new Adw.AboutDialog ();
            about.application_name = "Delta Chat";
            about.application_icon = "org.deltachat.Gnome";
            about.version = "0.1.0";
            about.developer_name = "pancake";
            about.developers = { "pancake" };
            about.license_type = Gtk.License.GPL_3_0;
            about.website = "https://delta.chat";
            about.issue_url = "https://github.com/nickolay/deltachat-gnome/issues";
            about.comments = "Native Delta Chat client for GNOME";
            about.present (this);
        }

        private void show_settings_dialog () {
            var dialog = new SettingsDialog (rpc, this);
            dialog.account_changed.connect (() => {
                reload_active_account.begin ();
            });
            dialog.present (this);
        }

        public async void reload_active_account () {
            if (rpc.account_id <= 0) {
                self_email = null;
                content_stack.visible_child_name = "empty";
                current_chat_id = 0;
                return;
            }
            try {
                self_email = yield rpc.get_config (rpc.account_id, "addr");
            } catch (Error e) {
                self_email = null;
            }
            current_chat_id = 0;
            content_stack.visible_child_name = "empty";
            yield load_chats ();
            yield load_profile_avatar ();
            if (!listening) {
                start_listener.begin ();
            }
        }

        /* ================================================================
         *  Keyboard Shortcuts
         * ================================================================ */

        private bool on_window_key_pressed (uint keyval, uint keycode,
                                            Gdk.ModifierType state) {
            /* Close fullscreen image viewer on any key */
            if (image_viewer_box.visible) {
                hide_image_viewer ();
                return true;
            }

            /* Escape: close message search if active */
            if (keyval == Gdk.Key.Escape) {
                if (message_search_revealer.reveal_child) {
                    message_search_revealer.reveal_child = false;
                    message_search_entry.text = "";
                    message_filter.changed (Gtk.FilterChange.DIFFERENT);
                    return true;
                }
                return false;
            }

            /* All other shortcuts require Ctrl */
            if ((state & Gdk.ModifierType.CONTROL_MASK) == 0) return false;

            switch (keyval) {
            case Gdk.Key.n:
            case Gdk.Key.N:
                on_new_chat ();
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
            case Gdk.Key.l:
            case Gdk.Key.L:
                if (current_chat_id > 0) {
                    scroll_to_bottom ();
                    compose_bar.grab_entry_focus ();
                }
                return true;
            }
            return false;
        }

        private void toggle_message_search () {
            if (current_chat_id <= 0) return;
            bool was_active = message_search_revealer.reveal_child;
            message_search_revealer.reveal_child = !was_active;
            if (!was_active) {
                message_search_entry.grab_focus ();
            } else {
                message_search_entry.text = "";
                message_filter.changed (Gtk.FilterChange.DIFFERENT);
            }
        }

        private void refresh_current_chat () {
            reload_chats ();
            if (current_chat_id > 0) {
                reload_messages ();
            }
        }

        private void show_quick_switch_dialog () {
            if (rpc.account_id <= 0) return;
            if (chat_store.get_n_items () == 0) return;

            var dialog = new Adw.Dialog ();
            dialog.title = "Switch Chat";
            dialog.content_width = 360;
            dialog.content_height = 400;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var header = new Adw.HeaderBar ();
            box.append (header);

            var inner = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            inner.margin_start = 12;
            inner.margin_end = 12;
            inner.margin_top = 8;
            inner.margin_bottom = 12;

            var entry = new Gtk.SearchEntry ();
            entry.placeholder_text = "Type to filter chats\u2026";
            entry.hexpand = true;
            inner.append (entry);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            var listbox = new Gtk.ListBox ();
            listbox.selection_mode = Gtk.SelectionMode.SINGLE;
            listbox.add_css_class ("boxed-list");
            scroll.child = listbox;
            inner.append (scroll);

            /* Populate with all chats */
            for (uint i = 0; i < chat_store.get_n_items (); i++) {
                var chat = (ChatEntry) chat_store.get_item (i);
                var row = new Adw.ActionRow ();
                row.title = chat.name;
                if (chat.last_message != null && chat.last_message.length > 0)
                    row.subtitle = chat.last_message;
                row.name = chat.id.to_string ();
                row.activatable = true;
                var avatar = new Adw.Avatar (32, chat.name, true);
                if (chat.avatar_path != null &&
                    FileUtils.test (chat.avatar_path, FileTest.EXISTS)) {
                    try {
                        avatar.custom_image = Gdk.Texture.from_filename (chat.avatar_path);
                    } catch (Error e) { /* fallback */ }
                }
                row.add_prefix (avatar);
                listbox.append (row);
            }

            /* Filter */
            listbox.set_filter_func ((row) => {
                string query = entry.text.strip ().down ();
                if (query.length == 0) return true;
                var action_row = row as Adw.ActionRow;
                if (action_row == null) return true;
                return action_row.title.down ().contains (query);
            });

            entry.search_changed.connect (() => {
                listbox.invalidate_filter ();
            });

            /* Enter picks the first matching chat */
            entry.activate.connect (() => {
                string query = entry.text.strip ().down ();
                for (uint i = 0; i < chat_store.get_n_items (); i++) {
                    var chat = (ChatEntry) chat_store.get_item (i);
                    if (query.length == 0 || chat.name.down ().contains (query)) {
                        dialog.close ();
                        select_chat_by_id (chat.id);
                        return;
                    }
                }
            });

            /* Click on a row */
            listbox.row_activated.connect ((row) => {
                var action_row = row as Adw.ActionRow;
                if (action_row == null) return;
                int chat_id = int.parse (action_row.name);
                dialog.close ();
                select_chat_by_id (chat_id);
            });

            /* Escape dismisses the dialog (SearchEntry would otherwise
             * swallow the key to clear its text). */
            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            key_ctrl.key_pressed.connect ((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    dialog.close ();
                    return true;
                }
                return false;
            });
            box.add_controller (key_ctrl);

            box.append (inner);
            dialog.child = box;
            dialog.present (this);
            entry.grab_focus ();
        }

        private void select_chat_by_id (int chat_id) {
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

        private void show_keyboard_shortcuts_dialog () {
            var dialog = new Adw.Dialog ();
            dialog.title = "Shortcuts";
            dialog.content_width = 400;
            dialog.content_height = 380;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var header = new Adw.HeaderBar ();
            box.append (header);

            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.margin_start = 12;
            list.margin_end = 12;
            list.margin_top = 12;
            list.margin_bottom = 12;

            add_shortcut_row (list, "New chat", "<Control>n");
            add_shortcut_row (list, "Open settings", "<Control>comma");
            add_shortcut_row (list, "Search in conversation", "<Control>f");
            add_shortcut_row (list, "Quick switch chat", "<Control>k");
            add_shortcut_row (list, "Refresh messages", "<Control>r");
            add_shortcut_row (list, "Focus message entry", "<Control>l");
            add_shortcut_row (list, "Close window", "<Control>w");
            add_shortcut_row (list, "Quit application", "<Control>q");

            box.append (list);
            dialog.child = box;
            dialog.present (this);
        }

        private void add_shortcut_row (Gtk.ListBox list, string description,
                                       string accel) {
            var row = new Adw.ActionRow ();
            row.title = description;
            var label = new Gtk.ShortcutLabel (accel);
            label.valign = Gtk.Align.CENTER;
            row.add_suffix (label);
            list.append (row);
        }

        /* ================================================================
         *  Double-click action
         * ================================================================ */

        private void handle_message_double_click_id (int msg_id) {
            switch (double_click_action) {
            case 0: /* Reply */
                start_replying_message (msg_id);
                break;
            case 1: /* React with heart */
                do_send_reaction.begin (msg_id, "❤️");
                break;
            case 2: /* React with thumbsup */
                do_send_reaction.begin (msg_id, "👍");
                break;
            case 3: /* Open user profile */
                open_sender_profile.begin (msg_id);
                break;
            case 4: /* Nothing */
                break;
            }
        }

        private async void open_sender_profile (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m == null || m.sender_address == null || m.is_outgoing) return;
            try {
                int contact_id = yield rpc.lookup_contact (
                    rpc.account_id, m.sender_address);
                if (contact_id <= 0) return;
                int chat_id = yield rpc.get_or_create_chat_by_contact (
                    rpc.account_id, contact_id);
                if (chat_id > 0) {
                    yield load_chats ();
                    select_chat_by_id (chat_id);
                }
            } catch (Error e) {
                show_toast ("Could not open profile: " + e.message);
            }
        }

        /* ================================================================
         *  Settings persistence
         * ================================================================ */

        private static string get_config_path () {
            return Path.build_filename (
                Environment.get_user_config_dir (),
                "deltachat-gnome", "settings.ini");
        }

        public void save_double_click_action (int action) {
            double_click_action = action;
            save_setting_to_file ((kf) => {
                kf.set_integer ("General", "double_click_action", action);
            });
        }

        public void save_markdown_rendering (bool enabled) {
            markdown_rendering = enabled;
            Markdown.enabled = enabled;
            save_setting_to_file ((kf) => {
                kf.set_boolean ("General", "markdown_rendering", enabled);
            });
        }

        public void save_shift_enter_sends (bool enabled) {
            shift_enter_sends = enabled;
            ComposeBar.shift_enter_sends = enabled;
            save_setting_to_file ((kf) => {
                kf.set_boolean ("General", "shift_enter_sends", enabled);
            });
        }

        public void save_notifications_enabled (bool enabled) {
            notifications_enabled = enabled;
            save_setting_to_file ((kf) => {
                kf.set_boolean ("General", "notifications_enabled", enabled);
            });
        }

        private delegate void SettingWriter (KeyFile kf);

        private void save_setting_to_file (SettingWriter writer) {
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

        private void load_settings () {
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

        /* ================================================================
         *  Utilities
         * ================================================================ */

        private void show_toast (string message) {
            var toast = new Adw.Toast (message);
            toast.timeout = 4;

            /* Find or create toast overlay */
            /* For simplicity, use the application window's built-in toast support */
            toast_overlay.add_toast (toast);
        }

        private async void nap (uint ms) {
            Timeout.add (ms, nap.callback);
            yield;
        }
    }
}
