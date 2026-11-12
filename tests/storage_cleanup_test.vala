using Dc;

// Synthetic profiles only; this server never opens a real account or attachment.
public int run_fake_storage_server () {
    var calls = new Json.Array ();
    bool fail = false;
    bool missing_total = false;
    int count = 205;
    string? line;
    while ((line = stdin.read_line ()) != null) {
        var request = object_from_json (line);
        string method = request.get_string_member ("method");
        var args = request.get_array_member ("params");
        var result = new Json.Node (Json.NodeType.NULL);
        if (!method.has_prefix ("test_")) calls.add_object_element (request);
        if ((fail && method == "get_messages" && args.get_array_element (1).get_int_element (0) == 201)
                || (missing_total && method == "get_account_file_size")) {
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
        case "test_missing_total": missing_total = true; break;
        case "test_new_message": count++; break;
        case "get_account_file_size": result.init_int (10 * 1024 * 1024); break;
        case "get_blob_dir":
            string? file = Environment.get_variable ("PARLA_TEST_STORAGE_FILE");
            if (file != null) result.init_string (Path.get_dirname (file));
            break;
        case "get_connectivity_html": result.init_string ("Quota: 5 MiB of 20 MiB used"); break;
        case "get_chatlist_entries":
            var chats = new Json.Array ();
            chats.add_int_element (args.get_element (1).is_null ()
                || (args.get_int_element (1) & 1) == 0 ? 100 : 101);
            result.init_array (chats);
            break;
        case "get_chatlist_items_by_entries":
            result.init_object (object_from_json ("""{"100":{"name":"Storage test chat"},"101":{"name":"Archived storage chat"}}"""));
            break;
        case "get_message_ids":
            assert (args.get_int_element (0) == 1);
            var ids = new Json.Array ();
            if (args.get_int_element (1) == 100) {
                for (int i = 1; i <= count; i++) ids.add_int_element (i);
            } else {
                assert (args.get_int_element (1) == 101);
                ids.add_int_element (300);
            }
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
                if (id == 300) msg.set_int_member ("chatId", 101);
                string? file = Environment.get_variable ("PARLA_TEST_STORAGE_FILE");
                if (file != null) msg.set_string_member ("file", file);
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

private Gtk.ProgressBar? storage_local_bar (Gtk.Widget root) {
    if (root.has_css_class ("storage-local-bar")) return root as Gtk.ProgressBar;
    for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = storage_local_bar (child);
        if (found != null) return found;
    }
    return null;
}

private async void check_storage_cleanup_ui (Adw.Window window) {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ test_executable, "--fake-storage" });
        rpc.account_id = 2;
        var details = new StorageDetailsDialog (rpc, 1);
        details.present (window);
        yield nap (300);
        var local_bar = storage_local_bar (details.child);
        for (int i = 0; i < 100 && local_bar.text == "Scanning local files…"; i++) yield nap (25);
        stdout.printf ("Local storage: %s (%f) — %s\n", local_bar.text, local_bar.fraction, local_bar.tooltip_text);
        assert (local_bar != null && local_bar.fraction == 0.4);
        assert (local_bar.text == "Downloaded message files: 40%");
        assert (retry_widget (details.child, "6.0 MB profile and other data · 4.0 MB downloaded message files · 10.0 MB total") != null);
        assert (retry_widget (details.child, "Archived storage chat") != null);
        var disk = storage_disk_bar (details.child);
        assert (disk != null && disk.sensitive);
        assert (disk.text.contains ("free of"));
        assert (disk.tooltip_text == Path.get_dirname (Environment.get_variable ("PARLA_TEST_STORAGE_FILE")));
        audio_screenshot (window, "storage-details.png");
        var clear = retry_widget (details.child, "Clear Chat…") as Gtk.Button;
        assert (clear != null && clear.is_sensitive ());
        clear.clicked ();
        yield nap (100);
        var options = window.get_visible_dialog () as Adw.AlertDialog;
        assert (options != null && options.default_response == "cancel");
        var keep = ephemeral_widget (options.extra_child, typeof (Gtk.CheckButton)) as Gtk.CheckButton;
        var days = ephemeral_widget (options.extra_child, typeof (Gtk.SpinButton)) as Gtk.SpinButton;
        assert (keep.active && days.value == 30);
        audio_screenshot (window, "storage-cleanup.png");
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
        yield nap (100);
        yield rpc.call ("test_missing_total", Params.begin ().build ());
        details = new StorageDetailsDialog (rpc, 1);
        details.present (window);
        yield nap (300);
        local_bar = storage_local_bar (details.child);
        assert (!local_bar.sensitive && local_bar.fraction == 0);
        assert (local_bar.text == "Local storage total unavailable");
        assert (retry_widget (details.child, "4.0 MB downloaded message files · local profile total unavailable") != null);
        details.close ();
    } catch (Error e) { error ("Storage UI: %s", e.message); }
    rpc.stop ();
    window.destroy ();
}

private Gtk.ProgressBar? storage_disk_bar (Gtk.Widget root) {
    if (root.has_css_class ("storage-disk-bar")) return root as Gtk.ProgressBar;
    for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = storage_disk_bar (child);
        if (found != null) return found;
    }
    return null;
}

public int run_storage_cleanup_ui_test () {
    string folder;
    try {
        folder = DirUtils.make_tmp ("parla-storage-test-XXXXXX");
        var file = Path.build_filename (folder, "shared-attachment");
        FileUtils.set_contents (file, string.nfill (4 * 1024 * 1024, 'a'));
        Environment.set_variable ("PARLA_TEST_STORAGE_FILE", file, true);
    } catch (Error e) { error ("Storage fixture: %s", e.message); }
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var window = new Adw.Window ();
    window.set_default_size (640, 760);
    window.present ();
    var loop = new MainLoop ();
    check_storage_cleanup_ui.begin (window, () => { loop.quit (); });
    loop.run ();
    FileUtils.unlink (Path.build_filename (folder, "shared-attachment"));
    DirUtils.remove (folder);
    Environment.unset_variable ("PARLA_TEST_STORAGE_FILE");
    return 0;
}

private async void check_disk_space_ui (Dc.Application app, Dc.Window window) {
    try {
        for (int i = 0; i < 100 && app.rpc.account_id == 0; i++) yield nap (50);
        yield nap (150);
        var rpc = app.rpc;
        assert (rpc.account_id == 1);
        var pill = disk_warning_button (window);
        assert (pill != null);
        assert ((yield retry_call_count (rpc, "get_blob_dir")) == 1);
        var space = DiskSpace.query (Environment.get_variable ("PARLA_TEST_DISK_PATH"));
        assert (pill.visible == space.is_low (1));
        var low = new DiskSpace (true, 10 * DiskSpace.BYTES_PER_GB, 0);
        window.update_disk_space_warning (rpc, 1, low);
        assert (pill.visible && pill.label.contains ("Low disk space"));
        window.update_disk_space_warning (rpc, 2, space);
        assert (pill.visible); // A background profile cannot hide this warning.
        yield nap (100);
        audio_screenshot (window, "disk-space-warning.png");
        pill.clicked ();
        yield nap (150);
        var details = window.get_visible_dialog () as StorageDetailsDialog;
        assert (details != null && storage_disk_bar (details.child).sensitive);
        assert (pill.visible == space.is_low (1)); // Refresh updates the pill too.
        details.close ();
        yield nap (50);
        assert (yield window.switch_account (2));
        window.update_disk_space_warning (rpc, 2, low);
        pill.clicked ();
        yield nap (150);
        details = window.get_visible_dialog () as StorageDetailsDialog;
        assert (details != null);
        var calls = (yield rpc.call ("test_calls", Params.begin ().build ())).get_array ();
        var last = calls.get_object_element (calls.get_length () - 1);
        assert (last.get_string_member ("method") == "get_blob_dir");
        assert (last.get_array_member ("params").get_int_element (0) == 2);
        details.close ();
        yield nap (50);

        var preferences = new SettingsDialog (window, rpc);
        preferences.present (window);
        var row = retry_widget (preferences, "Check Free Space on Startup");
        var toggle = ephemeral_widget (row, typeof (Gtk.Switch)) as Gtk.Switch;
        var threshold = retry_widget (preferences, "Warn Below (GB)") as Adw.SpinRow;
        assert (toggle.active && threshold.value == 1);
        window.update_disk_space_warning (rpc, 2, low);
        uint checks = yield retry_call_count (rpc, "get_blob_dir");
        toggle.active = false;
        assert (!pill.visible && !threshold.sensitive);
        yield nap (50);
        assert ((yield retry_call_count (rpc, "get_blob_dir")) == checks);
        threshold.value = 7;
        var saved = new SettingsManager ();
        saved.load ();
        assert (!saved.check_disk_space && saved.low_disk_space_gb == 7);
        preferences.close ();
        yield nap (50);
        // Disabled automatic checking must also survive reconnect/startup.
        yield window.reconnect_rpc_server ();
        assert ((yield retry_call_count (app.rpc, "get_blob_dir")) == 0);
        assert (!pill.visible);
        // Exercise a real startup warning without filling the test disk.
        int threshold_gb = (int) (space.free_bytes / DiskSpace.BYTES_PER_GB) + 1;
        if (threshold_gb <= 1024) {
            window.settings.save_low_disk_space_gb (threshold_gb);
            window.settings.save_check_disk_space (true);
            yield window.reconnect_rpc_server ();
            assert ((yield retry_call_count (app.rpc, "get_blob_dir")) == 1);
            assert (pill.visible);
        }
        app.rpc.stop ();
        window.destroy ();
    } catch (Error e) { error ("Disk space UI: %s", e.message); }
}

private Gtk.Button? disk_warning_button (Gtk.Widget root) {
    if (root.has_css_class ("low-disk-space")) return root as Gtk.Button;
    for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = disk_warning_button (child);
        if (found != null) return found;
    }
    return null;
}

public int run_disk_space_ui_test () {
    assert (Environment.get_variable ("PARLA_TEST_CONFIG") == Environment.get_user_config_dir ());
    DirUtils.create_with_parents (Environment.get_user_data_dir (), 0700);
    Environment.set_variable ("PARLA_TEST_DISK_PATH", Environment.get_user_data_dir (), true);
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register disk space test: %s", e.message); }
    var window = new Dc.Window (app);
    window.set_default_size (390, 640);
    window.present ();
    var loop = new MainLoop ();
    check_disk_space_ui.begin (app, window, () => { loop.quit (); });
    loop.run ();
    return 0;
}
