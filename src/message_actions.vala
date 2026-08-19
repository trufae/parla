namespace Dc {

    public class MessageActions : Object {

        private unowned Window window;
        private unowned RpcClient rpc;
        private unowned GLib.ListStore message_store;
        private unowned PinnedMessagesManager pinned;
        private unowned ComposeBar compose_bar;
        private unowned SettingsManager settings;
        private MentionRoster? reaction_roster = null;

        public signal void select_requested (int msg_id);

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

        public void set_reaction_roster (MentionRoster? roster) {
            reaction_roster = roster;
        }

        public void show_context_menu (int msg_id, bool is_outgoing,
                                       double x, double y,
                                       Gtk.Widget parent) {
            Gtk.Box vbox;
            var popover = popover_menu (parent, x, y, out vbox);

            /* Reactions — first so they are most easily reachable */
            append_emoji_rows (vbox, popover, msg_id, parent, x, y);
            var msg = find_message (message_store, msg_id);

            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var reply_btn = new PopoverButton (popover, "Reply");
            reply_btn.selected.connect (() => start_replying (msg_id));
            vbox.append (reply_btn);

            var forward_btn = new PopoverButton (popover, "Forward\u2026");
            forward_btn.selected.connect (() => start_forwarding (msg_id));
            vbox.append (forward_btn);

            bool msg_is_pinned = msg != null
                ? msg.is_pinned : pinned.is_pinned (msg_id);
            var pin_btn = new PopoverButton (popover,
                msg_is_pinned ? "Unpin" : "Pin");
            pin_btn.selected.connect (() => pinned.toggle_pin.begin (msg_id));
            vbox.append (pin_btn);

            if (msg != null && msg.can_edit_text) {
                var edit_btn = new PopoverButton (popover, "Edit");
                edit_btn.selected.connect (() => start_editing (msg_id));
                vbox.append (edit_btn);
            }

            var select_btn = new PopoverButton (popover, "Select...");
            select_btn.selected.connect (() => select_requested (msg_id));
            vbox.append (select_btn);

            var details_btn = new PopoverButton (popover, "Details...");
            details_btn.selected.connect (() => show_details (msg_id));
            vbox.append (details_btn);

            /* Save file (for messages with attachments) */
            if (msg != null && msg.file_path != null &&
                msg.file_path.length > 0) {
                string fpath = msg.file_path;
                string? fname = msg.file_name;
                var save_btn = new PopoverButton (popover, "Save file");
                save_btn.selected.connect (() =>
                    window.save_attachment.begin (fpath, fname));
                vbox.append (save_btn);
            }

            /* Transcribe voice messages with the external whisper tool */
            if (msg != null && msg.is_audio_file () && msg.has_local_file
                && Transcriber.available ()) {
                string apath = msg.file_path;
                var transcribe_btn = new PopoverButton (popover, "Transcribe");
                transcribe_btn.selected.connect (() =>
                    Transcriber.shared ().transcribe (apath));
                vbox.append (transcribe_btn);
            }

            /* Collect sticker attachments into a local pack */
            if (msg != null && msg.is_sticker_file () && msg.has_local_file) {
                string spath = msg.file_path;
                var sticker_btn = new PopoverButton (popover, "Add Sticker…");
                sticker_btn.selected.connect (() =>
                    StickerManagerDialog.prompt_add_sticker (window, spath));
                vbox.append (sticker_btn);
            }

            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var delete_btn = new PopoverButton (popover, "Delete…", true);
            delete_btn.selected.connect (() =>
                confirm_delete_message.begin (msg_id, is_outgoing));
            vbox.append (delete_btn);

            preserve_scroll_until_closed (popover);
            popover.popup ();
        }

        private async void confirm_delete_message (int msg_id,
                                                   bool is_outgoing) {
            string body = is_outgoing
                ? "Delete this message from your device only, or from all participants? This cannot be undone."
                : "Delete this message from your device? This cannot be undone.";
            var choice = yield confirm_delete_options (
                window, "Delete Message?", body, is_outgoing);
            if (choice == DeleteChoice.FOR_ME)
                delete_message.begin (msg_id, false);
            else if (choice == DeleteChoice.FOR_EVERYONE)
                delete_message.begin (msg_id, true);
        }

        /** Two rows of quick reaction emoji, plus "…" opening the full
            chooser when available. Shared by the context menu and the
            Workspace hover-action popover. */
        private void append_emoji_rows (Gtk.Box vbox, Gtk.Popover popover,
                                        int msg_id, Gtk.Widget parent,
                                        double x, double y) {
            string[] emojis = {
                "\xf0\x9f\x91\x8d", // thumbsup
                "\xf0\x9f\x91\x8e", // thumbsdown
                "\xe2\x9d\xa4\xef\xb8\x8f", // heart
                "\xf0\x9f\x94\xa5", // fire
                "\xf0\x9f\x98\x82", // laugh
                "\xf0\x9f\x98\xae", // surprised
                "\xf0\x9f\x98\xa2", // sad
            };
            if (gtk_emoji_chooser_available ()) {
                emojis += "…";
            }
            var msg = find_message (message_store, msg_id);
            var emoji_row1 = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            var emoji_row2 = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            for (int i = 0; i < emojis.length; i++) {
                string emoji = emojis[i];
                var btn = new PopoverButton (popover, emoji);
                bool is_more = (emoji == "…");
                if (is_more) {
                    btn.tooltip_text = "More emojis…";
                    btn.selected.connect (() => {
                        show_emoji_picker (msg_id, parent, x, y);
                    });
                } else {
                    if (has_my_reaction (msg, emoji)) btn.add_css_class ("suggested-action");
                    btn.selected.connect (() => {
                        send_reaction.begin (msg_id, emoji);
                    });
                }
                if (i < 4) emoji_row1.append (btn);
                else emoji_row2.append (btn);
            }
            vbox.append (emoji_row1);
            vbox.append (emoji_row2);
        }

        /** Standalone quick-reaction popover pointing at (x, y) in parent. */
        public void show_reaction_menu (int msg_id, Gtk.Widget parent,
                                        double x, double y) {
            Gtk.Box vbox;
            var popover = popover_menu (parent, x, y, out vbox);
            append_emoji_rows (vbox, popover, msg_id, parent, x, y);

            preserve_scroll_until_closed (popover);
            popover.popup ();
        }

        private void preserve_scroll_until_closed (Gtk.Popover popover) {
            var view = window.current_view ();
            double saved_scroll = view != null ? view.get_scroll_value () : 0;
            if (view != null) view.freeze_scroll_handler (1500);
            popover.closed.connect (() => {
                if (view != null) {
                    view.restore_scroll_value (saved_scroll);
                    view.restore_scroll_value_deferred (saved_scroll);
                }
            });
        }

        private bool has_my_reaction (Message? msg, string emoji) {
            if (msg == null || msg.my_reactions == null) return false;
            foreach (string me in msg.my_reactions.split (",")) {
                if (me == emoji) return true;
            }
            return false;
        }

        public async void send_reaction (int msg_id, string emoji) {
            try {
                var current = find_message (message_store, msg_id);
                if (has_my_reaction (current, emoji)) {
                    yield rpc.send_reaction (msg_id, new string[] {});
                } else {
                    yield rpc.send_reaction (msg_id, new string[] { emoji });
                }
                yield update_row (msg_id);
            } catch (Error e) {
                window.show_toast ("Reaction failed: " + e.message);
            }
        }

        private void show_emoji_picker (int msg_id, Gtk.Widget parent,
                                         double x, double y) {
            var chooser = create_emoji_chooser ();
            if (chooser == null) {
                window.show_toast ("Emoji picker unavailable");
                return;
            }
            chooser.emoji_picked.connect ((emoji) => {
                send_reaction.begin (msg_id, emoji);
            });
            chooser.set_parent (parent);
            chooser.set_pointing_to ({ (int) x, (int) y, 1, 1 });

            preserve_scroll_until_closed (chooser);
            unparent_on_close (chooser);
            chooser.popup ();
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
            if (m != null) start_editing_message (m);
        }

        public void start_editing_last () {
            var m = find_last_editable_text_message (message_store);
            if (m != null) start_editing_message (m);
        }

        private void start_editing_message (Message m) {
            compose_bar.begin_edit (m.id, m.text ?? "");
        }

        public void start_replying (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m == null) return;
            string sender = m.is_outgoing ? "You" : (m.sender_name ?? "");
            string preview = m.text ?? "(attachment)";
            compose_bar.begin_reply (msg_id, sender, preview);
        }

        public void start_forwarding (int msg_id) {
            start_forwarding_many (new int[] { msg_id });
        }

        public void start_forwarding_many (int[] msg_ids) {
            forward_with_picker (window, rpc, msg_ids);
        }

        /** Ask for a destination chat or contact and forward msg_ids there.
            Shared by the message context menu and the gallery dialog. */
        public static ContactPickerDialog? forward_with_picker (
                Window window, RpcClient rpc, int[] msg_ids) {
            if (msg_ids.length == 0) return null;
            int[] forward_ids = msg_ids.copy ();
            var picker = new ContactPickerDialog (rpc, window.chat_store,
                                                  "Forward To");
            picker.chat_picked.connect ((chat_id) => {
                forward_to_chat.begin (window, rpc, forward_ids.copy (),
                                       chat_id);
            });
            picker.contact_picked.connect ((contact_id, email) => {
                forward_to_contact.begin (window, rpc, forward_ids.copy (),
                                          contact_id, email);
            });
            picker.present (window);
            return picker;
        }

        private static async void forward_to_chat (Window window, RpcClient rpc,
                                                    owned int[] msg_ids,
                                                    int chat_id) {
            try {
                yield rpc.forward_messages (msg_ids, chat_id);
                window.request_reload_chats ();
                window.request_chat_messages_reload (chat_id);
                window.show_toast (msg_ids.length == 1
                    ? "Message forwarded" : "Messages forwarded");
            } catch (Error e) {
                window.show_toast ("Forward failed: " + e.message);
            }
        }

        private static async void forward_to_contact (Window window,
                                                       RpcClient rpc,
                                                       owned int[] msg_ids,
                                                       int contact_id,
                                                       string email) {
            int chat_id;
            try {
                int cid = contact_id;
                if (cid <= 0) {
                    cid = yield rpc.get_or_create_contact (email);
                }
                chat_id = yield rpc.get_or_create_chat_by_contact (cid);
            } catch (Error e) {
                window.show_toast ("Forward failed: " + e.message);
                return;
            }
            yield forward_to_chat (window, rpc, (owned) msg_ids, chat_id);
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
                var view = window.current_view ();
                if (view != null) {
                    view.replace_message (msg_id, msg);
                } else {
                    int idx = find_message_index (message_store, msg_id);
                    if (idx >= 0) {
                        Object[] replacements = { msg };
                        message_store.splice (idx, 1, replacements);
                    }
                }
            } catch (Error e) {
                /* Reaction will appear on next message reload */
            }
        }

        public void handle_double_click (int msg_id, bool is_outgoing,
                                         double x, double y,
                                         Gtk.Widget parent) {
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
            case 5: /* Open context menu */
                Idle.add (() => {
                    show_context_menu (msg_id, is_outgoing, x, y, parent);
                    return Source.REMOVE;
                });
                return;
            }
            compose_bar.grab_entry_focus ();
        }

        public void show_details (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m == null) return;
            var dialog = new MessageDetailsDialog (
                window, rpc, this, m, reaction_roster);
            dialog.present (window);
        }

        public async void open_sender_chat (int msg_id) {
            var m = find_message (message_store, msg_id);
            if (m == null) return;

            try {
                int contact_id = m.sender_contact_id;
                string? address = m.sender_address;
                if (m.is_outgoing && (address == null || address.length == 0)) {
                    address = rpc.self_email;
                }
                if (contact_id <= 0 && address != null && address.length > 0) {
                    contact_id = yield rpc.get_or_create_contact (address);
                }
                if (contact_id <= 0) return;

                int chat_id = yield rpc.get_or_create_chat_by_contact (contact_id);
                if (chat_id > 0) {
                    window.request_reload_chats ();
                    window.select_chat_by_id (chat_id);
                }
            } catch (Error e) {
                window.show_toast ("Could not open chat: " + e.message);
            }
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
