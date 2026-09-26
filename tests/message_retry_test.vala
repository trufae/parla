using Dc;

/* Offline core shared by the RPC regression and optional display test. */
public int run_fake_retry_server () {
    var messages = new HashTable<int, Json.Object> (direct_hash, direct_equal);
    var calls = new Json.Array ();
    string hold = "";
    string fail = "";
    string? held_reply = null;
    string? line;
    while ((line = stdin.read_line ()) != null) {
        var request = object_from_json (line);
        string method = request.get_string_member ("method");
        var args = request.get_array_member ("params");
        var result = new Json.Node (Json.NodeType.NULL);
        string? failure = null;
        if (method == "get_message" || method == "resend_messages")
            calls.add_object_element (request);
        if (method == fail) {
            fail = "";
            failure = "Relay unavailable <offline> & retry later";
        } else {
            switch (method) {
            case "get_system_info":
            case "get_chatlist_items_by_entries":
                result.init_object (new Json.Object ());
                break;
            case "get_all_accounts":
                var accounts = new Json.Array ();
                var account = new Json.Object ();
                account.set_int_member ("id", 1);
                accounts.add_object_element (account);
                result.init_array (accounts);
                break;
            case "is_configured": result.init_boolean (true); break;
            case "get_connectivity": result.init_int (1000); break;
            case "get_chatlist_entries":
            case "get_fresh_msgs":
            case "list_transports":
                result.init_array (new Json.Array ());
                break;
            case "get_next_event": continue;
            case "get_config":
            case "select_account":
            case "start_io_for_all_accounts":
            case "batch_set_config":
                break;
            case "test_message":
                var msg = args.get_object_element (0);
                messages.insert ((int) msg.get_int_member ("id"), msg);
                break;
            case "test_hold": hold = args.get_string_element (0); break;
            case "test_fail": fail = args.get_string_element (0); break;
            case "test_release":
                assert (held_reply != null);
                stdout.printf ("%s\n", held_reply);
                held_reply = null;
                hold = "";
                break;
            case "test_calls":
                result.init_array (calls);
                break;
            case "get_message":
                var msg = messages.lookup ((int) args.get_int_element (1));
                if (msg != null) result.init_object (msg);
                break;
            case "resend_messages":
                var ids = args.get_array_element (1);
                assert (ids.get_length () == 1);
                var msg = messages.lookup ((int) ids.get_int_element (0));
                assert (msg != null && msg.get_int_member ("state") == 24);
                assert (msg.get_int_member ("fromId") == 1);
                assert (!msg.get_boolean_member ("isInfo"));
                msg.set_int_member ("state", 20);
                msg.set_null_member ("error");
                break;
            default:
                error ("Unexpected retry fixture RPC: %s", method);
            }
        }
        var response = new Json.Object ();
        response.set_string_member ("jsonrpc", "2.0");
        response.set_int_member ("id", request.get_int_member ("id"));
        if (failure != null) {
            var err = new Json.Object ();
            err.set_int_member ("code", -32000);
            err.set_string_member ("message", failure);
            response.set_object_member ("error", err);
        } else {
            response.set_member ("result", result);
        }
        var node = new Json.Node (Json.NodeType.OBJECT);
        node.set_object (response);
        string reply = Json.to_string (node, false);
        if (method == hold) {
            assert (held_reply == null);
            held_reply = reply;
        } else {
            stdout.printf ("%s\n", reply);
        }
        stdout.flush ();
    }
    return 0;
}

private async Message retry_fixture (RpcClient rpc, int id = 100,
                                    int state = 24, int sender = 1,
                                    bool info = false) throws Error {
    var obj = new Json.Object ();
    obj.set_int_member ("id", id);
    obj.set_int_member ("chatId", 10);
    obj.set_int_member ("fromId", sender);
    obj.set_int_member ("state", state);
    obj.set_boolean_member ("isInfo", info);
    obj.set_string_member ("text", "Keep the original message");
    obj.set_string_member ("error", "Relay unavailable <offline> & retry later");
    obj.set_string_member ("viewType", id == 101 ? "File" : "Text");
    if (id == 101) {
        obj.set_string_member ("file", "/missing/attachment.pdf");
        obj.set_string_member ("fileName", "attachment.pdf");
    }
    var params = new Json.Array ();
    params.add_object_element (obj);
    var node = new Json.Node (Json.NodeType.ARRAY);
    node.set_array (params);
    yield rpc.call ("test_message", node);
    return RpcParsers.parse_message (obj);
}

private async uint retry_call_count (RpcClient rpc, string method) throws Error {
    var result = yield rpc.call ("test_calls", Params.begin ().build ());
    var calls = result.get_array ();
    uint count = 0;
    for (uint i = 0; i < calls.get_length (); i++) {
        if (calls.get_object_element (i).get_string_member ("method") == method)
            count++;
    }
    return count;
}

private async void check_message_retry () {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ test_executable, "--fake-retry" });
        rpc.account_id = 1;
        // Error text is nullable and survives the copies used to rebind rows.
        var msg = yield retry_fixture (rpc);
        assert (msg.error == "Relay unavailable <offline> & retry later");
        assert (msg.dup ().error == msg.error);
        assert (RpcParsers.parse_message (object_from_json ("{}")).error == null);
        assert (RpcParsers.parse_message (object_from_json ("{\"error\":null}")).error == null);
        assert (RpcParsers.parse_message (object_from_json ("{\"error\":\"\"}")).error == "");

        // Incoming, info, draft, preparing, pending, delivered and read messages
        // must never reach resend_messages, even from a stale menu/dialog.
        foreach (int state in new int[] { 0, 10, 13, 16, 18, 19, 20, 26, 28 }) {
            msg = yield retry_fixture (rpc, 100, state);
            assert (!msg.can_retry);
            assert (!(yield rpc.retry_failed_message_for (1, 100)));
        }
        msg = yield retry_fixture (rpc, 100, 24, 42);
        assert (!msg.can_retry && !(yield rpc.retry_failed_message_for (1, 100)));
        msg = yield retry_fixture (rpc, 100, 24, 1, true);
        assert (!msg.can_retry && !(yield rpc.retry_failed_message_for (1, 100)));
        assert (!(yield rpc.retry_failed_message_for (1, 999)));
        assert (!(yield rpc.retry_failed_message_for (0, 100)));
        assert (!(yield rpc.retry_failed_message_for (1, 0)));
        assert ((yield retry_call_count (rpc, "resend_messages")) == 0);

        foreach (int id in new int[] { 100, 101 }) {
            msg = yield retry_fixture (rpc, id);
            assert (msg.can_retry);
            assert (yield rpc.retry_failed_message_for (1, id));
            var updated = yield rpc.fetch_message_for (1, id);
            assert (updated.id == id && updated.is_pending && !updated.can_retry);
            assert (updated.text == msg.text && updated.file_path == msg.file_path);
            assert (updated.error == null);
            assert (!(yield rpc.retry_failed_message_for (1, id)));
        }
        assert ((yield retry_call_count (rpc, "resend_messages")) == 2);

        // Lock spans both the eligibility fetch and native resend. Changing the
        // active profile mid-flight must not change either request's account.
        foreach (string hold in new string[] { "get_message", "resend_messages" }) {
            yield retry_fixture (rpc);
            yield rpc.call ("test_hold", Params.begin ().add_string (hold).build ());
            uint before = yield retry_call_count (rpc, hold);
            bool finished = false;
            rpc.retry_failed_message_for.begin (1, 100, (o, res) => {
                try { assert (rpc.retry_failed_message_for.end (res)); }
                catch (Error e) { error ("Retry race: %s", e.message); }
                finished = true;
            });
            for (int i = 0; i < 100 && (yield retry_call_count (rpc, hold)) == before; i++)
                yield nap (10);
            assert (!finished && rpc.is_retrying_message_for (1, 100));
            assert (!(yield rpc.retry_failed_message_for (1, 100)));
            rpc.account_id = 2;
            yield rpc.call ("test_release", Params.begin ().build ());
            for (int i = 0; i < 100 && !finished; i++) yield nap (10);
            assert (finished && !rpc.is_retrying_message_for (1, 100));
        }
        assert ((yield retry_call_count (rpc, "resend_messages")) == 4);
        var result = yield rpc.call ("test_calls", Params.begin ().build ());
        var calls = result.get_array ();
        for (uint i = 0; i < calls.get_length (); i++)
            assert (calls.get_object_element (i).get_array_member ("params").get_int_element (0) == 1);

        // Both preflight and resend errors release the lock and retain useful
        // error text. A subsequent attempt can succeed.
        foreach (string method in new string[] { "get_message", "resend_messages" }) {
            yield retry_fixture (rpc);
            yield rpc.call ("test_fail", Params.begin ().add_string (method).build ());
            bool failed = false;
            try { yield rpc.retry_failed_message_for (1, 100); }
            catch (Error e) {
                failed = true;
                assert (e.message.contains ("Relay unavailable <offline> & retry later"));
            }
            assert (failed && !rpc.is_retrying_message_for (1, 100));
            assert (yield rpc.retry_failed_message_for (1, 100));
        }
    } catch (Error e) { error ("Message retry: %s", e.message); }
    rpc.stop ();
}

public void test_message_retry () {
    var loop = new MainLoop ();
    check_message_retry.begin (() => { loop.quit (); });
    loop.run ();
}

private Gtk.Widget? retry_widget (Gtk.Widget root, string label) {
    var button = root as Gtk.Button;
    var row = root as Adw.ActionRow;
    var text = root as Gtk.Label;
    if ((button != null && button.label == label) || (row != null && row.title == label)
            || (text != null && text.get_text () == label))
        return root;
    for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = retry_widget (child, label);
        if (found != null) return found;
    }
    return null;
}

private async void check_retry_ui (Dc.Application app, Dc.Window window) {
    try {
        for (int i = 0; i < 100 && app.rpc.account_id == 0; i++) yield nap (50);
        assert (app.rpc.account_id == 1);
        var rpc = app.rpc;
        var settings = new SettingsManager ();
        var store = new GLib.ListStore (typeof (Message));
        var pinned = new PinnedMessagesManager (store, settings);
        var compose = new ComposeBar ();
        var actions = new MessageActions (window, rpc, store, pinned, compose, settings);
        var msg = yield retry_fixture (rpc, 101);
        store.append (msg);
        var dialog = new MessageDetailsDialog (window, rpc, actions, msg, null);
        dialog.present (window);
        var button = retry_widget (dialog.child, "Retry") as Gtk.Button;
        var delivery = retry_widget (dialog.child, "Delivery") as Adw.ActionRow;
        var err = retry_widget (dialog.child, "Error") as Adw.ActionRow;
        assert (button != null && button.visible && button.sensitive);
        assert (err.visible && !err.use_markup && err.subtitle == msg.error);
        assert (delivery.subtitle == "Failed");

        // Failure keeps the explanation and makes the button available again.
        yield rpc.call ("test_fail", Params.begin ().add_string ("resend_messages").build ());
        button.clicked ();
        assert (!button.sensitive);
        for (int i = 0; i < 100 && !button.sensitive; i++) yield nap (10);
        assert (button.visible && button.sensitive && err.visible);
        assert (delivery.subtitle == "Failed" && err.subtitle == msg.error);
        string failure = "Could not retry message: RPC resend_messages: " + msg.error;
        for (int i = 0; i < 100 && retry_widget (dialog.child, failure) == null; i++)
            yield nap (10);
        assert (retry_widget (dialog.child, failure) != null);

        // Two activations while core is busy must only queue one native retry.
        yield rpc.call ("test_hold", Params.begin ().add_string ("resend_messages").build ());
        button.clicked ();
        button.clicked ();
        for (int i = 0; i < 100 && (yield retry_call_count (rpc, "resend_messages")) < 2; i++)
            yield nap (10);
        assert (!button.sensitive && button.label == "Retrying…");
        yield rpc.call ("test_release", Params.begin ().build ());
        for (int i = 0; i < 100 && button.visible; i++) yield nap (10);
        assert (!button.visible && !err.visible);
        assert (delivery.subtitle == "Pending");
        assert (find_message (store, 101).is_pending);
        assert ((yield retry_call_count (rpc, "resend_messages")) == 2);
        dialog.close ();

        // A callback from the previous profile cannot overwrite its cached row.
        msg = yield retry_fixture (rpc, 101);
        store.splice (0, 1, new Object[] { msg });
        yield rpc.call ("test_hold", Params.begin ().add_string ("resend_messages").build ());
        bool finished = false;
        actions.retry_message.begin (101, (o, res) => {
            assert (actions.retry_message.end (res) == null);
            finished = true;
        });
        for (int i = 0; i < 100 && (yield retry_call_count (rpc, "resend_messages")) < 3; i++)
            yield nap (10);
        rpc.account_id = 2;
        yield rpc.call ("test_release", Params.begin ().build ());
        for (int i = 0; i < 100 && !finished; i++) yield nap (10);
        assert (finished && find_message (store, 101).is_failed);
        rpc.stop ();
        window.destroy ();
        stdout.printf ("Retry details, literal errors, duplicate activation, state refresh and profile switch: PASS\n");
    } catch (Error e) { error ("Retry UI: %s", e.message); }
}

public int run_retry_ui_test () {
    Adw.init ();
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register retry test: %s", e.message); }
    var window = new Dc.Window (app);
    window.present ();
    var loop = new MainLoop ();
    check_retry_ui.begin (app, window, () => { loop.quit (); });
    loop.run ();
    return 0;
}
