namespace Dc {

    /**
     * Login parameters for a classic email transport, mirroring the
     * JSON-RPC EnteredLoginParam object. Optional fields left null (or
     * ports left at 0) are sent as null so the core autoconfigures them.
     */
    public class EnteredLoginParams : Object {
        public string addr = "";
        public string password = "";
        public string? imap_user = null;
        public string? imap_server = null;
        public int imap_port = 0;             /* 0 = automatic */
        public string? imap_security = null;  /* "ssl", "starttls", "plain" */
        public string? smtp_user = null;
        public string? smtp_password = null;  /* null = same as IMAP */
        public string? smtp_server = null;
        public int smtp_port = 0;             /* 0 = automatic */
        public string? smtp_security = null;  /* "ssl", "starttls", "plain" */
        /* null = automatic, or "strict" / "acceptInvalidCertificates" */
        public string? certificate_checks = null;

        public static EnteredLoginParams from_json (Json.Object obj) {
            var p = new EnteredLoginParams ();
            p.addr = json_str (obj, "addr") ?? "";
            p.password = json_str (obj, "password") ?? "";
            p.imap_user = json_str (obj, "imapUser");
            p.imap_server = json_str (obj, "imapServer");
            p.imap_port = (int) json_int (obj, "imapPort");
            p.imap_security = json_str (obj, "imapSecurity");
            p.smtp_user = json_str (obj, "smtpUser");
            p.smtp_password = json_str (obj, "smtpPassword");
            p.smtp_server = json_str (obj, "smtpServer");
            p.smtp_port = (int) json_int (obj, "smtpPort");
            p.smtp_security = json_str (obj, "smtpSecurity");
            p.certificate_checks = json_str (obj, "certificateChecks");
            /* The core reports "automatic" defaults explicitly; normalize
               them back to null so round-tripping stays canonical. */
            if (p.imap_security == "automatic") p.imap_security = null;
            if (p.smtp_security == "automatic") p.smtp_security = null;
            if (p.certificate_checks == "automatic") p.certificate_checks = null;
            return p;
        }
    }

    /**
     * Typed Delta Chat RPC API facade.
     * Transport/process concerns live in RpcTransport.
     */
    public class RpcClient : Object {

        private RpcTransport transport;

        public signal void disconnected (string reason);

        public bool is_connected { get { return transport.is_connected; } }
        public int account_id { get; set; default = 0; }
        public string? self_email { get; set; default = null; }

        construct {
            transport = new RpcTransport ();
            transport.disconnected.connect ((reason) => {
                disconnected (reason);
            });
        }

        public async void start (string[] argv, string? cwd = null,
                                   string? accounts_path = null) throws Error {
            yield transport.start (argv, cwd, accounts_path);
        }

        public void stop () {
            transport.stop ();
        }

        public async Json.Node? call (string method, Json.Node params) throws Error {
            return yield transport.call (method, params);
        }

        /* ---- High-level RPC methods ---- */

        public async Json.Node? get_all_accounts () throws Error {
            return yield call ("get_all_accounts", Params.begin ().build ());
        }

        public async int add_account () throws Error {
            var result = yield call ("add_account", Params.begin ().build ());
            return (int) result.get_int ();
        }

        public async void select_account (int acct_id) throws Error {
            yield call ("select_account", Params.begin ().add_int (acct_id).build ());
        }

        public async bool is_configured (int acct_id) throws Error {
            var result = yield call ("is_configured",
                Params.begin ().add_int (acct_id).build ());
            return result.get_boolean ();
        }

        public async void remove_account (int acct_id) throws Error {
            yield call ("remove_account", Params.begin ().add_int (acct_id).build ());
        }

        public async void start_io (int acct_id) throws Error {
            yield call ("start_io", Params.begin ().add_int (acct_id).build ());
        }

        public async void stop_io (int acct_id) throws Error {
            yield call ("stop_io", Params.begin ().add_int (acct_id).build ());
        }

        /* Start/stop IO for every account so background accounts keep receiving
           messages (and emitting notifications) while another one is active. */
        public async void start_io_for_all_accounts () throws Error {
            yield call ("start_io_for_all_accounts", Params.begin ().build ());
        }

        public async int get_connectivity (int acct_id) throws Error {
            var result = yield call ("get_connectivity",
                Params.begin ().add_int (acct_id).build ());
            return (int) result.get_int ();
        }

        public async string get_connectivity_html (int acct_id) throws Error {
            var result = yield call ("get_connectivity_html",
                Params.begin ().add_int (acct_id).build ());
            return result.get_string ();
        }

        public async int64 get_account_file_size (int acct_id) throws Error {
            var result = yield call ("get_account_file_size",
                Params.begin ().add_int (acct_id).build ());
            return result.get_int ();
        }

        public async string? get_blob_dir (int acct_id) throws Error {
            var result = yield call ("get_blob_dir",
                Params.begin ().add_int (acct_id).build ());
            if (result == null || result.is_null ()) return null;
            return result.get_string ();
        }

        public async void add_transport_from_qr (int acct_id, string qr_text) throws Error {
            yield call ("add_transport_from_qr",
                Params.begin ()
                    .add_int (acct_id)
                    .add_string (qr_text)
                    .build ());
        }

        public async void get_backup (int acct_id, string qr_text) throws Error {
            yield call ("get_backup",
                Params.begin ()
                    .add_int (acct_id)
                    .add_string (qr_text)
                    .build ());
        }

        public async void provide_backup (int acct_id) throws Error {
            yield call ("provide_backup",
                Params.begin ().add_int (acct_id).build ());
        }

        public async string get_backup_qr (int acct_id) throws Error {
            var result = yield call ("get_backup_qr",
                Params.begin ().add_int (acct_id).build ());
            return result.get_string ();
        }

        public async string create_qr_svg (string text) throws Error {
            var result = yield call ("create_qr_svg",
                Params.begin ().add_string (text).build ());
            return result.get_string ();
        }

        public async string get_chat_securejoin_qr_code (int acct_id,
                                                          int chat_id = 0) throws Error {
            var p = Params.begin ().add_int (acct_id);
            if (chat_id > 0) p.add_int (chat_id);
            else p.add_null ();

            var result = yield call ("get_chat_securejoin_qr_code", p.build ());
            return result.get_string ();
        }

        public async void stop_ongoing_process (int acct_id) throws Error {
            yield call ("stop_ongoing_process",
                Params.begin ().add_int (acct_id).build ());
        }

        /** HTTP GET through core (proxy-aware, cached). Returns the raw
            body; `mimetype` is the Content-Type without parameters, null
            when the server sent none. */
        public async uint8[] get_http_response (string url,
                                                out string? mimetype) throws Error {
            mimetype = null;
            var result = yield call ("get_http_response",
                Params.begin ()
                    .add_int (account_id)
                    .add_string (url)
                    .build ());
            if (result == null || result.get_node_type () != Json.NodeType.OBJECT)
                throw new IOError.FAILED ("Unexpected get_http_response result");
            var obj = result.get_object ();
            if (obj.has_member ("mimetype")
                && obj.get_member ("mimetype").get_node_type () == Json.NodeType.VALUE)
                mimetype = obj.get_string_member ("mimetype");
            string blob = obj.has_member ("blob") ? obj.get_string_member ("blob") : "";
            /* Core encodes with STANDARD_NO_PAD; g_base64_decode silently
               drops an unpadded final group, so restore the padding. */
            int rem = blob.length % 4;
            if (rem == 2) blob += "==";
            else if (rem == 3) blob += "=";
            return GLib.Base64.decode (blob);
        }

        public async Json.Object? check_qr (int acct_id, string qr_text) throws Error {
            var result = yield call ("check_qr",
                Params.begin ()
                    .add_int (acct_id)
                    .add_string (qr_text)
                    .build ());
            if (result == null || result.get_node_type () != Json.NodeType.OBJECT)
                return null;
            return result.get_object ();
        }

        public async int secure_join (int acct_id, string qr_text) throws Error {
            var result = yield call ("secure_join",
                Params.begin ()
                    .add_int (acct_id)
                    .add_string (qr_text)
                    .build ());
            return (int) result.get_int ();
        }

        /* Applies a self-QR action — used to withdraw (deactivate) or revive
           (re-activate) one of our own invite links. check_qr returns a
           withdraw or revive kind for those, and this toggles the token. */
        public async void set_config_from_qr (int acct_id, string qr_text) throws Error {
            yield call ("set_config_from_qr",
                Params.begin ()
                    .add_int (acct_id)
                    .add_string (qr_text)
                    .build ());
        }

        public async void add_or_update_transport (int acct_id,
                                                    EnteredLoginParams p)
                                                    throws Error {
            yield call ("add_or_update_transport",
                Params.begin ()
                    .add_int (acct_id)
                    .begin_object ()
                        .set_string_member ("addr", p.addr)
                        .set_string_member ("password", p.password)
                        .set_string_member ("imapUser", p.imap_user)
                        .set_string_member ("imapServer", p.imap_server)
                        .set_opt_int_member ("imapPort", p.imap_port)
                        .set_string_member ("imapSecurity", p.imap_security)
                        .set_string_member ("smtpUser", p.smtp_user)
                        .set_string_member ("smtpPassword", p.smtp_password)
                        .set_string_member ("smtpServer", p.smtp_server)
                        .set_opt_int_member ("smtpPort", p.smtp_port)
                        .set_string_member ("smtpSecurity", p.smtp_security)
                        .set_string_member ("certificateChecks",
                                            p.certificate_checks)
                        .set_null_member ("oauth2")
                    .end_object ()
                    .build ());
        }

        public async Json.Node? list_transports (int acct_id) throws Error {
            return yield call ("list_transports",
                Params.begin ().add_int (acct_id).build ());
        }

        public async void delete_transport (int acct_id, string addr) throws Error {
            yield call ("delete_transport",
                Params.begin ()
                    .add_int (acct_id)
                    .add_string (addr)
                    .build ());
        }

        public async void batch_set_config (string key, string val,
                                             int acct_id) throws Error {
            yield call ("batch_set_config",
                Params.begin ()
                    .add_int (acct_id)
                    .begin_object ()
                        .set_string_member (key, val)
                    .end_object ()
                    .build ());
        }

        public async string? get_config (string key, int acct_id) throws Error {
            var result = yield call ("get_config",
                Params.begin ().add_int (acct_id).add_string (key).build ());
            if (result == null || result.is_null ()) return null;
            return result.get_string ();
        }

        /* Chatlist flags understood by get_chatlist_entries (DC_GCL_*). */
        public const int GCL_ARCHIVED_ONLY = 0x01;
        public const int GCL_NO_SPECIALS = 0x02;

        public async Json.Array? get_chatlist_entries_for (int acct_id,
                                                            string? query = null,
                                                            int list_flags = -1) throws Error {
            var params = Params.begin ().add_int (acct_id);
            if (list_flags < 0) params.add_null ();      /* listFlags */
            else params.add_int (list_flags);
            var result = yield call ("get_chatlist_entries",
                params
                    .add_string (query)
                    .add_null ()            /* contactId */
                    .build ());
            if (result == null) return null;
            return result.get_array ();
        }

        public async Json.Object? get_chatlist_items_by_entries_for (int acct_id,
                                                                      Json.Array entries) throws Error {
            var result = yield call ("get_chatlist_items_by_entries",
                Params.begin ()
                    .add_int (acct_id)
                    .add_json_array (entries)
                    .build ());
            if (result == null) return null;
            return result.get_object ();
        }

        /**
         * Number of fresh (notification-worthy) messages for an account.
         * Mirrors the Delta Chat core semantics for badge counters: messages in
         * muted chats and contact requests are excluded.
         */
        public async int get_fresh_msg_count (int acct_id) throws Error {
            return (yield get_fresh_msg_ids (acct_id)).length;
        }

        public async int[] get_fresh_msg_ids (int acct_id) throws Error {
            if (acct_id <= 0) return {};
            var result = yield call ("get_fresh_msgs",
                Params.begin ().add_int (acct_id).build ());
            if (result == null || result.get_node_type () != Json.NodeType.ARRAY)
                return {};

            var arr = result.get_array ();
            int[] ids = new int[arr.get_length ()];
            for (uint i = 0; i < arr.get_length (); i++) {
                ids[i] = (int) arr.get_int_element (i);
            }
            return ids;
        }

        public async Json.Object? get_full_chat_by_id_for (int acct_id,
                                                            int chat_id) throws Error {
            var result = yield call ("get_full_chat_by_id",
                Params.begin ().add_int (acct_id).add_int (chat_id).build ());
            if (result == null) return null;
            return result.get_object ();
        }

        public async Json.Array? get_message_ids_for (int acct_id,
                                                       int chat_id,
                                                       bool info_only = false) throws Error {
            var result = yield call ("get_message_ids",
                Params.begin ()
                    .add_int (acct_id)
                    .add_int (chat_id)
                    .add_bool (info_only)
                    .add_bool (false)       /* addDayMarker */
                    .build ());
            if (result == null) return null;
            return result.get_array ();
        }

        public async Json.Object? get_message_for (int acct_id, int msg_id) throws Error {
            var result = yield call ("get_message",
                Params.begin ().add_int (acct_id).add_int (msg_id).build ());
            if (result == null) return null;
            return result.get_object ();
        }

        public async string? get_message_html_for (int acct_id, int msg_id) throws Error {
            var result = yield call ("get_message_html",
                Params.begin ().add_int (acct_id).add_int (msg_id).build ());
            if (result == null || result.is_null ()) return null;
            return result.get_string ();
        }

        public async string? get_message_html (int msg_id) throws Error {
            return yield get_message_html_for (account_id, msg_id);
        }

        public async void download_full_message (int msg_id) throws Error {
            yield call ("download_full_message",
                Params.begin ().add_int (account_id).add_int (msg_id).build ());
        }

        public async Message? fetch_message (int msg_id) throws Error {
            return yield fetch_message_for (account_id, msg_id, self_email);
        }

        public async Message? fetch_message_for (int acct_id, int msg_id,
                                                  string? self_addr = null) throws Error {
            var obj = yield get_message_for (acct_id, msg_id);
            if (obj == null) return null;
            return RpcParsers.parse_message (obj, self_addr);
        }

        public async Json.Object? get_messages_for (int acct_id,
                                                     int[] msg_ids) throws Error {
            var result = yield call ("get_messages",
                Params.begin ()
                    .add_int (acct_id)
                    .add_int_array (msg_ids)
                    .build ());
            if (result == null) return null;
            return result.get_object ();
        }

        /** Fetch and parse several messages at once, keeping msg_ids
            order. Entries that are missing or tagged "loadingError"
            (get_messages results are tagged) are skipped. */
        public async Message[] get_parsed_messages (int[] msg_ids) throws Error {
            var map = yield get_messages_for (account_id, msg_ids);
            Message[] msgs = {};
            if (map == null) return msgs;
            foreach (int msg_id in msg_ids) {
                string key = msg_id.to_string ();
                if (!map.has_member (key)) continue;
                var node = map.get_member (key);
                if (node == null ||
                    node.get_node_type () != Json.NodeType.OBJECT) continue;
                var obj = node.get_object ();
                if (json_str (obj, "kind") != "message") continue;
                msgs += RpcParsers.parse_message (obj, self_email);
            }
            return msgs;
        }

        public async int send_msg (int chat_id, string? text,
                                    string? file_path = null,
                                    string? file_name = null,
                                    int quoted_msg_id = 0,
                                    string? view_type = null) throws Error {
            var p = Params.begin ()
                .add_int (account_id)
                .add_int (chat_id)
                .begin_object ()
                .set_string_member ("text", text)
                .set_string_member ("file", file_path)
                .set_string_member ("filename", file_name)
                /* MessageData spells this field without an underscore, so
                   its JSON name is `viewtype`, not `viewType`. */
                .set_string_member ("viewtype", view_type);
            if (quoted_msg_id > 0) {
                p.set_int_member ("quotedMessageId", quoted_msg_id);
            } else {
                p.set_null_member ("quotedMessageId");
            }
            p.end_object ();
            var result = yield call ("send_msg", p.build ());
            return result != null ? (int) result.get_int () : 0;
        }

        public async Message? get_draft (int chat_id) throws Error {
            var result = yield call ("get_draft",
                Params.begin ().add_int (account_id).add_int (chat_id).build ());
            if (result == null || result.is_null () ||
                result.get_node_type () != Json.NodeType.OBJECT)
                return null;
            return RpcParsers.parse_message (result.get_object (), self_email);
        }

        public async void set_draft (int chat_id, string? text,
                                      string? file_path = null,
                                      string? file_name = null,
                                      int quoted_msg_id = 0,
                                      string? view_type = null) throws Error {
            var p = Params.begin ()
                .add_int (account_id)
                .add_int (chat_id)
                .add_string (text)
                .add_string (file_path)
                .add_string (file_name);
            if (quoted_msg_id > 0) p.add_int (quoted_msg_id);
            else p.add_null ();
            p.add_string (view_type);
            yield call ("misc_set_draft", p.build ());
        }

        public async void remove_draft (int chat_id) throws Error {
            yield call ("remove_draft",
                Params.begin ().add_int (account_id).add_int (chat_id).build ());
        }

        public async void send_edit_request (int msg_id, string new_text) throws Error {
            yield call ("send_edit_request",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (msg_id)
                    .add_string (new_text)
                    .build ());
        }

        public async void send_reaction (int msg_id, string[] emojis) throws Error {
            yield call ("send_reaction",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (msg_id)
                    .add_string_array (emojis)
                    .build ());
        }

        public async void set_pinned_message_state (int msg_id,
                                                     bool pinned) throws Error {
            yield call ("set_pinned_message_state",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (msg_id)
                    .add_bool (pinned)
                    .build ());
        }

        public async int[] get_pinned_messages (int chat_id) throws Error {
            var result = yield call ("get_pinned_messages",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (chat_id)
                    .build ());
            if (result == null ||
                result.get_node_type () != Json.NodeType.ARRAY) return {};

            var arr = result.get_array ();
            int[] msg_ids = new int[arr.get_length ()];
            for (uint i = 0; i < arr.get_length (); i++) {
                msg_ids[i] = (int) arr.get_int_element (i);
            }
            return msg_ids;
        }

        public async void marknoticed_chat (int chat_id) throws Error {
            yield call ("marknoticed_chat",
                Params.begin ().add_int (account_id).add_int (chat_id).build ());
        }

        public async void markfresh_chat (int chat_id) throws Error {
            yield call ("markfresh_chat",
                Params.begin ().add_int (account_id).add_int (chat_id).build ());
        }

        public async void mark_seen_msgs (int[] msg_ids) throws Error {
            yield call ("markseen_msgs",
                Params.begin ()
                    .add_int (account_id)
                    .add_int_array (msg_ids)
                    .build ());
        }

        /**
         * Blocks until the next event from the RPC server.
         * Returns the full event result: { contextId, event: { kind, ... } }
         * This is a global call (not per-account).
         */
        public async Json.Object? get_next_event () throws Error {
            var result = yield call ("get_next_event", Params.begin ().build ());
            if (result == null || result.get_node_type () != Json.NodeType.OBJECT)
                return null;
            return result.get_object ();
        }

        public async Json.Array? get_contact_ids_for (int acct_id, string? query) throws Error {
            var result = yield call ("get_contact_ids",
                Params.begin ()
                    .add_int (acct_id)
                    .add_int (0)            /* listFlags: 0 = all known contacts */
                    .add_string (query)
                    .build ());
            if (result == null || result.get_node_type () != Json.NodeType.ARRAY)
                return null;
            return result.get_array ();
        }

        public async int create_contact (string email) throws Error {
            var result = yield call ("create_contact",
                Params.begin ()
                    .add_int (account_id)
                    .add_string (email)
                    .add_string (null)
                    .build ());
            return (int) result.get_int ();
        }

        public async int lookup_contact (string email) throws Error {
            var result = yield call ("lookup_contact_id_by_addr",
                Params.begin ().add_int (account_id).add_string (email).build ());
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
                Params.begin ().add_int (account_id).add_int (contact_id).build ());
            if (result != null && !result.is_null () && result.get_int () > 0)
                return (int) result.get_int ();
            result = yield call ("create_chat_by_contact_id",
                Params.begin ().add_int (account_id).add_int (contact_id).build ());
            return (int) result.get_int ();
        }

        public async int create_group (string name, bool protect = true) throws Error {
            var result = yield call ("create_group_chat",
                Params.begin ()
                    .add_int (account_id)
                    .add_string (name)
                    .add_bool (protect)
                    .build ());
            return (int) result.get_int ();
        }

        public async int create_broadcast (string name) throws Error {
            var result = yield call ("create_broadcast",
                Params.begin ()
                    .add_int (account_id)
                    .add_string (name)
                    .build ());
            return (int) result.get_int ();
        }

        public async void leave_group (int chat_id) throws Error {
            yield call ("leave_group",
                Params.begin ().add_int (account_id).add_int (chat_id).build ());
        }

        public async void delete_chat (int chat_id) throws Error {
            yield call ("delete_chat",
                Params.begin ().add_int (account_id).add_int (chat_id).build ());
        }

        /* Accept an incoming contact-request chat: the chat leaves the
           "request" state and normal messaging is unlocked. */
        public async void accept_chat (int chat_id) throws Error {
            yield call ("accept_chat",
                Params.begin ().add_int (account_id).add_int (chat_id).build ());
        }

        /* Block a contact-request chat: the chat is moved out of the list and
           future messages from the sender are silently dropped. */
        public async void block_chat (int chat_id) throws Error {
            yield call ("block_chat",
                Params.begin ().add_int (account_id).add_int (chat_id).build ());
        }

        public async void block_contact (int contact_id) throws Error {
            yield call ("block_contact",
                Params.begin ().add_int (account_id).add_int (contact_id).build ());
        }

        public async void unblock_contact (int contact_id) throws Error {
            yield call ("unblock_contact",
                Params.begin ().add_int (account_id).add_int (contact_id).build ());
        }

        public async void change_contact_name (int contact_id, string name) throws Error {
            yield call ("change_contact_name",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (contact_id)
                    .add_string (name)
                    .build ());
        }

        /* Mute a chat's notifications: seconds > 0 mutes for that long,
           seconds < 0 mutes forever, 0 unmutes. Core tracks the deadline
           itself and reports the result as the boolean isMuted. */
        public async void set_chat_mute_duration (int chat_id, int seconds) throws Error {
            var p = Params.begin ()
                .add_int (account_id)
                .add_int (chat_id)
                .begin_object ();
            if (seconds > 0) {
                p.set_string_member ("kind", "Until");
                p.set_int_member ("duration", seconds);
            } else {
                p.set_string_member ("kind", seconds < 0 ? "Forever" : "NotMuted");
            }
            yield call ("set_chat_mute_duration", p.end_object ().build ());
        }

        public async void set_chat_visibility (int chat_id, string visibility) throws Error {
            yield call ("set_chat_visibility",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (chat_id)
                    .add_string (visibility)
                    .build ());
        }

        /**
         * Message ids of the given viewtypes (at most three) in a chat,
         * or in any chat of the account when chat_id <= 0. This is a
         * metadata-only database query in core — nothing is downloaded.
         * The result is sorted oldest first; callers wanting newest-first
         * must reverse it.
         */
        public async int[] get_chat_media (int chat_id,
                                            string[] types) throws Error {
            var p = Params.begin ().add_int (account_id);
            if (chat_id > 0) p.add_int (chat_id);
            else p.add_null ();
            /* The RPC takes exactly three viewtype slots. */
            for (int i = 0; i < 3; i++) {
                p.add_string (i < types.length ? types[i] : null);
            }

            var result = yield call ("get_chat_media", p.build ());
            if (result == null || result.get_node_type () != Json.NodeType.ARRAY)
                return {};
            var arr = result.get_array ();
            int[] ids = new int[arr.get_length ()];
            for (uint i = 0; i < arr.get_length (); i++) {
                ids[i] = (int) arr.get_int_element (i);
            }
            return ids;
        }

        public async void delete_messages (int[] msg_ids) throws Error {
            yield call ("delete_messages",
                Params.begin ()
                    .add_int (account_id)
                    .add_int_array (msg_ids)
                    .build ());
        }

        public async void forward_messages (int[] msg_ids, int chat_id) throws Error {
            yield call ("forward_messages",
                Params.begin ()
                    .add_int (account_id)
                    .add_int_array (msg_ids)
                    .add_int (chat_id)
                    .build ());
        }

        public async void delete_messages_for_all (int[] msg_ids) throws Error {
            yield call ("delete_messages_for_all",
                Params.begin ()
                    .add_int (account_id)
                    .add_int_array (msg_ids)
                    .build ());
        }

        public async Json.Object? get_contact_for (int acct_id, int contact_id) throws Error {
            var result = yield call ("get_contact",
                Params.begin ().add_int (acct_id).add_int (contact_id).build ());
            if (result == null || result.get_node_type () != Json.NodeType.OBJECT)
                return null;
            return result.get_object ();
        }

        public async void add_contact_to_chat (int chat_id, int contact_id) throws Error {
            yield call ("add_contact_to_chat",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (chat_id)
                    .add_int (contact_id)
                    .build ());
        }

        public async void remove_contact_from_chat (int chat_id, int contact_id) throws Error {
            yield call ("remove_contact_from_chat",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (chat_id)
                    .add_int (contact_id)
                    .build ());
        }

        public async void set_chat_profile_image (int chat_id, string image_path) throws Error {
            yield call ("set_chat_profile_image",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (chat_id)
                    .add_string (image_path)
                    .build ());
        }

        public async void set_chat_name (int chat_id, string name) throws Error {
            yield call ("set_chat_name",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (chat_id)
                    .add_string (name)
                    .build ());
        }

        public async void set_chat_ephemeral_timer (int chat_id, int timer) throws Error {
            yield call ("set_chat_ephemeral_timer",
                Params.begin ()
                    .add_int (account_id)
                    .add_int (chat_id)
                    .add_int (timer)
                    .build ());
        }

    }
}
