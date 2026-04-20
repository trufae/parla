namespace Dc {

    /**
     * A single row in the chat list sidebar.
     * Shows avatar placeholder, chat name, last message preview, time, and unread badge.
     */
    public class ChatRow : Gtk.Box {

        public int chat_id { get; private set; }

        private Gtk.Label name_label;
        private Gtk.Label preview_label;
        private Gtk.Label time_label;
        private Gtk.Label? badge_label = null;

        public ChatRow (ChatEntry entry) {
            Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 10);
            this.chat_id = entry.id;
            add_css_class ("chat-row");
            margin_start = 8;
            margin_end = 8;
            margin_top = 4;
            margin_bottom = 4;

            /* Avatar circle */
            var avatar = new Adw.Avatar (40, entry.name, true);
            avatar.custom_image = load_avatar (entry.avatar_path);
            append (avatar);

            /* Middle: name + preview */
            var mid = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            mid.hexpand = true;
            mid.valign = Gtk.Align.CENTER;

            /* Top row: name + time */
            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

            /* Show unread dot only for real unread chats, not contact requests */
            bool has_unread = entry.unread_count > 0 && !entry.is_contact_request;

            if (has_unread) {
                var dot = new Gtk.Label ("\u25CF");
                dot.add_css_class (entry.is_muted ? "unread-dot-muted" : "unread-dot");
                top.append (dot);
            }

            name_label = new Gtk.Label (entry.name);
            name_label.add_css_class ("heading");
            if (has_unread) {
                name_label.add_css_class ("unread-name");
            }
            name_label.ellipsize = Pango.EllipsizeMode.END;
            name_label.hexpand = true;
            name_label.halign = Gtk.Align.START;
            name_label.xalign = 0;
            top.append (name_label);

            if (entry.is_pinned) {
                var pin_label = new Gtk.Label ("📌");
                pin_label.add_css_class ("dim-label");
                pin_label.add_css_class ("caption");
                top.append (pin_label);
            }

            time_label = new Gtk.Label (format_time (entry.timestamp));
            time_label.add_css_class ("dim-label");
            time_label.add_css_class ("caption");
            top.append (time_label);

            mid.append (top);

            /* Bottom row: preview + badge */
            var bot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            preview_label = new Gtk.Label (format_preview (entry));
            if (!has_unread) {
                preview_label.add_css_class ("dim-label");
            }
            preview_label.ellipsize = Pango.EllipsizeMode.END;
            preview_label.hexpand = true;
            preview_label.halign = Gtk.Align.START;
            preview_label.xalign = 0;
            preview_label.max_width_chars = 30;
            bot.append (preview_label);

            /* Contact requests get a "Request" label instead of a count badge */
            if (entry.is_contact_request) {
                badge_label = new Gtk.Label ("Request");
                badge_label.add_css_class ("contact-request-badge");
                badge_label.halign = Gtk.Align.END;
                badge_label.valign = Gtk.Align.CENTER;
                bot.append (badge_label);
            } else if (has_unread) {
                badge_label = new Gtk.Label (entry.unread_count.to_string ());
                badge_label.add_css_class (entry.is_muted ? "unread-badge-muted" : "unread-badge");
                badge_label.halign = Gtk.Align.END;
                badge_label.valign = Gtk.Align.CENTER;
                bot.append (badge_label);
            }

            mid.append (bot);
            append (mid);
        }


        private static string format_preview (ChatEntry entry) {
            string preview = entry.last_message ?? "";
            if (entry.summary_prefix != null && entry.summary_prefix.length > 0) {
                if (preview.length > 0) {
                    return "%s: %s".printf (entry.summary_prefix, preview);
                }
                return entry.summary_prefix;
            }
            return preview;
        }

        private static string format_time (int64 timestamp) {
            if (timestamp <= 0) return "";

            var now = new DateTime.now_local ();
            var dt = new DateTime.from_unix_local (timestamp);

            /* Same day: show time, otherwise show date */
            if (now.get_year () == dt.get_year () &&
                now.get_day_of_year () == dt.get_day_of_year ()) {
                return dt.format ("%H:%M");
            }
            /* This week: show day name */
            int diff = (int) (now.to_unix () - dt.to_unix ());
            if (diff < 7 * 86400) {
                return dt.format ("%a");
            }
            /* Older: show date */
            return dt.format ("%d/%m/%y");
        }
    }

    public class ChatContextMenu : Object {

        private unowned Window window;
        private unowned RpcClient rpc;
        private unowned GLib.ListStore chat_store;

        public ChatContextMenu (Window window, RpcClient rpc,
                                GLib.ListStore chat_store) {
            this.window = window;
            this.rpc = rpc;
            this.chat_store = chat_store;
        }

        public void show (int chat_id, double x, double y, Gtk.Widget parent) {
            bool is_pinned = false;
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) is_pinned = entry.is_pinned;

            var popover = new Gtk.Popover ();
            popover.has_arrow = false;
            popover.set_parent (parent);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.add_css_class ("menu");

            var pin_btn = make_menu_button (is_pinned ? "Unpin" : "Pin");
            pin_btn.clicked.connect (() => {
                popover.popdown ();
                toggle_pin.begin (chat_id, is_pinned);
            });
            box.append (pin_btn);

            var info_btn = make_menu_button ("Chat Info");
            info_btn.clicked.connect (() => {
                popover.popdown ();
                show_info.begin (chat_id);
            });
            box.append (info_btn);

            var del_btn = make_menu_button ("Delete…");
            del_btn.clicked.connect (() => {
                popover.popdown ();
                confirm_delete.begin (chat_id);
            });
            box.append (del_btn);

            popover.child = box;
            popover.closed.connect (() => { popover.unparent (); });
            popover.popup ();
        }

        private static Gtk.Button make_menu_button (string label) {
            var btn = new Gtk.Button.with_label (label);
            btn.add_css_class ("flat");
            ((Gtk.Label) btn.child).xalign = 0;
            ((Gtk.Label) btn.child).halign = Gtk.Align.START;
            return btn;
        }

        private async void toggle_pin (int chat_id, bool currently_pinned) {
            try {
                string visibility = currently_pinned ? "Normal" : "Pinned";
                yield rpc.set_chat_visibility (chat_id, visibility);
                yield window.load_chats ();
            } catch (Error e) {
                window.show_toast ("Failed to update pin: " + e.message);
            }
        }

        private async void show_info (int chat_id) {
            var dialog = new ChatInfoDialog (rpc, chat_id);

            dialog.chat_deleted.connect ((cid) => {
                window.show_toast ("Chat deleted");
                if (window.current_chat_id == cid)
                    window.clear_chat_view ();
                window.request_reload_chats ();
            });

            dialog.chat_changed.connect (() => {
                window.request_reload_chats ();
                if (window.current_chat_id == chat_id)
                    window.request_messages_reload ();
            });

            dialog.present (window);
        }

        private async void confirm_delete (int chat_id) {
            string chat_name = "this chat";
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) chat_name = entry.name;

            confirm_delete_options (window, "Delete Chat?",
                "Remove \"%s\" from your chat list? You may still receive messages if you are a member.".printf (chat_name),
                () => { do_delete.begin (chat_id); },
                null);
        }

        private async void do_delete (int chat_id) {
            try {
                yield rpc.delete_chat (chat_id);
                window.show_toast ("Chat deleted");
                if (window.current_chat_id == chat_id)
                    window.clear_chat_view ();
                yield window.load_chats ();
            } catch (Error e) {
                window.show_toast ("Delete failed: " + e.message);
            }
        }
    }
}
