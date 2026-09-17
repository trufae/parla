namespace Dc {

    // Match core's delete_msgs_ext restrictions before offering a remote delete.
    public class MessageDeletion : Object {
        public static bool can_delete_for_everyone (Json.Object? message) {
            if (message == null || !message.has_member ("sender") || !message.has_member ("isInfo")
                    || !message.has_member ("showPadlock")) return false;
            var sender_node = message.get_member ("sender");
            if (sender_node.get_node_type () != Json.NodeType.OBJECT) return false;
            var sender = sender_node.get_object ();
            return sender.has_member ("id") && sender.get_int_member ("id") == 1
                && !message.get_boolean_member ("isInfo")
                && message.get_boolean_member ("showPadlock");
        }

        public static Json.Object? message_by_id (Json.Object messages, int id) {
            string key = id.to_string ();
            if (!messages.has_member (key)) return null;
            var node = messages.get_member (key);
            return node.get_node_type () == Json.NodeType.OBJECT
                ? node.get_object () : null;
        }

        // The gallery can select files from multiple chats. Core only accepts
        // one chat per delete-for-everyone request; never send a partial batch.
        public static int common_chat (Json.Object messages, int[] ids) {
            int chat_id = 0;
            foreach (int id in ids) {
                var message = message_by_id (messages, id);
                if (!can_delete_for_everyone (message)
                        || !message.has_member ("chatId")) return 0;
                int next_chat = (int) message.get_int_member ("chatId");
                if (next_chat <= 0 || (chat_id != 0 && chat_id != next_chat)) return 0;
                chat_id = next_chat;
            }
            return chat_id;
        }

        public static bool can_delete_in_chat (Json.Object chat) {
            return chat.has_member ("canSend") && chat.get_boolean_member ("canSend")
                && chat.has_member ("isEncrypted") && chat.get_boolean_member ("isEncrypted")
                && chat.has_member ("isSelfTalk") && !chat.get_boolean_member ("isSelfTalk");
        }
    }
}
