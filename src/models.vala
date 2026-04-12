namespace Dc {

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
}
