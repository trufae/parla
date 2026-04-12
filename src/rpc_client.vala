namespace Dc {

    /**
     * JSONRPC client that communicates with deltachat-rpc-server over stdio.
     * Each request is a JSON object terminated by newline.
     */
    public class RpcClient : Object {

        private Subprocess? process = null;
        private DataInputStream? reader = null;
        private OutputStream? writer = null;
        private int next_id = 1;
        private GenericArray<PendingCall> pending = new GenericArray<PendingCall> ();
        private string last_stderr = "";

        public signal void disconnected (string reason);

        public bool is_connected { get; private set; default = false; }
        public int account_id { get; set; default = 0; }
        public string? self_email { get; set; default = null; }

        /* ---- Connection lifecycle ---- */

        public async void start (string[] argv, string? cwd = null,
                                   string? accounts_path = null) throws Error {
            var flags = SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE
                        | SubprocessFlags.STDERR_PIPE;
            var launcher = new SubprocessLauncher (flags);
            if (cwd != null) {
                launcher.set_cwd (cwd);
            }
            if (accounts_path != null) {
                launcher.setenv ("DC_ACCOUNTS_PATH", accounts_path, true);
            }
            process = launcher.spawnv (argv);
            writer = process.get_stdin_pipe ();
            reader = new DataInputStream (process.get_stdout_pipe ());
            reader.set_newline_type (DataStreamNewlineType.LF);

            /* Drain stderr in background to prevent pipe buffer deadlock */
            drain_stderr.begin ();

            /* Start the read loop */
            read_loop.begin ();

            /* Test connectivity — if the process died, report stderr */
            try {
                yield call ("get_system_info", build_params ());
            } catch (Error e) {
                /* Give stderr drain a moment to collect output */
                yield nap (200);
                if (last_stderr.length > 0) {
                    throw new IOError.FAILED ("%s", last_stderr);
                }
                throw e;
            }
            is_connected = true;
        }

        private async void drain_stderr () {
            if (process == null) return;
            try {
                var err_stream = new DataInputStream (process.get_stderr_pipe ());
                string? line;
                size_t len;
                while ((line = yield err_stream.read_line_utf8_async (
                            Priority.DEFAULT, null, out len)) != null) {
                    last_stderr = line.strip ();
                }
            } catch (Error e) {
                /* ignore */
            }
        }

        private async void nap (uint ms) {
            Timeout.add (ms, nap.callback);
            yield;
        }

        public void stop () {
            is_connected = false;
            if (process != null) {
                process.force_exit ();
                process = null;
            }
            writer = null;
            reader = null;
        }

        /* ---- Low-level JSONRPC ---- */

        public async Json.Node? call (string method, Json.Node params) throws Error {
            if (writer == null || reader == null) {
                throw new IOError.NOT_CONNECTED ("RPC client not connected");
            }

            int id = next_id++;
            send_request (id, method, params);

            var pc = new PendingCall (id);
            pc.callback = call.callback;
            pending.add (pc);
            yield;

            /* Resumed — remove from pending and check result */
            remove_pending (id);

            if (pc.error_msg != null) {
                throw new IOError.FAILED ("RPC %s: %s", method, pc.error_msg);
            }
            return pc.result;
        }

        private void send_request (int id, string method, Json.Node params) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("jsonrpc"); b.add_string_value ("2.0");
            b.set_member_name ("id");      b.add_int_value (id);
            b.set_member_name ("method");  b.add_string_value (method);
            b.set_member_name ("params");  b.add_value (params);
            b.end_object ();

            var gen = new Json.Generator ();
            gen.set_root (b.get_root ());
            size_t json_len;
            string json = gen.to_data (out json_len);
            string line = json + "\n";

            size_t written;
            writer.write_all (line.data, out written);
            writer.flush ();
        }

        private async void read_loop () {
            try {
                while (true) {
                    size_t len;
                    string? line = yield reader.read_line_utf8_async (
                        Priority.DEFAULT, null, out len);
                    if (line == null) break;
                    if (line.strip ().length == 0) continue;

                    var parser = new Json.Parser ();
                    parser.load_from_data (line);
                    var root = parser.get_root ();
                    if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                        continue;

                    var obj = root.get_object ();
                    if (!obj.has_member ("id")) continue;

                    int resp_id = (int) obj.get_int_member ("id");
                    PendingCall? pc = find_pending (resp_id);
                    if (pc == null) continue;

                    if (obj.has_member ("error") &&
                        !obj.get_member ("error").is_null ()) {
                        var err = obj.get_object_member ("error");
                        pc.error_msg = err.has_member ("message")
                            ? err.get_string_member ("message")
                            : "Unknown RPC error";
                    } else if (obj.has_member ("result")) {
                        var result_member = obj.get_member ("result");
                        pc.result = (result_member != null) ? result_member.copy () : null;
                    }

                    if (pc.callback != null) {
                        var cb = (owned) pc.callback;
                        pc.callback = null;
                        Idle.add ((owned) cb);
                    }
                }
            } catch (Error e) {
                warning ("RPC read loop error: %s", e.message);
            }

            is_connected = false;
            disconnected ("RPC server closed");
        }

        private PendingCall? find_pending (int id) {
            for (int i = 0; i < pending.length; i++) {
                if (pending[i].id == id) return pending[i];
            }
            return null;
        }

        private void remove_pending (int id) {
            for (int i = 0; i < pending.length; i++) {
                if (pending[i].id == id) {
                    pending.remove_index (i);
                    return;
                }
            }
        }

        /* ---- Param builder helpers ---- */

        public static Json.Node build_params (/* varargs simulation via overloads */) {
            var b = new Json.Builder ();
            b.begin_array ();
            b.end_array ();
            return b.get_root ();
        }

        public static Json.Node build_params_int (int v) {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (v);
            b.end_array ();
            return b.get_root ();
        }

        public static Json.Node build_params_int2 (int v1, int v2) {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (v1);
            b.add_int_value (v2);
            b.end_array ();
            return b.get_root ();
        }

        public static Json.Node build_params_int3 (int v1, int v2, int v3) {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (v1);
            b.add_int_value (v2);
            b.add_int_value (v3);
            b.end_array ();
            return b.get_root ();
        }

        public static Json.Node build_params_int_str (int v, string? s) {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (v);
            if (s != null) b.add_string_value (s);
            else b.add_null_value ();
            b.end_array ();
            return b.get_root ();
        }

        public static Json.Node build_params_int_str2 (int v, string? s1, string? s2) {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (v);
            if (s1 != null) b.add_string_value (s1);
            else b.add_null_value ();
            if (s2 != null) b.add_string_value (s2);
            else b.add_null_value ();
            b.end_array ();
            return b.get_root ();
        }

        /* ---- High-level Delta Chat RPC methods ---- */

        public async Json.Node? get_all_accounts () throws Error {
            return yield call ("get_all_accounts", build_params ());
        }

        public async int add_account () throws Error {
            var result = yield call ("add_account", build_params ());
            return (int) result.get_int ();
        }

        public async void select_account (int acct_id) throws Error {
            yield call ("select_account", build_params_int (acct_id));
        }

        public async bool is_configured (int acct_id) throws Error {
            var result = yield call ("is_configured", build_params_int (acct_id));
            return result.get_boolean ();
        }

        public async void remove_account (int acct_id) throws Error {
            yield call ("remove_account", build_params_int (acct_id));
        }

        public async void start_io (int acct_id) throws Error {
            yield call ("start_io", build_params_int (acct_id));
        }

        public async void stop_io () throws Error {
            yield call ("stop_io", build_params_int (account_id));
        }

        public async void add_or_update_transport (int acct_id, string email,
                                                    string password) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (acct_id);
            b.begin_object ();
            b.set_member_name ("addr"); b.add_string_value (email);
            b.set_member_name ("password"); b.add_string_value (password);
            b.set_member_name ("imapServer"); b.add_null_value ();
            b.set_member_name ("imapPort"); b.add_null_value ();
            b.set_member_name ("imapSecurity"); b.add_null_value ();
            b.set_member_name ("imapUser"); b.add_null_value ();
            b.set_member_name ("smtpServer"); b.add_null_value ();
            b.set_member_name ("smtpPort"); b.add_null_value ();
            b.set_member_name ("smtpSecurity"); b.add_null_value ();
            b.set_member_name ("smtpUser"); b.add_null_value ();
            b.set_member_name ("smtpPassword"); b.add_null_value ();
            b.set_member_name ("certificateChecks"); b.add_null_value ();
            b.set_member_name ("oauth2"); b.add_null_value ();
            b.end_object ();
            b.end_array ();
            yield call ("add_or_update_transport", b.get_root ());
        }

        public async void batch_set_config (string key, string val) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.begin_object ();
            b.set_member_name (key); b.add_string_value (val);
            b.end_object ();
            b.end_array ();
            yield call ("batch_set_config", b.get_root ());
        }

        public async string? get_config (string key, int acct_id = 0) throws Error {
            int id = acct_id > 0 ? acct_id : account_id;
            var result = yield call ("get_config", build_params_int_str (id, key));
            if (result == null || result.is_null ()) return null;
            return result.get_string ();
        }

        public async Json.Array? get_chatlist_entries (string? query = null) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_null_value (); /* listFlags */
            if (query != null) b.add_string_value (query);
            else b.add_null_value ();
            b.add_null_value (); /* contactId */
            b.end_array ();
            var result = yield call ("get_chatlist_entries", b.get_root ());
            if (result == null) return null;
            return result.get_array ();
        }

        public async Json.Object? get_chatlist_items_by_entries (Json.Array entries) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            var entries_node = new Json.Node (Json.NodeType.ARRAY);
            entries_node.set_array (entries);
            b.add_value (entries_node);
            b.end_array ();
            var result = yield call ("get_chatlist_items_by_entries", b.get_root ());
            if (result == null) return null;
            return result.get_object ();
        }

        public async Json.Object? get_full_chat_by_id (int chat_id) throws Error {
            var result = yield call ("get_full_chat_by_id", build_params_int2 (account_id, chat_id));
            if (result == null) return null;
            return result.get_object ();
        }

        public async Json.Array? get_message_ids (int chat_id,
                                                    bool info_only = false) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_int_value (chat_id);
            b.add_boolean_value (info_only);
            b.add_boolean_value (false); /* addDayMarker */
            b.end_array ();
            var result = yield call ("get_message_ids", b.get_root ());
            if (result == null) return null;
            return result.get_array ();
        }

        public async Json.Object? get_message (int msg_id) throws Error {
            var result = yield call ("get_message", build_params_int2 (account_id, msg_id));
            if (result == null) return null;
            return result.get_object ();
        }

        public async Message? fetch_message (int msg_id) throws Error {
            var obj = yield get_message (msg_id);
            if (obj == null) return null;
            return parse_message (obj, self_email);
        }

        public async Json.Object? get_messages (int[] msg_ids) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.begin_array ();
            foreach (int id in msg_ids) {
                b.add_int_value (id);
            }
            b.end_array ();
            b.end_array ();
            var result = yield call ("get_messages", b.get_root ());
            if (result == null) return null;
            return result.get_object ();
        }

        public async int send_msg (int chat_id, string? text,
                                    string? file_path = null,
                                    string? file_name = null,
                                    int quoted_msg_id = 0) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_int_value (chat_id);
            if (text != null) b.add_string_value (text);
            else b.add_null_value ();
            if (file_path != null) b.add_string_value (file_path);
            else b.add_null_value ();
            if (file_name != null) b.add_string_value (file_name);
            else b.add_null_value ();
            b.add_null_value (); /* location */
            if (quoted_msg_id > 0) b.add_int_value (quoted_msg_id);
            else b.add_null_value ();
            b.end_array ();
            var result = yield call ("misc_send_msg", b.get_root ());
            /* Returns [messageId, ...] */
            if (result != null && result.get_node_type () == Json.NodeType.ARRAY) {
                var arr = result.get_array ();
                if (arr.get_length () > 0) {
                    return (int) arr.get_int_element (0);
                }
            }
            return 0;
        }

        public async void send_edit_request (int msg_id, string new_text) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_int_value (msg_id);
            b.add_string_value (new_text);
            b.end_array ();
            yield call ("send_edit_request", b.get_root ());
        }

        public async void send_reaction (int msg_id, string[] emojis) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_int_value (msg_id);
            b.begin_array ();
            foreach (string e in emojis) b.add_string_value (e);
            b.end_array ();
            b.end_array ();
            yield call ("send_reaction", b.get_root ());
        }

        public async void marknoticed_chat (int chat_id) throws Error {
            yield call ("marknoticed_chat", build_params_int2 (account_id, chat_id));
        }

        public async void mark_seen_msgs (int[] msg_ids) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.begin_array ();
            foreach (int mid in msg_ids) b.add_int_value (mid);
            b.end_array ();
            b.end_array ();
            yield call ("markseen_msgs", b.get_root ());
        }

        /**
         * Blocks until the next event from the RPC server.
         * Returns the full event result: { contextId, event: { kind, ... } }
         * This is a global call (not per-account).
         */
        public async Json.Object? get_next_event () throws Error {
            var result = yield call ("get_next_event", build_params ());
            if (result == null || result.get_node_type () != Json.NodeType.OBJECT)
                return null;
            return result.get_object ();
        }

        public async Json.Array? get_contact_ids (string? query) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_int_value (0); /* listFlags: 0 = all known contacts */
            if (query != null) b.add_string_value (query);
            else b.add_null_value ();
            b.end_array ();
            var result = yield call ("get_contact_ids", b.get_root ());
            if (result == null || result.get_node_type () != Json.NodeType.ARRAY)
                return null;
            return result.get_array ();
        }

        public async int create_contact (string email) throws Error {
            var result = yield call ("create_contact",
                build_params_int_str2 (account_id, email, null));
            return (int) result.get_int ();
        }

        public async int lookup_contact (string email) throws Error {
            var result = yield call ("lookup_contact_id_by_addr",
                build_params_int_str (account_id, email));
            if (result == null || result.is_null ()) return 0;
            return (int) result.get_int ();
        }

        public async int get_or_create_contact (string email) throws Error {
            int contact_id = yield lookup_contact (email);
            if (contact_id == 0) {
                contact_id = yield create_contact (email);
            }
            return contact_id;
        }

        public async int get_or_create_chat_by_contact (int contact_id) throws Error {
            var result = yield call ("get_chat_id_by_contact_id",
                build_params_int2 (account_id, contact_id));
            if (result != null && !result.is_null () && result.get_int () > 0)
                return (int) result.get_int ();
            result = yield call ("create_chat_by_contact_id",
                build_params_int2 (account_id, contact_id));
            return (int) result.get_int ();
        }

        public async int create_group (string name, bool protect = true) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_string_value (name);
            b.add_boolean_value (protect);
            b.end_array ();
            var result = yield call ("create_group_chat", b.get_root ());
            return (int) result.get_int ();
        }

        public async void leave_group (int chat_id) throws Error {
            yield call ("leave_group", build_params_int2 (account_id, chat_id));
        }

        public async void delete_chat (int chat_id) throws Error {
            yield call ("delete_chat", build_params_int2 (account_id, chat_id));
        }

        public async void set_chat_visibility (int chat_id, string visibility) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_int_value (chat_id);
            b.add_string_value (visibility);
            b.end_array ();
            yield call ("set_chat_visibility", b.get_root ());
        }

        public async void delete_messages (int[] msg_ids) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.begin_array ();
            foreach (int mid in msg_ids) b.add_int_value (mid);
            b.end_array ();
            b.end_array ();
            yield call ("delete_messages", b.get_root ());
        }

        public async void delete_messages_for_all (int[] msg_ids) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.begin_array ();
            foreach (int mid in msg_ids) b.add_int_value (mid);
            b.end_array ();
            b.end_array ();
            yield call ("delete_messages_for_all", b.get_root ());
        }

        public async Json.Object? get_contact (int contact_id) throws Error {
            var result = yield call ("get_contact", build_params_int2 (account_id, contact_id));
            if (result == null) return null;
            return result.get_object ();
        }

        public async void add_contact_to_chat (int chat_id, int contact_id) throws Error {
            yield call ("add_contact_to_chat", build_params_int3 (account_id, chat_id, contact_id));
        }

        public async void remove_contact_from_chat (int chat_id, int contact_id) throws Error {
            yield call ("remove_contact_from_chat", build_params_int3 (account_id, chat_id, contact_id));
        }

        public async void set_chat_profile_image (int chat_id, string image_path) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            b.add_int_value (account_id);
            b.add_int_value (chat_id);
            b.add_string_value (image_path);
            b.end_array ();
            yield call ("set_chat_profile_image", b.get_root ());
        }

        public async void set_chat_ephemeral_timer (int chat_id, int timer) throws Error {
            yield call ("set_chat_ephemeral_timer",
                build_params_int3 (account_id, chat_id, timer));
        }

        /* ---- Parsing helpers ---- */

        /**
         * Parse a JSON contact object into a Dc.Contact model.
         */
        public static Contact parse_contact (int contact_id, Json.Object obj) {
            var c = new Contact ();
            c.id = contact_id;
            c.display_name = json_str (obj, "displayName") ?? "";
            c.address = json_str (obj, "address") ?? "";
            c.profile_image = json_str (obj, "profileImage");
            c.is_verified = json_bool (obj, "isVerified");
            return c;
        }

        /**
         * Parse a JSON message object into a Dc.Message model.
         */
        public static Message parse_message (Json.Object obj, string? self_email = null) {
            var msg = new Message ();
            msg.id = (int) json_int (obj, "id");
            msg.chat_id = (int) json_int (obj, "chatId");
            msg.text = json_str (obj, "text");
            msg.timestamp = json_int (obj, "timestamp");
            msg.is_info = json_bool (obj, "isInfo");

            msg.file_path = json_str (obj, "file");
            msg.file_name = json_str (obj, "fileName");
            msg.file_mime = json_str (obj, "fileMime");
            msg.file_bytes = (int) json_int (obj, "fileBytes");
            msg.view_type = json_str (obj, "viewType");

            if (obj.has_member ("sender") && !obj.get_member ("sender").is_null ()) {
                var sender = obj.get_object_member ("sender");
                msg.sender_address = json_str (sender, "address");
                msg.sender_name = json_str (sender, "displayName")
                    ?? json_str (sender, "name");
            }

            /* Determine outgoing status */
            if (self_email != null && msg.sender_address != null) {
                msg.is_outgoing = msg.sender_address.down () == self_email.down ();
            }
            /* fromId == 1 means self in DeltaChat */
            if (obj.has_member ("fromId") && obj.get_int_member ("fromId") == 1) {
                msg.is_outgoing = true;
            }

            /* Reactions */
            if (obj.has_member ("reactions") && !obj.get_member ("reactions").is_null ()) {
                var reactions_obj = obj.get_object_member ("reactions");
                if (reactions_obj != null &&
                    reactions_obj.has_member ("reactionsByContact") &&
                    !reactions_obj.get_member ("reactionsByContact").is_null ()) {
                    var by_contact = reactions_obj.get_object_member ("reactionsByContact");
                    string[] r_emojis = {};
                    int[] r_counts = {};

                    var members = by_contact.get_members ();
                    foreach (unowned string cid in members) {
                        var node = by_contact.get_member (cid);
                        if (node.get_node_type () != Json.NodeType.ARRAY) continue;
                        var arr = node.get_array ();
                        for (uint j = 0; j < arr.get_length (); j++) {
                            string emoji = arr.get_string_element (j);
                            int found = -1;
                            for (int k = 0; k < r_emojis.length; k++) {
                                if (r_emojis[k] == emoji) { found = k; break; }
                            }
                            if (found >= 0) {
                                r_counts[found] = r_counts[found] + 1;
                            } else {
                                r_emojis += emoji;
                                r_counts += 1;
                            }
                        }
                    }

                    if (r_emojis.length > 0) {
                        var sb = new StringBuilder ();
                        for (int k = 0; k < r_emojis.length; k++) {
                            if (sb.len > 0) sb.append (",");
                            sb.append_printf ("%s:%d", r_emojis[k], r_counts[k]);
                        }
                        msg.reactions = sb.str;
                    }
                }
            }

            /* Quote / reply */
            if (obj.has_member ("quote") && !obj.get_member ("quote").is_null ()) {
                var quote = obj.get_object_member ("quote");
                msg.quote_text = json_str (quote, "text");
                msg.quote_sender_name = json_str (quote, "authorDisplayName");
                msg.quote_msg_id = (int) json_int (quote, "messageId");
            }

            return msg;
        }

        /**
         * Parse a chatlist item JSON object into a Dc.ChatEntry model.
         */
        public static ChatEntry parse_chat_item (int chat_id, Json.Object obj) {
            var entry = new ChatEntry ();
            entry.id = chat_id;
            entry.name = json_str (obj, "name") ?? "";

            var s1 = json_str (obj, "summaryText1");
            if (s1 != null && s1.length > 0) entry.summary_prefix = s1;

            var s2 = json_str (obj, "summaryText2");
            if (s2 != null && s2.length > 0) entry.last_message = s2;

            if (entry.last_message == null) {
                entry.last_message = json_str (obj, "lastMessageText");
            }

            entry.unread_count = (int) json_int (obj, "freshMessageCounter");
            entry.timestamp = json_int (obj, "lastMessageTimestamp");
            entry.avatar_path = json_str (obj, "avatarPath");
            entry.is_muted = json_bool (obj, "isMuted");
            entry.is_contact_request = json_bool (obj, "isContactRequest");
            entry.is_archived = json_bool (obj, "isArchived");
            entry.is_pinned = json_bool (obj, "isPinned");
            return entry;
        }
    }

    /* Pending call bookkeeping for async RPC */
    private class PendingCall {
        public int id;
        public SourceFunc? callback = null;
        public Json.Node? result = null;
        public string? error_msg = null;

        public PendingCall (int id) {
            this.id = id;
        }
    }
}
