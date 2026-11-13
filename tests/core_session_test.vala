using Dc;

/* A real executable for the CLI's subprocess tests, including Windows. */
private int fake_core (string mode) throws Error {
    if (mode == "locked") {
        stderr.printf ("accounts.lock: account store already running\n");
        return 1;
    }
    var log = FileStream.open (Environment.get_variable ("PARLA_TEST_LOG"), "w");
    log.printf ("%s\n", Environment.get_variable ("DC_ACCOUNTS_PATH"));
    log.flush ();
    var seen = new HashTable<int, bool> (direct_hash, direct_equal);
    var history_reads = new HashTable<int, int> (direct_hash, direct_equal);
    var pinned = new HashTable<int, bool> (direct_hash, direct_equal);
    var message_maps = new HashTable<int, Json.Object> (direct_hash, direct_equal);
    var my_reactions = new HashTable<string, Json.Array> (str_hash, str_equal);
    string? line;
    while ((line = stdin.read_line ()) != null) {
        log.printf ("%s\n", line);
        log.flush ();
        var parser = new Json.Parser ();
        parser.load_from_data (line);
        var request = parser.get_root ().get_object ();
        string method = request.get_string_member ("method");
        var args = request.get_array_member ("params");
        string result = "null";
        switch (method) {
        case "get_system_info": result = "{}"; break;
        case "get_all_accounts": result = mode == "empty" ? "[]" : "[{\"id\":1},{\"id\":2}]"; break;
        case "is_configured": result = args.get_int_element (0) <= 2 ? "true" : "false"; break;
        case "list_transports":
            result = "[{\"addr\":\"user%lld@example.org\"}]".printf (args.get_int_element (0)); break;
        case "get_chatlist_entries": result = "[10]"; break;
        case "get_chatlist_items_by_entries":
            result = "{\"10\":{\"name\":\"%s\",\"chatType\":\"%s\",\"freshMessageCounter\":%d,\"isPinned\":%s,\"lastMessageTimestamp\":1700000000,\"summaryText2\":\"Latest message preview\"}}".printf (
                mode == "terminal" ? "Profile %lld chat".printf (args.get_int_element (0)) : "Shared chat",
                mode == "terminal" ? "Group" : "Single", seen[(int) args.get_int_element (0)] ? 0 : 2, pinned[(int) args.get_int_element (0)] ? "true" : "false"); break;
        case "set_chat_visibility": pinned[(int) args.get_int_element (0)] = args.get_string_element (2) == "Pinned"; break;
        case "get_message_ids": result = mode == "terminal" ? "[42,44]" : "[42]"; break;
        case "get_messages":
            if (mode == "terminal") {
                int account = (int) args.get_int_element (0);
                history_reads[account] = history_reads[account] + 1;
                result = "{\"42\":{\"kind\":\"message\",\"id\":42,\"chatId\":10,\"state\":%d,\"text\":\"Account %d history\\nsecond line\",\"sender\":{\"id\":2,\"displayName\":\"Alice\"}},\"44\":{\"kind\":\"message\",\"id\":44,\"chatId\":10,\"timestamp\":1700000000,\"state\":%d,\"text\":\"My own text\",\"sender\":{\"id\":1,\"displayName\":\"Me\"}}}".printf (seen[account] ? 16 : 10, account, history_reads[account] == 1 ? 20 : 26);
            }
            else result = "{\"42\":{\"kind\":\"message\",\"id\":42,\"chatId\":10,\"text\":\"Shared history\",\"sender\":{\"displayName\":\"Alice\"}}}";
            var parsed_messages = new Json.Parser ();
            parsed_messages.load_from_data (result);
            var map = parsed_messages.get_root ().get_object ();
            string? attachment = Environment.get_variable ("PARLA_TEST_ATTACHMENT");
            if (mode == "terminal" && attachment != null) {
                var message = map.get_object_member ("44");
                message.set_string_member ("file", attachment);
                message.set_string_member ("fileName", "test image.png");
                message.set_string_member ("fileMime", "image/png");
            }
            message_maps[(int) args.get_int_element (0)] = map;
            result = Json.to_string (parsed_messages.get_root (), false);
            break;
        case "get_message":
            var map = message_maps[(int) args.get_int_element (0)];
            string id = args.get_int_element (1).to_string ();
            result = map != null && map.has_member (id) ? Json.to_string (map.get_member (id), false) : "null";
            break;
        case "get_message_reactions":
            string key = "%lld:%lld".printf (args.get_int_element (0), args.get_int_element (1));
            var own = my_reactions[key];
            if (own == null) { own = new Json.Array (); own.add_string_element ("❤"); }
            var arr = new Json.Node (Json.NodeType.ARRAY); arr.set_array (own);
            result = "{\"reactionsByContact\":{\"1\":%s,\"2\":[\"👍\"]}}".printf (Json.to_string (arr, false));
            break;
        case "send_reaction":
            string key = "%lld:%lld".printf (args.get_int_element (0), args.get_int_element (1));
            my_reactions[key] = args.get_array_element (2);
            break;
        case "markseen_msgs": case "marknoticed_chat": seen[(int) args.get_int_element (0)] = true; break;
        case "get_full_chat_by_id": result = "{\"name\":\"Test group\",\"chatType\":\"Group\",\"canSend\":true,\"ephemeralTimer\":3600,\"contactIds\":[1,2]}"; break;
        case "get_contact": result = args.get_int_element (1) == 1 ? "{\"displayName\":\"Me\"}" : "{\"displayName\":\"Alice\"}"; break;
        case "get_contact_ids": result = "[2]"; break;
        case "lookup_contact_id_by_addr": result = args.get_string_element (1) == "alice@example.org" ? "2" : "null"; break;
        case "create_contact": result = "3"; break;
        case "get_chat_id_by_contact_id": result = args.get_int_element (1) == 2 ? "10" : "null"; break;
        case "create_chat_by_contact_id": result = "11"; break;
        case "get_chat_securejoin_qr_code": result = "\"https://i.delta.chat/#example\""; break;
        case "create_qr_svg":
            string svg;
            FileUtils.get_contents (Environment.get_variable ("PARLA_TEST_QR_SVG"), out svg);
            var qr_node = new Json.Node (Json.NodeType.VALUE); qr_node.set_string (svg);
            result = Json.to_string (qr_node, false); break;
        case "send_msg": result = "43"; break;
        case "test_echo":
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.set_array (args);
            result = Json.to_string (node, false);
            break;
        case "test_disconnect": return 0;
        }
        stdout.printf ("{\"jsonrpc\":\"2.0\",\"id\":%lld,\"result\":%s}\n",
            request.get_int_member ("id"), result);
        stdout.flush ();
    }
    log.puts ("EOF\n");
    return 0;
}

int main (string[] args) {
    try {
        string? mode = Environment.get_variable ("PARLA_TEST_SERVER");
        if (mode != null) return fake_core (mode);
        var core = new CoreSession ();
        assert (!core.rpc.is_connected);
        var settings = core.settings;
        assert (settings.default_account_addr == "user2@example.org");
        settings.save_shift_enter_sends (true);
        settings.save_auto_download_limit (262144);
        var restored = new CoreSession ();
        assert (restored.settings.shift_enter_sends);
        assert (restored.settings.auto_download_limit == 262144);
        assert (restored.settings.default_account_addr == settings.default_account_addr);
        assert (restored.settings.effective_accounts_path () == settings.effective_accounts_path ());
        var file = new KeyFile ();
        file.load_from_file (SettingsManager.get_config_path (), KeyFileFlags.NONE);
        assert (file.get_string ("General", "future_setting") == "preserved");
        assert (settings.rpc_check_updates_on_startup);
        assert (!settings.startup_update_checks_enabled ());
        assert (!settings.rpc_auto_update_enabled ());
        assert (RpcInstaller.is_newer_version ("v0.10.10", "0.10.9"));
        assert (!RpcInstaller.is_newer_version ("v0.9.9", "0.10.9"));
        return 0;
    } catch (Error e) {
        stderr.printf ("%s\n", e.message);
        return 1;
    }
}
