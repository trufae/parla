namespace Dc {

    public class RpcParsers {

        public static Contact parse_contact (int contact_id, Json.Object obj) {
            var c = new Contact ();
            c.id = contact_id;
            c.display_name = json_str (obj, "displayName") ?? "";
            c.address = json_str (obj, "address") ?? "";
            c.profile_image = json_str (obj, "profileImage");
            c.is_verified = json_bool (obj, "isVerified");
            c.is_blocked = json_bool (obj, "isBlocked");
            c.status = json_str (obj, "status");
            c.was_seen_recently = json_bool (obj, "wasSeenRecently");
            return c;
        }

        public static Message parse_message (Json.Object obj,
                                             string? self_email = null) {
            var msg = new Message ();
            msg.id = (int) json_int (obj, "id");
            msg.chat_id = (int) json_int (obj, "chatId");
            msg.text = json_str (obj, "text");
            msg.timestamp = json_int (obj, "timestamp");
            msg.is_info = json_bool (obj, "isInfo");
            msg.is_forwarded = json_bool (obj, "isForwarded");
            msg.is_edited = json_bool (obj, "isEdited");
            msg.is_pinned = json_bool (obj, "isPinned");
            msg.override_sender_name = json_str (obj, "overrideSenderName");

            msg.file_path = json_str (obj, "file");
            msg.file_name = json_str (obj, "fileName");
            msg.file_mime = json_str (obj, "fileMime");
            msg.file_bytes = (int) json_int (obj, "fileBytes");
            msg.view_type = json_str (obj, "viewType");
            msg.state = (int) json_int (obj, "state");
            msg.has_html = json_bool (obj, "hasHtml");
            msg.download_state = json_str (obj, "downloadState") ?? "Done";

            var sender = json_obj (obj, "sender");
            if (sender != null) {
                msg.sender_address = json_str (sender, "address");
                msg.sender_name = json_str (sender, "displayName")
                    ?? json_str (sender, "name");
                msg.sender_avatar_path = json_str (sender, "profileImage")
                    ?? json_str (sender, "avatarPath");
                msg.sender_contact_id = (int) json_int (sender, "id");
                msg.sender_was_seen_recently =
                    json_bool (sender, "wasSeenRecently");
            }

            if (obj.has_member ("fromId")) {
                msg.sender_contact_id = (int) obj.get_int_member ("fromId");
            }

            if (self_email != null && msg.sender_address != null) {
                msg.is_outgoing = msg.sender_address.down () == self_email.down ();
            }
            if (obj.has_member ("fromId") && obj.get_int_member ("fromId") == 1) {
                msg.is_outgoing = true;
            }

            parse_reactions (obj, msg);
            parse_quote (obj, msg);
            return msg;
        }

        public static ChatEntry parse_chat_item (int chat_id, Json.Object obj) {
            var entry = new ChatEntry ();
            entry.id = chat_id;
            entry.name = json_str (obj, "name") ?? "";

            var s1 = json_str (obj, "summaryText1");
            if (s1 != null && s1.length > 0) entry.summary_prefix = s1;

            var s2 = json_str (obj, "summaryText2");
            if (s2 != null && s2.length > 0) {
                entry.last_message = s2;
            }

            entry.last_message_id = (int) json_int (obj, "lastMessageId");
            entry.is_draft = (int) json_int (obj, "summaryStatus")
                             == (int) MessageState.OUT_DRAFT;
            entry.unread_count = (int) json_int (obj, "freshMessageCounter");
            entry.timestamp = json_int (obj, "lastMessageTimestamp");
            entry.avatar_path = json_str (obj, "avatarPath");
            entry.kind = parse_chat_kind (obj);
            entry.is_muted = json_bool (obj, "isMuted");
            entry.is_contact_request = json_bool (obj, "isContactRequest");
            entry.is_pinned = json_bool (obj, "isPinned");
            entry.is_archived = json_bool (obj, "isArchived");
            entry.was_seen_recently = json_bool (obj, "wasSeenRecently");
            if (!entry.was_seen_recently && obj.has_member ("contact") &&
                !obj.get_member ("contact").is_null ()) {
                var contact = obj.get_object_member ("contact");
                entry.was_seen_recently =
                    json_bool (contact, "wasSeenRecently");
            }
            return entry;
        }

        public static ChatKind parse_chat_kind (Json.Object obj) {
            string chat_type = json_str (obj, "chatType") ?? "";
            bool is_self_talk = json_bool (obj, "isSelfTalk");
            bool is_device_chat = json_bool (obj, "isDeviceChat");

            if (chat_type == "Single" && !is_self_talk && !is_device_chat) {
                return ChatKind.DIRECT;
            }
            if (chat_type == "Group" ||
                chat_type == "Broadcast" ||
                chat_type == "OutBroadcast") {
                return ChatKind.GROUP;
            }
            return ChatKind.UNKNOWN;
        }

        private static void parse_reactions (Json.Object obj, Message msg) {
            var reactions_obj = json_obj (obj, "reactions");
            if (reactions_obj == null) return;

            var by_contact = json_obj (reactions_obj, "reactionsByContact");
            if (by_contact == null) return;
            var reaction_details = new GenericArray<MessageReaction> ();
            string[] r_emojis = {};
            int[] r_counts = {};
            string[] my_emojis = {};

            var members = by_contact.get_members ();
            foreach (unowned string cid in members) {
                var node = by_contact.get_member (cid);
                if (node.get_node_type () != Json.NodeType.ARRAY) continue;
                var arr = node.get_array ();
                bool is_self = (cid == "1");
                int contact_id = int.parse (cid);
                for (uint j = 0; j < arr.get_length (); j++) {
                    string emoji = arr.get_string_element (j);
                    if (is_self) my_emojis += emoji;
                    var reaction = find_reaction (reaction_details, emoji);
                    if (reaction == null) {
                        reaction = new MessageReaction (emoji);
                        reaction_details.add (reaction);
                    }
                    reaction.add_user (contact_id);

                    int found = -1;
                    for (int k = 0; k < r_emojis.length; k++) {
                        if (r_emojis[k] == emoji) {
                            found = k;
                            break;
                        }
                    }
                    if (found >= 0) {
                        r_counts[found] = r_counts[found] + 1;
                    } else {
                        r_emojis += emoji;
                        r_counts += 1;
                    }
                }
            }

            if (my_emojis.length > 0) {
                msg.my_reactions = string.joinv (",", my_emojis);
            }

            if (r_emojis.length == 0) return;

            msg.reaction_details = reaction_details;

            var sb = new StringBuilder ();
            for (int k = 0; k < r_emojis.length; k++) {
                if (sb.len > 0) sb.append (",");
                sb.append_printf ("%s:%d", r_emojis[k], r_counts[k]);
            }
            msg.reactions = sb.str;
        }

        private static MessageReaction? find_reaction (
                GenericArray<MessageReaction> reactions, string emoji) {
            for (int i = 0; i < reactions.length; i++) {
                if (reactions[i].emoji == emoji) return reactions[i];
            }
            return null;
        }

        private static void parse_quote (Json.Object obj, Message msg) {
            var quote = json_obj (obj, "quote");
            if (quote == null) return;
            msg.quote_text = json_str (quote, "text");
            msg.quote_sender_name = json_str (quote, "authorDisplayName");
            msg.quote_msg_id = (int) json_int (quote, "messageId");
        }
    }
}
