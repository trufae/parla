namespace Dc {

    /** Locale date plus time, e.g. "07/25/2026 · 17:42". */
    public static string format_date_time (int64 ts) {
        if (ts <= 0) return "";
        return new DateTime.from_unix_local (ts).format ("%x · %H:%M");
    }

    /* ---- JSON helpers ---- */

    public static string? json_str (Json.Object obj, string key) {
        if (!obj.has_member (key)) return null;
        var m = obj.get_member (key);
        if (m == null || m.is_null ()) return null;
        return obj.get_string_member (key);
    }

    // Object-valued member, or null when missing/null/not an object.
    public static Json.Object? json_obj (Json.Object obj, string key) {
        if (!obj.has_member (key)) return null;
        var m = obj.get_member (key);
        if (m == null || m.get_node_type () != Json.NodeType.OBJECT) return null;
        return obj.get_object_member (key);
    }

    public static int64 json_int (Json.Object obj, string key, int64 fallback = 0) {
        if (!obj.has_member (key)) return fallback;
        var m = obj.get_member (key);
        if (m == null || m.is_null ()) return fallback;
        return obj.get_int_member (key);
    }

    public static bool json_bool (Json.Object obj, string key) {
        if (!obj.has_member (key)) return false;
        var m = obj.get_member (key);
        if (m == null || m.is_null ()) return false;
        return obj.get_boolean_member (key);
    }

    // Decode a JSON-RPC result that is an array of ints; empty array when
    // the node is missing or not an array.
    public static int[] json_int_array (Json.Node? result) {
        if (result == null || result.get_node_type () != Json.NodeType.ARRAY)
            return {};
        var arr = result.get_array ();
        int[] ids = new int[arr.get_length ()];
        for (uint i = 0; i < arr.get_length (); i++) {
            ids[i] = (int) arr.get_int_element (i);
        }
        return ids;
    }

    public class ChatEntry : Object {
        public int id { get; set; default = 0; }
        public string name { get; set; default = ""; }
        public string? last_message { get; set; default = null; }
        public int last_message_id { get; set; default = 0; }
        public string? summary_prefix { get; set; default = null; }
        public int64 timestamp { get; set; default = 0; }
        public int unread_count { get; set; default = 0; }
        public string? avatar_path { get; set; default = null; }
        public ChatKind kind { get; set; default = ChatKind.UNKNOWN; }
        public bool is_muted { get; set; default = false; }
        public bool is_contact_request { get; set; default = false; }
        public string chat_type { get; set; default = ""; }
        public bool can_leave_chat { get; set; default = false; }
        public bool is_pinned { get; set; default = false; }
        public bool is_archived { get; set; default = false; }
        public bool was_seen_recently { get; set; default = false; }
        /* Client-side flag: an unseen message in this chat mentions the local
           user. Not persisted (see Window.mentioned_chats). */
        public bool has_mention { get; set; default = false; }
        /* The summary describes the chat's draft, not its last message. */
        public bool is_draft { get; set; default = false; }

        /* True when a ChatRow built from `o` would look exactly like one
           built from this entry (everything the row renders). */
        public bool same_display (ChatEntry o) {
            return id == o.id
                && name == o.name
                && last_message == o.last_message
                && summary_prefix == o.summary_prefix
                && timestamp == o.timestamp
                && unread_count == o.unread_count
                && avatar_path == o.avatar_path
                && kind == o.kind
                && is_muted == o.is_muted
                && is_contact_request == o.is_contact_request
                && chat_type == o.chat_type
                && can_leave_chat == o.can_leave_chat
                && is_pinned == o.is_pinned
                && is_archived == o.is_archived
                && was_seen_recently == o.was_seen_recently
                && has_mention == o.has_mention;
        }
    }

    public enum ChatKind {
        UNKNOWN = 0,
        DIRECT = 1,
        GROUP = 2;
    }

    public class MessageReactionUser : Object {
        public int contact_id { get; set; default = 0; }

        public MessageReactionUser (int contact_id) {
            this.contact_id = contact_id;
        }
    }

    public class MessageReaction : Object {
        public string emoji { get; set; default = ""; }
        public int count { get; set; default = 0; }
        public GenericArray<MessageReactionUser> users =
            new GenericArray<MessageReactionUser> ();

        public MessageReaction (string emoji) {
            this.emoji = emoji;
        }

        public void add_user (int contact_id) {
            users.add (new MessageReactionUser (contact_id));
            count++;
        }
    }

    /* Message state values from Delta Chat JSON-RPC. */
    public enum MessageState {
        UNDEFINED     = 0,
        IN_FRESH      = 10,
        IN_NOTICED    = 13,
        IN_SEEN       = 16,
        OUT_PREPARING = 18,
        OUT_DRAFT     = 19,
        OUT_PENDING   = 20,
        OUT_FAILED    = 24,
        OUT_DELIVERED = 26,
        OUT_MDN_RCVD  = 28;
    }

    public class Message : Object {
        private const string[] IMAGE_EXTENSIONS = {
            ".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".svg"
        };
        private const string[] VIDEO_EXTENSIONS = {
            ".mp4", ".m4v", ".webm", ".mkv", ".mov", ".avi", ".ogv", ".3gp", ".wmv", ".flv"
        };
        private const string[] AUDIO_EXTENSIONS = {
            ".mp3", ".ogg", ".oga", ".opus", ".wav", ".m4a", ".aac", ".flac", ".weba", ".amr"
        };
        private const string[] TEXT_EXTENSIONS = {
            ".txt", ".text", ".md", ".markdown", ".html", ".htm"
        };

        public int id { get; set; default = 0; }
        public int chat_id { get; set; default = 0; }
        public string? text { get; set; default = null; }
        public string? sender_address { get; set; default = null; }
        public string? sender_name { get; set; default = null; }
        public string? sender_avatar_path { get; set; default = null; }
        public int sender_contact_id { get; set; default = 0; }
        public bool sender_was_seen_recently { get; set; default = false; }
        /* True when the message was forwarded into this chat. */
        public bool is_forwarded { get; set; default = false; }
        /* True when the message text was edited after sending. */
        public bool is_edited { get; set; default = false; }
        /* Overridden author name (mailing lists, bots, non-group senders);
           shown with a leading "~" by convention. */
        public string? override_sender_name { get; set; default = null; }
        public int64 timestamp { get; set; default = 0; }
        public bool is_outgoing { get; set; default = false; }
        public string? file_path { get; set; default = null; }
        public string? file_name { get; set; default = null; }
        public string? file_mime { get; set; default = null; }
        public int file_bytes { get; set; default = 0; }
        public int dimensions_width { get; set; default = 0; }
        public int dimensions_height { get; set; default = 0; }
        public string? view_type { get; set; default = null; }
        public VcardContact? vcard_contact { get; set; default = null; }
        public bool is_info { get; set; default = false; }
        public bool has_html { get; set; default = false; }
        public string download_state { get; set; default = "Done"; }
        public string? reactions { get; set; default = null; }
        public GenericArray<MessageReaction>? reaction_details = null;
        /* Emojis the local user has reacted with (comma-separated). */
        public string? my_reactions { get; set; default = null; }
        public int quote_msg_id { get; set; default = 0; }
        public string? quote_text { get; set; default = null; }
        public string? quote_sender_name { get; set; default = null; }
        public bool is_pinned { get; set; default = false; }
        public bool highlighted { get; set; default = false; }
        public bool selection_visible { get; set; default = false; }
        public bool selected { get; set; default = false; }
        /* Lazily fetched full-message content and its transient presentation
           state. This data belongs to the current conversation view only. */
        public string? full_message_text { get; set; default = null; }
        public bool full_message_expanded { get; set; default = false; }
        public bool full_message_loading { get; set; default = false; }

        /* Delivery state — one of MessageState. */
        public int state { get; set; default = 0; }
        public string? error { get; set; default = null; }

        /* Convenience derived flags for the UI. */
        public bool is_pending {
            get {
                return state == MessageState.OUT_PENDING
                    || state == MessageState.OUT_PREPARING;
            }
        }
        public bool is_delivered {
            get {
                return state == MessageState.OUT_DELIVERED
                    || state == MessageState.OUT_MDN_RCVD;
            }
        }
        public bool is_read {
            get { return state == MessageState.OUT_MDN_RCVD; }
        }
        public bool is_failed {
            get { return state == MessageState.OUT_FAILED; }
        }
        public bool can_retry {
            get { return id > 0 && is_outgoing && is_failed && !is_info; }
        }
        public bool has_text {
            get { return text != null && text.strip ().length > 0; }
        }
        public bool can_download_full_message {
            get { return download_state == "Available" || download_state == "Failure"; }
        }
        public bool is_downloading_full_message {
            get { return download_state == "InProgress"; }
        }
        public bool has_full_message_action {
            get {
                return can_download_full_message || has_html
                    || full_message_text != null;
            }
        }
        /* Mirrors the checks in core's send_edit_request(): messages with an
           HTML/full-message part are not editable on purpose — the stored
           full version would keep the old text, silently diverging from the
           edited one. This includes long messages truncated by core. */
        public bool can_edit_text {
            get {
                return is_outgoing && !is_info && has_text
                    && !has_html && !view_type_is ("call");
            }
        }
        public bool has_file {
            get { return has_value (file_name) || has_value (file_path); }
        }
        public bool has_local_file {
            get { return has_value (file_path) && FileUtils.test (file_path, FileTest.EXISTS); }
        }
        public bool is_image_only {
            get {
                return !is_info && !has_text && has_value (file_path)
                    && (is_image_file () || is_sticker_file ());
            }
        }

        public bool is_image_file () {
            return has_mime ("image/")
                || view_type_is ("image", "gif", "sticker")
                || path_has_suffix (IMAGE_EXTENSIONS);
        }

        /** Sticker is a semantic Delta Chat view type, independent of the
            attachment's encoded media format. */
        public bool is_sticker_file () {
            return view_type_is ("sticker");
        }

        /** Webxdc mini-app attachment (runnable when built with -Dwebxdc). */
        public bool is_webxdc () {
            return view_type_is ("webxdc");
        }

        public bool is_vcard () {
            return view_type_is ("vcard") || vcard_contact != null
                || AttachmentTypes.is_vcard (file_path, file_name, file_mime);
        }

        public bool is_video_sticker_file () {
            return has_mime ("video/webm")
                || path_has_suffix ({ ".webm" });
        }

        public bool is_video_file () {
            return has_mime ("video/")
                || view_type_is ("video")
                || path_has_suffix (VIDEO_EXTENSIONS);
        }

        public bool is_audio_file () {
            return has_mime ("audio/")
                || view_type_is ("audio", "voice")
                || path_has_suffix (AUDIO_EXTENSIONS);
        }

        /** Text-like attachments (txt/md/html) can be previewed inline. */
        public bool is_text_preview_file () {
            return has_mime ("text/plain")
                || has_mime ("text/markdown")
                || has_mime ("text/html")
                || path_has_suffix (TEXT_EXTENSIONS);
        }

        public bool is_markdown_file () {
            return has_mime ("text/markdown")
                || path_has_suffix ({ ".md", ".markdown" });
        }

        public bool is_html_file () {
            return has_mime ("text/html")
                || path_has_suffix ({ ".html", ".htm" });
        }

        public string display_file_name (string fallback = "file") {
            return has_value (file_name) ? file_name : fallback;
        }

        /** Copy all properties into a fresh instance. Gtk.ListView reuses the
         * row widget when the same Message pointer reappears at a position, so
         * mutating in place never rebinds; splicing a distinct copy does. */
        public Message dup () {
            var copy = new Message ();
            const ParamFlags RW = ParamFlags.READABLE | ParamFlags.WRITABLE;
            foreach (var spec in get_class ().list_properties ()) {
                if ((spec.flags & RW) != RW) continue;
                var val = GLib.Value (spec.value_type);
                get_property (spec.name, ref val);
                copy.set_property (spec.name, val);
            }
            copy.reaction_details = reaction_details;
            return copy;
        }

        private bool has_value (string? value) {
            return value != null && value.length > 0;
        }

        private bool has_mime (string prefix) {
            return file_mime != null && file_mime.has_prefix (prefix);
        }

        private bool view_type_is (string a, string? b = null, string? c = null) {
            if (view_type == null) return false;
            string vt = view_type.down ();
            return vt == a || (b != null && vt == b) || (c != null && vt == c);
        }

        private bool path_has_suffix (string[] suffixes) {
            string lower = (file_path ?? "").down ();
            string name = (file_name ?? "").down ();
            foreach (string suffix in suffixes) {
                if (lower.has_suffix (suffix) || name.has_suffix (suffix)) return true;
            }
            return false;
        }
    }

    public class Contact : Object {
        public int id { get; set; default = 0; }
        public string display_name { get; set; default = ""; }
        public string address { get; set; default = ""; }
        public string? profile_image { get; set; default = null; }
        public bool is_blocked { get; set; default = false; }
        public string? status { get; set; default = null; }
        public bool was_seen_recently { get; set; default = false; }
    }

    public ChatEntry? find_chat_entry (GLib.ListStore store, int chat_id) {
        for (uint i = 0; i < store.get_n_items (); i++) {
            var entry = (ChatEntry) store.get_item (i);
            if (entry.id == chat_id) return entry;
        }
        return null;
    }

    public Message? find_message (GLib.ListModel store, int msg_id) {
        for (uint i = 0; i < store.get_n_items (); i++) {
            var m = (Message) store.get_item (i);
            if (m.id == msg_id) return m;
        }
        return null;
    }

    public int find_message_index (GLib.ListModel store, int msg_id) {
        for (uint i = 0; i < store.get_n_items (); i++) {
            var m = (Message) store.get_item (i);
            if (m.id == msg_id) return (int) i;
        }
        return -1;
    }

    public Message? find_last_editable_text_message (GLib.ListStore store) {
        for (uint i = store.get_n_items (); i > 0; i--) {
            var m = (Message) store.get_item (i - 1);
            if (m.can_edit_text) return m;
        }
        return null;
    }
}
