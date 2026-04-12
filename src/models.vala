namespace Dc {

    public delegate void VoidFunc ();

    public static void show_error (Gtk.Widget parent, string message) {
        var d = new Adw.AlertDialog ("Error", message);
        d.add_response ("ok", "OK");
        d.present (parent);
    }

    public static void confirm_action (Gtk.Widget parent, string title,
                                        string body, string action_id,
                                        string action_label,
                                        owned VoidFunc on_confirm) {
        var d = new Adw.AlertDialog (title, body);
        d.add_response ("cancel", "Cancel");
        d.add_response (action_id, action_label);
        d.set_response_appearance (action_id, Adw.ResponseAppearance.DESTRUCTIVE);
        d.default_response = "cancel";
        d.response.connect ((r) => { if (r == action_id) on_confirm (); });
        d.present (parent);
    }

    public static void install_escape_close (Adw.Dialog dialog) {
        var kc = new Gtk.EventControllerKey ();
        kc.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        kc.key_pressed.connect ((kv, kc, st) => {
            if (kv == Gdk.Key.Escape) { dialog.close (); return true; }
            return false;
        });
        ((Gtk.Widget) dialog).add_controller (kc);
    }

    public static Gdk.Texture? load_avatar (string? path) {
        if (path != null && path.length > 0 &&
            FileUtils.test (path, FileTest.EXISTS)) {
            try {
                return Gdk.Texture.from_filename (path);
            } catch (Error e) { /* fallback */ }
        }
        return null;
    }

    public class Account : Object {
        public int id { get; set; default = 0; }
        public string email { get; set; default = ""; }
        public string password { get; set; default = ""; }
        public bool configured { get; set; default = false; }
        public string? display_name { get; set; default = null; }
    }

    public class ChatEntry : Object {
        public int id { get; set; default = 0; }
        public string name { get; set; default = ""; }
        public string? last_message { get; set; default = null; }
        public string? summary_prefix { get; set; default = null; }
        public int64 timestamp { get; set; default = 0; }
        public int unread_count { get; set; default = 0; }
        public string? avatar_path { get; set; default = null; }
        public int chat_type { get; set; default = 0; }
        public bool is_muted { get; set; default = false; }
        public bool is_contact_request { get; set; default = false; }
        public bool is_archived { get; set; default = false; }
        public bool is_pinned { get; set; default = false; }
    }

    public class Message : Object {
        public int id { get; set; default = 0; }
        public int chat_id { get; set; default = 0; }
        public string? text { get; set; default = null; }
        public string? sender_address { get; set; default = null; }
        public string? sender_name { get; set; default = null; }
        public int64 timestamp { get; set; default = 0; }
        public bool is_outgoing { get; set; default = false; }
        public string? file_path { get; set; default = null; }
        public string? file_name { get; set; default = null; }
        public string? file_mime { get; set; default = null; }
        public int file_bytes { get; set; default = 0; }
        public string? view_type { get; set; default = null; }
        public bool is_info { get; set; default = false; }
        public string? reactions { get; set; default = null; }
        public int quote_msg_id { get; set; default = 0; }
        public string? quote_text { get; set; default = null; }
        public string? quote_sender_name { get; set; default = null; }
        public bool is_pinned { get; set; default = false; }
        public bool highlighted { get; set; default = false; }
    }

    public class Contact : Object {
        public int id { get; set; default = 0; }
        public string display_name { get; set; default = ""; }
        public string address { get; set; default = ""; }
        public string? profile_image { get; set; default = null; }
        public bool is_verified { get; set; default = false; }
    }

    public class FoundInstallation : Object {
        public string label { get; set; default = ""; }
        public string data_path { get; set; default = ""; }
        public string? email { get; set; default = null; }
        public string? password { get; set; default = null; }
        public string source { get; set; default = ""; }
    }

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
