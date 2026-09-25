namespace Dc {

    public class ChatActions : Object {
        public static bool is_channel (string type) {
            return type == "InBroadcast" || type == "OutBroadcast" || type == "Broadcast";
        }

        public static string[] reaction_choices (string type) {
            // Core permits only these five reactions in channels.
            if (is_channel (type)) return { "👍", "👎", "❤️", "😂", "🙁" };
            return { "👍", "👎", "❤️", "🔥", "😂", "😮", "😢" };
        }

        public static bool can_leave (string type, bool encrypted,
                                      bool member, bool request) {
            return member && (type == "InBroadcast"
                || (type == "Group" && encrypted && !request));
        }

        public static bool can_edit_members (string type, bool encrypted,
                                              bool can_send) {
            return encrypted && can_send
                && (type == "Group" || type == "OutBroadcast" || type == "Broadcast");
        }

        public static string request_action (string type) {
            if (type == "Group") return "Delete Request…";
            if (type == "Single") return "Block Contact…";
            return "Block Chat…";
        }
    }
}
