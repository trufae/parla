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
        private Gtk.ListBox message_listbox;
        private Gtk.ScrolledWindow message_scroll;
        private GLib.ListStore message_store;
        private ComposeBar compose_bar;

        /* Message search */
        private Gtk.Revealer message_search_revealer;
        private Gtk.SearchEntry message_search_entry;

        /* Status */
        private Adw.StatusPage empty_status;
        private Gtk.Stack content_stack;

        /* State */
        private int current_chat_id = 0;
        private string? self_email = null;
        private bool listening = false;
        private bool stick_to_bottom = true;

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

            /* Click on title to show app menu (Settings / About) */
            var title_click = new Gtk.GestureClick ();
            title_click.button = 0; /* any button */
            title_click.pressed.connect ((n, x, y) => {
                show_app_menu (title_widget, x, y);
            });
            title_widget.add_controller (title_click);

            /* New chat button in header */
            var new_chat_btn = new Gtk.Button.from_icon_name ("list-add-symbolic");
            new_chat_btn.tooltip_text = "New chat";
            new_chat_btn.clicked.connect (on_new_chat);
            sidebar_header.pack_start (new_chat_btn);

            /* New group button */
            var new_group_btn = new Gtk.Button.from_icon_name ("system-users-symbolic");
            new_group_btn.tooltip_text = "New group";
            new_group_btn.clicked.connect (on_new_group);
            sidebar_header.pack_start (new_group_btn);

            /* Refresh button */
            var refresh_btn = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
            refresh_btn.tooltip_text = "Refresh chats";
            refresh_btn.clicked.connect (() => { load_chats.begin (); });
            sidebar_header.pack_end (refresh_btn);

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
            message_scroll.vadjustment.notify["upper"].connect (() => { maybe_autoscroll (); });
            message_scroll.vadjustment.notify["page-size"].connect (() => { maybe_autoscroll (); });
            message_scroll.vadjustment.notify["value"].connect (() => {
                stick_to_bottom = is_near_bottom ();
            });

            message_listbox = new Gtk.ListBox ();
            message_listbox.selection_mode = Gtk.SelectionMode.NONE;
            message_listbox.add_css_class ("boxed-list-separate");
            message_listbox.set_header_func (null);
            message_listbox.set_filter_func ((row) => {
                if (!message_search_revealer.reveal_child) return true;
                string query = message_search_entry.text.strip ().down ();
                if (query.length == 0) return true;
                var msg_row = row as MessageRow;
                if (msg_row == null) return true;
                return msg_row.message_text != null
                    && msg_row.message_text.down ().contains (query);
            });
            message_listbox.row_activated.connect (on_message_row_activated);

            /* Right-click context menu for reactions */
            var msg_right_click = new Gtk.GestureClick ();
            msg_right_click.button = 3;
            msg_right_click.pressed.connect ((n, x, y) => {
                var row = message_listbox.get_row_at_y ((int) y);
                if (row == null) return;
                var msg_row = row as MessageRow;
                if (msg_row == null) return;
                show_message_context_menu (msg_row.message_id, msg_row.is_outgoing, x, y);
            });
            message_listbox.add_controller (msg_right_click);

            message_scroll.child = message_listbox;

            /* Message search bar (toggled by Ctrl+F) */
            message_search_entry = new Gtk.SearchEntry ();
            message_search_entry.placeholder_text = "Search in conversation\u2026";
            message_search_entry.hexpand = true;
            message_search_entry.margin_start = 8;
            message_search_entry.margin_end = 8;
            message_search_entry.margin_top = 4;
            message_search_entry.margin_bottom = 4;
            message_search_entry.search_changed.connect (() => {
                message_listbox.invalidate_filter ();
            });
            message_search_revealer = new Gtk.Revealer ();
            message_search_revealer.child = message_search_entry;
            message_search_revealer.reveal_child = false;
            message_search_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
            msg_box.append (message_search_revealer);

            msg_box.append (message_scroll);

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
            this.content = toast_overlay;

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
            var app = (Dc.Application) this.application;

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
                yield app.rpc.start (rpc_cmd, data_dir, accounts_path);
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
            yield ensure_account (app.rpc);

            if (app.rpc.account_id > 0) {
                try {
                    self_email = yield app.rpc.get_config (app.rpc.account_id, "addr");
                } catch (Error ce) {
                    self_email = null;
                }
                yield load_chats ();
                start_listener.begin ();

                var title = (Adw.WindowTitle) sidebar_header.title_widget;
                title.subtitle = self_email ?? "Connected";
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
            var rpc = ((Dc.Application) this.application).rpc;
            if (rpc.account_id <= 0) return;

            try {
                var entries = yield rpc.get_chatlist_entries (rpc.account_id);
                if (entries == null) return;

                /* Get details for all entries */
                var items = yield rpc.get_chatlist_items_by_entries (rpc.account_id, entries);

                /* Clear and rebuild chat list */
                chat_store.remove_all ();

                /* Remove old rows */
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

                /* Re-select the active chat so it stays highlighted */
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

            /* Find matching ChatEntry in store */
            for (uint i = 0; i < chat_store.get_n_items (); i++) {
                var entry = (ChatEntry) chat_store.get_item (i);
                if (entry.id == chat_row.chat_id) {
                    return entry.name.down ().contains (query);
                }
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
            for (uint i = 0; i < chat_store.get_n_items (); i++) {
                var entry = (ChatEntry) chat_store.get_item (i);
                if (entry.id == current_chat_id) {
                    content_title_label.label = entry.name;
                    break;
                }
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
            var rpc = ((Dc.Application) this.application).rpc;
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
            var rpc = ((Dc.Application) this.application).rpc;
            if (rpc.account_id <= 0) return;

            try {
                var msg_ids = yield rpc.get_message_ids (rpc.account_id, chat_id);
                if (msg_ids == null) return;

                /* Fetch all messages first, then populate in one
                   synchronous pass to avoid listener interference. */
                uint start = msg_ids.get_length () > 100
                    ? msg_ids.get_length () - 100 : 0;

                var messages = new GLib.GenericArray<Message> ();
                for (uint i = start; i < msg_ids.get_length (); i++) {
                    int msg_id = (int) msg_ids.get_int_element (i);
                    var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                    if (msg_obj == null) continue;
                    messages.add (RpcClient.parse_message (msg_obj, self_email));
                }

                /* Discard if the user switched chats while fetching. */
                if (chat_id != current_chat_id) return;

                /* Clear and populate in one synchronous pass.
                   Messages are already sorted by the RPC, so append(). */
                message_store.remove_all ();
                Gtk.ListBoxRow? row;
                while ((row = message_listbox.get_row_at_index (0)) != null) {
                    message_listbox.remove (row);
                }

                for (uint i = 0; i < messages.length; i++) {
                    var msg = messages[i];
                    message_store.append (msg);
                    message_listbox.append (create_message_row (msg));
                }

                /* Defer scroll until GTK has laid out the new rows,
                   otherwise the adjustment upper is stale. */
                stick_to_bottom = true;
                Idle.add (() => {
                    scroll_to_bottom ();
                    return Source.REMOVE;
                });
            } catch (Error e) {
                show_toast ("Failed to load messages: " + e.message);
            }
        }

        private bool is_near_bottom () {
            var adj = message_scroll.vadjustment;
            if (adj.upper <= adj.page_size) return true;
            return (adj.upper - adj.value - adj.page_size) < 80;
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

        private MessageRow create_message_row (Message msg) {
            var row = new MessageRow (msg);
            row.quote_clicked.connect ((qid) => { scroll_to_message (qid); });
            return row;
        }

        /* Insert a message row at the correct chronological position. */
        private void insert_message_sorted (MessageRow row) {
            /* Fast path: new message is newer than the last row. */
            int count = (int) message_store.get_n_items ();
            if (count > 0) {
                var last = message_listbox.get_row_at_index (count - 1) as MessageRow;
                if (last != null && (row.timestamp > last.timestamp ||
                    (row.timestamp == last.timestamp
                     && row.message_id >= last.message_id))) {
                    message_listbox.append (row);
                    return;
                }
            }
            /* Slow path: find the correct position. */
            int pos = 0;
            Gtk.ListBoxRow? existing;
            while ((existing = message_listbox.get_row_at_index (pos)) != null) {
                var mr = existing as MessageRow;
                if (mr != null && (mr.timestamp > row.timestamp ||
                    (mr.timestamp == row.timestamp && mr.message_id > row.message_id))) {
                    message_listbox.insert (row, pos);
                    return;
                }
                pos++;
            }
            message_listbox.append (row);
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
            var rpc = ((Dc.Application) this.application).rpc;
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
                        message_store.append (msg);
                        insert_message_sorted (create_message_row (msg));
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

        private void on_message_row_activated (Gtk.ListBoxRow row) {
            var msg_row = row as MessageRow;
            if (msg_row == null || msg_row.file_path == null) return;
            if (!FileUtils.test (msg_row.file_path, FileTest.EXISTS)) {
                show_toast ("File not available");
                return;
            }
            save_attachment.begin (msg_row.file_path, msg_row.file_name);
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
         *  Event Loop
         * ================================================================ */

        private async void start_listener () {
            if (listening) return;
            listening = true;

            var rpc = ((Dc.Application) this.application).rpc;

            while (rpc.is_connected) {
                try {
                    var ev = yield rpc.get_next_event ();
                    if (ev == null) continue;

                    int ctx = (int) ev.get_int_member ("contextId");
                    if (ctx != rpc.account_id) continue;

                    var event = ev.get_object_member ("event");
                    if (event == null) continue;

                    string kind = event.get_string_member ("kind");
                    yield handle_event (kind, event);
                } catch (Error e) {
                    if (rpc.is_connected) {
                        warning ("Event loop error: %s", e.message);
                        yield nap (1000);
                    }
                }
            }

            listening = false;
        }

        private async void handle_event (string kind, Json.Object event) {
            switch (kind) {
            case "IncomingMsg":
                int chat_id = (int) event.get_int_member ("chatId");
                int msg_id = (int) event.get_int_member ("msgId");
                yield on_incoming_msg (chat_id, msg_id);
                break;

            case "MsgsChanged":
                int changed_chat = (int) event.get_int_member ("chatId");
                /* Broad change or change in the current chat — reload messages */
                if (changed_chat == 0 || changed_chat == current_chat_id) {
                    if (current_chat_id > 0) {
                        yield load_messages (current_chat_id);
                    }
                }
                break;

            case "MsgDelivered":
            case "MsgRead":
            case "MsgFailed":
                int state_chat = (int) event.get_int_member ("chatId");
                if (state_chat == current_chat_id && current_chat_id > 0) {
                    yield load_messages (current_chat_id);
                }
                break;

            case "MsgDeleted":
                int del_chat = (int) event.get_int_member ("chatId");
                if (del_chat == current_chat_id && current_chat_id > 0) {
                    yield load_messages (current_chat_id);
                }
                break;

            case "ChatlistChanged":
                yield load_chats ();
                break;

            case "ChatlistItemChanged":
                /* Could do selective update, but full reload is simple and correct */
                yield load_chats ();
                break;

            case "MsgsNoticed":
                yield load_chats ();
                break;

            case "ChatModified":
            case "ChatDeleted":
                yield load_chats ();
                break;

            case "ReactionsChanged":
                int rx_chat = (int) event.get_int_member ("chatId");
                if (rx_chat == current_chat_id && current_chat_id > 0) {
                    yield load_messages (current_chat_id);
                }
                break;

            default:
                /* Info, Warning, ConnectivityChanged, etc. — ignore */
                break;
            }
        }

        private async void on_incoming_msg (int chat_id, int msg_id) {
            var rpc = ((Dc.Application) this.application).rpc;

            if (chat_id == current_chat_id && current_chat_id > 0) {
                /* Message is in the active chat — show it and mark seen */
                try {
                    var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                    if (msg_obj != null) {
                        var msg = RpcClient.parse_message (msg_obj, self_email);
                        message_store.append (msg);
                        var row = create_message_row (msg);
                        insert_message_sorted (row);
                        row.highlight ();
                    }
                    yield rpc.mark_seen_msgs (rpc.account_id, new int[] { msg_id });
                } catch (Error e) {
                    warning ("Failed to handle incoming msg: %s", e.message);
                }
            }
            /* For all incoming messages (current chat or not), refresh the
               chat list to update preview text and unread counters. */
            yield load_chats ();
        }

        /* ================================================================
         *  Actions
         * ================================================================ */

        private void on_new_chat () {
            var rpc = ((Dc.Application) this.application).rpc;
            if (rpc.account_id <= 0) return;

            var picker = new ContactPickerDialog (rpc, rpc.account_id);
            picker.contact_picked.connect ((contact_id, email) => {
                create_chat_by_email.begin (email);
            });
            picker.present (this);
        }

        private async void create_chat_by_email (string email) {
            var rpc = ((Dc.Application) this.application).rpc;
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
            var rpc = ((Dc.Application) this.application).rpc;
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
            var menu = new GLib.Menu ();
            menu.append ("Chat Info", "win.chat-info");
            menu.append ("Delete for Me", "win.chat-delete");

            /* Set up actions with the chat_id */
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
            group.add_action (info_action);
            group.add_action (delete_action);
            this.insert_action_group ("win", group);

            var popover = new Gtk.PopoverMenu.from_model (menu);
            popover.set_parent (chat_listbox);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
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

            if (is_outgoing) {
                /* Allow editing only if the message has text */
                bool has_text = false;
                for (uint i = 0; i < message_store.get_n_items (); i++) {
                    var m = (Message) message_store.get_item (i);
                    if (m.id == msg_id) {
                        has_text = (m.text != null && m.text.strip ().length > 0);
                        break;
                    }
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
            popover.set_parent (message_listbox);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
        }

        private async void do_send_reaction (int msg_id, string emoji) {
            var rpc = ((Dc.Application) this.application).rpc;
            try {
                yield rpc.send_reaction (rpc.account_id, msg_id,
                                          new string[] { emoji });
                yield update_message_row (msg_id);
            } catch (Error e) {
                show_toast ("Reaction failed: " + e.message);
            }
        }

        private async void do_delete_message (int msg_id, bool for_all) {
            var rpc = ((Dc.Application) this.application).rpc;
            try {
                if (for_all) {
                    yield rpc.delete_messages_for_all (rpc.account_id, new int[] { msg_id });
                } else {
                    yield rpc.delete_messages (rpc.account_id, new int[] { msg_id });
                }
                /* Remove the row from the UI */
                int idx = 0;
                Gtk.ListBoxRow? row;
                while ((row = message_listbox.get_row_at_index (idx)) != null) {
                    var mr = row as MessageRow;
                    if (mr != null && mr.message_id == msg_id) {
                        message_listbox.remove (row);
                        /* Also remove from the backing store */
                        for (uint i = 0; i < message_store.get_n_items (); i++) {
                            var m = (Message) message_store.get_item (i);
                            if (m.id == msg_id) {
                                message_store.remove (i);
                                break;
                            }
                        }
                        break;
                    }
                    idx++;
                }
            } catch (Error e) {
                show_toast ("Delete failed: " + e.message);
            }
        }

        private void start_editing_message (int msg_id) {
            /* Find the message text from the backing store */
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var m = (Message) message_store.get_item (i);
                if (m.id == msg_id) {
                    compose_bar.begin_edit (msg_id, m.text ?? "");
                    return;
                }
            }
        }

        private void start_replying_message (int msg_id) {
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var m = (Message) message_store.get_item (i);
                if (m.id == msg_id) {
                    string sender = m.is_outgoing ? "You" : (m.sender_name ?? "");
                    string preview = m.text ?? "(attachment)";
                    compose_bar.begin_reply (msg_id, sender, preview);
                    return;
                }
            }
        }

        private void scroll_to_message (int msg_id) {
            int idx = 0;
            Gtk.ListBoxRow? row;
            while ((row = message_listbox.get_row_at_index (idx)) != null) {
                var mr = row as MessageRow;
                if (mr != null && mr.message_id == msg_id) {
                    /* Scroll so the row is visible, then highlight it */
                    int row_y;
                    Graphene.Point pt;
                    if (row.compute_point (message_listbox, { 0, 0 }, out pt)) {
                        row_y = (int) pt.y;
                    } else {
                        row_y = idx * 60; /* rough fallback */
                    }
                    var adj = message_scroll.vadjustment;
                    double target = double.min (row_y, adj.upper - adj.page_size);
                    if (target < 0) target = 0;
                    adj.value = target;
                    stick_to_bottom = is_near_bottom ();
                    mr.highlight ();
                    return;
                }
                idx++;
            }
        }

        private void on_edit_message (int msg_id, string new_text) {
            do_edit_message.begin (msg_id, new_text);
        }

        private async void do_edit_message (int msg_id, string new_text) {
            var rpc = ((Dc.Application) this.application).rpc;
            try {
                yield rpc.send_edit_request (rpc.account_id, msg_id, new_text);
                yield update_message_row (msg_id);
            } catch (Error e) {
                show_toast ("Edit failed: " + e.message);
            }
        }

        private async void update_message_row (int msg_id) {
            var rpc = ((Dc.Application) this.application).rpc;
            try {
                var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                if (msg_obj == null) return;
                var msg = RpcClient.parse_message (msg_obj, self_email);

                int idx = 0;
                Gtk.ListBoxRow? row;
                while ((row = message_listbox.get_row_at_index (idx)) != null) {
                    var mr = row as MessageRow;
                    if (mr != null && mr.message_id == msg_id) {
                        message_listbox.remove (row);
                        var new_row = create_message_row (msg);
                        message_listbox.insert (new_row, idx);
                        return;
                    }
                    idx++;
                }
            } catch (Error e) {
                /* Reaction will appear on next message reload */
            }
        }

        private async void show_chat_info (int chat_id) {
            var rpc = ((Dc.Application) this.application).rpc;
            var dialog = new ChatInfoDialog (rpc, rpc.account_id, chat_id);

            dialog.chat_deleted.connect ((cid) => {
                show_toast ("Chat deleted");
                if (current_chat_id == cid) {
                    current_chat_id = 0;
                    content_stack.visible_child_name = "empty";
                }
                load_chats.begin ();
            });

            dialog.chat_changed.connect (() => {
                load_chats.begin ();
                if (current_chat_id == chat_id) {
                    load_messages.begin (chat_id);
                }
            });

            dialog.present (this);
        }

        private async void confirm_delete_chat (int chat_id) {
            /* Find chat name */
            string chat_name = "this chat";
            for (uint i = 0; i < chat_store.get_n_items (); i++) {
                var entry = (ChatEntry) chat_store.get_item (i);
                if (entry.id == chat_id) {
                    chat_name = entry.name;
                    break;
                }
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
            var rpc = ((Dc.Application) this.application).rpc;
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

        private void show_app_menu (Gtk.Widget anchor, double x, double y) {
            var popover = new Gtk.Popover ();

            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            vbox.margin_start = 4;
            vbox.margin_end = 4;
            vbox.margin_top = 4;
            vbox.margin_bottom = 4;

            var settings_btn = new Gtk.Button.with_label ("Settings");
            settings_btn.add_css_class ("flat");
            settings_btn.clicked.connect (() => {
                popover.popdown ();
                show_settings_dialog ();
            });
            vbox.append (settings_btn);

            var shortcuts_btn = new Gtk.Button.with_label ("Keyboard Shortcuts");
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
            popover.set_parent (anchor);
            popover.popup ();
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
            var rpc = ((Dc.Application) this.application).rpc;
            var dialog = new SettingsDialog (rpc, this);
            dialog.account_changed.connect (() => {
                reload_active_account.begin ();
            });
            dialog.present (this);
        }

        public async void reload_active_account () {
            var rpc = ((Dc.Application) this.application).rpc;
            if (rpc.account_id <= 0) {
                self_email = null;
                var title = (Adw.WindowTitle) sidebar_header.title_widget;
                title.subtitle = "";
                content_stack.visible_child_name = "empty";
                current_chat_id = 0;
                return;
            }
            try {
                self_email = yield rpc.get_config (rpc.account_id, "addr");
            } catch (Error e) {
                self_email = null;
            }
            var title = (Adw.WindowTitle) sidebar_header.title_widget;
            title.subtitle = self_email ?? "Connected";
            current_chat_id = 0;
            content_stack.visible_child_name = "empty";
            yield load_chats ();
            if (!listening) {
                start_listener.begin ();
            }
        }

        /* ================================================================
         *  Keyboard Shortcuts
         * ================================================================ */

        private bool on_window_key_pressed (uint keyval, uint keycode,
                                            Gdk.ModifierType state) {
            /* Escape: close message search if active */
            if (keyval == Gdk.Key.Escape) {
                if (message_search_revealer.reveal_child) {
                    message_search_revealer.reveal_child = false;
                    message_search_entry.text = "";
                    message_listbox.invalidate_filter ();
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
                message_listbox.invalidate_filter ();
            }
        }

        private void refresh_current_chat () {
            load_chats.begin ();
            if (current_chat_id > 0) {
                load_messages.begin (current_chat_id);
            }
        }

        private void show_quick_switch_dialog () {
            var rpc = ((Dc.Application) this.application).rpc;
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
            dialog.title = "Keyboard Shortcuts";
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
