namespace Dc {

    public class ContactPickerDialog : Adw.Dialog {

        public signal void contact_picked (int contact_id, string email);
        public signal void chat_picked (int chat_id);

        private RpcClient rpc;
        private GLib.ListStore? chat_store;
        private Gtk.SearchEntry search_entry;
        private Gtk.ListBox chat_listbox;
        private Gtk.ListBox contact_listbox;
        private Gtk.Label chats_header;
        private Gtk.Label contacts_header;
        private Gtk.Button use_email_btn;
        private GenericArray<Contact> all_contacts = new GenericArray<Contact> ();

        public ContactPickerDialog (RpcClient rpc,
                                     GLib.ListStore? chat_store = null,
                                     string? title = null) {
            this.rpc = rpc;
            this.chat_store = chat_store;
            this.title = title ?? (chat_store != null
                ? "Select Destination" : "Select Contact");
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
            search_entry.placeholder_text = chat_store != null
                ? "Search chats, contacts or enter email\u2026"
                : "Search or enter email\u2026";
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

            /* Scrollable list area containing chat + contact sections */
            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            var list_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            chats_header = new Gtk.Label ("Chats");
            chats_header.add_css_class ("heading");
            chats_header.add_css_class ("dim-label");
            chats_header.halign = Gtk.Align.START;
            chats_header.visible = false;
            list_box.append (chats_header);

            chat_listbox = new Gtk.ListBox ();
            chat_listbox.selection_mode = Gtk.SelectionMode.NONE;
            chat_listbox.add_css_class ("boxed-list");
            chat_listbox.row_activated.connect (on_chat_row_activated);
            chat_listbox.visible = false;
            list_box.append (chat_listbox);

            contacts_header = new Gtk.Label ("Contacts");
            contacts_header.add_css_class ("heading");
            contacts_header.add_css_class ("dim-label");
            contacts_header.halign = Gtk.Align.START;
            contacts_header.visible = (chat_store != null);
            list_box.append (contacts_header);

            contact_listbox = new Gtk.ListBox ();
            contact_listbox.selection_mode = Gtk.SelectionMode.NONE;
            contact_listbox.add_css_class ("boxed-list");
            contact_listbox.row_activated.connect (on_contact_row_activated);
            list_box.append (contact_listbox);

            scroll.child = list_box;
            content.append (scroll);

            box.append (content);
            this.child = box;

            /* Close on Escape — cancels the picker without side effects */
            install_escape_close (this);

            /* Load contacts */
            load_contacts.begin ();

            /* Populate chat rows (synchronous — chat_store is already loaded) */
            if (chat_store != null) {
                rebuild_chat_list ("");
            }
        }

        private async void load_contacts () {
            try {
                var ids = yield rpc.get_contact_ids (null);
                if (ids == null) return;

                for (uint i = 0; i < ids.get_length (); i++) {
                    int cid = (int) ids.get_int_element (i);
                    if (cid <= 1) continue; /* skip self (1) and special IDs */

                    var obj = yield rpc.get_contact (cid);
                    if (obj == null) continue;

                    var ci = RpcClient.parse_contact (cid, obj);
                    if (ci.address.length == 0) continue;

                    all_contacts.add (ci);
                }

                rebuild_contact_list ("");
            } catch (Error e) {
                var lbl = new Gtk.Label ("Failed to load contacts: " + e.message);
                lbl.add_css_class ("dim-label");
                lbl.wrap = true;
                contact_listbox.append (lbl);
            }
        }

        private void rebuild_contact_list (string query) {
            clear_listbox (contact_listbox);

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

        private void rebuild_chat_list (string query) {
            clear_listbox (chat_listbox);
            if (chat_store == null) return;

            string q = query.strip ().down ();
            bool any = false;

            for (uint i = 0; i < chat_store.get_n_items (); i++) {
                var chat = (ChatEntry) chat_store.get_item (i);
                if (q.length > 0 && !chat.name.down ().contains (q)) continue;

                var row = new Adw.ActionRow ();
                row.title = chat.name;
                if (chat.last_message != null && chat.last_message.length > 0)
                    row.subtitle = chat.last_message;
                row.name = chat.id.to_string ();
                row.activatable = true;
                var avatar = new Adw.Avatar (32, chat.name, true);
                avatar.custom_image = load_avatar (chat.avatar_path);
                row.add_prefix (avatar);
                chat_listbox.append (row);
                any = true;
            }

            chats_header.visible = any;
            chat_listbox.visible = any;
        }

        private Adw.ActionRow build_contact_row (Contact ci) {
            var row = contact_row (ci, true);
            /* Store contact_id and email in row name for retrieval */
            row.name = "%d\n%s".printf (ci.id, ci.address);
            return row;
        }

        private void on_search_changed () {
            string text = search_entry.text.strip ();
            rebuild_contact_list (text);
            if (chat_store != null) rebuild_chat_list (text);

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

            /* Prefer the first visible chat row, otherwise the first contact */
            if (chat_store != null) {
                var first_chat = chat_listbox.get_row_at_index (0);
                var second_chat = chat_listbox.get_row_at_index (1);
                var first_contact = contact_listbox.get_row_at_index (0);
                if (first_chat != null && second_chat == null &&
                    first_contact == null) {
                    on_chat_row_activated (first_chat);
                    return;
                }
            }

            var first = contact_listbox.get_row_at_index (0);
            var second = contact_listbox.get_row_at_index (1);
            if (first != null && second == null) {
                on_contact_row_activated (first);
                return;
            }

            /* Otherwise if it looks like an email, use it directly */
            if (text.contains ("@") && text.length > 3) {
                on_use_email ();
            }
        }

        private void on_contact_row_activated (Gtk.ListBoxRow row) {
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

        private void on_chat_row_activated (Gtk.ListBoxRow row) {
            var action_row = row as Adw.ActionRow;
            if (action_row == null) {
                var child = row.child as Adw.ActionRow;
                if (child != null) action_row = child;
                else return;
            }

            int chat_id = int.parse (action_row.name ?? "0");
            if (chat_id <= 0) return;

            chat_picked (chat_id);
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
