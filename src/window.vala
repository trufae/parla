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

        /* Status */
        private Adw.StatusPage empty_status;
        private Gtk.Stack content_stack;

        /* State */
        private int current_chat_id = 0;
        private string? self_email = null;
        private bool listening = false;

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
            sidebar_header.title_widget = new Adw.WindowTitle ("Delta Chat", "");

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

            message_listbox = new Gtk.ListBox ();
            message_listbox.selection_mode = Gtk.SelectionMode.NONE;
            message_listbox.add_css_class ("boxed-list-separate");
            message_listbox.set_header_func (null);
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
            msg_box.append (message_scroll);

            compose_bar = new ComposeBar ();
            compose_bar.send_message.connect (on_send_message);
            msg_box.append (compose_bar);

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
                    string kind = acct.has_member ("kind")
                        ? acct.get_string_member ("kind") : "unknown";
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

                for (uint i = 0; i < entries.get_length (); i++) {
                    int chat_id = (int) entries.get_int_element (i);
                    string id_str = chat_id.to_string ();

                    if (items != null && items.has_member (id_str)) {
                        var item = items.get_object_member (id_str);
                        var entry = RpcClient.parse_chat_item (chat_id, item);
                        chat_store.append (entry);

                        var chat_row = new ChatRow (entry);
                        chat_listbox.append (chat_row);
                    }
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

            current_chat_id = chat_row.chat_id;

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

            /* On narrow layout, navigate to content */
            split_view.show_content = true;
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

                /* Clear existing messages */
                message_store.remove_all ();
                Gtk.ListBoxRow? row;
                while ((row = message_listbox.get_row_at_index (0)) != null) {
                    message_listbox.remove (row);
                }

                /* Load messages (last 100 max for performance) */
                uint start = msg_ids.get_length () > 100
                    ? msg_ids.get_length () - 100 : 0;

                for (uint i = start; i < msg_ids.get_length (); i++) {
                    int msg_id = (int) msg_ids.get_int_element (i);
                    var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                    if (msg_obj == null) continue;

                    var msg = RpcClient.parse_message (msg_obj, self_email);
                    message_store.append (msg);

                    var msg_row = new MessageRow (msg);
                    message_listbox.append (msg_row);
                }

                scroll_to_bottom ();
            } catch (Error e) {
                show_toast ("Failed to load messages: " + e.message);
            }
        }

        private ulong scroll_handler_id = 0;

        private void scroll_to_bottom () {
            var adj = message_scroll.vadjustment;
            /* If already at bottom or content fits, set directly */
            if (adj.upper <= adj.page_size) return;

            /* Connect a one-shot handler on the adjustment's "changed" signal
               which fires after the layout pass updates upper/page_size. */
            if (scroll_handler_id != 0) {
                adj.disconnect (scroll_handler_id);
            }
            scroll_handler_id = adj.changed.connect (() => {
                adj.value = adj.upper - adj.page_size;
                adj.disconnect (scroll_handler_id);
                scroll_handler_id = 0;
            });
            /* Also try immediately in case layout is already done */
            adj.value = adj.upper - adj.page_size;
        }

        /* ================================================================
         *  Sending
         * ================================================================ */

        private void on_send_message (string text, string? file_path) {
            if (current_chat_id <= 0) return;
            do_send.begin (text, file_path);
        }

        private async void do_send (string text, string? file_path) {
            var rpc = ((Dc.Application) this.application).rpc;
            try {
                string? send_text = text.length > 0 ? text : null;
                string? send_file = file_path;
                string? send_name = null;
                if (send_file != null) {
                    send_name = Path.get_basename (send_file);
                }

                int msg_id = yield rpc.send_msg (rpc.account_id, current_chat_id,
                                                  send_text, send_file, send_name);

                /* Append the sent message directly instead of reloading all */
                if (msg_id > 0) {
                    var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                    if (msg_obj != null) {
                        var msg = RpcClient.parse_message (msg_obj, self_email);
                        message_store.append (msg);
                        message_listbox.append (new MessageRow (msg));
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
         *  Message Listener
         * ================================================================ */

        private async void start_listener () {
            if (listening) return;
            listening = true;

            var rpc = ((Dc.Application) this.application).rpc;

            while (rpc.is_connected && rpc.account_id > 0) {
                try {
                    int[] new_ids = yield rpc.wait_next_msgs (rpc.account_id);

                    foreach (int msg_id in new_ids) {
                        var msg_obj = yield rpc.get_message (rpc.account_id, msg_id);
                        if (msg_obj == null) continue;

                        var msg = RpcClient.parse_message (msg_obj, self_email);

                        /* Skip self messages and info messages without text */
                        if (msg.is_outgoing) continue;
                        if (msg.text == null && msg.file_path == null) continue;

                        /* Mark as seen */
                        yield rpc.mark_seen_msgs (rpc.account_id, new int[] { msg_id });

                        /* If this message belongs to current chat, append it */
                        if (msg.chat_id == current_chat_id) {
                            message_store.append (msg);
                            var row = new MessageRow (msg);
                            message_listbox.append (row);
                            row.highlight ();
                            scroll_to_bottom ();
                        }

                        /* Refresh chat list to update previews */
                        yield load_chats ();
                    }
                } catch (Error e) {
                    if (rpc.is_connected) {
                        warning ("Listener error: %s", e.message);
                        /* Brief pause before retry */
                        yield nap (1000);
                    }
                }
            }

            listening = false;
        }

        /* ================================================================
         *  Actions
         * ================================================================ */

        private void on_new_chat () {
            /* Simple dialog to create a new chat by email */
            var dialog = new Adw.AlertDialog (
                "New Chat",
                "Enter the email address of the person you want to chat with."
            );

            var entry = new Gtk.Entry ();
            entry.placeholder_text = "user@example.com";
            entry.input_purpose = Gtk.InputPurpose.EMAIL;
            dialog.extra_child = entry;

            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("create", "Create");
            dialog.set_response_appearance ("create", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "create";

            entry.activate.connect (() => {
                dialog.response ("create");
            });

            dialog.response.connect ((resp) => {
                if (resp == "create") {
                    string email = entry.text.strip ();
                    if (email.length > 0 && email.contains ("@")) {
                        create_chat_by_email.begin (email);
                    }
                }
            });

            dialog.present (this);
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
            menu.append ("Delete Chat", "win.chat-delete");

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
                        var new_row = new MessageRow (msg);
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
                "Delete Chat",
                "Delete \"%s\"? This cannot be undone.".printf (chat_name)
            );
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("delete", "Delete");
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
