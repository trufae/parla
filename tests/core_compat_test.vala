using Dc;

private string test_executable;

private async void nap (uint milliseconds) {
    Timeout.add (milliseconds, nap.callback);
    yield;
}

private int run_fake_server () {
    int event_number = 0;
    string? line;
    while ((line = stdin.read_line ()) != null) {
        var request = object_from_json (line);
        string method = request.get_string_member ("method");
        var args = request.get_array_member ("params");
        string result;
        switch (method) {
        case "get_system_info": result = "{}"; break;
        case "get_all_accounts":
            result = "[{\"id\":2},{\"id\":1}]";
            break;
        case "is_configured": result = "true"; break;
        case "select_account": result = "null"; break;
        case "list_transports":
            result = args.get_int_element (0) == 1
                ? "[{\"addr\":\"one@relay.example\"},{\"addr\":\"two@relay.example\"}]"
                : "[]";
            break;
        case "get_next_event":
            if (event_number >= 2) continue;
            result = "{\"contextId\":%d,\"event\":{\"kind\":\"PinnedMessagesChanged\",\"chatId\":10}}"
                .printf (event_number++ == 0 ? 2 : 1);
            break;
        default:
            stderr.printf ("Unexpected RPC method: %s\n", method);
            return 1;
        }
        stdout.printf ("{\"jsonrpc\":\"2.0\",\"id\":%lld,\"result\":%s}\n",
            request.get_int_member ("id"), result);
        stdout.flush ();
    }
    return 0;
}

private Json.Object object_from_json (string text) {
    var parser = new Json.Parser ();
    try { parser.load_from_data (text); }
    catch (Error e) { error ("Invalid fixture: %s", e.message); }
    return parser.get_root ().get_object ();
}

private void test_presence () {
    foreach (string freshness in new string[] {
        "RecentlySeen", "Normal", "Old", "FutureValue"
    }) {
        var obj = object_from_json (
            "{\"freshness\":\"%s\",\"wasSeenRecently\":true}".printf (freshness));
        bool recent = freshness == "RecentlySeen";
        assert (RpcParsers.parse_contact (42, obj).was_seen_recently == recent);
        assert (RpcParsers.parse_chat_item (10, obj).was_seen_recently == recent);
        var message = new Json.Object ();
        message.set_object_member ("sender", obj);
        assert (RpcParsers.parse_message (message).sender_was_seen_recently == recent);
    }

    var legacy = object_from_json ("{\"wasSeenRecently\":true}");
    assert (RpcParsers.parse_contact (42, legacy).was_seen_recently);
    assert (RpcParsers.parse_chat_item (10, legacy).was_seen_recently);
    var absent = new Json.Object ();
    assert (!RpcParsers.parse_contact (42, absent).was_seen_recently);
}

private void test_message_identity () {
    // An account need not expose any address to identify its own messages.
    var self = object_from_json ("{\"fromId\":1}");
    assert (RpcParsers.parse_message (self).is_outgoing);
    var sender = object_from_json (
        "{\"sender\":{\"id\":1,\"address\":\"another@relay.example\"}}");
    assert (RpcParsers.parse_message (sender).is_outgoing);
    var other = object_from_json (
        "{\"fromId\":42,\"sender\":{\"id\":42,\"address\":\"self@relay.example\"}}");
    assert (!RpcParsers.parse_message (other).is_outgoing);
    assert (!RpcParsers.parse_message (new Json.Object ()).is_outgoing);
}

private async void check_account_addresses () {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ test_executable, "--fake-core" });
        var addresses = yield rpc.get_account_addresses (1);
        assert (addresses.length == 2);
        assert (addresses[1] == "two@relay.example");
        assert ((yield rpc.get_account_address (1)) == "one@relay.example");
        assert ((yield rpc.get_account_address (2)) == null);
        string? description;
        string? toast;
        int selected = yield AccountFinder.ensure_configured (rpc,
            " TWO@RELAY.EXAMPLE ", out description, out toast);
        assert (selected == 1);
        assert (rpc.account_id == 1);
        assert (toast == null);
    } catch (Error e) { error ("Account addresses: %s", e.message); }
    rpc.stop ();
}

private void test_account_addresses () {
    var loop = new MainLoop ();
    check_account_addresses.begin (() => { loop.quit (); });
    loop.run ();
}

private async void check_pin_events () {
    var rpc = new RpcClient ();
    try { yield rpc.start ({ test_executable, "--fake-core" }); }
    catch (Error e) { error ("Start core: %s", e.message); }
    rpc.account_id = 1;
    var events = new EventHandler (rpc);
    events.active_chat_id = 10;
    int changes = 0;
    int reloads = 0;
    events.chat_messages_changed.connect ((acct, chat) => {
        assert (acct == 1 && chat == 10);
        changes++;
    });
    events.messages_reload_fired.connect (() => { reloads++; });
    events.start.begin ();
    for (int i = 0; i < 100 && reloads == 0; i++) yield nap (10);
    assert (changes == 1);
    assert (reloads == 1);
    rpc.stop ();
    while (events.is_listening) yield nap (10);
}

private void test_pin_events () {
    var loop = new MainLoop ();
    check_pin_events.begin (() => { loop.quit (); });
    loop.run ();
}

public int main (string[] args) {
    if (args.length > 1 && args[1] == "--fake-core") return run_fake_server ();
    test_executable = File.new_for_path (args[0]).get_path ();
    Test.init (ref args);
    Test.add_func ("/core-compat/presence", test_presence);
    Test.add_func ("/core-compat/message-identity", test_message_identity);
    Test.add_func ("/core-compat/account-addresses", test_account_addresses);
    Test.add_func ("/core-compat/pin-events", test_pin_events);
    return Test.run ();
}
