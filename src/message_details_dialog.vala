namespace Dc {

    public class MessageDetailsDialog : Adw.Dialog {

        private unowned Window window;
        private RpcClient rpc;
        private MessageActions actions;
        private Message msg;
        private MentionRoster? reaction_roster;

        private Gtk.TextView? edit_view = null;
        private Gtk.Button? save_edit_btn = null;
        private Gtk.Label? edit_status_lbl = null;
        private string edit_original_text = "";
        private Adw.ActionRow delivery_row;
        private Adw.ActionRow error_row;
        private Gtk.Button retry_btn;
        private bool retry_running = false;
        private bool dialog_closed = false;
        private int account_id;
        private Adw.ActionRow timer_row;
        private Adw.ActionRow expiry_row;
        private bool expiry_loading = false;
        private bool expiry_pending = false;

        public MessageDetailsDialog (Window window, RpcClient rpc,
                                     MessageActions actions, Message msg,
                                     MentionRoster? reaction_roster) {
            this.window = window;
            this.rpc = rpc;
            this.actions = actions;
            this.msg = msg;
            this.account_id = rpc.account_id;
            this.reaction_roster = reaction_roster;
            this.title = _("Message Details");
            this.content_width = 480;
            this.content_height = 620;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            header.show_end_title_buttons = true;
            box.append (header);

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
            content.margin_start = 16;
            content.margin_end = 16;
            content.margin_top = 12;
            content.margin_bottom = 16;

            content.append (build_sender_button ());

            if (msg.can_edit_text) {
                content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
                content.append (build_edit_section ());
            }

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            content.append (build_reactions_section ());

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            content.append (build_message_info_section ());

            if (msg.has_file) {
                content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
                content.append (build_attachment_section ());
            }

            if (has_value (msg.quote_text) || msg.quote_msg_id > 0) {
                content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
                content.append (build_quote_section ());
            }

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            content.append (build_actions_section ());

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = content;
            box.append (scroll);

            var toasts = new Adw.ToastOverlay ();
            toasts.child = box;
            this.child = toasts;
            install_escape_close (this);
            ulong info_handler = window.message_info_changed.connect ((acct, chat) => {
                if (acct == account_id && (chat == 0 || chat == msg.chat_id))
                    load_expiry.begin ();
            });
            closed.connect (() => {
                dialog_closed = true;
                window.disconnect (info_handler);
            });
            load_expiry.begin ();
        }

        private async void load_expiry () {
            if (dialog_closed) return;
            expiry_pending = true;
            if (expiry_loading) return;
            expiry_loading = true;
            do {
                expiry_pending = false;
                try {
                    var info = yield rpc.get_message_info_object_for (account_id, msg.id);
                    if (dialog_closed) break;
                    if (expiry_pending) continue;
                    var timer = info != null ? json_obj (info, "ephemeralTimer") : null;
                    bool enabled = timer != null && json_str (timer, "kind") == "enabled";
                    timer_row.visible = expiry_row.visible = enabled;
                    if (enabled) {
                        timer_row.subtitle = ephemeral_duration (json_int (timer, "duration"));
                        int64 expires = json_int (info, "ephemeralTimestamp");
                        var date = expires > 0 ? new DateTime.from_unix_local (expires) : null;
                        expiry_row.subtitle = expires <= 0 ? _("Timer not started")
                            : date != null ? date.format ("%Y-%m-%d %H:%M:%S %Z") : _("Unknown");
                    }
                } catch (Error e) {
                    // Older engines may not provide this metadata. Do not
                    // infer expiry from the chat's timer or the sent date.
                    if (!dialog_closed && expiry_row.visible)
                        expiry_row.subtitle = _("Expiry information unavailable");
                }
            } while (expiry_pending && !dialog_closed);
            expiry_loading = false;
        }

        private Gtk.Widget build_sender_button () {
            string name;
            string? address;
            string? avatar_path;
            sender_identity (out name, out address, out avatar_path);

            var button = new Gtk.Button ();
            button.add_css_class ("flat");
            button.add_css_class ("message-details-sender");
            button.halign = Gtk.Align.FILL;
            button.tooltip_text = _("Show contact details");
            button.sensitive = sender_details_available ();
            button.clicked.connect (() => {
                this.close ();
                actions.open_sender_profile.begin (msg.id);
            });

            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            row.halign = Gtk.Align.FILL;
            row.append (presence_avatar (56, name, avatar_path,
                !msg.is_outgoing && msg.sender_was_seen_recently,
                null, "list-presence-avatar-ring"));

            var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
            labels.valign = Gtk.Align.CENTER;
            labels.hexpand = true;

            var name_lbl = new Gtk.Label (name);
            name_lbl.add_css_class ("title-3");
            name_lbl.halign = Gtk.Align.START;
            name_lbl.xalign = 0;
            name_lbl.ellipsize = Pango.EllipsizeMode.END;
            labels.append (name_lbl);

            var sub = new Gtk.Label (address != null && address.length > 0
                ? address : (msg.is_outgoing ? _("Outgoing message") : _("Incoming message")));
            sub.add_css_class ("dim-label");
            sub.halign = Gtk.Align.START;
            sub.xalign = 0;
            sub.ellipsize = Pango.EllipsizeMode.END;
            labels.append (sub);

            row.append (labels);
            row.append (new Gtk.Image.from_icon_name ("go-next-symbolic"));
            button.child = row;
            return button;
        }

        private Gtk.Widget build_edit_section () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            box.append (heading (_("Edit Message")));

            edit_original_text = msg.text ?? "";
            edit_view = new Gtk.TextView ();
            edit_view.wrap_mode = Gtk.WrapMode.WORD_CHAR;
            edit_view.accepts_tab = false;
            edit_view.top_margin = 8;
            edit_view.bottom_margin = 8;
            edit_view.left_margin = 10;
            edit_view.right_margin = 10;
            edit_view.buffer.text = edit_original_text;
            edit_view.add_css_class ("message-details-edit-view");
            edit_view.buffer.changed.connect (update_edit_button);

            var editor_scroll = new Gtk.ScrolledWindow ();
            editor_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            editor_scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            editor_scroll.height_request = 140;
            editor_scroll.child = edit_view;
            box.append (editor_scroll);

            var actions_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            edit_status_lbl = dim ("");
            edit_status_lbl.hexpand = true;
            edit_status_lbl.valign = Gtk.Align.CENTER;
            actions_row.append (edit_status_lbl);

            save_edit_btn = new Gtk.Button.with_label (_("Save"));
            save_edit_btn.add_css_class ("suggested-action");
            save_edit_btn.clicked.connect (() => {
                save_edit.begin ();
            });
            actions_row.append (save_edit_btn);
            box.append (actions_row);

            update_edit_button ();
            return box;
        }

        private Gtk.Widget build_reactions_section () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            box.append (heading (_("Reactions")));

            var list = boxed_list ();
            var reactions = sorted_reactions ();
            if (reactions.length == 0) {
                list.append (info_row (_("No reactions"), _("Nobody has reacted to this message yet.")));
            } else {
                for (int i = 0; i < reactions.length; i++) {
                    var reaction = reactions[i];
                    if (reaction.count > reaction.users.length) {
                        list.append (reaction_count_row (reaction));
                    }

                    int[] users = sorted_reaction_user_ids (reaction);
                    for (int u = 0; u < users.length; u++) {
                        list.append (reaction_user_row (
                            reaction.emoji, users[u]));
                    }
                }
            }
            box.append (list);
            return box;
        }

        private Gtk.Widget build_message_info_section () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            box.append (heading (_("Message")));

            var list = boxed_list ();
            list.append (info_row (_("Message ID"), msg.id.to_string ()));
            list.append (info_row (_("Chat ID"), msg.chat_id.to_string ()));
            list.append (info_row (_("Sent"), format_full_timestamp (msg.timestamp)));
            timer_row = info_row (_("Disappearing messages"), "");
            expiry_row = info_row (_("Expires"), "");
            timer_row.visible = expiry_row.visible = false;
            list.append (timer_row);
            list.append (expiry_row);
            list.append (info_row (_("Direction"), msg.is_outgoing ? _("Outgoing") : _("Incoming")));
            delivery_row = info_row (_("Delivery"), delivery_state ());
            list.append (delivery_row);
            error_row = info_row (_("Error"), msg.error ?? "", 0);
            error_row.visible = has_value (msg.error);
            list.append (error_row);
            list.append (info_row (_("Type"), message_type ()));
            list.append (info_row (_("Flags"), flags_text ()));
            list.append (info_row (_("Sender contact ID"),
                msg.sender_contact_id > 0 ? msg.sender_contact_id.to_string () : _("Unknown")));

            string? sender_addr = msg.is_outgoing ? rpc.self_email : msg.sender_address;
            if (has_value (sender_addr)) {
                list.append (info_row (_("Sender address"), sender_addr));
            }

            if (has_value (msg.override_sender_name)) {
                list.append (info_row (_("Override sender"), msg.override_sender_name));
            }

            if (has_value (msg.download_state)) {
                list.append (info_row (_("Download state"), download_state ()));
            }

            box.append (list);
            retry_btn = new Gtk.Button.with_label (_("Retry"));
            retry_btn.halign = Gtk.Align.START;
            retry_btn.visible = msg.can_retry;
            retry_btn.clicked.connect (() => { retry_message.begin (); });
            box.append (retry_btn);
            return box;
        }

        private async void retry_message () {
            if (retry_running || !msg.can_retry) return;
            retry_running = true;
            retry_btn.sensitive = false;
            retry_btn.label = _("Retrying…");
            var updated = yield actions.retry_message (msg.id);
            retry_running = false;
            if (dialog_closed) return;
            if (updated != null) msg = updated;
            delivery_row.subtitle = delivery_state ();
            error_row.subtitle = msg.error ?? "";
            error_row.visible = has_value (msg.error);
            retry_btn.label = _("Retry");
            retry_btn.visible = msg.can_retry;
            retry_btn.sensitive = msg.can_retry;
        }

        private Gtk.Widget build_attachment_section () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            box.append (heading (_("Attachment")));

            var list = boxed_list ();
            if (has_value (msg.file_name)) {
                list.append (info_row (_("File name"), msg.file_name));
            }
            if (has_value (msg.file_mime)) {
                list.append (info_row (_("MIME type"), msg.file_mime));
            }
            if (msg.file_bytes > 0) {
                list.append (info_row (_("Size"), format_bytes (msg.file_bytes)));
            }
            if (has_value (msg.file_path)) {
                list.append (info_row (_("Local path"), msg.file_path, 3));
                list.append (info_row (_("Local copy"),
                    msg.has_local_file ? _("Available") : _("Not downloaded")));
            }
            box.append (list);
            return box;
        }

        private Gtk.Widget build_quote_section () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            box.append (heading (_("Reply Context")));

            var list = boxed_list ();
            if (msg.quote_msg_id > 0) {
                list.append (info_row (_("Quoted message ID"),
                    msg.quote_msg_id.to_string ()));
            }
            if (has_value (msg.quote_sender_name)) {
                list.append (info_row (_("Quoted sender"), msg.quote_sender_name));
            }
            if (has_value (msg.quote_text)) {
                list.append (info_row (_("Quoted text"), msg.quote_text, 4));
            }
            box.append (list);
            return box;
        }

        private Gtk.Widget build_actions_section () {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row.halign = Gtk.Align.END;

            var delete_btn = new Gtk.Button.with_label (_("Delete…"));
            delete_btn.add_css_class ("destructive-action");
            delete_btn.clicked.connect (() => {
                confirm_delete_message.begin ();
            });
            row.append (delete_btn);

            var forward_btn = new Gtk.Button.with_label (_("Forward…"));
            forward_btn.clicked.connect (() => {
                this.close ();
                actions.start_forwarding (msg.id);
            });
            row.append (forward_btn);

            var reply_btn = new Gtk.Button.with_label (_("Reply"));
            reply_btn.add_css_class ("suggested-action");
            reply_btn.clicked.connect (() => {
                this.close ();
                actions.start_replying (msg.id);
            });
            row.append (reply_btn);

            return row;
        }

        private Gtk.ListBox boxed_list () {
            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            return list;
        }

        private Gtk.Label heading (string text) {
            var label = new Gtk.Label (text);
            label.add_css_class ("heading");
            label.halign = Gtk.Align.START;
            label.xalign = 0;
            return label;
        }

        private Gtk.Label dim (string text) {
            var label = new Gtk.Label (text);
            label.add_css_class ("dim-label");
            label.halign = Gtk.Align.START;
            label.xalign = 0;
            label.wrap = true;
            return label;
        }

        private Adw.ActionRow info_row (string title, string subtitle,
                                        int subtitle_lines = 2) {
            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = title;
            row.subtitle = has_value (subtitle) ? subtitle : _("None");
            row.subtitle_lines = subtitle_lines;
            return row;
        }

        private Adw.ActionRow reaction_count_row (MessageReaction reaction) {
            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = ngettext ("%d reaction", "%d reactions",
                reaction.count).printf (reaction.count);

            var emoji = new Gtk.Label (reaction.emoji);
            emoji.add_css_class ("message-details-reaction-emoji");
            row.add_prefix (emoji);
            return row;
        }

        private Adw.ActionRow reaction_user_row (string emoji, int contact_id) {
            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = reaction_user_name (contact_id);
            row.activatable = contact_id > 0;

            var emoji_lbl = new Gtk.Label (emoji);
            emoji_lbl.add_css_class ("message-details-reaction-emoji");
            row.add_prefix (emoji_lbl);

            if (contact_id > 0) {
                row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
                row.activated.connect (() => {
                    this.close ();
                    open_reaction_user_chat.begin (contact_id);
                });
            }
            return row;
        }

        private GenericArray<MessageReaction> sorted_reactions () {
            var sorted = new GenericArray<MessageReaction> ();

            if (msg.reaction_details != null && msg.reaction_details.length > 0) {
                for (int i = 0; i < msg.reaction_details.length; i++) {
                    sorted.add (msg.reaction_details[i]);
                }
            } else if (has_value (msg.reactions)) {
                foreach (string part in msg.reactions.split (",")) {
                    var kv = part.split (":", 2);
                    if (kv.length < 2) continue;
                    var reaction = new MessageReaction (kv[0]);
                    reaction.count = int.parse (kv[1]);
                    sorted.add (reaction);
                }
            }

            sorted.sort ((a, b) => {
                return a.emoji.collate (b.emoji);
            });
            return sorted;
        }

        private int[] sorted_reaction_user_ids (
                MessageReaction reaction) {
            int[] users = {};
            for (int i = 0; i < reaction.users.length; i++) {
                users += reaction.users[i].contact_id;
            }

            for (int i = 1; i < users.length; i++) {
                int key = users[i];
                string key_name = reaction_user_name (key);
                int j = i - 1;
                while (j >= 0 &&
                       key_name.collate (reaction_user_name (users[j])) < 0) {
                    users[j + 1] = users[j];
                    j--;
                }
                users[j + 1] = key;
            }
            return users;
        }

        private string reaction_user_name (int contact_id) {
            if (contact_id == 1) {
                return MessageRow.self_display_name != null
                    && MessageRow.self_display_name.length > 0
                    ? MessageRow.self_display_name : _("You");
            }

            MentionMember? member = reaction_roster != null
                ? reaction_roster.lookup_contact (contact_id) : null;
            if (member != null) {
                if (member.display_name.length > 0) return member.display_name;
                if (member.address.length > 0) return member.address;
            }

            if (!msg.is_outgoing && contact_id > 0 &&
                contact_id == msg.sender_contact_id) {
                string name;
                string? address;
                string? avatar_path;
                sender_identity (out name, out address, out avatar_path);
                return name;
            }

            return contact_id > 0 ? _("Contact %d").printf (contact_id)
                                  : _("Unknown user");
        }

        private void sender_identity (out string name, out string? address,
                                      out string? avatar_path) {
            if (msg.is_outgoing) {
                name = MessageRow.self_display_name != null
                    && MessageRow.self_display_name.length > 0
                    ? MessageRow.self_display_name : _("You");
                address = rpc.self_email;
                avatar_path = MessageRow.self_avatar_path;
                return;
            }

            if (has_value (msg.override_sender_name)) {
                name = "~" + msg.override_sender_name;
            } else if (has_value (msg.sender_name)) {
                name = msg.sender_name;
            } else if (has_value (msg.sender_address)) {
                name = msg.sender_address;
            } else {
                name = _("Unknown sender");
            }
            address = msg.sender_address;
            avatar_path = msg.sender_avatar_path;
        }

        private bool sender_details_available () {
            return msg.is_outgoing || msg.sender_contact_id > 0
                || has_value (msg.sender_address);
        }

        private void update_edit_button () {
            if (edit_view == null || save_edit_btn == null) return;
            string text = text_buffer_text (edit_view.buffer);
            save_edit_btn.sensitive =
                text != edit_original_text && text.strip ().length > 0;
            if (edit_status_lbl != null && save_edit_btn.sensitive) {
                edit_status_lbl.label = "";
            }
        }

        private async void save_edit () {
            if (edit_view == null || save_edit_btn == null) return;
            string text = text_buffer_text (edit_view.buffer);
            if (text.strip ().length == 0 || text == edit_original_text) return;

            save_edit_btn.sensitive = false;
            if (edit_status_lbl != null) edit_status_lbl.label = _("Saving…");

            try {
                yield rpc.send_edit_request (msg.id, text);
                msg.text = text;
                msg.is_edited = true;
                yield actions.update_row (msg.id);
                edit_original_text = text;
                if (edit_status_lbl != null) edit_status_lbl.label = _("Saved");
                update_edit_button ();
            } catch (Error e) {
                if (edit_status_lbl != null) {
                    edit_status_lbl.label = _("Edit failed: ") + e.message;
                }
                window.show_toast (_("Edit failed: ") + e.message);
                update_edit_button ();
            }
        }

        private async void open_reaction_user_chat (int contact_id) {
            if (contact_id <= 0) return;

            try {
                int chat_id = yield rpc.get_or_create_chat_by_contact (contact_id);
                if (chat_id > 0) {
                    window.request_reload_chats ();
                    window.select_chat_by_id (chat_id);
                }
            } catch (Error e) {
                window.show_toast (_("Could not open chat: ") + e.message);
            }
        }

        private static string text_buffer_text (Gtk.TextBuffer buffer) {
            Gtk.TextIter start;
            Gtk.TextIter end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            return buffer.get_text (start, end, false);
        }

        private async void confirm_delete_message () {
            var choice = yield confirm_message_deletion (this, rpc, { msg.id });
            if (choice == DeleteChoice.CANCEL) return;
            actions.delete_message.begin (
                msg.id, choice == DeleteChoice.FOR_EVERYONE);
            this.close ();
        }

        private string format_full_timestamp (int64 ts) {
            if (ts <= 0) return _("Unknown");
            var dt = new DateTime.from_unix_local (ts);
            return "%s (%s)".printf (dt.format ("%Y-%m-%d %H:%M:%S"),
                ts.to_string ());
        }

        private string delivery_state () {
            if (!msg.is_outgoing) return _("Received");
            if (msg.is_failed) return _("Failed");
            if (msg.is_read) return _("Read");
            if (msg.is_delivered) return _("Delivered");
            if (msg.is_pending) return _("Pending");
            if (msg.state == MessageState.OUT_DRAFT) return _("Draft");
            return msg.state > 0 ? _("State %d").printf (msg.state) : _("Unknown");
        }

        private string download_state () {
            switch (msg.download_state) {
            case "Done": return _("Downloaded");
            case "Available": return _("Not downloaded");
            case "InProgress": return _("Downloading…");
            case "Failure": return _("Download failed");
            default: return msg.download_state;
            }
        }

        private string message_type () {
            if (msg.is_info) return _("Info");
            if (has_value (msg.view_type)) return msg.view_type;
            if (msg.is_image_file ()) return _("Image");
            if (msg.is_video_file ()) return _("Video");
            if (msg.is_audio_file ()) return _("Audio");
            if (msg.has_file) return _("File");
            return _("Text");
        }

        private string flags_text () {
            string[] flags = {};
            if (msg.is_forwarded) flags += _("Forwarded");
            if (msg.is_edited) flags += _("Edited");
            if (msg.is_pinned) flags += _("Pinned");
            if (msg.is_info) flags += _("Info");
            if (msg.has_html) flags += "HTML";
            if (msg.has_full_message_action) flags += _("Full message action");
            return flags.length == 0 ? _("None") : string.joinv (", ", flags);
        }

        private static string format_bytes (int64 bytes) {
            if (bytes < 1024) return bytes.to_string () + " B";
            double kb = (double) bytes / 1024.0;
            if (kb < 1024.0) return "%.1f KB".printf (kb);
            double mb = kb / 1024.0;
            if (mb < 1024.0) return "%.1f MB".printf (mb);
            return "%.1f GB".printf (mb / 1024.0);
        }

        private static bool has_value (string? value) {
            return value != null && value.length > 0;
        }
    }
}
