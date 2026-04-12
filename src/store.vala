namespace Dc {

    public ChatEntry? find_chat_entry (GLib.ListStore store, int chat_id) {
        for (uint i = 0; i < store.get_n_items (); i++) {
            var entry = (ChatEntry) store.get_item (i);
            if (entry.id == chat_id) return entry;
        }
        return null;
    }

    public Message? find_message (GLib.ListStore store, int msg_id) {
        for (uint i = 0; i < store.get_n_items (); i++) {
            var m = (Message) store.get_item (i);
            if (m.id == msg_id) return m;
        }
        return null;
    }

    public int find_message_index (GLib.ListStore store, int msg_id) {
        for (uint i = 0; i < store.get_n_items (); i++) {
            var m = (Message) store.get_item (i);
            if (m.id == msg_id) return (int) i;
        }
        return -1;
    }

    /* Find the ListBoxRow index for a given message ID. Returns -1 if not found. */
    public int find_message_row_index (Gtk.ListBox listbox, int msg_id) {
        int idx = 0;
        Gtk.ListBoxRow? row;
        while ((row = listbox.get_row_at_index (idx)) != null) {
            var mr = row as MessageRow;
            if (mr != null && mr.message_id == msg_id) return idx;
            idx++;
        }
        return -1;
    }

    /* Remove and re-insert a message row at the same position. */
    public void replace_message_row (Gtk.ListBox listbox, int idx, Gtk.Widget new_row) {
        var old = listbox.get_row_at_index (idx);
        if (old != null) listbox.remove (old);
        listbox.insert (new_row, idx);
    }
}
