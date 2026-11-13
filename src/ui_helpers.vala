namespace Dc {

    public enum DeleteChoice { CANCEL, FOR_ME, FOR_EVERYONE }
    public enum LeaveChoice { CANCEL, KEEP_HISTORY, DELETE_HISTORY }

    // Manual deletion is synced by core; it is not a device-only cache purge.
    /* Long explanations shared by the delete/clear confirmations.
       Marked with N_ so xgettext picks them up from this const
       initializer; call sites wrap them with _() at display time. */
    public const string DELETE_FOR_ME_DESCRIPTION = N_(
        "Messages and their attachments, including in-chat apps, are removed from this history. Deletion is also requested on the server and linked devices using this profile. Other participants keep their copies.");
    public const string DELETE_COPIES_DESCRIPTION = N_(
        "Files saved elsewhere, forwarded copies and backups are not removed. This cannot be undone.");

    /** Flat, left-aligned button for hand-built popover menus. It closes
        its popover before emitting selected from an idle. */
    public class PopoverButton : Gtk.Button {
        private WeakRef popover_ref;

        public signal void selected ();

        public PopoverButton (Gtk.Popover popover, string label,
                              bool destructive = false,
                              bool hexpand = false, string? accel = null,
                              bool menu_item = false) {
            Object (label: label, hexpand: hexpand);
            add_css_class ("flat");
            if (menu_item) {
                /* Gtk.Button text follows the theme's bold button typography,
                   unlike the GtkModelButton rows replaced for AccessKit. */
                add_css_class ("menu-item");
            }
            if (destructive) add_css_class ("menu-destructive");
            var label_widget = child as Gtk.Label;
            if (label_widget != null) {
                label_widget.xalign = 0;
                label_widget.halign = Gtk.Align.START;
            }
            if (accel != null) add_accel_hint (label, accel);
            popover_ref = WeakRef (popover);
        }

        /* Right-aligned shortcut hint, as GtkPopoverMenu shows one. The
           custom child drops GTK's own label relation, so the accessible
           name and shortcut are restated by hand. */
        private void add_accel_hint (string label, string accel) {
            var text = child;
            text.hexpand = true;
            var hint = new Gtk.Label (accel);
            hint.add_css_class ("dim-label");
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 24);
            child = row;
            row.append (text);
            row.append (hint);
            /* Keep the padding of a label-only button. */
            add_css_class ("text-button");
#if A11Y
            update_property (Gtk.AccessibleProperty.LABEL, label,
                             Gtk.AccessibleProperty.KEY_SHORTCUTS, accel, -1);
#endif
        }

        public override void clicked () {
            sensitive = false;
            var popover = popover_ref.get () as Gtk.Popover;
            if (popover != null) popover.popdown ();
            /* Re-enabled for popovers that outlive one activation. */
            Idle.add (() => { selected (); sensitive = true; return Source.REMOVE; });
        }
    }

    public static void show_error (Gtk.Widget parent, string message) {
        var d = new Adw.AlertDialog (_("Error"), message);
        d.add_response ("ok", "OK");
        d.present (parent);
    }

    // Vertically-centered flat button, shared by dialogs and header bars.
    public static Gtk.Button flat_button (string label, bool error = false) {
        var button = new Gtk.Button.with_label (label);
        button.valign = Gtk.Align.CENTER;
        button.add_css_class ("flat");
        if (error) button.add_css_class ("error");
        return button;
    }

    public static Gtk.Button flat_icon_button (string icon_name, string tooltip,
                                               bool error = false) {
        var button = new Gtk.Button.from_icon_name (icon_name);
        button.valign = Gtk.Align.CENTER;
        button.add_css_class ("flat");
        if (error) button.add_css_class ("error");
        button.tooltip_text = tooltip;
        return button;
    }

    public static bool is_dialog_dismissal (Error error) {
        return error is IOError.CANCELLED
            || error is Gtk.DialogError.CANCELLED
            || error is Gtk.DialogError.DISMISSED;
    }

    public static async bool confirm_action (Gtk.Widget parent, string title,
                                             string body, string action_id,
                                             string action_label) {
        var d = new Adw.AlertDialog (title, body);
        d.add_response ("cancel", _("Cancel"));
        d.add_response (action_id, action_label);
        d.set_response_appearance (action_id, Adw.ResponseAppearance.DESTRUCTIVE);
        d.default_response = "cancel";
        d.close_response = "cancel";
        return (yield d.choose (parent, null)) == action_id;
    }

    // Single-line text prompt with a suggested confirm action. Returns the
    // entered text (unstripped) on confirm, null if cancelled/dismissed.
    public static async string? prompt_text (Gtk.Widget parent, string title,
                                             string? body, string action_label,
                                             string initial = "",
                                             string? placeholder = null) {
        var d = new Adw.AlertDialog (title, body);
        d.add_response ("cancel", _("Cancel"));
        d.add_response ("ok", action_label);
        d.set_response_appearance ("ok", Adw.ResponseAppearance.SUGGESTED);
        d.default_response = "ok";
        d.close_response = "cancel";

        var entry = new Gtk.Entry ();
        entry.text = initial;
        entry.hexpand = true;
        entry.activates_default = true;
        if (placeholder != null) entry.placeholder_text = placeholder;
        d.extra_child = entry;

        if ((yield d.choose (parent, null)) != "ok") return null;
        return entry.text;
    }

    public static async DeleteChoice confirm_message_deletion (
            Gtk.Widget parent, RpcClient rpc, int[] ids) {
        if (ids.length == 0) return DeleteChoice.CANCEL;
        int account_id = rpc.account_id;
        bool allow_delete_for_everyone;
        try {
            allow_delete_for_everyone = yield can_delete_messages_for_everyone (
                rpc, ids);
        } catch (Error e) {
            show_error (parent, _("Could not check message deletion options: ") + e.message);
            return DeleteChoice.CANCEL;
        }
        if (rpc.account_id != account_id) return DeleteChoice.CANCEL;
        string title = ids.length == 1 ? _("Delete Message?")
            : _("Delete %d Messages?").printf (ids.length);
        string body = _("Delete for Me: ") + _(DELETE_FOR_ME_DESCRIPTION);
        if (allow_delete_for_everyone) {
            body += "\n\n" + _("Delete for Everyone also asks other participants’ apps to delete these messages. Saved or forwarded copies may remain.");
        }
        body += "\n\n" + _(DELETE_COPIES_DESCRIPTION);
        var d = new Adw.AlertDialog (title, body);
        d.add_response ("cancel", _("Cancel"));
        d.add_response ("delete_me", _("Delete for Me"));
        d.set_response_appearance ("delete_me", Adw.ResponseAppearance.DESTRUCTIVE);
        if (allow_delete_for_everyone) {
            d.add_response ("delete_all", _("Delete for Everyone"));
            d.set_response_appearance ("delete_all",
                Adw.ResponseAppearance.DESTRUCTIVE);
        }
        d.default_response = "cancel";
        d.close_response = "cancel";
        string response = yield d.choose (parent, null);
        if (rpc.account_id != account_id) return DeleteChoice.CANCEL;
        if (response == "delete_me") return DeleteChoice.FOR_ME;
        if (response == "delete_all") return DeleteChoice.FOR_EVERYONE;
        return DeleteChoice.CANCEL;
    }

    public static async bool can_delete_messages_for_everyone (
            RpcClient rpc, int[] ids) throws Error {
        if (ids.length == 0) return false;
        int account_id = rpc.account_id;
        var messages = yield rpc.get_messages_for (account_id, ids);
        if (messages == null) return false;
        int chat_id = MessageDeletion.common_chat (messages, ids);
        if (chat_id == 0) return false;
        var chat = yield rpc.get_full_chat_by_id_for (account_id, chat_id);
        return chat != null && MessageDeletion.can_delete_in_chat (chat);
    }

    public static async bool confirm_chat_deletion (Gtk.Widget parent,
                                                    string name) {
        return yield confirm_action (parent, _("Delete Chat?"),
            _("Delete “%s” and its messages?\n\n").printf (name)
            + _(DELETE_FOR_ME_DESCRIPTION)
            + "\n\n" + _("Any draft in this chat is also deleted. This does not leave a group or channel, unsubscribe from a mailing list, or block a contact. New messages may make the chat appear again.")
            + "\n\n" + _(DELETE_COPIES_DESCRIPTION),
            "delete", _("Delete Chat"));
    }

    public static async bool confirm_chat_clear (Gtk.Widget parent,
                                                string name, bool for_all,
                                                int count) {
        string body = (count == 1 ? _("Delete 1 message in “%s”?").printf (name)
            : _("Delete %d messages in “%s”?").printf (count, name)) + "\n\n";
        body += for_all
            ? _("Only encrypted messages sent by this profile are selected. They and their attachments, including in-chat apps, are removed from this history, and deletion is requested on the server, linked devices and other participants’ apps. Messages from other people, unencrypted messages and status messages are kept.")
            : _(DELETE_FOR_ME_DESCRIPTION);
        return yield confirm_action (parent,
            for_all ? _("Delete Sent Messages for Everyone?") : _("Clear Chat?"),
            body + "\n\n" + _("The chat, its draft and messages arriving after this confirmation opens are kept.")
                + "\n\n" + _(DELETE_COPIES_DESCRIPTION),
            "clear", for_all ? _("Delete for Everyone") : _("Clear for Me"));
    }

    public static bool can_leave_chat (Json.Object chat) {
        bool member = chat.has_member ("contactIds")
            && (1 in json_int_array (chat.get_member ("contactIds")));
        return ChatActions.can_leave (json_str (chat, "chatType") ?? "",
            json_bool (chat, "isEncrypted"), member,
            json_bool (chat, "isContactRequest"));
    }

    public static async LeaveChoice confirm_group_leave (Gtk.Widget parent,
                                                         RpcClient rpc, int chat_id) {
        int account_id = rpc.account_id;
        Json.Object? chat;
        try {
            chat = yield rpc.get_full_chat_by_id_for (account_id, chat_id);
        } catch (Error e) {
            show_error (parent, _("Could not check group membership: ") + e.message);
            return LeaveChoice.CANCEL;
        }
        if (account_id != rpc.account_id) return LeaveChoice.CANCEL;
        if (chat == null || !can_leave_chat (chat)) {
            show_error (parent, _("This group or channel can no longer be left."));
            return LeaveChoice.CANCEL;
        }
        bool channel = json_str (chat, "chatType") == "InBroadcast";
        string leave_label = channel ? _("Leave Channel") : _("Leave Group");
        string body = _("Leave “%s” and stop receiving new messages?").printf (
            json_str (chat, "name") ?? _("this chat"));
        if (!channel && !json_bool (chat, "isUnpromoted"))
            body += _(" Other members will be notified.");
        body += "\n\n" + (_("%s keeps the chat history. Leave and Delete also deletes the chat, its draft, messages and attachments for this profile. Deletion is requested on the server and linked devices. Other participants keep their history.").printf (leave_label))
            + "\n\n" + _(DELETE_COPIES_DESCRIPTION);
        var d = new Adw.AlertDialog (channel ? _("Leave Channel?") : _("Leave Group?"), body);
        d.add_response ("cancel", _("Cancel"));
        d.add_response ("leave", leave_label);
        d.add_response ("delete", _("Leave and Delete"));
        d.set_response_appearance ("leave", Adw.ResponseAppearance.DESTRUCTIVE);
        d.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        d.default_response = "cancel";
        d.close_response = "cancel";
        string response = yield d.choose (parent, null);
        if (account_id != rpc.account_id) return LeaveChoice.CANCEL;
        if (response == "leave") return LeaveChoice.KEEP_HISTORY;
        if (response == "delete") return LeaveChoice.DELETE_HISTORY;
        return LeaveChoice.CANCEL;
    }

    public static async bool confirm_chat_block (Gtk.Widget parent,
                                                 string name, bool contact) {
        return yield confirm_action (parent,
            contact ? _("Block Contact?") : _("Block Chat?"),
            _("Block “%s”? The chat is hidden and its history is kept. Blocking syncs to linked devices using this profile.").printf (name)
            + "\n\n"
            + (contact
                ? _("Direct messages from this contact will be blocked. Their messages in shared groups can still appear. The contact is not notified.")
                : _("New messages in this chat will be hidden. This does not leave a channel or unsubscribe from a mailing list."))
            + "\n\n" + _("Unblock it later from Profile → Blocked Contacts."),
            "block", contact ? _("Block Contact") : _("Block Chat"));
    }

    /** Skeleton for hand-built popover menus: a no-arrow popover pointing
        at (x, y) in parent whose child is a vertical "menu" box ready for
        PopoverButton rows. Unparents itself after closing. */
    public static Gtk.Popover popover_menu (Gtk.Widget parent,
                                            double x, double y,
                                            out Gtk.Box vbox) {
        var popover = new Gtk.Popover ();
        popover.has_arrow = false;
        popover.set_parent (parent);
        popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });

        vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        vbox.add_css_class ("menu");
        vbox.margin_start = 8;
        vbox.margin_end = 8;
        vbox.margin_top = 8;
        vbox.margin_bottom = 8;
        popover.child = vbox;

        unparent_on_close (popover);
        return popover;
    }

    /** Unparent a manually-parented popover once it closes, from an idle:
        tearing it down inside its own closed handler upsets GTK. Call after
        set_parent and before popup so the focus can be restored. */
    public static void unparent_on_close (Gtk.Popover popover) {
        restore_focus_on_close (popover);
        popover.closed.connect (on_popover_closed);
    }

    /* After closing, GTK hands the focus to the popover's parent: for the
       message list that focuses (and highlights) a row instead of returning
       to the composer. Put back whatever had it before the popover opened.
       HIGH_IDLE runs after GTK's fallback but before the redraw and before
       PopoverButton.selected, so menu actions can still move the focus. */
    private static void restore_focus_on_close (Gtk.Popover popover) {
        var root = popover.get_root ();
        var previous = root != null ? root.get_focus () : null;
        WeakRef previous_ref = WeakRef (previous);
        popover.closed.connect ((closed) => {
            /* closed runs before GTK's cascade_popdown focuses the parent.
               Even a temporary focus on the first list row scrolls its
               viewport, and restoring an offscreen cursor scrolls it again. */
            var viewport = hold_focus_scroll (closed);
            WeakRef popover_ref = WeakRef (closed);
            Idle.add_full (Priority.HIGH_IDLE, () => {
                restore_popover_focus (popover_ref, previous_ref);
                release_focus_scroll (viewport);
                return Source.REMOVE;
            });
        });
    }

    private static void restore_popover_focus (WeakRef popover_ref, WeakRef previous_ref) {
        var p = popover_ref.get () as Gtk.Popover;
        var target = previous_ref.get () as Gtk.Widget;
        if (p == null || target == null) return;
        var r = p.get_root ();
        var parent = p.get_parent ();
        if (r == null || target.get_root () != r) return;
        var focus = r.get_focus ();
        /* Only undo GTK's fallback into the parent, not a move
           elsewhere such as an opened dialog. */
        if (focus != target && (focus == null || focus == parent
                || focus.is_ancestor (p)
                || (parent != null && focus.is_ancestor (parent))))
            target.grab_focus ();
    }

    /* Nestable because a menu may close its parent menu, or a list refresh
       may run during focus restoration. Keyboard navigation outside these
       short, synchronous focus transfers keeps GTK's normal scrolling. */
    internal static Gtk.Viewport? hold_focus_scroll (Gtk.Widget widget) {
        var viewport = widget.get_ancestor (typeof (Gtk.Viewport)) as Gtk.Viewport;
        if (viewport == null) return null;
        int holds = viewport.get_data<int> ("parla-focus-scroll-holds");
        if (holds == 0) {
            viewport.set_data<bool> ("parla-focus-scroll-enabled", viewport.scroll_to_focus);
            viewport.scroll_to_focus = false;
        }
        viewport.set_data<int> ("parla-focus-scroll-holds", holds + 1);
        return viewport;
    }

    internal static void release_focus_scroll (Gtk.Viewport? viewport) {
        if (viewport == null) return;
        int holds = viewport.get_data<int> ("parla-focus-scroll-holds") - 1;
        viewport.set_data<int> ("parla-focus-scroll-holds", holds);
        if (holds == 0)
            viewport.scroll_to_focus = viewport.get_data<bool> ("parla-focus-scroll-enabled");
    }

    private static void on_popover_closed (Gtk.Popover popover) {
        Idle.add (() => { popover.unparent (); return Source.REMOVE; });
    }

    public static void install_escape_close (Adw.Dialog dialog) {
        var kc = new Gtk.EventControllerKey ();
        kc.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        Signal.connect_object (kc, "key-pressed",
            (Callback) on_dialog_key_pressed, dialog, (ConnectFlags) 0);
        ((Gtk.Widget) dialog).add_controller (kc);
    }

    private static bool on_dialog_key_pressed (Gtk.EventControllerKey controller,
                                                uint keyval, uint keycode,
                                                Gdk.ModifierType state,
                                                Adw.Dialog dialog) {
        if (keyval != Gdk.Key.Escape) return false;
        /* Step back through an inner navigation view (an app detail page,
           say) before closing the whole dialog, matching Adw's own
           Escape behaviour. */
        var nav = find_navigation_view (dialog);
        if (nav != null) {
            var page = nav.get_visible_page ();
            if (page != null && nav.get_previous_page (page) != null) {
                nav.pop ();
                return true;
            }
        }
        dialog.close ();
        return true;
    }

    private static Adw.NavigationView? find_navigation_view (Gtk.Widget root) {
        for (var c = root.get_first_child (); c != null;
             c = c.get_next_sibling ()) {
            if (c is Adw.NavigationView) return (Adw.NavigationView) c;
            var inner = find_navigation_view (c);
            if (inner != null) return inner;
        }
        return null;
    }

    public static Gdk.Texture? load_avatar (string? path) {
        if (path != null && path.length > 0 &&
            FileUtils.test (path, FileTest.EXISTS)) {
            try {
                return Gdk.Texture.from_filename (path);
            } catch (Error e) { /* fallback */ }
        }
        return null;
    }

    /* ---- Widget helpers ---- */

    public static void clear_listbox (Gtk.ListBox lb) {
        Gtk.ListBoxRow? row;
        while ((row = lb.get_row_at_index (0)) != null) {
            lb.remove (row);
        }
    }

    public static async int[] chat_message_ids_for_clear (RpcClient rpc,
                                                           int account_id,
                                                           int chat_id,
                                                           bool for_all,
                                                           int64 older_than = 0) throws Error {
        var msg_ids = yield rpc.get_message_ids_for (account_id, chat_id);
        if (msg_ids == null || msg_ids.get_length () == 0) return {};

        int[] all_ids = new int[msg_ids.get_length ()];
        for (uint i = 0; i < msg_ids.get_length (); i++) {
            all_ids[i] = (int) msg_ids.get_int_element (i);
        }
        if (!for_all && older_than == 0) return all_ids;

        if (for_all) {
            var chat = yield rpc.get_full_chat_by_id_for (account_id, chat_id);
            if (chat == null || !MessageDeletion.can_delete_in_chat (chat)) return {};
        }
        int[] ids = {};
        for (int start = 0; start < all_ids.length; start += 200) {
            int end = int.min (start + 200, all_ids.length);
            var map = yield rpc.get_messages_for (account_id, all_ids[start:end]);
            if (map == null) throw new IOError.FAILED (_("Could not load messages to clear"));
            for (int i = start; i < end; i++) {
                var message = MessageDeletion.message_by_id (map, all_ids[i]);
                if (message == null || json_int (message, "chatId") != chat_id) continue;
                if (older_than > 0 && !MessageDeletion.is_older_than (
                        message, chat_id, older_than)) continue;
                if (!for_all || MessageDeletion.can_delete_for_everyone (message))
                    ids += all_ids[i];
            }
        }
        return ids;
    }

    public static async LocalFile? pick_image_file (Gtk.Window parent, string title) {
        var chooser = new Gtk.FileDialog ();
        chooser.title = title;
        var filter = new Gtk.FileFilter ();
        filter.add_mime_type ("image/*");
        filter.name = _("Images");
        var filters = new ListStore (typeof (Gtk.FileFilter));
        filters.append (filter);
        chooser.filters = filters;
        try {
            var file = yield chooser.open (parent, null);
            if (file != null) return yield LocalFile.from_file (file);
        } catch (Error e) {
            if (!is_dialog_dismissal (e))
                show_error (parent, e.message);
        }
        return null;
    }

    public static Adw.ActionRow contact_row (Contact c, bool activatable = false,
                                             bool show_presence = true) {
        string title = c.display_name.length > 0 ? c.display_name : c.address;
        string subtitle = c.display_name.length > 0 ? c.address : "";
        if (c.is_blocked && subtitle.length > 0) subtitle += " (blocked)";
        else if (c.is_blocked) subtitle = "(blocked)";

        var row = new Adw.ActionRow ();
        row.use_markup = false;
        row.title = title;
        row.subtitle = subtitle;
        row.activatable = activatable;

        row.add_prefix (presence_avatar (32, title, c.profile_image,
            show_presence && c.was_seen_recently, null,
            "list-presence-avatar-ring"));
        return row;
    }

    public static Adw.ActionRow chat_pick_row (ChatEntry chat) {
        var row = new Adw.ActionRow ();
        row.use_markup = false;
        row.title = chat.name;
        row.title_lines = 1;
        row.subtitle_lines = 1;
        if (chat.last_message != null && chat.last_message.length > 0) {
            row.subtitle = Markdown.single_line_preview (chat.last_message, 0);
        }
        row.name = chat.id.to_string ();
        row.activatable = true;

        row.add_prefix (presence_avatar (32, chat.name, chat.avatar_path,
            chat.was_seen_recently, null, "list-presence-avatar-ring"));
        return row;
    }

    public static Gtk.Widget presence_avatar (int size, string text,
                                               string? path, bool online,
                                               string? avatar_css = null,
                                               string? ring_css = null) {
        var avatar = new Adw.Avatar (size, text, true);
        avatar.custom_image = load_avatar (path);
        if (avatar_css != null && avatar_css.length > 0) {
            avatar.add_css_class (avatar_css);
        }
        if (!online) return avatar;

        var ring = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        /* The ring's CSS background is circular only at its natural square
           size.  Action rows and other list layouts can otherwise stretch a
           fill-aligned Box along one axis, making the glow oval. */
        ring.halign = Gtk.Align.CENTER;
        ring.valign = Gtk.Align.CENTER;
        ring.add_css_class ("presence-avatar-ring");
        if (size <= 24) ring.add_css_class ("presence-avatar-ring-small");
        if (ring_css != null && ring_css.length > 0) {
            ring.add_css_class (ring_css);
        }
        ring.append (avatar);
        return ring;
    }

}
