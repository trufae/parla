private void backup_test_cleanup (File file) throws Error {
    var info = file.query_info ("standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
    if (info.get_file_type () == FileType.DIRECTORY) {
        var enumerator = file.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = enumerator.next_file ()) != null) backup_test_cleanup (file.get_child (child.get_name ()));
        enumerator.close ();
    }
    file.delete ();
}

private async void backup_real_core_async (string server) throws Error {
    string root = DirUtils.make_tmp ("parla-core-backup-XXXXXX");
    string source = Path.build_filename (root, "accounts");
    string restored = Path.build_filename (root, "restored");
    string archive = Path.build_filename (root, "backup.zip");
    var rpc = new Dc.RpcClient ();
    var secret = new SafeStore.SecretValue ("disposable core backup password");
    try {
        yield rpc.start ({server}, root, source);
        int first = yield rpc.add_account ();
        int second = yield rpc.add_account ();
        yield rpc.call ("set_config", Dc.Params.begin ().add_int (first).add_string ("addr").add_string ("first@example.invalid").build ());
        yield rpc.call ("set_config", Dc.Params.begin ().add_int (second).add_string ("addr").add_string ("second@example.invalid").build ());
        rpc.account_id = first;
        int contact = yield rpc.create_contact ("friend@example.invalid");
        int chat = yield rpc.get_or_create_chat_by_contact (contact);
        string attachment = Path.build_filename (root, "attachment.txt");
        FileUtils.set_contents (attachment, "attachment preserved through core backup");
        yield rpc.set_draft (chat, "draft preserved through core backup", attachment, "attachment.txt", 0, "File");
        yield rpc.stop_gracefully ();
        int[] ids = Dc.AccountBackup.validate_layout (source);
        assert_cmpint (ids.length, CompareOperator.EQ, 2);
        var backups = new SafeStore.Backups ();
        yield backups.create (source, archive, secret);
        yield backups.restore (archive, restored, secret);
        ids = Dc.AccountBackup.validate_layout (restored);
        assert_cmpint (ids.length, CompareOperator.EQ, 2);
        yield rpc.start ({server}, root, restored);
        assert_cmpstr (yield rpc.get_config ("addr", first), CompareOperator.EQ, "first@example.invalid");
        assert_cmpstr (yield rpc.get_config ("addr", second), CompareOperator.EQ, "second@example.invalid");
        var draft = yield rpc.get_draft (chat);
        assert_true (draft != null);
        assert_cmpstr (draft.text, CompareOperator.EQ, "draft preserved through core backup");
        string attachment_contents;
        FileUtils.get_contents (draft.file_path, out attachment_contents);
        assert_cmpstr (attachment_contents, CompareOperator.EQ, "attachment preserved through core backup");
        assert_true (Filename.canonicalize (draft.file_path).has_prefix (restored + Path.DIR_SEPARATOR_S));
        yield rpc.stop_gracefully ();
        // The independent original still opens with both account identities.
        yield rpc.start ({server}, root, source);
        assert_cmpstr (yield rpc.get_config ("addr", first), CompareOperator.EQ, "first@example.invalid");
        yield rpc.stop_gracefully ();
    } finally {
        rpc.stop (); secret.clear ();
        try { backup_test_cleanup (File.new_for_path (root)); } catch (Error e) { Test.fail_printf ("%s", e.message); }
    }
}

private void test_backup_core () {
    string? server = Environment.get_variable ("PARLA_TEST_CORE");
    if (server == null) { Test.skip ("Set PARLA_TEST_CORE to a local core binary for the offline roundtrip"); return; }
    var loop = new MainLoop (); Error? failure = null;
    backup_real_core_async.begin (server, (obj, result) => {
        try { backup_real_core_async.end (result); } catch (Error e) { failure = e; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.message ("%s", failure.message);
    assert_true (failure == null);
}

private void test_backup_account_paths () {
    string? root = null;
    try {
        root = DirUtils.make_tmp ("parla-backup-paths-XXXXXX");
        string uuid = "12345678-1234-1234-1234-123456789abc";
        DirUtils.create (Path.build_filename (root, uuid), 0700);
        FileUtils.set_contents (Path.build_filename (root, uuid, "dc.db"), "fixture");
        string prefix = "selected_account = 1\nnext_id = 2\naccounts_order = [\n 1,\n]\n\n[[accounts]]\nid = 1\nuuid = \"" + uuid + "\"\ndir = ";
        string metadata = Path.build_filename (root, "accounts.toml");
        FileUtils.set_contents (metadata, prefix + "\"" + uuid + "\"\n");
        assert_cmpint (Dc.AccountBackup.validate_layout (root).length, CompareOperator.EQ, 1);
        string[] unsafe = { "\"/outside\"", "\"../outside\"", "\"C:\\\\outside\"", "\"\"\"\n/outside\n\"\"\"", "\"" + uuid + "\"\n[unexpected]\ndir = \"/outside\"" };
        foreach (string path in unsafe) {
            FileUtils.set_contents (metadata, prefix + path + "\n");
            try { Dc.AccountBackup.validate_layout (root); assert_not_reached (); } catch (Error e) { }
        }
    } catch (Error e) { Test.fail_printf ("%s", e.message); }
    finally { if (root != null) { try { backup_test_cleanup (File.new_for_path (root)); } catch (Error e) { Test.fail (); } } }
}

void register_account_backup_tests () {
    Test.add_func ("/backup/account-metadata", test_backup_account_paths);
    Test.add_func ("/backup/real-core-roundtrip", test_backup_core);
}

private async void backup_ui_async (string server, string root) throws Error {
    string source = Path.build_filename (root, "accounts");
    var settings = new Dc.SettingsManager ();
    settings.save_rpc_server_path (server);
    settings.save_rpc_server_source (Dc.RpcServerSource.CUSTOM);
    settings.save_accounts_path (source);
    var key = new KeyFile ();
    key.load_from_file (Dc.SettingsManager.get_config_path (), KeyFileFlags.NONE);
    key.set_boolean ("General", "rpc_check_updates_on_startup", false);
    key.save_to_file (Dc.SettingsManager.get_config_path ());
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    app.register (null);
    var window = new Dc.Window (app);
    window.present ();
    try {
        for (int i = 0; i < 100 && !app.rpc.is_connected; i++) yield nap (50);
        assert_true (app.rpc.is_connected);
        yield nap (200);
        // Settings and restore are available before creating the first account.
        var preferences = new Dc.SettingsDialog (window, app.rpc);
        preferences.present (window);
        yield nap (100);
        var row = search_widget (preferences, typeof (Adw.ActionRow), "Restore Backup…") as Adw.ActionRow;
        // search_widget matches labels, so locate the row through its label.
        if (row == null) {
            var label = search_widget (preferences, typeof (Gtk.Label), "Restore Backup…");
            assert_true (label != null);
            row = label.get_ancestor (typeof (Adw.ActionRow)) as Adw.ActionRow;
        }
        assert_true (row != null);
        row.activated ();
        yield nap (100);
        var dialog = window.get_visible_dialog ();
        assert_true (dialog is Dc.BackupDialog);
        assert_cmpstr (dialog.title, CompareOperator.EQ, "Restore Encrypted Backup");
        var paintable = new Gtk.WidgetPaintable (window);
        var snapshot = new Gtk.Snapshot ();
        paintable.snapshot (snapshot, window.get_width (), window.get_height ());
        var node = snapshot.free_to_node ();
        if (node != null) window.get_renderer ().render_texture (node, null).save_to_png (Path.build_filename (root, "backup-dialog.png"));
        dialog.close ();
        yield nap (100);
        int id = yield app.rpc.add_account ();
        yield app.rpc.call ("set_config", Dc.Params.begin ().add_int (id).add_string ("addr").add_string ("ui@example.invalid").build ());
        var backups = new SafeStore.Backups ();
        var secret = new SafeStore.SecretValue ("UI test disposable password");
        string zip = Path.build_filename (root, "ui.zip");
        yield window.create_account_backup (backups, zip, secret, new Cancellable ());
        assert_true (app.rpc.is_connected);
        assert_false (window.backup_busy);
        string restored = Path.build_filename (root, "restored");
        yield backups.restore (zip, restored, secret);
        yield window.use_restored_accounts (restored);
        assert_cmpstr (window.settings.effective_accounts_path (), CompareOperator.EQ, restored);
        assert_cmpstr (yield app.rpc.get_config ("addr", id), CompareOperator.EQ, "ui@example.invalid");
        settings.load ();
        assert_cmpstr (settings.effective_accounts_path (), CompareOperator.EQ, restored);
        assert_true (FileUtils.test (Path.build_filename (source, "accounts.toml"), FileTest.IS_REGULAR));
        yield app.rpc.stop_gracefully ();
        secret.clear ();
        stdout.printf ("Settings restore before first account, coordinated backup, reconnect, restore switch, and durable preference: OK\n");
    } finally { app.rpc.stop (); window.destroy (); }
}

public int run_backup_ui_test (string server, string root) {
    // Caller supplies isolated XDG directories and an empty fixture root.
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var loop = new MainLoop (); Error? failure = null;
    backup_ui_async.begin (server, root, (obj, result) => {
        try { backup_ui_async.end (result); } catch (Error e) { failure = e; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) { stderr.printf ("Backup UI: %s\n", failure.message); return 1; }
    return 0;
}
