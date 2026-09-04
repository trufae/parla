namespace Dc {

    /**
     * A single row in the chat list sidebar.
     * Shows avatar placeholder, chat name, last message preview, time, and unread badge.
     * Can switch between full and compact (avatar-only) presentations.
     */
    public class ChatRow : Gtk.Box {

        public int chat_id { get; private set; }

        private Gtk.Box mid_box;
        private Gtk.Overlay avatar_overlay;
        private Gtk.Widget? compact_unread_marker = null;
        private Gtk.Image? compact_pin_icon = null;
        private bool compact = false;
        private FileDropTarget? file_drop_target;

        public signal bool accept_file_drop ();
        public signal void file_dropped (string path, string name);
        public signal void file_drop_failed (string message);

        public ChatRow (ChatEntry entry) {
            Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 10);
            this.chat_id = entry.id;
            bool is_request = entry.is_contact_request;
            bool has_unread = entry.unread_count > 0 && !is_request;
            bool is_muted = entry.is_muted;
            bool is_pinned = entry.is_pinned;
            bool has_mention = entry.has_mention;
            add_css_class ("chat-row");
            if (has_mention) add_css_class ("chat-row-mention");
            set_margins (8, 4);

            /* Avatar circle wrapped in an overlay so we can stick compact-mode
               badge/pin markers on top of it. */
            var avatar = presence_avatar (40, entry.name, entry.avatar_path,
                entry.was_seen_recently, null, "list-presence-avatar-ring");

            avatar_overlay = new Gtk.Overlay ();
            avatar_overlay.child = avatar;
            avatar_overlay.valign = Gtk.Align.CENTER;
            avatar_overlay.halign = Gtk.Align.CENTER;

            /* Compact unread indicator (badge or count) — shown only in compact */
            if (is_request) {
                compact_unread_marker = add_compact_marker (
                    new Gtk.Label ("!"), "compact-request-marker", Gtk.Align.START);
            } else if (has_unread) {
                int n = entry.unread_count;
                compact_unread_marker = add_compact_marker (
                    new Gtk.Label (n > 99 ? "99+" : n.to_string ()),
                    is_muted ? "compact-unread-badge-muted" : "compact-unread-badge",
                    Gtk.Align.START);
            }

            /* Compact pin indicator — small bottom-right dot */
            if (is_pinned) {
                compact_pin_icon = new Gtk.Image.from_icon_name ("view-pin-symbolic");
                compact_pin_icon.pixel_size = 12;
                add_compact_marker (compact_pin_icon, "compact-pin-marker", Gtk.Align.END);
            }

            append (avatar_overlay);

            /* Middle: name + preview (hidden in compact mode) */
            mid_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            mid_box.hexpand = true;
            mid_box.valign = Gtk.Align.CENTER;

            /* Top row: name + time */
            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

            if (has_unread) {
                var dot = new Gtk.Label ("●");
                dot.add_css_class (is_muted ? "unread-dot-muted" : "unread-dot");
                top.append (dot);
            }

            if (has_mention) {
                var at = new Gtk.Label ("@");
                at.add_css_class ("mention-marker");
                at.tooltip_text = "You were mentioned";
                top.append (at);
            }

            var name_label = expanding_label (entry.name);
            name_label.add_css_class ("heading");
            if (has_unread) name_label.add_css_class ("unread-name");
            top.append (name_label);

            if (is_muted) {
                var mute_icon = new Gtk.Image.from_icon_name (
                    "notifications-disabled-symbolic");
                mute_icon.pixel_size = 12;
                mute_icon.add_css_class ("dim-label");
                mute_icon.tooltip_text = "Notifications muted";
                top.append (mute_icon);
            }

            if (is_pinned) {
                var pin_label = new Gtk.Label ("📌");
                pin_label.add_css_class ("dim-label");
                pin_label.add_css_class ("caption");
                top.append (pin_label);
            }

            var time_label = new Gtk.Label (format_time (entry.timestamp));
            time_label.add_css_class ("dim-label");
            time_label.add_css_class ("caption");
            top.append (time_label);

            mid_box.append (top);

            /* Bottom row: preview + badge */
            var bot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var preview_label = expanding_label (
                MessageRow.spread_adjacent_emoji (format_preview (entry)));
            if (!has_unread) preview_label.add_css_class ("dim-label");
            preview_label.max_width_chars = 30;
            bot.append (preview_label);

            /* Contact requests get a "Request" label instead of a count badge */
            if (is_request || has_unread) {
                var badge_label = new Gtk.Label (
                    is_request ? "Request" : entry.unread_count.to_string ());
                badge_label.add_css_class (is_request ? "contact-request-badge"
                    : is_muted ? "unread-badge-muted" : "unread-badge");
                badge_label.halign = Gtk.Align.END;
                badge_label.valign = Gtk.Align.CENTER;
                bot.append (badge_label);
            }

            mid_box.append (bot);
            append (mid_box);

            /* Treat every chat row as a file destination. The window decides
               whether this particular chat can currently accept an
               attachment and switches to it when the drop completes. */
            file_drop_target = new FileDropTarget (this);
            file_drop_target.accept.connect (() => accept_file_drop ());
            file_drop_target.dropped.connect ((path, name) => file_dropped (path, name));
            file_drop_target.failed.connect ((message) => file_drop_failed (message));
        }

        public void set_compact (bool compact) {
            if (this.compact == compact) return;
            this.compact = compact;
            mid_box.visible = !compact;
            avatar_overlay.hexpand = compact;
            if (compact) {
                set_margins (0, 2);
                add_css_class ("chat-row-compact");
            } else {
                set_margins (8, 4);
                remove_css_class ("chat-row-compact");
            }
            if (compact_unread_marker != null) compact_unread_marker.visible = compact;
            if (compact_pin_icon != null) compact_pin_icon.visible = compact;
        }

        /* Start-aligned label that takes the remaining width and ellipsizes. */
        private static Gtk.Label expanding_label (string text) {
            var label = new Gtk.Label (text);
            label.ellipsize = Pango.EllipsizeMode.END;
            label.hexpand = true;
            label.halign = Gtk.Align.START;
            label.xalign = 0;
            return label;
        }

        private void set_margins (int horizontal, int vertical) {
            margin_start = horizontal;
            margin_end = horizontal;
            margin_top = vertical;
            margin_bottom = vertical;
        }

        /* Overlay marker on the avatar, hidden until set_compact shows it. */
        private Gtk.Widget add_compact_marker (Gtk.Widget marker, string css,
                                               Gtk.Align valign) {
            marker.add_css_class (css);
            marker.halign = Gtk.Align.END;
            marker.valign = valign;
            marker.visible = false;
            avatar_overlay.add_overlay (marker);
            return marker;
        }

        private static string format_preview (ChatEntry entry) {
            string preview = Markdown.single_line_preview (
                entry.last_message ?? "", 0);
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
            bool is_archived = false;
            bool is_muted = false;
            bool has_unread = false;
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) {
                is_pinned = entry.is_pinned;
                is_archived = entry.is_archived;
                is_muted = entry.is_muted;
                has_unread = entry.unread_count > 0;
            }

            var popover = new Gtk.Popover ();
            popover.has_arrow = false;
            popover.set_parent (parent);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.add_css_class ("menu");

            /* Same visibility matrix as the official client: an archived
               chat only offers Unarchive (pinning would unarchive it). */
            if (!is_archived) {
                append_menu_button (box, popover,
                    is_pinned ? "Unpin" : "Pin").selected.connect (() => {
                        toggle_pin.begin (chat_id, is_pinned);
                    });
            }
            append_menu_button (box, popover,
                is_archived ? "Unarchive" : "Archive").selected.connect (() => {
                    toggle_archive.begin (chat_id, is_archived);
                });
            /* Mute is normally managed from the Details dialog, but for
               archived chats it is the mechanism that keeps them archived
               (core auto-unarchives unmuted chats on new messages), so it
               earns a direct entry here. */
            if (is_archived) {
                append_menu_button (box, popover,
                    is_muted ? "Unmute" : "Mute").selected.connect (() => {
                        set_mute_state.begin (chat_id, !is_muted, null);
                    });
            }
            append_menu_button (box, popover,
                has_unread ? "Mark as read" : "Mark as unread",
                false, has_unread || chat_id != window.current_chat_id)
                .selected.connect (() => {
                    set_unread_state.begin (chat_id, !has_unread);
                });
            append_menu_button (box, popover, "View Media")
                .selected.connect (() => { show_media (chat_id); });
            append_menu_button (box, popover, "Details…")
                .selected.connect (() => { show_info (chat_id); });
            box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            append_menu_button (box, popover, "Clear Chat…", true)
                .selected.connect (() => {
                    confirm_clear_history.begin (chat_id);
                });
            if (entry != null && entry.kind == ChatKind.GROUP) {
                append_menu_button (box, popover, "Leave…", true)
                    .selected.connect (() => { confirm_leave.begin (chat_id); });
            }
            append_menu_button (box, popover, "Delete…", true)
                .selected.connect (() => { confirm_delete.begin (chat_id); });

            popover.child = box;
            unparent_on_close (popover);
            popover.popup ();
        }

        private static PopoverButton append_menu_button (
                Gtk.Box box, Gtk.Popover popover, string label,
                bool destructive = false, bool sensitive = true) {
            var btn = new PopoverButton (popover, label, destructive);
            btn.sensitive = sensitive;
            box.append (btn);
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

        private async void toggle_archive (int chat_id, bool currently_archived) {
            var entry = find_chat_entry (chat_store, chat_id);
            bool already_muted = entry != null && entry.is_muted;
            try {
                yield rpc.set_chat_visibility (chat_id,
                    currently_archived ? "Normal" : "Archived");
                if (currently_archived) {
                    window.show_toast ("Chat unarchived");
                } else if (already_muted) {
                    window.show_toast ("Chat archived");
                } else {
                    /* Unmuted chats pop back on the next message; offer the
                       one-click way to make the archive stick. */
                    var toast = window.show_action_toast (
                        "Chat archived. New messages will unarchive it.",
                        "Mute");
                    toast.button_clicked.connect (() => {
                        set_mute_state.begin (chat_id, true,
                            "Muted. Chat will stay archived.");
                    });
                }
                yield window.load_chats ();
            } catch (Error e) {
                window.show_toast ("Failed to update archive: " + e.message);
            }
        }

        private async void set_mute_state (int chat_id, bool mute,
                                           string? done_message) {
            try {
                yield rpc.set_chat_mute_duration (chat_id, mute ? -1 : 0);
                window.show_toast (done_message ??
                    (mute ? "Chat muted" : "Chat unmuted"));
                window.request_reload_chats ();
            } catch (Error e) {
                window.show_toast ("Failed to update mute: " + e.message);
            }
        }

        private async void set_unread_state (int chat_id, bool unread) {
            try {
                if (unread) {
                    yield rpc.markfresh_chat (chat_id);
                } else {
                    yield rpc.marknoticed_chat (chat_id);
                }
                window.request_reload_chats ();
                window.show_toast (unread ? "Marked unread" : "Marked read");
            } catch (Error e) {
                window.show_toast ("Failed to update unread marker: " + e.message);
            }
        }

        private void show_media (int chat_id) {
            var entry = find_chat_entry (chat_store, chat_id);
            var dialog = new GalleryDialog (window, rpc, chat_id,
                                            entry != null ? entry.name : null);
            dialog.present (window);
        }

        public void show_info (int chat_id) {
            var dialog = new ChatInfoDialog (window, rpc, chat_id);

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

            dialog.contact_blocked.connect ((cid) => {
                window.show_toast ("Contact blocked");
                if (window.current_chat_id == cid)
                    window.clear_chat_view ();
                window.request_reload_chats ();
            });

            dialog.present (window);
        }

        private async void confirm_clear_history (int chat_id) {
            string chat_name = "this chat";
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) chat_name = entry.name;

            if (yield confirm_action (window, "Clear Chat",
                "Remove all messages in \"%s\" from this device? The chat will stay in your conversation list.".printf (chat_name),
                "clear", "Clear Chat"))
                do_clear_history.begin (chat_id, false);
        }

        private async void confirm_leave (int chat_id) {
            string chat_name = "this chat";
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) chat_name = entry.name;

            if (yield confirm_action (window, "Leave Group",
                "Leave \"%s\"? You will stop receiving messages and the chat will be removed from your list.".printf (chat_name),
                "leave", "Leave"))
                do_leave.begin (chat_id);
        }

        private async void do_leave (int chat_id) {
            try {
                yield rpc.leave_group (chat_id);
                yield rpc.delete_chat (chat_id);
                window.show_toast ("You left the chat");
                if (window.current_chat_id == chat_id)
                    window.clear_chat_view ();
                yield window.load_chats ();
            } catch (Error e) {
                window.show_toast ("Leave failed: " + e.message);
            }
        }

        private async void confirm_delete (int chat_id) {
            string chat_name = "this chat";
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) chat_name = entry.name;

            if (yield confirm_action (window, "Delete Chat",
                "Remove \"%s\" from your conversation list? You may still receive new messages if you are a member.".printf (chat_name),
                "delete", "Delete"))
                do_delete.begin (chat_id);
        }

        private async void do_clear_history (int chat_id, bool for_all) {
            try {
                int[] ids = yield chat_message_ids_for_clear (
                    rpc, rpc.account_id, chat_id, for_all);
                if (ids.length > 0) {
                    if (for_all) yield rpc.delete_messages_for_all (ids);
                    else yield rpc.delete_messages (ids);
                } else if (for_all) {
                    window.show_toast ("No sent messages to clear for everyone");
                    return;
                }
                window.show_toast (for_all
                    ? "Sent messages cleared for everyone" : "Chat cleared");
                if (window.current_chat_id == chat_id)
                    window.request_messages_reload ();
                window.request_reload_chats ();
            } catch (Error e) {
                window.show_toast ("Clear failed: " + e.message);
            }
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
