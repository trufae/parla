namespace Dc {

    /* Mute presets; seconds < 0 means forever (matches the official
       app's set). */
    public const string[] MUTE_DURATION_LABELS = {
        "For 1 hour", "For 8 hours", "For 1 day", "For 7 days", "Forever"
    };
    public const int[] MUTE_DURATION_SECONDS = {
        3600, 28800, 86400, 604800, -1
    };

    public delegate void RowActivated ();
    public delegate void ComboSelected (uint index);

    public class ChatInfoDialog : Adw.Dialog {

        private unowned Window app_window;
        private RpcClient rpc;
        private int chat_id;
        private bool is_group = false;
        private Gtk.ListBox? members_list = null;
        private Gtk.Box content;
        private ImageViewer viewer;
        private string chat_name = "";
        private bool is_channel = false;
        private bool can_edit_members = false;
        private bool is_unpromoted = false;
        private Contact? dm_contact = null;

        public signal void chat_deleted (int chat_id);
        public signal void chat_changed ();
        public signal void contact_blocked (int chat_id);

        private Gtk.ListBox boxed_list () {
            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            return list;
        }

        private Adw.ActionRow action_row (string title, string subtitle,
                                          string icon_name) {
            var row = new Adw.ActionRow ();
            row.title = title;
            row.subtitle = subtitle;
            row.add_prefix (new Gtk.Image.from_icon_name (icon_name));
            row.activatable = true;
            return row;
        }

        // ActionRow carrying a trailing drop-down; on_selected fires with the
        // chosen index.
        private Adw.ActionRow dropdown_row (string title, string[] labels,
                                            uint active, ComboSelected on_selected) {
            var row = new Adw.ActionRow ();
            row.title = title;
            var combo = new Gtk.DropDown.from_strings (labels);
            combo.selected = active;
            combo.valign = Gtk.Align.CENTER;
            combo.notify["selected"].connect (() => on_selected (combo.selected));
            row.add_suffix (combo);
            row.activatable_widget = combo;
            return row;
        }

        // action_row + its activation handler + append, in one call.
        private Adw.ActionRow add_action_row (Gtk.ListBox list, string title,
                                              string subtitle, string icon,
                                              RowActivated activate) {
            var row = action_row (title, subtitle, icon);
            row.activated.connect (() => activate ());
            list.append (row);
            return row;
        }

        public ChatInfoDialog (Window window, RpcClient rpc, int chat_id) {
            this.app_window = window;
            this.rpc = rpc;
            this.chat_id = chat_id;
            this.title = "Chat Details";
            this.content_width = 360;
            this.content_height = 500;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            header.show_end_title_buttons = true;
            box.append (header);

            content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = 16;
            content.margin_end = 16;
            content.margin_top = 12;
            content.margin_bottom = 16;

            var spinner = new Gtk.Spinner ();
            spinner.spinning = true;
            spinner.halign = Gtk.Align.CENTER;
            spinner.margin_top = 40;
            content.append (spinner);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = content;
            box.append (scroll);

            /* Same fullscreen viewer the conversation uses, overlaid on the
               dialog (the window-level one would be hidden behind it). */
            viewer = new ImageViewer ();
            viewer.set_window (window);

            var overlay = new Gtk.Overlay ();
            overlay.child = box;
            overlay.add_overlay (viewer.widget);
            this.child = overlay;

            /* Route keys to the viewer while it is open, so Escape closes
               the viewer, not the dialog. */
            var kc = new Gtk.EventControllerKey ();
            kc.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            kc.key_pressed.connect ((kv, code, state) => {
                if (viewer.visible) return viewer.handle_key (kv);
                return false;
            });
            ((Gtk.Widget) this).add_controller (kc);

            /* Adw.Dialog handles Escape itself before the controller above —
               block it while the viewer is up and dismiss the viewer from
               close_attempt. */
            viewer.widget.notify["visible"].connect (() => {
                can_close = !viewer.visible;
            });
            close_attempt.connect (() => {
                if (viewer.visible) viewer.hide ();
            });

            load_info.begin (spinner);
        }

        private async void load_info (Gtk.Spinner spinner) {
            try {
                var chat = yield rpc.get_full_chat_by_id_for (
                    rpc.account_id, chat_id);
                if (chat == null) return;

                spinner.visible = false;

                string name = json_str (chat, "name") ?? "Chat";
                string chat_type = json_str (chat, "chatType") ?? "";
                string? profile_image = json_str (chat, "profileImage");
                bool encrypted = json_bool (chat, "isEncrypted");
                bool is_dm_chat = chat_type == "Single"
                    && !json_bool (chat, "isSelfTalk")
                    && !json_bool (chat, "isDeviceChat");

                is_channel = chat_type == "Broadcast" || chat_type == "OutBroadcast"
                    || chat_type == "InBroadcast";
                is_group = chat_type == "Group" || is_channel;
                can_edit_members = ChatActions.can_edit_members (
                    chat_type, encrypted, json_bool (chat, "canSend"));
                is_unpromoted = json_bool (chat, "isUnpromoted");
                chat_name = name;
                dm_contact = null;

                int dm_contact_id = 0;
                if (is_dm_chat && chat.has_member ("contactIds")) {
                    var ids = chat.get_array_member ("contactIds");
                    if (ids.get_length () > 0)
                        dm_contact_id = (int) ids.get_int_element (0);
                }

                var avatar = new Adw.Avatar (80, name, true);
                avatar.custom_image = load_avatar (profile_image);
                if (profile_image != null && profile_image.length > 0) {
                    /* A real button so the fullscreen preview is also
                       reachable with the keyboard. */
                    string img = profile_image;
                    var avatar_btn = new Gtk.Button ();
                    avatar_btn.child = avatar;
                    avatar_btn.add_css_class ("flat");
                    avatar_btn.add_css_class ("circular");
                    avatar_btn.halign = Gtk.Align.CENTER;
                    avatar_btn.tooltip_text = "View image";
                    avatar_btn.clicked.connect (() => {
                        viewer.show_list ({ img }, 0);
                    });
                    content.append (avatar_btn);
                } else {
                    avatar.halign = Gtk.Align.CENTER;
                    content.append (avatar);
                }

                if (can_edit_members) {
                    var change_avatar_btn = flat_button ("Change Avatar");
                    change_avatar_btn.clicked.connect (() => pick_avatar.begin ());
                    change_avatar_btn.halign = Gtk.Align.CENTER;
                    content.append (change_avatar_btn);
                }

                var name_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
                name_box.halign = Gtk.Align.CENTER;

                var name_lbl = new Gtk.Label (name);
                name_lbl.add_css_class ("title-1");
                name_lbl.ellipsize = Pango.EllipsizeMode.END;
                name_lbl.max_width_chars = 24;
                name_box.append (name_lbl);

                if (is_dm_chat && dm_contact_id > 1) {
                    var edit_contact_btn = flat_icon_button (
                        "document-edit-symbolic", "Edit contact name");
                    edit_contact_btn.clicked.connect (() =>
                        show_edit_contact_name_dialog.begin (dm_contact_id, name_lbl));
                    name_box.append (edit_contact_btn);
                } else if (can_edit_members) {
                    var edit_group_btn = flat_icon_button (
                        "document-edit-symbolic", is_channel ? "Edit channel name" : "Edit group name");
                    edit_group_btn.clicked.connect (() =>
                        show_edit_group_name_dialog.begin (name_lbl));
                    name_box.append (edit_group_btn);
                }

                content.append (name_box);

                string type_str = chat_type == "Broadcast" || chat_type == "OutBroadcast"
                        || chat_type == "InBroadcast" ? "Channel"
                    : chat_type == "Group" ? "Group"
                    : chat_type == "Mailinglist" ? "Mailing List"
                    : json_bool (chat, "isSelfTalk") ? "Saved Messages"
                    : json_bool (chat, "isDeviceChat") ? "Device Messages"
                    : chat_type == "Single" ? "Direct Chat" : "Chat";
                if (encrypted) type_str += " · End-to-end encrypted";
                var type_lbl = new Gtk.Label (type_str);
                type_lbl.add_css_class ("dim-label");
                type_lbl.halign = Gtk.Align.CENTER;
                content.append (type_lbl);

                if (can_edit_members) {
                    var invite_list = boxed_list ();
                    add_action_row (invite_list, "Invite Link",
                        "Share a link or QR code for others to join",
                        "mail-forward-symbolic", () => {
                        var dialog = new InviteCodeDialog (rpc, rpc.account_id, chat_id);
                        dialog.present (this);
                    });
                    content.append (invite_list);
                }

                int ephemeral_timer = (int) json_int (chat, "ephemeralTimer");

                int[] timer_values = { 0, 60, 300, 1800, 3600, 21600, 86400, 604800, 2419200 };
                string[] timer_labels = {
                    "Off", "1 minute", "5 minutes", "30 minutes",
                    "1 hour", "6 hours", "1 day", "1 week", "4 weeks"
                };
                int active_idx = 0;
                for (int i = 0; i < timer_values.length; i++) {
                    if (timer_values[i] == ephemeral_timer) {
                        active_idx = i;
                    }
                }
                var ephem_row = dropdown_row ("Disappearing messages",
                    timer_labels, active_idx, (idx) => {
                    if (idx < timer_values.length) {
                        rpc.set_chat_ephemeral_timer.begin (
                            chat_id, timer_values[(int) idx]);
                    }
                });
                ephem_row.sensitive = encrypted && json_bool (chat, "canSend")
                    && chat_type != "Mailinglist" && chat_type != "InBroadcast";
                ephem_row.subtitle = "Applies to new messages for everyone in this chat";

                /* Mute selector. Core only reports the boolean isMuted, not
                   the remaining time, so a timed mute shows as "Forever"
                   here; picking any entry always applies that duration. */
                bool is_muted = json_bool (chat, "isMuted");
                string[] mute_labels = new string[MUTE_DURATION_LABELS.length + 1];
                mute_labels[0] = "Off";
                for (int i = 0; i < MUTE_DURATION_LABELS.length; i++) {
                    mute_labels[i + 1] = MUTE_DURATION_LABELS[i];
                }
                var mute_row = dropdown_row ("Mute notifications", mute_labels,
                    is_muted ? mute_labels.length - 1 : 0, (idx) => {
                    if (idx < mute_labels.length) {
                        int secs = idx == 0
                            ? 0 : MUTE_DURATION_SECONDS[(int) idx - 1];
                        set_mute.begin (secs);
                    }
                });

                var ephem_list = boxed_list ();
                int account_id = rpc.account_id;
                add_action_row (ephem_list, "Open Chat", "Open this conversation",
                    "mail-message-new-symbolic", () => {
                    var dialogs = app_window.get_dialogs ();
                    for (uint i = dialogs.get_n_items (); i > 0; i--) {
                        var details = dialogs.get_item (i - 1) as ChatInfoDialog;
                        if (details != null) details.close ();
                    }
                    app_window.open_chat_from_notification.begin (account_id, chat_id);
                });
                add_action_row (ephem_list,
                    "View Media",
                    "Browse apps and media shared in this chat",
                    "view-grid-symbolic", () => {
                    var dialog = new GalleryDialog (
                        app_window, rpc, chat_id, chat_name);
                    dialog.presenter_dialog = this;
                    dialog.present (this);
                });
                ephem_list.append (mute_row);
                ephem_list.append (ephem_row);
                content.append (ephem_list);

                content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

                if (chat.has_member ("contactIds")) {
                    var ids = chat.get_array_member ("contactIds");

                    var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

                    var members_lbl = new Gtk.Label (
                        is_group ? "Members (%u)".printf (ids.get_length ()) : "Contact");
                    members_lbl.add_css_class ("heading");
                    members_lbl.halign = Gtk.Align.START;
                    members_lbl.hexpand = true;
                    header_box.append (members_lbl);

                    if (can_edit_members) {
                        var add_member_btn = flat_icon_button (
                            "list-add-symbolic", "Add member");
                        add_member_btn.clicked.connect (() =>
                            add_member_dialog.begin ());
                        header_box.append (add_member_btn);
                    }

                    content.append (header_box);

                    members_list = boxed_list ();

                    for (uint i = 0; i < ids.get_length (); i++) {
                        int cid = (int) ids.get_int_element (i);
                        var contact_obj = yield rpc.get_contact_for (
                            rpc.account_id, cid);
                        var contact = contact_obj != null
                            ? RpcParsers.parse_contact (cid, contact_obj)
                            : null;
                        if (contact == null) continue;
                        if (is_dm_chat && contact.id > 1 && dm_contact == null)
                            dm_contact = contact;

                        var row = build_contact_row (contact);
                        members_list.append (row);
                    }

                    content.append (members_list);
                }

                content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

                var actions_list = boxed_list ();

                if (is_group && chat_type != "InBroadcast") {
                    add_action_row (actions_list,
                        is_channel ? "New Channel with Same Members"
                                   : "New Group with Same Members",
                        "Start a new one without picking members again",
                        "system-users-symbolic",
                        () => show_duplicate_group_dialog.begin ());
                }

                if (dm_contact != null) {
                    actions_list.append (build_contact_block_row (dm_contact));
                } else if (chat_type == "Mailinglist" || chat_type == "InBroadcast") {
                    add_action_row (actions_list, "Block Chat…",
                        "Hide this chat and new messages; keep the history",
                        "action-unavailable-symbolic", () => confirm_block_chat.begin ());
                }
                if (actions_list.get_first_child () != null) content.append (actions_list);

                var deletion_list = boxed_list ();

                add_action_row (deletion_list, "Clear Chat…",
                    "Delete messages for this profile and keep the chat",
                    "edit-clear-symbolic",
                    () => confirm_clear_history.begin (false));

                if (MessageDeletion.can_delete_in_chat (chat)) {
                    add_action_row (deletion_list,
                        "Delete Sent Messages for Everyone…",
                        "Ask other participants to delete messages sent by this profile",
                        "edit-delete-symbolic",
                        () => confirm_clear_history.begin (true));
                }

                if (can_leave_chat (chat)) {
                    add_action_row (deletion_list,
                        is_channel ? "Leave Channel…" : "Leave Group…",
                        "Stop receiving messages, with the option to keep the history",
                        "system-log-out-symbolic",
                        () => confirm_leave_group.begin ());
                }

                add_action_row (deletion_list, "Delete Chat…",
                    "Delete the chat and its messages for this profile", "user-trash-symbolic",
                    () => confirm_delete_chat.begin ());

                content.append (deletion_list);

            } catch (Error e) {
                spinner.visible = false;
                var err = new Gtk.Label ("Failed to load: " + e.message);
                err.add_css_class ("dim-label");
                err.wrap = true;
                content.append (err);
            }
        }

        private async void set_mute (int seconds) {
            try {
                yield rpc.set_chat_mute_duration (chat_id, seconds);
                chat_changed ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private Adw.ActionRow build_contact_row (Contact contact) {
            var row = contact_row (contact, is_group && contact.id > 0, false);

            if (is_group) {
                row.tooltip_text = "View contact details";
                row.activated.connect (() => show_contact_details.begin (contact));

                var right_click = new Gtk.GestureClick ();
                right_click.button = 3;
                right_click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
                right_click.pressed.connect ((n, x, y) => {
                    right_click.set_state (Gtk.EventSequenceState.CLAIMED);
                    row.grab_focus ();
                    show_contact_menu (contact, row, x, y);
                });
                row.add_controller (right_click);

                var menu_keys = new Gtk.EventControllerKey ();
                menu_keys.key_pressed.connect ((keyval, keycode, state) => {
                    bool shift_f10 = keyval == Gdk.Key.F10 &&
                        (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                    if (keyval != Gdk.Key.Menu && !shift_f10) return false;
                    show_contact_menu (contact, row,
                        row.get_width () / 2, row.get_height () / 2);
                    return true;
                });
                row.add_controller (menu_keys);
            }

            if (contact.address.length > 0) {
                string addr = contact.address;
                var copy_btn = flat_icon_button (
                    "edit-copy-symbolic", "Copy email address");
                copy_btn.clicked.connect (() =>
                    this.get_clipboard ().set_text (addr));
                row.add_suffix (copy_btn);
            }

            if (can_edit_members && contact.id > 1) {
                var remove_btn = flat_icon_button (
                    "user-trash-symbolic",
                    is_channel ? "Remove from channel…" : "Remove from group…", true);
                remove_btn.clicked.connect (() => confirm_remove_member.begin (contact, row));
                row.add_suffix (remove_btn);
            }

            return row;
        }

        private void show_contact_menu (Contact contact, Adw.ActionRow row,
                                        double x, double y) {
            Gtk.Box box;
            var popover = popover_menu (row, x, y, out box);

            var details_btn = new PopoverButton (popover, "View Contact Details");
            details_btn.sensitive = contact.id > 0;
            details_btn.selected.connect (() => show_contact_details.begin (contact));
            box.append (details_btn);

            if (contact.address.length > 0) {
                var copy_btn = new PopoverButton (popover, "Copy Email Address");
                copy_btn.selected.connect (() =>
                    this.get_clipboard ().set_text (contact.address));
                box.append (copy_btn);
            }

            if (can_edit_members && contact.id > 1) {
                box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
                var remove_btn = new PopoverButton (popover,
                    is_channel ? "Remove from Channel…" : "Remove from Group…", true);
                remove_btn.selected.connect (() => confirm_remove_member.begin (contact, row));
                box.append (remove_btn);
            }

            popover.popup ();
        }

        private async void show_contact_details (Contact contact) {
            if (contact.id <= 0) return;
            int account_id = rpc.account_id;
            try {
                int contact_chat_id = yield rpc.get_or_create_chat_by_contact_for (
                    account_id, contact.id);
                if (rpc.account_id != account_id || contact_chat_id <= 0) return;
                app_window.show_chat_info (contact_chat_id);
            } catch (Error e) {
                show_error (this, "Could not open contact details: " + e.message);
            }
        }

        private Adw.ActionRow build_contact_block_row (Contact contact) {
            var row = new Adw.ActionRow ();
            row.add_prefix (new Gtk.Image.from_icon_name ("action-unavailable-symbolic"));
            row.activatable = true;
            update_contact_block_row (row, contact);
            row.activated.connect (() => {
                if (contact.is_blocked) {
                    set_contact_blocked.begin (contact, row, false);
                } else {
                    confirm_block_contact.begin (contact, row);
                }
            });
            return row;
        }

        private void update_contact_block_row (Adw.ActionRow row,
                                                Contact contact) {
            string label = contact_label (contact);
            if (contact.is_blocked) {
                row.title = "Unblock Contact";
                row.subtitle = "Allow messages from %s".printf (label);
            } else {
                row.title = "Block Contact…";
                row.subtitle = "Block direct messages from %s and keep the history".printf (label);
            }
        }

        private static string contact_label (Contact contact) {
            if (contact.display_name.length > 0) return contact.display_name;
            if (contact.address.length > 0) return contact.address;
            return "this contact";
        }

        private async void show_edit_contact_name_dialog (int contact_id,
                                                           Gtk.Label name_lbl) {
            string? name = yield prompt_text (this, "Edit Contact Name",
                "Leave empty to use the contact's own name.", "Save",
                name_lbl.label, "Contact name");
            if (name != null)
                yield save_contact_name (contact_id, name.strip (), name_lbl);
        }

        private async void save_contact_name (int contact_id, string new_name,
                                              Gtk.Label name_lbl) {
            try {
                yield rpc.change_contact_name (contact_id, new_name);

                var contact_obj = yield rpc.get_contact_for (
                    rpc.account_id, contact_id);
                var contact = contact_obj != null
                    ? RpcParsers.parse_contact (contact_id, contact_obj)
                    : null;
                if (contact != null) {
                    dm_contact = contact;
                    chat_name = contact_label (contact);
                    name_lbl.label = chat_name;
                    if (members_list != null && !is_group) {
                        clear_listbox (members_list);
                        members_list.append (build_contact_row (contact));
                    }
                } else if (new_name.length > 0) {
                    chat_name = new_name;
                    name_lbl.label = new_name;
                }

                chat_changed ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void show_edit_group_name_dialog (Gtk.Label name_lbl) {
            string? name = yield prompt_text (this,
                is_channel ? "Edit Channel Name" : "Edit Group Name", null,
                "Save", name_lbl.label, is_channel ? "Channel name" : "Group name");
            if (name == null) return;
            string new_name = name.strip ();
            /* Groups must keep a name, so ignore an empty entry. */
            if (new_name.length > 0)
                yield save_group_name (new_name, name_lbl);
        }

        private async void save_group_name (string new_name, Gtk.Label name_lbl) {
            try {
                yield rpc.set_chat_name (chat_id, new_name);
                chat_name = new_name;
                name_lbl.label = new_name;
                chat_changed ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void confirm_remove_member (Contact contact, Adw.ActionRow row) {
            int account_id = rpc.account_id;
            string body = "Remove \"%s\" from \"%s\"? They keep messages already received.".printf (
                contact_label (contact), chat_name);
            body += is_channel
                ? " They will no longer receive new messages sent to this channel."
                : " They will no longer receive new group messages.";
            if (!is_channel && !is_unpromoted) body += " Group members will be notified.";
            if (!(yield confirm_action (this,
                is_channel ? "Remove Subscriber?" : "Remove Member?",
                body, "remove", is_channel ? "Remove Subscriber" : "Remove Member"))) return;
            if (rpc.account_id != account_id) return;
            try {
                yield rpc.remove_contact_from_chat (chat_id, contact.id);
                members_list.remove (row);
                chat_changed ();
            } catch (Error e) {
                row.subtitle = "Remove failed: " + e.message;
            }
        }

        private async void add_member_dialog () {
            var picker = new ContactPickerDialog (rpc);
            picker.contact_picked.connect ((_, email) => {
                do_add_member.begin (email);
            });
            picker.present (this);
        }

        private async void do_add_member (string email) {
            try {
                int contact_id = yield rpc.get_or_create_contact (email);
                yield rpc.add_contact_to_chat (chat_id, contact_id);

                var contact_obj = yield rpc.get_contact_for (
                    rpc.account_id, contact_id);
                var contact = contact_obj != null
                    ? RpcParsers.parse_contact (contact_id, contact_obj)
                    : null;
                if (contact != null && members_list != null) {
                    var row = build_contact_row (contact);
                    members_list.append (row);
                }
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void confirm_block_contact (Contact contact,
                                                  Adw.ActionRow row) {
            int account_id = rpc.account_id;
            if (yield confirm_chat_block (this, contact_label (contact), true)) {
                if (rpc.account_id == account_id)
                    set_contact_blocked.begin (contact, row, true);
            }
        }

        private async void confirm_block_chat () {
            int account_id = rpc.account_id;
            if (!(yield confirm_chat_block (this, chat_name, false))) return;
            if (rpc.account_id != account_id) return;
            try {
                yield rpc.block_chat (chat_id);
                contact_blocked (chat_id);
                this.close ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void set_contact_blocked (Contact contact,
                                                Adw.ActionRow row,
                                                bool blocked) {
            try {
                if (blocked) {
                    yield rpc.block_contact (contact.id);
                } else {
                    yield rpc.unblock_contact (contact.id);
                }
                contact.is_blocked = blocked;
                update_contact_block_row (row, contact);
                if (blocked) contact_blocked (chat_id);
                else chat_changed ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void confirm_clear_history (bool for_all) {
            int account_id = rpc.account_id;
            try {
                int[] ids = yield chat_message_ids_for_clear (
                    rpc, account_id, chat_id, for_all);
                if (rpc.account_id != account_id) return;
                if (ids.length == 0) {
                    app_window.show_toast (for_all
                        ? "No sent messages can be deleted for everyone"
                        : "No messages to clear");
                    return;
                }
                if (!(yield confirm_chat_clear (this, chat_name, for_all, ids.length))) return;
                if (rpc.account_id != account_id) return;
                if (for_all) yield rpc.delete_messages_for_all (ids);
                else yield rpc.delete_messages (ids);
                chat_changed ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        /* Query the member list at activation time rather than reusing the
           snapshot from load_info, so members added or removed while this
           dialog is open are reflected. */
        private async void show_duplicate_group_dialog () {
            string[] addresses = {};
            try {
                var chat = yield rpc.get_full_chat_by_id_for (
                    rpc.account_id, chat_id);
                if (chat != null && chat.has_member ("contactIds")) {
                    var ids = chat.get_array_member ("contactIds");
                    for (uint i = 0; i < ids.get_length (); i++) {
                        int cid = (int) ids.get_int_element (i);
                        /* Self is added automatically on creation. */
                        if (cid <= 1) continue;
                        var contact_obj = yield rpc.get_contact_for (
                            rpc.account_id, cid);
                        var contact = contact_obj != null
                            ? RpcParsers.parse_contact (cid, contact_obj)
                            : null;
                        if (contact != null && contact.address.contains ("@"))
                            addresses += contact.address;
                    }
                }
            } catch (Error e) {
                show_error (this, e.message);
                return;
            }

            var dialog = new NewGroupDialog (rpc, is_channel);
            foreach (var address in addresses)
                dialog.add_member_email (address);
            dialog.group_created.connect ((new_chat_id) => {
                on_duplicate_created.begin (new_chat_id);
            });
            dialog.present (this);
        }

        private async void on_duplicate_created (int new_chat_id) {
            yield app_window.load_chats ();
            app_window.select_chat_by_id (new_chat_id);
            app_window.show_toast (is_channel
                ? "Channel created" : "Group created");
            this.close ();
        }

        private async void confirm_leave_group () {
            var choice = yield confirm_group_leave (this, rpc, chat_id);
            if (choice != LeaveChoice.CANCEL)
                do_leave_group.begin (choice == LeaveChoice.DELETE_HISTORY);
        }

        private async void do_leave_group (bool delete_history) {
            int account_id = rpc.account_id;
            bool left = false;
            try {
                yield rpc.leave_group (chat_id);
                left = true;
                if (delete_history) {
                    yield rpc.delete_chat (chat_id, account_id);
                    chat_deleted (chat_id);
                } else {
                    chat_changed ();
                    app_window.show_toast ("Chat left; history kept");
                }
                this.close ();
            } catch (Error e) {
                chat_changed ();
                show_error (this, (left
                    ? "Chat left, but its history could not be deleted: "
                    : "Could not finish leaving; chat history was kept: ") + e.message);
            }
        }

        private async void confirm_delete_chat () {
            int account_id = rpc.account_id;
            if (yield confirm_chat_deletion (this, chat_name)) {
                if (rpc.account_id == account_id) do_delete_chat_from_dialog.begin ();
            }
        }

        private async void do_delete_chat_from_dialog () {
            try {
                yield rpc.delete_chat (chat_id);
                chat_deleted (chat_id);
                this.close ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void pick_avatar () {
            string? path = yield pick_image_file (
                (Gtk.Window) this.get_root (), "Select Avatar Image");
            if (path == null) return;
            try {
                yield rpc.set_chat_profile_image (chat_id, path);
            } catch (Error e) { /* ignore */ }
        }
    }
}
