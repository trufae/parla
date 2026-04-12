namespace Dc {

    public class ContactPickerDialog : Adw.Dialog {

        public signal void contact_picked (int contact_id, string email);

        private RpcClient rpc;
        private int acct_id;
        private Gtk.SearchEntry search_entry;
        private Gtk.ListBox contact_listbox;
        private Gtk.Button use_email_btn;
        private GenericArray<Contact> all_contacts = new GenericArray<Contact> ();

        public ContactPickerDialog (RpcClient rpc, int acct_id) {
            this.rpc = rpc;
            this.acct_id = acct_id;
            this.title = "Select Contact";
            this.content_width = 360;
            this.content_height = 500;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            header.show_end_title_buttons = true;
            box.append (header);

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            content.margin_start = 12;
            content.margin_end = 12;
            content.margin_top = 8;
            content.margin_bottom = 12;

            /* Search / filter entry */
            search_entry = new Gtk.SearchEntry ();
            search_entry.placeholder_text = "Search or enter email\u2026";
            search_entry.hexpand = true;
            search_entry.search_changed.connect (on_search_changed);
            search_entry.activate.connect (on_activate_search);
            content.append (search_entry);

            /* "Use this email" button, shown when search text looks like an email */
            use_email_btn = new Gtk.Button ();
            use_email_btn.add_css_class ("suggested-action");
            use_email_btn.visible = false;
            use_email_btn.clicked.connect (on_use_email);
            content.append (use_email_btn);

            /* Scrollable contact list */
            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            contact_listbox = new Gtk.ListBox ();
            contact_listbox.selection_mode = Gtk.SelectionMode.NONE;
            contact_listbox.add_css_class ("boxed-list");
            contact_listbox.row_activated.connect (on_row_activated);
            scroll.child = contact_listbox;
            content.append (scroll);

            box.append (content);
            this.child = box;

            /* Close on Escape */
            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            key_ctrl.key_pressed.connect ((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    this.close ();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget) this).add_controller (key_ctrl);

            /* Load contacts */
            load_contacts.begin ();
        }

        private async void load_contacts () {
            try {
                var ids = yield rpc.get_contact_ids (acct_id, null);
                if (ids == null) return;

                for (uint i = 0; i < ids.get_length (); i++) {
                    int cid = (int) ids.get_int_element (i);
                    if (cid <= 1) continue; /* skip self (1) and special IDs */

                    var obj = yield rpc.get_contact (acct_id, cid);
                    if (obj == null) continue;

                    var ci = RpcClient.parse_contact (cid, obj);
                    if (ci.address.length == 0) continue;

                    all_contacts.add (ci);
                }

                rebuild_list ("");
            } catch (Error e) {
                var lbl = new Gtk.Label ("Failed to load contacts: " + e.message);
                lbl.add_css_class ("dim-label");
                lbl.wrap = true;
                contact_listbox.append (lbl);
            }
        }

        private void rebuild_list (string query) {
            /* Remove all rows */
            Gtk.ListBoxRow? row;
            while ((row = contact_listbox.get_row_at_index (0)) != null) {
                contact_listbox.remove (row);
            }

            string q = query.strip ().down ();

            for (uint i = 0; i < all_contacts.length; i++) {
                var ci = all_contacts[i];

                if (q.length > 0) {
                    bool matches = ci.display_name.down ().contains (q)
                        || ci.address.down ().contains (q);
                    if (!matches) continue;
                }

                var r = build_contact_row (ci);
                contact_listbox.append (r);
            }
        }

        private Adw.ActionRow build_contact_row (Contact ci) {
            string title = ci.display_name.length > 0 ? ci.display_name : ci.address;
            string subtitle = ci.display_name.length > 0 ? ci.address : "";
            if (ci.is_verified && subtitle.length > 0) subtitle += " (verified)";
            else if (ci.is_verified) subtitle = "(verified)";

            var row = new Adw.ActionRow ();
            row.title = title;
            row.subtitle = subtitle;
            row.activatable = true;

            var avatar = new Adw.Avatar (32, title, true);
            if (ci.profile_image != null &&
                FileUtils.test (ci.profile_image, FileTest.EXISTS)) {
                try {
                    avatar.custom_image = Gdk.Texture.from_filename (ci.profile_image);
                } catch (Error e) { /* fallback */ }
            }
            row.add_prefix (avatar);

            /* Store contact_id and email in row name for retrieval */
            row.name = "%d\n%s".printf (ci.id, ci.address);

            return row;
        }

        private void on_search_changed () {
            string text = search_entry.text.strip ();
            rebuild_list (text);

            /* Show "use this email" button if text looks like an email
               and doesn't exactly match an existing contact */
            if (text.contains ("@") && text.length > 3) {
                bool already_listed = false;
                for (uint i = 0; i < all_contacts.length; i++) {
                    var ci = all_contacts[i];
                    if (ci.address.down () == text.down ()) {
                        already_listed = true;
                        break;
                    }
                }
                use_email_btn.label = "Start chat with %s".printf (text);
                use_email_btn.visible = !already_listed;
            } else {
                use_email_btn.visible = false;
            }
        }

        private void on_activate_search () {
            string text = search_entry.text.strip ();

            /* If there's exactly one visible row, pick it */
            var first = contact_listbox.get_row_at_index (0);
            var second = contact_listbox.get_row_at_index (1);
            if (first != null && second == null) {
                on_row_activated (first);
                return;
            }

            /* Otherwise if it looks like an email, use it directly */
            if (text.contains ("@") && text.length > 3) {
                on_use_email ();
            }
        }

        private void on_row_activated (Gtk.ListBoxRow row) {
            /* The Adw.ActionRow is the direct child of the ListBoxRow */
            var action_row = row as Adw.ActionRow;
            if (action_row == null) {
                var child = row.child as Adw.ActionRow;
                if (child != null) action_row = child;
                else return;
            }

            string data = action_row.name ?? "";
            string[] parts = data.split ("\n", 2);
            if (parts.length < 2) return;

            int contact_id = int.parse (parts[0]);
            string email = parts[1];

            contact_picked (contact_id, email);
            this.close ();
        }

        private void on_use_email () {
            string email = search_entry.text.strip ();
            if (email.length == 0 || !email.contains ("@")) return;

            /* contact_id 0 means "new contact, create it" */
            contact_picked (0, email);
            this.close ();
        }
    }
}
