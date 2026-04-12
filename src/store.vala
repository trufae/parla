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
}
