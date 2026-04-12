namespace Dc {

    public class NewGroupDialog : Adw.Dialog {

        public signal void group_created (int chat_id);

        private RpcClient rpc;
        private int acct_id;
        private Gtk.Entry name_entry;
        /* member_entry removed — contact picker is used instead */
        private Gtk.ListBox member_listbox;
        private GenericArray<string> member_emails = new GenericArray<string> ();
        private string? avatar_path = null;
        private Adw.Avatar avatar_widget;

        public NewGroupDialog (RpcClient rpc, int acct_id) {
            this.rpc = rpc;
            this.acct_id = acct_id;
            this.title = "New Group";
            this.content_width = 360;
            this.content_height = 480;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            var create_btn = new Gtk.Button.with_label ("Create");
            create_btn.add_css_class ("suggested-action");
            create_btn.clicked.connect (() => {
                do_create.begin ();
            });
            header.pack_end (create_btn);
            box.append (header);

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = 16;
            content.margin_end = 16;
            content.margin_top = 12;
            content.margin_bottom = 16;

            /* Avatar */
            avatar_widget = new Adw.Avatar (72, "Group", true);
            avatar_widget.halign = Gtk.Align.CENTER;
            content.append (avatar_widget);

            var avatar_btn = new Gtk.Button.with_label ("Set Avatar");
            avatar_btn.halign = Gtk.Align.CENTER;
            avatar_btn.add_css_class ("flat");
            avatar_btn.clicked.connect (() => {
                pick_avatar.begin ();
            });
            content.append (avatar_btn);

            /* Group name */
            var name_lbl = new Gtk.Label ("Group Name");
            name_lbl.add_css_class ("heading");
            name_lbl.halign = Gtk.Align.START;
            content.append (name_lbl);

            name_entry = new Gtk.Entry ();
            name_entry.placeholder_text = "My Group";
            name_entry.changed.connect (() => {
                avatar_widget.text = name_entry.text.length > 0
                    ? name_entry.text : "Group";
            });
            content.append (name_entry);

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            /* Members */
            var members_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var members_lbl = new Gtk.Label ("Members");
            members_lbl.add_css_class ("heading");
            members_lbl.halign = Gtk.Align.START;
            members_lbl.hexpand = true;
            members_header.append (members_lbl);
            content.append (members_header);

            /* Add member button — opens contact picker */
            var add_btn = new Gtk.Button.with_label ("Add Member\u2026");
            add_btn.add_css_class ("suggested-action");
            add_btn.clicked.connect (on_pick_member);
            content.append (add_btn);

            /* Member list */
            member_listbox = new Gtk.ListBox ();
            member_listbox.selection_mode = Gtk.SelectionMode.NONE;
            member_listbox.add_css_class ("boxed-list");
            content.append (member_listbox);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = content;
            box.append (scroll);

            this.child = box;
        }

        private void on_pick_member () {
            var picker = new ContactPickerDialog (rpc, acct_id);
            picker.contact_picked.connect ((contact_id, email) => {
                add_member_email (email);
            });
            picker.present (this);
        }

        private void add_member_email (string email) {
            if (email.length == 0 || !email.contains ("@")) return;

            /* Avoid duplicates */
            for (uint i = 0; i < member_emails.length; i++) {
                if (member_emails[i] == email) return;
            }

            member_emails.add (email);

            var row = new Adw.ActionRow ();
            row.title = email;

            var avatar = new Adw.Avatar (28, email, true);
            row.add_prefix (avatar);

            var remove_btn = new Gtk.Button.from_icon_name ("user-trash-symbolic");
            remove_btn.valign = Gtk.Align.CENTER;
            remove_btn.add_css_class ("flat");
            remove_btn.add_css_class ("error");
            remove_btn.clicked.connect (() => {
                for (uint i = 0; i < member_emails.length; i++) {
                    if (member_emails[i] == email) {
                        member_emails.remove_index (i);
                        break;
                    }
                }
                member_listbox.remove (row);
            });
            row.add_suffix (remove_btn);

            member_listbox.append (row);
        }

        private async void do_create () {
            string name = name_entry.text.strip ();
            if (name.length == 0) {
                name_entry.add_css_class ("error");
                return;
            }
            name_entry.remove_css_class ("error");

            try {
                int new_chat_id = yield rpc.create_group (acct_id, name, true);

                /* Set avatar if picked */
                if (avatar_path != null) {
                    try {
                        yield rpc.set_chat_profile_image (acct_id, new_chat_id, avatar_path);
                    } catch (Error ae) {
                        /* non-fatal */
                    }
                }

                /* Add members */
                for (uint i = 0; i < member_emails.length; i++) {
                    string email = member_emails[i];
                    try {
                        int contact_id = yield rpc.get_or_create_contact (acct_id, email);
                        yield rpc.add_contact_to_chat (acct_id, new_chat_id, contact_id);
                    } catch (Error me) {
                        /* skip failed member, continue */
                    }
                }

                group_created (new_chat_id);
                this.close ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void pick_avatar () {
            var chooser = new Gtk.FileDialog ();
            chooser.title = "Select Group Avatar";

            var filter = new Gtk.FileFilter ();
            filter.add_mime_type ("image/*");
            filter.name = "Images";
            var filters = new ListStore (typeof (Gtk.FileFilter));
            filters.append (filter);
            chooser.filters = filters;

            try {
                var file = yield chooser.open ((Gtk.Window) this.get_root (), null);
                if (file != null) {
                    avatar_path = file.get_path ();
                    avatar_widget.custom_image = load_avatar (avatar_path);
                }
            } catch (Error e) {
                /* cancelled */
            }
        }
    }
}
