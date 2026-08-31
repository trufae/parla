namespace Dc {

    public class ContactPickerDialog : Adw.Dialog {

        public signal void contact_picked (int contact_id, string email);
        public signal void chat_picked (int chat_id);

        /* The account whose chat/contact was picked. Callers read this after
           a pick signal to know which account to act on — it equals the
           current account unless the account selector is enabled and the user
           switched to another one (used by cross-account forwarding). */
        public int selected_account_id { get; private set; default = 0; }

        private RpcClient rpc;
        private GLib.ListStore? chat_store;
        private Gtk.SearchEntry search_entry;
        private Gtk.ListBox chat_listbox;
        private Gtk.ListBox contact_listbox;
        private Gtk.Label chats_header;
        private Gtk.Label contacts_header;
        private Gtk.Button use_email_btn;
        private GenericArray<Contact> all_contacts = new GenericArray<Contact> ();

        /* Account selector state — only used when enable_account_selector is
           set. When active, chats are loaded from the RPC for the selected
           account instead of the passed-in chat_store. */
        private bool account_selector_enabled = false;
        private Gtk.DropDown? account_dropdown = null;
        private int[] account_ids = {};
        private GenericArray<ChatEntry> loaded_chats = new GenericArray<ChatEntry> ();
        private uint chat_load_gen = 0;
        private uint contact_load_gen = 0;

        public ContactPickerDialog (RpcClient rpc,
                                     GLib.ListStore? chat_store = null,
                                     string? title = null,
                                     bool enable_account_selector = false) {
            this.rpc = rpc;
            this.chat_store = chat_store;
            this.account_selector_enabled = enable_account_selector;
            this.selected_account_id = rpc.account_id;
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

            /* Account selector — lets the user forward into a different
               account. Populated asynchronously from get_all_accounts. */
            if (account_selector_enabled) {
                account_dropdown = new Gtk.DropDown (new Gtk.StringList (null), null);
                account_dropdown.hexpand = true;
                account_dropdown.tooltip_text = "Destination account";
                account_dropdown.notify["selected"].connect (on_account_changed);
                content.append (account_dropdown);
            }

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

            /* Load contacts for the initially-selected account. */
            load_contacts.begin ();

            if (account_selector_enabled) {
                /* Chats come from the RPC so any account can be shown; also
                   populates the account dropdown. */
                load_accounts.begin ();
                load_chats_for_account.begin (selected_account_id);
            } else if (chat_store != null) {
                /* Populate chat rows (synchronous — chat_store is already
                   loaded for the current account). */
                rebuild_chat_list ("");
            }
        }

        /* Fill the account dropdown with every configured account and preselect
           the current one. */
        private async void load_accounts () {
            if (account_dropdown == null) return;
            var model = (Gtk.StringList) account_dropdown.model;
            int[] ids = {};
            int selected_idx = 0;
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node != null
                    && accounts_node.get_node_type () == Json.NodeType.ARRAY) {
                    var accounts = accounts_node.get_array ();
                    for (uint i = 0; i < accounts.get_length (); i++) {
                        var acct = accounts.get_object_element (i);
                        if (acct == null) continue;
                        int id = (int) acct.get_int_member ("id");
                        if (id <= 0 || !(yield rpc.is_configured (id))) continue;

                        string? name = yield rpc.get_config ("displayname", id);
                        string? addr = yield rpc.get_config ("addr", id);
                        string label = (name != null && name.length > 0)
                            ? name : (addr ?? "Account #%d".printf (id));
                        if (name != null && name.length > 0
                            && addr != null && addr.length > 0)
                            label = "%s (%s)".printf (name, addr);

                        if (id == selected_account_id)
                            selected_idx = ids.length;
                        ids += id;
                        model.append (label);
                    }
                }
            } catch (Error e) {
                /* Leave the dropdown as-is; the current account still works. */
            }
            account_ids = ids;
            /* Setting selected here won't spuriously reload: on_account_changed
               is a no-op when the id doesn't actually change. */
            if (ids.length > 0) account_dropdown.selected = selected_idx;
        }

        private void on_account_changed () {
            if (account_dropdown == null) return;
            int idx = (int) account_dropdown.selected;
            if (idx < 0 || idx >= account_ids.length) return;
            int id = account_ids[idx];
            if (id == selected_account_id) return;

            selected_account_id = id;
            search_entry.text = "";
            load_contacts.begin ();
            load_chats_for_account.begin (id);
        }

        /* Fetch the chat list for an account via the RPC and rebuild the chat
           section. Used only in account-selector mode. */
        private async void load_chats_for_account (int acct_id) {
            uint gen = ++chat_load_gen;
            var chats = new GenericArray<ChatEntry> ();
            try {
                var entries = yield rpc.get_chatlist_entries_for (
                    acct_id, null, RpcClient.GCL_NO_SPECIALS);
                if (entries != null) {
                    var items = yield rpc.get_chatlist_items_by_entries_for (
                        acct_id, entries);
                    for (uint i = 0; i < entries.get_length (); i++) {
                        int chat_id = (int) entries.get_int_element (i);
                        string id_str = chat_id.to_string ();
                        if (items != null && items.has_member (id_str)) {
                            var item = items.get_object_member (id_str);
                            chats.add (RpcParsers.parse_chat_item (chat_id, item));
                        }
                    }
                }
            } catch (Error e) {
                /* Fall through with whatever was collected. */
            }
            if (gen != chat_load_gen) return; /* superseded by a newer switch */
            loaded_chats = chats;
            rebuild_chat_list (search_entry.text.strip ());
        }

        private async void load_contacts () {
            uint gen = ++contact_load_gen;
            int acct_id = selected_account_id;
            var collected = new GenericArray<Contact> ();
            try {
                var ids = yield rpc.get_contact_ids_for (acct_id, null);
                if (ids == null) return;

                for (uint i = 0; i < ids.get_length (); i++) {
                    int cid = (int) ids.get_int_element (i);
                    if (cid <= 1) continue; /* skip self (1) and special IDs */

                    var obj = yield rpc.get_contact_for (acct_id, cid);
                    if (obj == null) continue;

                    var ci = RpcParsers.parse_contact (cid, obj);
                    if (ci.address.length == 0) continue;

                    collected.add (ci);
                }

                if (gen != contact_load_gen) return; /* superseded */
                all_contacts = collected;
                rebuild_contact_list (search_entry.text.strip ());
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

            string q = query.strip ().down ();
            bool any = false;

            /* In account-selector mode chats come from the RPC (loaded_chats);
               otherwise from the current account's chat_store. */
            if (account_selector_enabled) {
                for (uint i = 0; i < loaded_chats.length; i++) {
                    var chat = loaded_chats[i];
                    if (q.length > 0 && !chat.name.down ().contains (q)) continue;
                    chat_listbox.append (chat_pick_row (chat));
                    any = true;
                }
            } else {
                if (chat_store == null) return;
                for (uint i = 0; i < chat_store.get_n_items (); i++) {
                    var chat = (ChatEntry) chat_store.get_item (i);
                    if (q.length > 0 && !chat.name.down ().contains (q)) continue;

                    chat_listbox.append (chat_pick_row (chat));
                    any = true;
                }
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
            if (chat_store != null || account_selector_enabled)
                rebuild_chat_list (text);

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
