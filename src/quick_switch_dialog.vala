namespace Dc {

    public class QuickSwitchDialog : Adw.Dialog {

        private GLib.ListStore chat_store;
        private Gtk.SearchEntry entry;
        private Gtk.ListBox listbox;

        public signal void chat_selected (int chat_id);

        public QuickSwitchDialog (GLib.ListStore chat_store) {
            this.chat_store = chat_store;
            this.title = "Switch Chat";
            this.content_width = 360;
            this.content_height = 400;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var header = new Adw.HeaderBar ();
            box.append (header);

            var inner = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            inner.margin_start = 12;
            inner.margin_end = 12;
            inner.margin_top = 8;
            inner.margin_bottom = 12;

            entry = new Gtk.SearchEntry ();
            entry.placeholder_text = "Type to filter chats\u2026";
            entry.hexpand = true;
            inner.append (entry);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            listbox = new Gtk.ListBox ();
            listbox.selection_mode = Gtk.SelectionMode.SINGLE;
            listbox.add_css_class ("boxed-list");
            scroll.child = listbox;
            inner.append (scroll);

            /* Populate with all chats */
            for (uint i = 0; i < chat_store.get_n_items (); i++) {
                var chat = (ChatEntry) chat_store.get_item (i);
                var row = new Adw.ActionRow ();
                row.title = chat.name;
                if (chat.last_message != null && chat.last_message.length > 0)
                    row.subtitle = chat.last_message;
                row.name = chat.id.to_string ();
                row.activatable = true;
                var avatar = new Adw.Avatar (32, chat.name, true);
                avatar.custom_image = load_avatar (chat.avatar_path);
                row.add_prefix (avatar);
                listbox.append (row);
            }

            /* Filter */
            listbox.set_filter_func ((row) => {
                string query = entry.text.strip ().down ();
                if (query.length == 0) return true;
                var action_row = row as Adw.ActionRow;
                if (action_row == null) return true;
                return action_row.title.down ().contains (query);
            });

            entry.search_changed.connect (() => {
                listbox.invalidate_filter ();
            });

            /* Enter picks the first matching chat */
            entry.activate.connect (() => {
                string query = entry.text.strip ().down ();
                for (uint i = 0; i < chat_store.get_n_items (); i++) {
                    var chat = (ChatEntry) chat_store.get_item (i);
                    if (query.length == 0 || chat.name.down ().contains (query)) {
                        this.close ();
                        chat_selected (chat.id);
                        return;
                    }
                }
            });

            /* Click on a row */
            listbox.row_activated.connect ((row) => {
                var action_row = row as Adw.ActionRow;
                if (action_row == null) return;
                int cid = int.parse (action_row.name);
                this.close ();
                chat_selected (cid);
            });

            /* Escape dismisses the dialog (SearchEntry would otherwise
             * swallow the key to clear its text). */
            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            key_ctrl.key_pressed.connect ((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    this.close ();
                    return true;
                }
                return false;
            });
            box.add_controller (key_ctrl);

            box.append (inner);
            this.child = box;
        }

        public void focus_entry () {
            entry.grab_focus ();
        }
    }
}
