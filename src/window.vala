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
        private bool search_toggling;

        /* Status */
        private Adw.StatusPage empty_status;
        private Gtk.Stack content_stack;

        /* Profile avatar */
        private Adw.Avatar profile_avatar;

        /* State */
        private unowned RpcClient rpc;
        private int _current_chat_id = 0;
        private int current_chat_id {
            get { return _current_chat_id; }
            set {
                _current_chat_id = value;
                if (events != null) events.active_chat_id = value;
            }
        }
        private string? self_email = null;
        private bool stick_to_bottom = true;
        private Json.Array? all_msg_ids = null;
        private uint loaded_start_index = 0;
        private bool loading_more = false;
        private bool loading_chat = false;

        /* Extracted managers */
        public SettingsManager settings;
        private ImageViewer image_viewer;
        private PinnedMessagesManager pinned;
        private EventHandler events;
        private MessageActions msg_actions;

        /* Modal dialog guard – only one at a time */
        private Adw.Dialog? active_modal = null;

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
            settings = new SettingsManager ();
            image_viewer = new ImageViewer ();
            image_viewer.save_requested.connect ((path, name) => {
                save_attachment.begin (path, name);
            });
            image_viewer.toast_requested.connect ((msg) => { show_toast (msg); });
            pinned = new PinnedMessagesManager (message_store, settings);
            pinned.scroll_requested.connect ((msg_id) => {
                scroll_to_message (msg_id);
            });
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
                    if (msg_actions != null)
                        msg_actions.show_context_menu (msg.id, msg.is_outgoing, x, y, row);
                });
                row.add_controller (rc);

                /* Double-click and single-click activation */
                var dc = new Gtk.GestureClick ();
                dc.button = 1;
                dc.pressed.connect ((n, x, y) => {
                    if (n == 2 && msg_actions != null)
                        msg_actions.handle_double_click (msg.id);
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
            msg_box.append (pinned.revealer);

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
            compose_bar.edit_message.connect ((msg_id, new_text) => {
                if (msg_actions != null)
                    msg_actions.edit_message.begin (msg_id, new_text);
            });
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
            var image_overlay = new Gtk.Overlay ();
            image_overlay.child = toast_overlay;
            image_overlay.add_overlay (image_viewer.widget);

            this.content = image_overlay;

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

            /* Create event handler and message actions now that rpc is ready */
            events = new EventHandler (rpc);
            events.chats_reload_fired.connect (() => { load_chats.begin (); });
            events.messages_reload_fired.connect (() => {
                if (current_chat_id > 0)
                    load_messages.begin (current_chat_id);
            });
            events.incoming_msg_received.connect ((chat_id, msg_id) => {
                on_incoming_msg.begin (chat_id, msg_id);
            });

            msg_actions = new MessageActions (rpc, message_store, pinned,
                                              compose_bar, settings);
            msg_actions.self_email = self_email;
            msg_actions.toast.connect ((msg) => { show_toast (msg); });
            msg_actions.save_file_requested.connect ((path, name) => {
                save_attachment.begin (path, name);
            });
            msg_actions.reload_chats_requested.connect (() => {
                load_chats.begin ();
            });
            msg_actions.select_chat_requested.connect ((chat_id) => {
                select_chat_by_id (chat_id);
            });

            if (rpc.account_id > 0) {
                try {
                    self_email = yield rpc.get_config (rpc.account_id, "addr");
                    msg_actions.self_email = self_email;
                } catch (Error ce) {
                    self_email = null;
                }
                yield load_chats ();
                yield load_profile_avatar ();
                events.start.begin ();
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

                loaded_start_index = all_msg_ids.get_length () > 30
                    ? all_msg_ids.get_length () - 30 : 0;

                var messages = yield fetch_messages_batch (
                    loaded_start_index, all_msg_ids.get_length ());

                if (chat_id != current_chat_id) return;

                pinned.load_for_chat (chat_id);

                loading_chat = true;
                stick_to_bottom = true;

                var batch = new GLib.Object[messages.length];
                for (uint i = 0; i < messages.length; i++) {
                    messages[i].is_pinned = pinned.is_pinned (messages[i].id);
                    batch[i] = messages[i];
                }
                message_store.splice (0, message_store.get_n_items (), batch);

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

                pinned.update_bar ();
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
            uint count = end - start;
            int[] ids = new int[count];
            for (uint i = 0; i < count; i++) {
                ids[i] = (int) all_msg_ids.get_int_element (start + i);
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
                    msg.is_pinned = pinned.is_pinned (msg.id);
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
                image_viewer.show (msg.file_path);
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
         *  Event Loop (delegates to EventHandler)
         * ================================================================ */

        private void reload_chats () {
            if (events != null) events.schedule_chats_reload ();
        }

        private void reload_messages () {
            if (events != null) events.schedule_messages_reload ();
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
            if (settings.notifications_enabled && !this.is_active) {
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
            if (active_modal != null) return;

            var picker = new ContactPickerDialog (rpc, rpc.account_id);
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
            if (active_modal != null) return;

            var dialog = new NewGroupDialog (rpc, rpc.account_id);
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
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
            add_action (pin_action);
            add_action (info_action);
            add_action (delete_action);

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

        private GLib.MenuModel build_app_menu () {
            var a_new_chat = new SimpleAction ("new-chat", null);
            a_new_chat.activate.connect (() => { on_new_chat (); });
            add_action (a_new_chat);

            var a_new_group = new SimpleAction ("new-group", null);
            a_new_group.activate.connect (() => { on_new_group (); });
            add_action (a_new_group);

            var a_refresh = new SimpleAction ("refresh", null);
            a_refresh.activate.connect (() => { load_chats.begin (); });
            add_action (a_refresh);

            var a_settings = new SimpleAction ("settings", null);
            a_settings.activate.connect (() => { show_settings_dialog (); });
            add_action (a_settings);

            var a_shortcuts = new SimpleAction ("shortcuts", null);
            a_shortcuts.activate.connect (() => { show_keyboard_shortcuts_dialog (); });
            add_action (a_shortcuts);

            var a_about = new SimpleAction ("about", null);
            a_about.activate.connect (() => { show_about_dialog (); });
            add_action (a_about);

            var section1 = new GLib.Menu ();
            section1.append ("New Chat", "win.new-chat");
            section1.append ("New Group", "win.new-group");

            var section2 = new GLib.Menu ();
            // section2.append ("Refresh", "win.refresh");
            section2.append ("Settings", "win.settings");
            var section3 = new GLib.Menu ();
            section3.append ("Shortcuts", "win.shortcuts");
            section3.append ("About", "win.about");

            var menu = new GLib.Menu ();
            menu.append_section (null, section1);
            menu.append_section (null, section2);
            menu.append_section (null, section3);

            return menu;
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
            if (active_modal != null) return;

            var dialog = new SettingsDialog (rpc, this);
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.account_changed.connect (() => {
                reload_active_account.begin ();
            });
            dialog.present (this);
        }

        public async void reload_active_account () {
            if (rpc.account_id <= 0) {
                self_email = null;
                if (msg_actions != null) msg_actions.self_email = null;
                content_stack.visible_child_name = "empty";
                current_chat_id = 0;
                return;
            }
            try {
                self_email = yield rpc.get_config (rpc.account_id, "addr");
            } catch (Error e) {
                self_email = null;
            }
            if (msg_actions != null) msg_actions.self_email = self_email;
            current_chat_id = 0;
            content_stack.visible_child_name = "empty";
            yield load_chats ();
            yield load_profile_avatar ();
            if (events != null && !events.is_listening) {
                events.start.begin ();
            }
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

            /* Escape: close message search if active */
            if (keyval == Gdk.Key.Escape) {
                if (message_search_revealer.reveal_child) {
                    message_search_revealer.reveal_child = false;
                    message_search_entry.text = "";
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
            if (current_chat_id <= 0 || search_toggling) return;
            search_toggling = true;
            bool was_active = message_search_revealer.reveal_child;
            message_search_revealer.reveal_child = !was_active;
            if (!was_active) {
                Idle.add (() => {
                    message_search_entry.grab_focus ();
                    search_toggling = false;
                    return Source.REMOVE;
                });
            } else {
                message_search_entry.text = "";
                Idle.add (() => {
                    search_toggling = false;
                    return Source.REMOVE;
                });
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
            if (active_modal != null) return;

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
            add_shortcut_row (list, "New group", "<Control>g");
            add_shortcut_row (list, "Open settings", "<Control>comma");
            add_shortcut_row (list, "Search in conversation", "<Control>f");
            add_shortcut_row (list, "Quick switch chat", "<Control>k");
            add_shortcut_row (list, "Refresh messages", "<Control>r");
            add_shortcut_row (list, "Focus message entry", "<Control>l");
            add_shortcut_row (list, "Close window", "<Control>w");
            add_shortcut_row (list, "Quit application", "<Control>q");

            box.append (list);
            dialog.child = box;
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
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
         *  Utilities
         * ================================================================ */

        private void show_toast (string message) {
            var toast = new Adw.Toast (message);
            toast.timeout = 4;

            /* Find or create toast overlay */
            /* For simplicity, use the application window's built-in toast support */
            toast_overlay.add_toast (toast);
        }

    }
}
