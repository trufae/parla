namespace Dc {

    public class ChatInfoDialog : Adw.Dialog {

        private RpcClient rpc;
        private int acct_id;
        private int chat_id;
        private bool is_group = false;
        private Gtk.ListBox? members_list = null;
        private Gtk.Box content;
        private string chat_name = "";
        private int[] member_contact_ids = {};

        public signal void chat_deleted (int chat_id);
        public signal void chat_changed ();

        public ChatInfoDialog (RpcClient rpc, int acct_id, int chat_id) {
            this.rpc = rpc;
            this.acct_id = acct_id;
            this.chat_id = chat_id;
            this.title = "Chat Info";
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

            this.child = box;

            load_info.begin (spinner);
        }

        private async void load_info (Gtk.Spinner spinner) {
            try {
                var chat = yield rpc.get_full_chat_by_id (acct_id, chat_id);
                if (chat == null) return;

                spinner.visible = false;

                string name = chat.has_member ("name")
                    ? chat.get_string_member ("name") : "Chat";
                string chat_type = chat.has_member ("chatType")
                    ? chat.get_string_member ("chatType") : "";
                string? profile_image = chat.has_member ("profileImage")
                    && !chat.get_member ("profileImage").is_null ()
                    ? chat.get_string_member ("profileImage") : null;
                bool encrypted = chat.has_member ("isEncrypted")
                    && chat.get_boolean_member ("isEncrypted");

                is_group = chat_type == "Group" || chat_type == "Broadcast";
                chat_name = name;

                /* Avatar */
                var avatar = new Adw.Avatar (80, name, true);
                avatar.custom_image = load_avatar (profile_image);
                avatar.halign = Gtk.Align.CENTER;
                content.append (avatar);

                /* Change avatar button for groups */
                if (is_group) {
                    var change_avatar_btn = new Gtk.Button.with_label ("Change Avatar");
                    change_avatar_btn.halign = Gtk.Align.CENTER;
                    change_avatar_btn.add_css_class ("flat");
                    change_avatar_btn.clicked.connect (() => {
                        pick_avatar.begin ();
                    });
                    content.append (change_avatar_btn);
                }

                /* Name */
                var name_lbl = new Gtk.Label (name);
                name_lbl.add_css_class ("title-1");
                name_lbl.halign = Gtk.Align.CENTER;
                content.append (name_lbl);

                /* Type + encryption */
                string type_str = chat_type;
                if (encrypted) type_str += " (encrypted)";
                var type_lbl = new Gtk.Label (type_str);
                type_lbl.add_css_class ("dim-label");
                type_lbl.halign = Gtk.Align.CENTER;
                content.append (type_lbl);

                /* Disappearing messages */
                int ephemeral_timer = chat.has_member ("ephemeralTimer")
                    ? (int) chat.get_int_member ("ephemeralTimer") : 0;

                var ephem_row = new Adw.ActionRow ();
                ephem_row.title = "Disappearing messages";

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
                var combo = new Gtk.DropDown.from_strings (timer_labels);
                combo.selected = active_idx;
                combo.valign = Gtk.Align.CENTER;
                combo.notify["selected"].connect (() => {
                    uint idx = combo.selected;
                    if (idx < timer_values.length) {
                        rpc.set_chat_ephemeral_timer.begin (
                            acct_id, chat_id, timer_values[(int) idx]);
                    }
                });
                ephem_row.add_suffix (combo);
                ephem_row.activatable_widget = combo;

                var ephem_list = new Gtk.ListBox ();
                ephem_list.selection_mode = Gtk.SelectionMode.NONE;
                ephem_list.add_css_class ("boxed-list");
                ephem_list.append (ephem_row);
                content.append (ephem_list);

                /* Separator */
                content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

                /* Members */
                if (chat.has_member ("contactIds")) {
                    var ids = chat.get_array_member ("contactIds");

                    var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

                    var members_lbl = new Gtk.Label (
                        is_group ? "Members (%u)".printf (ids.get_length ()) : "Contact");
                    members_lbl.add_css_class ("heading");
                    members_lbl.halign = Gtk.Align.START;
                    members_lbl.hexpand = true;
                    header_box.append (members_lbl);

                    if (is_group) {
                        var add_btn = new Gtk.Button.from_icon_name ("list-add-symbolic");
                        add_btn.tooltip_text = "Add member";
                        add_btn.add_css_class ("flat");
                        add_btn.clicked.connect (() => {
                            add_member_dialog.begin ();
                        });
                        header_box.append (add_btn);
                    }

                    content.append (header_box);

                    members_list = new Gtk.ListBox ();
                    members_list.selection_mode = Gtk.SelectionMode.NONE;
                    members_list.add_css_class ("boxed-list");

                    for (uint i = 0; i < ids.get_length (); i++) {
                        int cid = (int) ids.get_int_element (i);
                        member_contact_ids += cid;
                        var contact_obj = yield rpc.get_contact (acct_id, cid);
                        if (contact_obj == null) continue;
                        var contact = RpcClient.parse_contact (cid, contact_obj);

                        var row = build_contact_row (contact);
                        members_list.append (row);
                    }

                    content.append (members_list);
                }

                /* ---- Destructive Actions ---- */
                content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

                var actions_list = new Gtk.ListBox ();
                actions_list.selection_mode = Gtk.SelectionMode.NONE;
                actions_list.add_css_class ("boxed-list");

                /* Clear History */
                var clear_row = new Adw.ActionRow ();
                clear_row.title = "Clear History";
                // clear_row.subtitle = "Delete all messages";

                var clear_me_btn = new Gtk.Button.with_label ("For Me");
                clear_me_btn.valign = Gtk.Align.CENTER;
                clear_me_btn.add_css_class ("flat");
                clear_me_btn.clicked.connect (() => {
                    confirm_clear_history.begin (false);
                });
                clear_row.add_suffix (clear_me_btn);

                var clear_all_btn = new Gtk.Button.with_label ("For Everyone");
                clear_all_btn.valign = Gtk.Align.CENTER;
                clear_all_btn.add_css_class ("flat");
                clear_all_btn.add_css_class ("error");
                clear_all_btn.clicked.connect (() => {
                    confirm_clear_history.begin (true);
                });
                clear_row.add_suffix (clear_all_btn);

                actions_list.append (clear_row);

                if (is_group) {
                    /* Leave Group */
                    var leave_row = new Adw.ActionRow ();
                    leave_row.title = "Leave Group";
                    leave_row.subtitle = "Stop receiving messages";
                    leave_row.add_prefix (new Gtk.Image.from_icon_name ("system-log-out-symbolic"));
                    leave_row.activatable = true;
                    leave_row.activated.connect (() => {
                        confirm_leave_group.begin ();
                    });
                    actions_list.append (leave_row);

                    /* Disband Group */
                    var disband_row = new Adw.ActionRow ();
                    disband_row.title = "Disband Group";
                    disband_row.subtitle = "Remove all members and delete messages";
                    disband_row.add_prefix (new Gtk.Image.from_icon_name ("edit-delete-symbolic"));
                    disband_row.activatable = true;
                    disband_row.activated.connect (() => {
                        confirm_disband_group.begin ();
                    });
                    actions_list.append (disband_row);
                }

                /* Delete for Me */
                var del_row = new Adw.ActionRow ();
                del_row.title = "Delete for Me";
                del_row.subtitle = "Remove from your chat list";
                del_row.add_prefix (new Gtk.Image.from_icon_name ("user-trash-symbolic"));
                del_row.activatable = true;
                del_row.activated.connect (() => {
                    confirm_delete_chat.begin ();
                });
                actions_list.append (del_row);

                content.append (actions_list);

            } catch (Error e) {
                spinner.visible = false;
                var err = new Gtk.Label ("Failed to load: " + e.message);
                err.add_css_class ("dim-label");
                err.wrap = true;
                content.append (err);
            }
        }

        private Adw.ActionRow build_contact_row (Contact contact) {
            string title = contact.display_name.length > 0
                ? contact.display_name : contact.address;
            string subtitle = contact.display_name.length > 0
                ? contact.address : "";
            if (contact.is_verified) subtitle += " (verified)";

            var row = new Adw.ActionRow ();
            row.title = title;
            row.subtitle = subtitle;

            var avatar = new Adw.Avatar (32, title, true);
            avatar.custom_image = load_avatar (contact.profile_image);
            row.add_prefix (avatar);

            /* Copy email button */
            if (contact.address.length > 0) {
                string addr = contact.address;
                var copy_btn = new Gtk.Button.from_icon_name ("edit-copy-symbolic");
                copy_btn.valign = Gtk.Align.CENTER;
                copy_btn.add_css_class ("flat");
                copy_btn.tooltip_text = "Copy email address";
                copy_btn.clicked.connect (() => {
                    var clipboard = this.get_clipboard ();
                    clipboard.set_text (addr);
                });
                row.add_suffix (copy_btn);
            }

            /* Remove button for groups (not self, contact_id=1 is self) */
            if (is_group && contact.id != 1) {
                int cid = contact.id;
                var remove_btn = new Gtk.Button.from_icon_name ("user-trash-symbolic");
                remove_btn.valign = Gtk.Align.CENTER;
                remove_btn.add_css_class ("flat");
                remove_btn.add_css_class ("error");
                remove_btn.tooltip_text = "Remove from group";
                remove_btn.clicked.connect (() => {
                    remove_member.begin (cid, row);
                });
                row.add_suffix (remove_btn);
            }

            return row;
        }

        private async void remove_member (int contact_id, Adw.ActionRow row) {
            try {
                yield rpc.remove_contact_from_chat (acct_id, chat_id, contact_id);
                members_list.remove (row);
            } catch (Error e) {
                /* show inline error */
                row.subtitle = "Remove failed: " + e.message;
            }
        }

        private async void add_member_dialog () {
            var picker = new ContactPickerDialog (rpc, acct_id);
            picker.contact_picked.connect ((contact_id, email) => {
                do_add_member.begin (email);
            });
            picker.present (this);
        }

        private async void do_add_member (string email) {
            try {
                int contact_id = yield rpc.get_or_create_contact (acct_id, email);
                yield rpc.add_contact_to_chat (acct_id, chat_id, contact_id);

                /* Refresh the member list */
                var contact_obj = yield rpc.get_contact (acct_id, contact_id);
                if (contact_obj != null && members_list != null) {
                    var contact = RpcClient.parse_contact (contact_id, contact_obj);
                    var row = build_contact_row (contact);
                    members_list.append (row);
                }
            } catch (Error e) {
                var err_dialog = new Adw.AlertDialog ("Error", e.message);
                err_dialog.add_response ("ok", "OK");
                err_dialog.present (this);
            }
        }

        /* ---- Destructive action confirmations ---- */

        private async void confirm_clear_history (bool for_all) {
            string title = for_all ? "Clear for Everyone" : "Clear History";
            string body = for_all
                ? "Delete all messages for all participants? This cannot be undone."
                : "Delete all messages from your device? This cannot be undone.";
            string action_label = for_all ? "Clear for Everyone" : "Clear";

            var dialog = new Adw.AlertDialog (title, body);
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("clear", action_label);
            dialog.set_response_appearance ("clear", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.response.connect ((resp) => {
                if (resp == "clear") {
                    do_clear_history.begin (for_all);
                }
            });
            dialog.present (this);
        }

        private async void do_clear_history (bool for_all) {
            try {
                var msg_ids = yield rpc.get_message_ids (acct_id, chat_id);
                if (msg_ids == null || msg_ids.get_length () == 0) return;

                int[] ids = new int[msg_ids.get_length ()];
                for (uint i = 0; i < msg_ids.get_length (); i++) {
                    ids[i] = (int) msg_ids.get_int_element (i);
                }

                if (for_all) {
                    yield rpc.delete_messages_for_all (acct_id, ids);
                } else {
                    yield rpc.delete_messages (acct_id, ids);
                }

                chat_changed ();
            } catch (Error e) {
                var err = new Adw.AlertDialog ("Error", e.message);
                err.add_response ("ok", "OK");
                err.present (this);
            }
        }

        private async void confirm_leave_group () {
            var dialog = new Adw.AlertDialog (
                "Leave Group",
                "Leave \"%s\"? You will stop receiving messages.".printf (chat_name)
            );
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("leave", "Leave");
            dialog.set_response_appearance ("leave", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.response.connect ((resp) => {
                if (resp == "leave") {
                    do_leave_group.begin ();
                }
            });
            dialog.present (this);
        }

        private async void do_leave_group () {
            try {
                yield rpc.leave_group (acct_id, chat_id);
                chat_changed ();
                this.close ();
            } catch (Error e) {
                var err = new Adw.AlertDialog ("Error", e.message);
                err.add_response ("ok", "OK");
                err.present (this);
            }
        }

        private async void confirm_disband_group () {
            var dialog = new Adw.AlertDialog (
                "Disband Group",
                "Remove all members from \"%s\" and delete all messages? This cannot be undone.".printf (chat_name)
            );
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("disband", "Disband");
            dialog.set_response_appearance ("disband", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.response.connect ((resp) => {
                if (resp == "disband") {
                    do_disband_group.begin ();
                }
            });
            dialog.present (this);
        }

        private async void do_disband_group () {
            try {
                /* Remove all members except self */
                foreach (int cid in member_contact_ids) {
                    if (cid != 1) {
                        yield rpc.remove_contact_from_chat (acct_id, chat_id, cid);
                    }
                }

                /* Delete all messages for everyone */
                var msg_ids = yield rpc.get_message_ids (acct_id, chat_id);
                if (msg_ids != null && msg_ids.get_length () > 0) {
                    int[] ids = new int[msg_ids.get_length ()];
                    for (uint i = 0; i < msg_ids.get_length (); i++) {
                        ids[i] = (int) msg_ids.get_int_element (i);
                    }
                    yield rpc.delete_messages_for_all (acct_id, ids);
                }

                /* Leave and delete the chat */
                yield rpc.leave_group (acct_id, chat_id);
                yield rpc.delete_chat (acct_id, chat_id);

                chat_deleted (chat_id);
                this.close ();
            } catch (Error e) {
                var err = new Adw.AlertDialog ("Error", e.message);
                err.add_response ("ok", "OK");
                err.present (this);
            }
        }

        private async void confirm_delete_chat () {
            var dialog = new Adw.AlertDialog (
                "Delete for Me",
                "Remove \"%s\" from your chat list? You may still receive messages if you are a member.".printf (chat_name)
            );
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("delete", "Delete");
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.response.connect ((resp) => {
                if (resp == "delete") {
                    do_delete_chat_from_dialog.begin ();
                }
            });
            dialog.present (this);
        }

        private async void do_delete_chat_from_dialog () {
            try {
                yield rpc.delete_chat (acct_id, chat_id);
                chat_deleted (chat_id);
                this.close ();
            } catch (Error e) {
                var err = new Adw.AlertDialog ("Error", e.message);
                err.add_response ("ok", "OK");
                err.present (this);
            }
        }

        private async void pick_avatar () {
            var chooser = new Gtk.FileDialog ();
            chooser.title = "Select Avatar Image";

            var filter = new Gtk.FileFilter ();
            filter.add_mime_type ("image/*");
            filter.name = "Images";
            var filters = new ListStore (typeof (Gtk.FileFilter));
            filters.append (filter);
            chooser.filters = filters;

            try {
                var file = yield chooser.open ((Gtk.Window) this.get_root (), null);
                if (file != null) {
                    string path = file.get_path ();
                    yield rpc.set_chat_profile_image (acct_id, chat_id, path);
                }
            } catch (Error e) {
                /* cancelled or error */
            }
        }
    }
}
