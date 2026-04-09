namespace Dc {

    public class ChatInfoDialog : Adw.Dialog {

        private RpcClient rpc;
        private int acct_id;
        private int chat_id;
        private bool is_group = false;
        private Gtk.ListBox? members_list = null;
        private Gtk.Box content;

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

                /* Avatar */
                var avatar = new Adw.Avatar (80, name, true);
                if (profile_image != null &&
                    FileUtils.test (profile_image, FileTest.EXISTS)) {
                    try {
                        avatar.custom_image = Gdk.Texture.from_filename (profile_image);
                    } catch (Error e) { /* fallback */ }
                }
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
                        var contact = yield rpc.get_contact (acct_id, cid);
                        if (contact == null) continue;

                        var row = build_contact_row (contact, cid);
                        members_list.append (row);
                    }

                    content.append (members_list);
                }

            } catch (Error e) {
                spinner.visible = false;
                var err = new Gtk.Label ("Failed to load: " + e.message);
                err.add_css_class ("dim-label");
                err.wrap = true;
                content.append (err);
            }
        }

        private Adw.ActionRow build_contact_row (Json.Object contact, int contact_id) {
            string display = contact.has_member ("displayName")
                && !contact.get_member ("displayName").is_null ()
                ? contact.get_string_member ("displayName") : "";
            string addr = contact.has_member ("address")
                ? contact.get_string_member ("address") : "";
            string? img = contact.has_member ("profileImage")
                && !contact.get_member ("profileImage").is_null ()
                ? contact.get_string_member ("profileImage") : null;
            bool verified = contact.has_member ("isVerified")
                && contact.get_boolean_member ("isVerified");

            string title = display.length > 0 ? display : addr;
            string subtitle = display.length > 0 ? addr : "";
            if (verified) subtitle += " (verified)";

            var row = new Adw.ActionRow ();
            row.title = title;
            row.subtitle = subtitle;

            var avatar = new Adw.Avatar (32, title, true);
            if (img != null && FileUtils.test (img, FileTest.EXISTS)) {
                try {
                    avatar.custom_image = Gdk.Texture.from_filename (img);
                } catch (Error e) { /* fallback */ }
            }
            row.add_prefix (avatar);

            /* Copy email button */
            if (addr.length > 0) {
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
            if (is_group && contact_id != 1) {
                var remove_btn = new Gtk.Button.from_icon_name ("user-trash-symbolic");
                remove_btn.valign = Gtk.Align.CENTER;
                remove_btn.add_css_class ("flat");
                remove_btn.add_css_class ("error");
                remove_btn.tooltip_text = "Remove from group";
                remove_btn.clicked.connect (() => {
                    remove_member.begin (contact_id, row);
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
                int contact_id = yield rpc.lookup_contact (acct_id, email);
                if (contact_id == 0) {
                    contact_id = yield rpc.create_contact (acct_id, email);
                }
                yield rpc.add_contact_to_chat (acct_id, chat_id, contact_id);

                /* Refresh the member list */
                var contact = yield rpc.get_contact (acct_id, contact_id);
                if (contact != null && members_list != null) {
                    var row = build_contact_row (contact, contact_id);
                    members_list.append (row);
                }
            } catch (Error e) {
                var err_dialog = new Adw.AlertDialog ("Error", e.message);
                err_dialog.add_response ("ok", "OK");
                err_dialog.present (this);
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
