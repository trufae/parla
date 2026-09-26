namespace Dc {

    public class RpcParsers {

        public static Contact parse_contact (int contact_id, Json.Object obj) {
            var c = new Contact ();
            c.id = contact_id;
            c.display_name = json_str (obj, "displayName") ?? "";
            c.address = json_str (obj, "address") ?? "";
            c.profile_image = json_str (obj, "profileImage");
            c.is_blocked = json_bool (obj, "isBlocked");
            c.status = json_str (obj, "status");
            c.was_seen_recently = was_seen_recently (obj);
            return c;
        }

        public static Message parse_message (Json.Object obj) {
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
            msg.error = json_str (obj, "error");
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
                    was_seen_recently (sender);
            }

            if (obj.has_member ("fromId")) {
                msg.sender_contact_id = (int) obj.get_int_member ("fromId");
            }

            // Contact IDs identify SELF across all relays and linked devices.
            msg.is_outgoing = msg.sender_contact_id == 1;

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
            entry.chat_type = json_str (obj, "chatType") ?? "";
            entry.can_leave_chat = ChatActions.can_leave (entry.chat_type,
                json_bool (obj, "isEncrypted"), json_bool (obj, "isSelfInGroup"),
                entry.is_contact_request);
            entry.is_pinned = json_bool (obj, "isPinned");
            entry.is_archived = json_bool (obj, "isArchived");
            entry.was_seen_recently = was_seen_recently (obj);
            if (!obj.has_member ("freshness") &&
                !entry.was_seen_recently && obj.has_member ("contact") &&
                !obj.get_member ("contact").is_null ()) {
                var contact = obj.get_object_member ("contact");
                entry.was_seen_recently =
                    was_seen_recently (contact);
            }
            return entry;
        }

        /* Core 2.61 replaced the presence boolean on contacts and chats.
           Normal and Old must both leave the recent-presence ring hidden. */
        private static bool was_seen_recently (Json.Object obj) {
            if (obj.has_member ("freshness"))
                return json_str (obj, "freshness") == "RecentlySeen";
            return json_bool (obj, "wasSeenRecently");
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

            var details = new GenericArray<MessageReaction> ();
            string[] my_emojis = {};
            Json.Array? totals = null;
            if (reactions_obj.has_member ("reactions")) {
                var node = reactions_obj.get_member ("reactions");
                if (node.get_node_type () == Json.NodeType.ARRAY)
                    totals = node.get_array ();
            }
            // Counts are authoritative even when channel identities are hidden.
            if (totals != null) {
                for (uint i = 0; i < totals.get_length (); i++) {
                    var entry = totals.get_object_element (i);
                    string? emoji = json_str (entry, "emoji");
                    int count = (int) json_int (entry, "count");
                    if (emoji == null || emoji.length == 0 || count <= 0) continue;
                    var reaction = new MessageReaction (emoji);
                    reaction.count = count;
                    details.add (reaction);
                    if (json_bool (entry, "isFromSelf")) my_emojis += emoji;
                }
            }

            var by_contact = json_obj (reactions_obj, "reactionsByContact");
            if (by_contact != null) {
                foreach (unowned string cid in by_contact.get_members ()) {
                    var node = by_contact.get_member (cid);
                    if (node.get_node_type () != Json.NodeType.ARRAY) continue;
                    var emojis = node.get_array ();
                    for (uint j = 0; j < emojis.get_length (); j++) {
                        string emoji = emojis.get_string_element (j);
                        var reaction = find_reaction (details, emoji);
                        if (totals == null) {
                            if (reaction == null) {
                                reaction = new MessageReaction (emoji);
                                details.add (reaction);
                            }
                            reaction.add_user (int.parse (cid));
                            if (cid == "1") my_emojis += emoji;
                        } else if (reaction != null) {
                            reaction.users.add (new MessageReactionUser (int.parse (cid)));
                        }
                    }
                }
            }

            if (details.length == 0) return;
            msg.reaction_details = details;
            if (my_emojis.length > 0)
                msg.my_reactions = string.joinv (",", my_emojis);
            var summary = new StringBuilder ();
            for (int i = 0; i < details.length; i++) {
                if (summary.len > 0) summary.append (",");
                summary.append_printf ("%s:%d", details[i].emoji, details[i].count);
            }
            msg.reactions = summary.str;
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
