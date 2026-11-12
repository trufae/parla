using Dc;

// Synthetic profiles only; this server never opens a real account or attachment.
public int run_fake_storage_server () {
    var calls = new Json.Array ();
    bool fail = false;
    int count = 205;
    string? line;
    while ((line = stdin.read_line ()) != null) {
        var request = object_from_json (line);
        string method = request.get_string_member ("method");
        var args = request.get_array_member ("params");
        var result = new Json.Node (Json.NodeType.NULL);
        if (!method.has_prefix ("test_")) calls.add_object_element (request);
        if (fail && method == "get_messages" && args.get_array_element (1).get_int_element (0) == 201) {
            stdout.printf ("{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":-32000,\"message\":\"Scan failed\"}}\n",
                request.get_int_member ("id").to_string ());
            stdout.flush ();
            fail = false;
            continue;
        }
        switch (method) {
        case "get_system_info": result.init_object (new Json.Object ()); break;
        case "test_calls": result.init_array (calls); break;
        case "test_fail": fail = true; break;
        case "test_new_message": count++; break;
        case "get_account_file_size": result.init_int (10 * 1024 * 1024); break;
        case "get_blob_dir": break;
        case "get_connectivity_html": result.init_string ("Quota: 5 MiB of 20 MiB used"); break;
        case "get_chatlist_entries":
            var chats = new Json.Array ();
            if (args.get_element (1).is_null () || (args.get_int_element (1) & 1) == 0)
                chats.add_int_element (100);
            result.init_array (chats);
            break;
        case "get_chatlist_items_by_entries":
            result.init_object (object_from_json ("""{"100":{"name":"Storage test chat"}}"""));
            break;
        case "get_message_ids":
            assert (args.get_int_element (0) == 1 && args.get_int_element (1) == 100);
            var ids = new Json.Array ();
            for (int i = 1; i <= count; i++) ids.add_int_element (i);
            result.init_array (ids);
            break;
        case "get_messages":
            assert (args.get_int_element (0) == 1);
            var batch = args.get_array_element (1);
            assert (batch.get_length () <= 200);
            var messages = new Json.Object ();
            for (uint i = 0; i < batch.get_length (); i++) {
                int id = (int) batch.get_int_element (i);
                var msg = object_from_json ("""{"kind":"message","chatId":100,"timestamp":1000,"fileBytes":1024}""");
                msg.set_int_member ("id", id);
                if (id == 2) msg.set_int_member ("timestamp", new DateTime.now_utc ().to_unix ());
                if (id == 3) msg.set_int_member ("receivedTimestamp", new DateTime.now_utc ().to_unix ());
                if (id == 4) msg.remove_member ("timestamp");
                if (id == 5) msg.set_string_member ("kind", "loadingError");
                if (id == 6) msg.set_int_member ("timestamp", 4102444800);
                if (id == 7) msg.set_int_member ("chatId", 200);
                messages.set_object_member (id.to_string (), msg);
            }
            result.init_object (messages);
            break;
        case "delete_messages":
            assert (args.get_int_element (0) == 1);
            break;
        default: error ("Unexpected storage RPC: %s", method);
        }
        stdout.printf ("{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}\n",
            request.get_int_member ("id").to_string (), Json.to_string (result, false));
        stdout.flush ();
    }
    return 0;
}

private async void check_storage_cleanup () {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ test_executable, "--fake-storage" });
        rpc.account_id = 2;
        var ids = yield chat_message_ids_for_clear (rpc, 1, 100, false, 2000);
        assert (ids.length == 199 && ids[0] == 1 && ids[1] == 8 && ids[198] == 205);
        yield rpc.call ("test_new_message", Params.begin ().build ());
        yield rpc.delete_messages_for (1, ids);
        var calls = (yield rpc.call ("test_calls", Params.begin ().build ())).get_array ();
        var last = calls.get_object_element (calls.get_length () - 1);
        assert (last.get_string_member ("method") == "delete_messages");
        assert (last.get_array_member ("params").get_int_element (0) == 1);
        assert (last.get_array_member ("params").get_array_element (1).get_length () == 199);
        var all = yield chat_message_ids_for_clear (rpc, 1, 100, false);
        assert (all.length == 206);
        yield rpc.call ("test_fail", Params.begin ().build ());
        bool failed = false;
        try { yield chat_message_ids_for_clear (rpc, 1, 100, false, 2000); }
        catch (Error e) { failed = true; }
        assert (failed);
    } catch (Error e) { error ("Storage cleanup: %s", e.message); }
    rpc.stop ();
}

public void test_storage_cleanup () {
    var loop = new MainLoop ();
    check_storage_cleanup.begin (() => { loop.quit (); });
    loop.run ();
}

private async void check_storage_cleanup_ui (Adw.Window window) {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ test_executable, "--fake-storage" });
        rpc.account_id = 2;
        var details = new StorageDetailsDialog (rpc, 1);
        details.present (window);
        yield nap (300);
        var clear = retry_widget (details.child, "Clear Chat…") as Gtk.Button;
        assert (clear != null && clear.is_sensitive ());
        clear.clicked ();
        yield nap (100);
        var options = window.get_visible_dialog () as Adw.AlertDialog;
        assert (options != null && options.default_response == "cancel");
        var keep = ephemeral_widget (options.extra_child, typeof (Gtk.CheckButton)) as Gtk.CheckButton;
        var days = ephemeral_widget (options.extra_child, typeof (Gtk.SpinButton)) as Gtk.SpinButton;
        assert (keep.active && days.value == 30);
        days.value = 36500;
        options.response ("review");
        yield nap (200);
        var empty = window.get_visible_dialog () as Adw.AlertDialog;
        assert (empty.heading == "No messages to clear");
        empty.response ("close");
        yield nap (100);
        clear.clicked ();
        yield nap (100);
        options = window.get_visible_dialog () as Adw.AlertDialog;
        options.response ("review");
        yield nap (200);
        var confirm = window.get_visible_dialog () as Adw.AlertDialog;
        assert (confirm != null && confirm.body.contains ("199 messages"));
        confirm.response ("cancel");
        yield nap (150);
        assert (clear.is_sensitive ());
        clear.clicked ();
        yield nap (100);
        options = window.get_visible_dialog () as Adw.AlertDialog;
        keep = ephemeral_widget (options.extra_child, typeof (Gtk.CheckButton)) as Gtk.CheckButton;
        keep.active = false;
        options.response ("review");
        yield nap (200);
        confirm = window.get_visible_dialog () as Adw.AlertDialog;
        assert (confirm.body.contains ("205 messages"));
        yield rpc.call ("test_new_message", Params.begin ().build ());
        confirm.response ("clear");
        yield nap (300);
        var calls = (yield rpc.call ("test_calls", Params.begin ().build ())).get_array ();
        int deletions = 0;
        for (uint i = 0; i < calls.get_length (); i++) {
            var call = calls.get_object_element (i);
            if (call.get_string_member ("method") != "delete_messages") continue;
            deletions++;
            var args = call.get_array_member ("params");
            assert (args.get_int_element (0) == 1);
            assert (args.get_array_element (1).get_length () == 205);
        }
        assert (deletions == 1);
        details.close ();
    } catch (Error e) { error ("Storage UI: %s", e.message); }
    rpc.stop ();
    window.destroy ();
}

public int run_storage_cleanup_ui_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var window = new Adw.Window ();
    window.set_default_size (640, 760);
    window.present ();
    var loop = new MainLoop ();
    check_storage_cleanup_ui.begin (window, () => { loop.quit (); });
    loop.run ();
    return 0;
}
