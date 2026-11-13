using Dc;

/* Intentionally plain stdio. Only the blocking fgets-based read runs on a
 * worker; all backend calls stay on the GLib main context so RPC, updates and
 * network IO continue while the terminal waits for input.
 */
private async string? read_line () {
    string? line = null;
    new Thread<void*> ("stdin", () => {
        line = stdin.read_line ();
        Idle.add (() => { read_line.callback (); return Source.REMOVE; });
        return null;
    });
    yield;
    return line;
}

private const string HELP = """accounts                   List profiles
account ID                 Select a configured profile
chats [QUERY]              List chats
messages CHAT_ID           Show the last 50 messages
send CHAT_ID TEXT          Send a text message
settings                   Show shared settings and data paths
updates                    Check for updates using the saved policy
rpc METHOD [JSON_ARRAY]    Call the core directly (explicit account parameters)
help                       Show commands
quit                       Stop the core and exit
""";

private int positive_id (string value) throws Error {
    int id;
    if (!int.try_parse (value, out id) || id <= 0)
        throw new IOError.INVALID_ARGUMENT ("Expected a positive numeric ID");
    return id;
}

private void print_json (Json.Node? node) {
    stdout.printf ("%s\n", node != null ? Json.to_string (node, false) : "null");
}

private async void check_updates (CoreSession core) {
    string? version = yield core.check_parla_update ();
    if (version != null) stdout.printf ("Parla %s available\n", version);
    version = yield core.check_core_update ();
    if (version != null) stdout.printf ("Chatmail Core %s available\n", version);
}

private async void command (CoreSession core, string line) throws Error {
    var rpc = core.rpc;
    string[] words = line.split (" ", 2);
    string arg = words.length > 1 ? words[1].strip () : "";
    switch (words[0]) {
    case "help": stdout.puts (HELP); return;
    case "settings":
        stdout.printf ("Settings: %s\nAccounts: %s\nCore: %s\nAccount: %d\nDownload limit: %d\nStartup updates: %s\n",
            SettingsManager.get_config_path (), core.settings.effective_accounts_path (),
            core.server_path ?? "", rpc.account_id, core.settings.auto_download_limit,
            core.settings.startup_update_checks_enabled ().to_string ());
        return;
    case "updates": yield check_updates (core); return;
    case "accounts": print_json (yield rpc.get_all_accounts ()); return;
    case "account":
        int id = positive_id (arg);
        if (!(yield rpc.is_configured (id)))
            throw new IOError.INVALID_ARGUMENT ("Profile is not configured");
        yield rpc.select_account (id);
        rpc.account_id = id;
        rpc.self_email = null;
        yield core.start_io ();
        stdout.printf ("Account %d\n", id);
        return;
    case "rpc":
        string[] parts = arg.split (" ", 2);
        if (parts[0] == "") throw new IOError.INVALID_ARGUMENT ("Usage: rpc METHOD [JSON_ARRAY]");
        var parser = new Json.Parser ();
        parser.load_from_data (parts.length > 1 ? parts[1] : "[]");
        if (parser.get_root ().get_node_type () != Json.NodeType.ARRAY)
            throw new IOError.INVALID_ARGUMENT ("RPC parameters must be a JSON array");
        print_json (yield rpc.call (parts[0], parser.get_root ()));
        return;
    }
    if (rpc.account_id <= 0)
        throw new IOError.NOT_INITIALIZED ("No configured profile; use the GUI to set one up, or rpc for core access");
    switch (words[0]) {
    case "chats":
        var entries = yield rpc.get_chatlist_entries_for (rpc.account_id,
            arg == "" ? null : arg, RpcClient.GCL_NO_SPECIALS);
        if (entries == null) return;
        var items = yield rpc.get_chatlist_items_by_entries_for (rpc.account_id, entries);
        if (items == null) return;
        for (uint i = 0; i < entries.get_length (); i++) {
            int id = (int) entries.get_int_element (i);
            var item = json_obj (items, id.to_string ());
            if (item == null) continue;
            var chat = RpcParsers.parse_chat_item (id, item);
            stdout.printf ("%d\t%s\t%d unread\n", chat.id, chat.name, chat.unread_count);
        }
        return;
    case "messages":
        var entries = yield rpc.get_message_ids_for (rpc.account_id, positive_id (arg));
        if (entries == null) return;
        int count = (int) entries.get_length ();
        int[] ids = {};
        for (int i = int.max (0, count - 50); i < count; i++)
            ids += (int) entries.get_int_element (i);
        foreach (var msg in yield rpc.get_parsed_messages (ids))
            stdout.printf ("%d\t%s\t%s: %s\n", msg.id, format_date_time (msg.timestamp),
                msg.sender_name ?? msg.sender_address ?? "", msg.text ?? msg.file_name ?? "");
        return;
    case "send":
        string[] parts = arg.split (" ", 2);
        if (parts.length < 2 || parts[1].strip () == "")
            throw new IOError.INVALID_ARGUMENT ("Usage: send CHAT_ID TEXT");
        int id = yield rpc.send_msg (positive_id (parts[0]), parts[1]);
        stdout.printf ("Sent %d\n", id);
        return;
    default: throw new IOError.INVALID_ARGUMENT ("Unknown command; type help");
    }
}

private async int repl (CoreSession core, MainLoop loop) {
    try {
        yield core.start ();
        core.rpc.disconnected.connect ((reason) => {
            stderr.printf ("Disconnected: %s\n", reason);
            loop.quit ();
        });
        string? description, notice;
        yield core.prepare_accounts (out description, out notice);
        if (description != null) stdout.printf ("%s\n", description);
        if (notice != null) stderr.printf ("%s\n", notice);
        check_updates.begin (core);
        stdout.printf ("Parla %s — account %d. Type help for commands.\n", Parla.VERSION, core.rpc.account_id);
        while (core.rpc.is_connected) {
            if (Posix.isatty (stdin.fileno ())) stdout.printf ("parla> ");
            stdout.flush ();
            string? line = yield read_line ();
            if (line == null) break;
            line = line.strip ();
            if (line == "quit" || line == "exit") break;
            if (line == "") continue;
            try { yield command (core, line); }
            catch (Error e) { stderr.printf ("%s\n", e.message); }
        }
        bool connected = core.rpc.is_connected;
        yield core.rpc.stop_gracefully ();
        return connected ? 0 : 1;
    } catch (Error e) {
        stderr.printf ("%s\n", e.message);
        return 1;
    }
}

int main (string[] args) {
    if (args.length > 1) {
        if (args.length == 2 && args[1] == "--version") {
            stdout.printf ("Parla %s\n", Parla.VERSION);
            return 0;
        }
        stdout.printf ("Usage: parla-cli [--help|--version]\n\n%s", HELP);
        return args.length == 2 && args[1] == "--help" ? 0 : 1;
    }
    Localization.initialize (SettingsManager.load_language ());
    var core = new CoreSession ();
    var loop = new MainLoop ();
    int status = 1;
#if !WINDOWS
    Unix.signal_add (Posix.Signal.INT, () => { loop.quit (); return Source.CONTINUE; });
    Unix.signal_add (Posix.Signal.TERM, () => { loop.quit (); return Source.CONTINUE; });
#endif
    Idle.add (() => {
        repl.begin (core, loop, (obj, result) => { status = repl.end (result); loop.quit (); });
        return Source.REMOVE;
    });
    loop.run ();
    core.rpc.stop ();
    return status;
}
