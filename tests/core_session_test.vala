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
        case "get_chatlist_items_by_entries": result = "{\"10\":{\"name\":\"Shared chat\",\"freshMessageCounter\":2}}"; break;
        case "get_message_ids": result = "[42]"; break;
        case "get_messages": result = "{\"42\":{\"kind\":\"message\",\"id\":42,\"chatId\":10,\"text\":\"Shared history\",\"sender\":{\"displayName\":\"Alice\"}}}"; break;
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
