using Dc;

private string test_executable;

private async void nap (uint milliseconds) {
    Timeout.add (milliseconds, nap.callback);
    yield;
}

private int run_fake_server (string mode) {
    int event_number = 0;
    int64 pending_seen = 0;
    int first_unread = 0;
    var requests = new Json.Array ();
    string? line;
    while ((line = stdin.read_line ()) != null) {
        var request = object_from_json (line);
        string method = request.get_string_member ("method");
        var args = request.get_array_member ("params");
        if (method != "test_calls") requests.add_object_element (request);
        if (method == "init_transports" && mode != "latest") {
            stdout.printf ("{\"jsonrpc\":\"2.0\",\"id\":%lld,\"error\":{\"code\":%d,\"message\":\"%s\"}}\n",
                request.get_int_member ("id"), mode == "legacy" ? -32601 : -32000,
                mode == "legacy" ? "Method not found" : "Relay unavailable");
            stdout.flush ();
            continue;
        }
        string result;
        switch (method) {
        case "get_system_info": result = "{}"; break;
        case "get_all_accounts":
            result = "[{\"id\":2},{\"id\":1}]";
            break;
        case "is_configured": result = "true"; break;
        case "select_account": result = "null"; break;
        case "markseen_msgs":
            if (mode == "read-race") {
                pending_seen = request.get_int_member ("id");
                continue;
            }
            first_unread = 0;
            result = "null";
            break;
        case "release_read":
            assert (pending_seen != 0);
            stdout.printf ("{\"jsonrpc\":\"2.0\",\"id\":%lld,\"result\":null}\n", pending_seen);
            pending_seen = 0;
            first_unread = 0;
            result = "null";
            break;
        case "markfresh_chat":
            assert (pending_seen == 0);
            first_unread = 42;
            result = "null";
            break;
        case "marknoticed_chat": result = "null"; break;
        case "get_first_unread_message_of_chat":
            result = first_unread > 0 ? first_unread.to_string () : "null";
            break;
        case "init_transports": result = "null"; break;
        case "add_transport_from_qr":
            assert (mode == "legacy");
            result = "null";
            break;
        case "check_qr":
            string qr = args.get_string_element (1);
            result = qr.has_prefix ("DCACCOUNT:") ? "{\"kind\":\"account\"}"
                : qr.has_prefix ("DCLOGIN:") ? "{\"kind\":\"login\"}"
                : "{\"kind\":\"askVerifyContact\"}";
            break;
        case "test_calls":
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.set_array (requests);
            var generator = new Json.Generator ();
            generator.set_root (node);
            result = generator.to_data (null);
            break;
        case "list_transports":
            result = args.get_int_element (0) == 1
                ? "[{\"addr\":\"one@relay.example\"},{\"addr\":\"two@relay.example\"}]"
                : "[]";
            break;
        case "get_next_event":
            if (event_number >= 4) continue;
            string kind = event_number < 2 ? "TransportsModified" : "PinnedMessagesChanged";
            result = "{\"contextId\":%d,\"event\":{\"kind\":\"%s\",\"chatId\":10}}"
                .printf (event_number++ % 2 == 0 ? 2 : 1, kind);
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

private void test_channel_reactions () {
    foreach (string type in new string[] { "InBroadcast", "OutBroadcast" }) {
        assert (ChatActions.is_channel (type));
        assert (string.joinv (",", ChatActions.reaction_choices (type)) == "👍,👎,❤️,😂,🙁");
    }
    assert (!ChatActions.is_channel ("Group"));
    assert (!ChatActions.is_channel ("Single"));
    var obj = object_from_json ("""
        {"reactions": {
            "reactions": [
                {"emoji":"👍","count":12,"isFromSelf":true},
                {"emoji":"❤️","count":8,"isFromSelf":false}],
            "reactionsByContact":{"1":["👍"]}
        }}
        """);
    var msg = RpcParsers.parse_message (obj);
    assert (msg.reactions == "👍:12,❤️:8");
    assert (msg.my_reactions == "👍");
    assert (msg.reaction_details.length == 2);
    assert (msg.reaction_details[0].count == 12);
    assert (msg.reaction_details[0].users.length == 1);
    assert (msg.reaction_details[1].users.length == 0);

    // Even a missing contact map must not hide aggregate counts or our vote.
    obj.get_object_member ("reactions").remove_member ("reactionsByContact");
    msg = RpcParsers.parse_message (obj);
    assert (msg.reactions == "👍:12,❤️:8");
    assert (msg.my_reactions == "👍");
    assert (msg.reaction_details[0].users.length == 0);

    // An empty aggregate list is authoritative over a stale identity map.
    obj = object_from_json ("""
        {"reactions":{"reactions":[],"reactionsByContact":{"1":["👍"]}}}
        """);
    assert (RpcParsers.parse_message (obj).reactions == null);

    // Older responses without aggregates still expose all identities.
    obj = object_from_json ("""
        {"reactions":{"reactionsByContact":{"1":["👍"],"42":["👍"]}}}
        """);
    msg = RpcParsers.parse_message (obj);
    assert (msg.reactions == "👍:2");
    assert (msg.my_reactions == "👍");
    assert (msg.reaction_details[0].users.length == 2);
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
    int[] transport_accounts = {};
    events.transports_changed.connect ((acct) => { transport_accounts += acct; });
    events.chat_messages_changed.connect ((acct, chat) => {
        assert (acct == 1 && chat == 10);
        changes++;
    });
    events.messages_reload_fired.connect (() => { reloads++; });
    events.start.begin ();
    for (int i = 0; i < 100 && reloads == 0; i++) yield nap (10);
    assert (changes == 1);
    assert (reloads == 1);
    assert (transport_accounts.length == 2);
    assert (transport_accounts[0] == 2);
    assert (transport_accounts[1] == 1);
    rpc.stop ();
    while (events.is_listening) yield nap (10);
}

private void test_pin_events () {
    var loop = new MainLoop ();
    check_pin_events.begin (() => { loop.quit (); });
    loop.run ();
}

private async void check_onboarding (string mode, string? qr,
                                     string? expected_relay = null) {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ test_executable, "--fake-core", mode });
        bool failed = false;
        try { yield initialize_profile_transports (rpc, 7, qr); }
        catch (Error e) {
            assert (mode == "failure");
            failed = true;
        }
        assert (failed == (mode == "failure"));
        var result = yield rpc.call ("test_calls", Params.begin ().build ());
        var calls = result.get_array ();
        var init = calls.get_object_element (1);
        assert (init.get_string_member ("method") == "init_transports");
        var args = init.get_array_member ("params");
        assert (args.get_int_element (0) == 7);
        if (qr == null) assert (args.get_element (1).is_null ());
        else assert (args.get_string_element (1) == qr);
        if (expected_relay == null) {
            assert (calls.get_length () == 2);
        } else {
            assert (calls.get_length () == (qr == null ? 3 : 4));
            var add = calls.get_object_element (calls.get_length () - 1);
            assert (add.get_string_member ("method") == "add_transport_from_qr");
            assert (add.get_array_member ("params").get_int_element (0) == 7);
            assert (add.get_array_member ("params").get_string_element (1) == expected_relay);
        }
    } catch (Error e) { error ("Onboarding: %s", e.message); }
    rpc.stop ();
}

private async void check_onboarding_cases () {
    string explicit_relay = "DCACCOUNT:https://custom.example/new";
    string login = "DCLOGIN:custom.example";
    string invite = "OPENPGP4FPR:inviter";
    string fallback = build_chatmail_qr (CHATMAIL_RELAYS[0].domain);
    yield check_onboarding ("latest", null);
    yield check_onboarding ("latest", explicit_relay);
    yield check_onboarding ("latest", invite);
    yield check_onboarding ("legacy", null, fallback);
    yield check_onboarding ("legacy", explicit_relay, explicit_relay);
    yield check_onboarding ("legacy", login, login);
    yield check_onboarding ("legacy", invite, fallback);
    yield check_onboarding ("failure", null);
}

private void test_onboarding () {
    var loop = new MainLoop ();
    check_onboarding_cases.begin (() => { loop.quit (); });
    loop.run ();
}

private async void check_unread_calls () {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ test_executable, "--fake-core", "read-race" });
        rpc.account_id = 1;
        assert ((yield rpc.get_first_unread_message_of_chat (10)) == 0);
        bool seen_done = false;
        bool unread_done = false;
        rpc.mark_seen_msgs.begin ({ 42 }, (o, res) => {
            try { rpc.mark_seen_msgs.end (res); }
            catch (Error e) { error ("Seen: %s", e.message); }
            seen_done = true;
        });
        rpc.markfresh_chat.begin (10, (o, res) => {
            try { rpc.markfresh_chat.end (res); }
            catch (Error e) { error ("Unread: %s", e.message); }
            assert (seen_done);
            unread_done = true;
        });
        // A queued operation must keep the account that initiated it.
        rpc.account_id = 2;
        yield rpc.call ("release_read", Params.begin ().build ());
        assert ((yield rpc.get_first_unread_message_of_chat (10)) == 42);
        assert (unread_done);
        var result = yield rpc.call ("test_calls", Params.begin ().build ());
        var calls = result.get_array ();
        assert (calls.get_object_element (3).get_string_member ("method") == "release_read");
        var unread = calls.get_object_element (4);
        assert (unread.get_string_member ("method") == "markfresh_chat");
        assert (unread.get_array_member ("params").get_int_element (0) == 1);
        assert (calls.get_object_element (5).get_array_member ("params").get_int_element (0) == 2);
    } catch (Error e) { error ("Read state: %s", e.message); }
    rpc.stop ();
}

private void test_unread_calls () {
    var loop = new MainLoop ();
    check_unread_calls.begin (() => { loop.quit (); });
    loop.run ();
}

public int main (string[] args) {
    if (args.length > 1 && args[1] == "--unread-ui")
        return run_unread_ui_test ();
    if (args.length > 1 && args[1] == "--fake-core")
        return run_fake_server (args.length > 2 ? args[2] : "latest");
    test_executable = File.new_for_path (args[0]).get_path ();
    Test.init (ref args);
    Test.add_func ("/core-compat/presence", test_presence);
    Test.add_func ("/core-compat/message-identity", test_message_identity);
    Test.add_func ("/core-compat/channel-reactions", test_channel_reactions);
    Test.add_func ("/core-compat/account-addresses", test_account_addresses);
    Test.add_func ("/core-compat/pin-events", test_pin_events);
    Test.add_func ("/core-compat/onboarding", test_onboarding);
    Test.add_func ("/core-compat/unread-calls", test_unread_calls);
    return Test.run ();
}
