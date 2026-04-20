namespace Dc {

    public class MessageActions : Object {

        private unowned Window window;
        private unowned RpcClient rpc;
        private unowned GLib.ListStore message_store;
        private unowned PinnedMessagesManager pinned;
        private unowned ComposeBar compose_bar;
        private unowned SettingsManager settings;


        public MessageActions (Window window, RpcClient rpc,
                               GLib.ListStore message_store,
                               PinnedMessagesManager pinned,
                               ComposeBar compose_bar,
                               SettingsManager settings) {
            this.window = window;
            this.rpc = rpc;
            this.message_store = message_store;
            this.pinned = pinned;
            this.compose_bar = compose_bar;
            this.settings = settings;
        }

        public void show_context_menu (int msg_id, bool is_outgoing,
                                       double x, double y,
                                       Gtk.Widget parent) {
            var popover = new Gtk.Popover ();

            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            vbox.margin_start = 4;
            vbox.margin_end = 4;
            vbox.margin_top = 4;
            vbox.margin_bottom = 4;

            /* Reactions — first so they are most easily reachable */
            string[] emojis = { "\xf0\x9f\x91\x8d", "\xe2\x9d\xa4\xef\xb8\x8f",
                                 "\xf0\x9f\x98\x82", "\xf0\x9f\x98\xae",
                                 "\xf0\x9f\x98\xa2", "\xf0\x9f\x91\x8e" };
            var emoji_row1 = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            var emoji_row2 = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            for (int i = 0; i < emojis.length; i++) {
                string emoji = emojis[i];
                var btn = new Gtk.Button.with_label (emoji);
                btn.add_css_class ("flat");
                btn.clicked.connect (() => {
                    popover.popdown ();
                    send_reaction.begin (msg_id, emoji);
                });
                if (i < 3) emoji_row1.append (btn);
                else emoji_row2.append (btn);
            }
            vbox.append (emoji_row1);
            vbox.append (emoji_row2);

            /* Reply button (for all messages) */
            var reply_btn = new Gtk.Button.with_label ("Reply");
            reply_btn.add_css_class ("flat");
            reply_btn.clicked.connect (() => {
                popover.popdown ();
                start_replying (msg_id);
            });
            vbox.append (reply_btn);

            /* Forward… */
            var forward_btn = new Gtk.Button.with_label ("Forward\u2026");
            forward_btn.add_css_class ("flat");
            forward_btn.clicked.connect (() => {
                popover.popdown ();
                start_forwarding (msg_id);
            });
            vbox.append (forward_btn);

            /* Pin / Unpin */
            bool msg_is_pinned = pinned.is_pinned (msg_id);
            var pin_btn = new Gtk.Button.with_label (
                msg_is_pinned ? "Unpin" : "Pin");
            pin_btn.add_css_class ("flat");
            pin_btn.clicked.connect (() => {
                popover.popdown ();
                pinned.toggle_pin (msg_id);
            });
            vbox.append (pin_btn);

            var msg = find_message (message_store, msg_id);

            /* Save file (for messages with attachments) */
            if (msg != null && msg.file_path != null &&
                msg.file_path.length > 0) {
                string fpath = msg.file_path;
                string? fname = msg.file_name;
                var save_btn = new Gtk.Button.with_label ("Save file");
                save_btn.add_css_class ("flat");
                save_btn.clicked.connect (() => {
                    popover.popdown ();
                    window.save_attachment.begin (fpath, fname);
                });
                vbox.append (save_btn);
            }

            if (is_outgoing) {
                /* Allow editing only if the message has text */
                bool has_text = false;
                if (msg != null) {
                    has_text = (msg.text != null &&
                                msg.text.strip ().length > 0);
                }
                if (has_text) {
                    var edit_btn = new Gtk.Button.with_label ("Edit");
                    edit_btn.add_css_class ("flat");
                    edit_btn.clicked.connect (() => {
                        popover.popdown ();
                        start_editing (msg_id);
                    });
                    vbox.append (edit_btn);
                }
            }

            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var del_btn = new Gtk.Button.with_label ("Delete…");
            del_btn.add_css_class ("flat");
            del_btn.clicked.connect (() => {
                popover.popdown ();
                if (is_outgoing) {
                    confirm_delete_options (window, "Delete Message?",
                        "Delete this message from your device only, or from all participants? This cannot be undone.",
                        () => { delete_message.begin (msg_id, false); },
                        () => { delete_message.begin (msg_id, true); });
                } else {
                    confirm_delete_options (window, "Delete Message?",
                        "Delete this message from your device? This cannot be undone.",
                        () => { delete_message.begin (msg_id, false); },
                        null);
                }
            });
            vbox.append (del_btn);

            popover.child = vbox;
            popover.set_parent (parent);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
        }

        public async void send_reaction (int msg_id, string emoji) {
            try {
                yield rpc.send_reaction (msg_id, new string[] { emoji });
                yield update_row (msg_id);
            } catch (Error e) {
                window.show_toast ("Reaction failed: " + e.message);
            }
        }

        public async void delete_message (int msg_id, bool for_all) {
            try {
                if (for_all) {
                    yield rpc.delete_messages_for_all (new int[] { msg_id });
                } else {
                    yield rpc.delete_messages (new int[] { msg_id });
                }
                int idx = find_message_index (message_store, msg_id);
                if (idx >= 0) message_store.remove (idx);
            } catch (Error e) {
                window.show_toast ("Delete failed: " + e.message);
            }
        }

        public void start_editing (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m != null) {
                compose_bar.begin_edit (msg_id, m.text ?? "");
            }
        }

        public void start_replying (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m != null) {
                string sender = m.is_outgoing ? "You" : (m.sender_name ?? "");
                string preview = m.text ?? "(attachment)";
                compose_bar.begin_reply (msg_id, sender, preview);
            }
        }

        public void start_forwarding (int msg_id) {
            var picker = new ContactPickerDialog (rpc, window.chat_store,
                                                  "Forward To");
            picker.chat_picked.connect ((chat_id) => {
                forward_to_chat.begin (msg_id, chat_id);
            });
            picker.contact_picked.connect ((contact_id, email) => {
                forward_to_contact.begin (msg_id, contact_id, email);
            });
            picker.present (window);
        }

        private async void forward_to_chat (int msg_id, int chat_id) {
            try {
                yield rpc.forward_messages (new int[] { msg_id }, chat_id);
                window.request_reload_chats ();
                window.show_toast ("Message forwarded");
            } catch (Error e) {
                window.show_toast ("Forward failed: " + e.message);
            }
        }

        private async void forward_to_contact (int msg_id, int contact_id,
                                                string email) {
            try {
                int cid = contact_id;
                if (cid <= 0) {
                    cid = yield rpc.get_or_create_contact (email);
                }
                int chat_id = yield rpc.get_or_create_chat_by_contact (cid);
                yield rpc.forward_messages (new int[] { msg_id }, chat_id);
                window.request_reload_chats ();
                window.show_toast ("Message forwarded");
            } catch (Error e) {
                window.show_toast ("Forward failed: " + e.message);
            }
        }

        public async void edit_message (int msg_id, string new_text) {
            try {
                yield rpc.send_edit_request (msg_id, new_text);
                yield update_row (msg_id);
            } catch (Error e) {
                window.show_toast ("Edit failed: " + e.message);
            }
        }

        public async void update_row (int msg_id) {
            try {
                var msg = yield rpc.fetch_message (msg_id);
                if (msg == null) return;
                int idx = find_message_index (message_store, msg_id);
                if (idx >= 0) {
                    Object[] replacements = { msg };
                    message_store.splice (idx, 1, replacements);
                }
            } catch (Error e) {
                /* Reaction will appear on next message reload */
            }
        }

        public void handle_double_click (int msg_id) {
            switch (settings.double_click_action) {
            case 0: /* Reply */
                start_replying (msg_id);
                break;
            case 1: /* React with heart */
                send_reaction.begin (msg_id, "\xe2\x9d\xa4\xef\xb8\x8f");
                break;
            case 2: /* React with thumbsup */
                send_reaction.begin (msg_id, "\xf0\x9f\x91\x8d");
                break;
            case 3: /* Open user profile */
                open_sender_profile.begin (msg_id);
                break;
            case 4: /* Nothing */
                break;
            }
            compose_bar.grab_entry_focus ();
        }

        public async void open_sender_profile (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m == null || m.sender_address == null || m.is_outgoing) return;
            try {
                int contact_id = yield rpc.lookup_contact (m.sender_address);
                if (contact_id <= 0) return;
                int chat_id = yield rpc.get_or_create_chat_by_contact (contact_id);
                if (chat_id > 0) {
                    window.request_reload_chats ();
                    window.select_chat_by_id (chat_id);
                }
            } catch (Error e) {
                window.show_toast ("Could not open profile: " + e.message);
            }
        }
    }
}
