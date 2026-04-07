namespace Dc {

    public class ChatInfoDialog : Adw.Dialog {

        public ChatInfoDialog (RpcClient rpc, int acct_id, int chat_id) {
            this.title = "Chat Info";
            this.content_width = 360;
            this.content_height = 480;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            header.show_end_title_buttons = true;
            box.append (header);

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
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

            load_info.begin (rpc, acct_id, chat_id, content, spinner);
        }

        private async void load_info (RpcClient rpc, int acct_id, int chat_id,
                                       Gtk.Box content, Gtk.Spinner spinner) {
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

                /* Separator */
                content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

                /* Members */
                if (chat.has_member ("contactIds")) {
                    var ids = chat.get_array_member ("contactIds");

                    var members_lbl = new Gtk.Label (
                        ids.get_length () == 1 ? "Contact" : "Members (%u)".printf (ids.get_length ()));
                    members_lbl.add_css_class ("heading");
                    members_lbl.halign = Gtk.Align.START;
                    members_lbl.margin_top = 4;
                    content.append (members_lbl);

                    var members_list = new Gtk.ListBox ();
                    members_list.selection_mode = Gtk.SelectionMode.NONE;
                    members_list.add_css_class ("boxed-list");

                    for (uint i = 0; i < ids.get_length (); i++) {
                        int cid = (int) ids.get_int_element (i);
                        var contact = yield rpc.get_contact (acct_id, cid);
                        if (contact == null) continue;

                        var row = build_contact_row (contact);
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

        private Adw.ActionRow build_contact_row (Json.Object contact) {
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

            return row;
        }
    }
}
