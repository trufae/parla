private void backup_remove_fixture (File file) throws Error {
    var info = file.query_info ("standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
    if (info.get_file_type () == FileType.DIRECTORY) {
        var children = file.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file ()) != null) backup_remove_fixture (file.get_child (child.get_name ()));
        children.close ();
    }
    file.delete ();
}

private async void backup_roundtrip () throws Error {
    assert_true (SafeStore.Backups.available);
    string root = DirUtils.make_tmp ("safestore-backup-test-XXXXXX");
    string source = Path.build_filename (root, "accounts");
    string zip = Path.build_filename (root, "backup.zip");
    string restored = Path.build_filename (root, "restored");
    DirUtils.create_with_parents (Path.build_filename (source, "one", "blobs"), 0700);
    DirUtils.create_with_parents (Path.build_filename (source, "two", "empty"), 0700);
    FileUtils.set_contents (Path.build_filename (source, "accounts.toml"), "two disposable accounts");
    FileUtils.set_contents (Path.build_filename (source, "one", "dc.db"), "first database");
    FileUtils.set_contents (Path.build_filename (source, "one", "dc.db-wal"), "must preserve WAL");
    FileUtils.set_contents (Path.build_filename (source, "one", "blobs", "image.png"), "attachment bytes");
    FileUtils.set_contents (Path.build_filename (source, "two", "dc.db"), "second database");
    FileUtils.set_contents (Path.build_filename (source, "accounts.lock"), "ignored runtime lock");
    var service = new SafeStore.Backups ();
    var secret = new SafeStore.SecretValue ("test-only strong backup password");
    try {
        try { yield service.validate_restore_destination (source, Path.build_filename (source, "nested")); assert_not_reached (); }
        catch (IOError.INVALID_ARGUMENT e) { }
        yield service.validate_restore_destination (source, restored);
        var info = yield service.create (source, zip, secret);
        assert_cmpuint (info.files, CompareOperator.EQ, 5);
        var verified = yield service.verify (zip, secret);
        assert_cmpuint (verified.files, CompareOperator.EQ, 5);
        var archive = new SafeStore.Archive (zip, false, secret.peek (), null);
        for (uint64 i = 0; i < archive.count (); i++) {
            string name = archive.name (i);
            assert_true (name == "manifest.ini" || name.has_prefix ("data/"));
            archive.size (name); // Requires AES-256 on every member.
        }
        archive = null;
        var restored_info = yield service.restore (zip, restored, secret);
        assert_cmpstr (restored_info.restored_path, CompareOperator.EQ, restored);
        string text;
        FileUtils.get_contents (Path.build_filename (restored, "one", "dc.db-wal"), out text);
        assert_cmpstr (text, CompareOperator.EQ, "must preserve WAL");
        FileUtils.get_contents (Path.build_filename (restored, "one", "blobs", "image.png"), out text);
        assert_cmpstr (text, CompareOperator.EQ, "attachment bytes");
        assert_true (FileUtils.test (Path.build_filename (restored, "two", "empty"), FileTest.IS_DIR));
        assert_false (FileUtils.test (Path.build_filename (restored, "accounts.lock"), FileTest.EXISTS));

        // Wrong passwords must not create even an empty restore folder.
        string wrong_target = Path.build_filename (root, "wrong-password");
        try { yield service.restore (zip, wrong_target, new SafeStore.SecretValue ("wrong")); assert_not_reached (); }
        catch (IOError e) { }
        assert_false (FileUtils.test (wrong_target, FileTest.EXISTS));

        // Never overwrite an existing backup or directory; preserve both copies.
        uint8[] original;
        FileUtils.get_data (zip, out original);
        try { yield service.create (source, zip, secret); assert_not_reached (); } catch (IOError e) { }
        uint8[] after;
        FileUtils.get_data (zip, out after);
        assert_true (original.length == after.length);
        assert_true (Memory.cmp (original, after, original.length) == 0);
        try { yield service.restore (zip, restored, secret); assert_not_reached (); } catch (IOError e) { }
        yield service.verify (zip, secret);

        var cancelled = new Cancellable (); cancelled.cancel ();
        try { yield service.create (source, Path.build_filename (root, "cancelled.zip"), secret, cancelled); assert_not_reached (); }
        catch (IOError.CANCELLED e) { }
        assert_false (FileUtils.test (Path.build_filename (root, "cancelled.zip"), FileTest.EXISTS));

        // Core's exclusive lock blocks a snapshot, independent of UI cooperation.
        var lease = new SafeStore.Lease (Path.build_filename (source, "accounts.lock"));
        try { yield service.create (source, Path.build_filename (root, "busy.zip"), secret); assert_not_reached (); }
        catch (IOError e) { }
        assert_false (FileUtils.test (Path.build_filename (root, "busy.zip"), FileTest.EXISTS));
        lease = null;
        service.maximum_restore_bytes = 1;
        try { yield service.verify (zip, secret); assert_not_reached (); } catch (IOError.NO_SPACE e) { }
        service.maximum_restore_bytes = 1024 * 1024;

        // A central directory that still opens must not hide damaged encrypted data.
        uint8[] damaged;
        FileUtils.get_data (zip, out damaged);
        damaged[64] ^= 0x80;
        string broken = Path.build_filename (root, "damaged.zip");
        FileUtils.set_data (broken, damaged);
        try { yield service.verify (broken, secret); assert_not_reached (); } catch (Error e) { }
        FileUtils.set_data (broken, damaged[0:damaged.length / 2]);
        try { yield service.verify (broken, secret); assert_not_reached (); } catch (Error e) { }
        FileUtils.get_contents (Path.build_filename (source, "one", "dc.db"), out text);
        assert_cmpstr (text, CompareOperator.EQ, "first database");
        // Cancellation while compression is running must not publish a partial ZIP.
        service.maximum_restore_bytes = 64 * 1024 * 1024;
        var large = new uint8[8 * 1024 * 1024];
        for (int i = 0; i < large.length; i++) large[i] = (uint8) (i % 251);
        FileUtils.set_data (Path.build_filename (source, "large"), large);
        var during = new Cancellable ();
        ulong progress_id = service.progress.connect ((phase, done, total) => {
            if (phase == "encrypt") during.cancel ();
        });
        try { yield service.create (source, Path.build_filename (root, "interrupted.zip"), secret, during); assert_not_reached (); }
        catch (IOError.CANCELLED e) { }
        service.disconnect (progress_id);
        assert_false (FileUtils.test (Path.build_filename (root, "interrupted.zip"), FileTest.EXISTS));
#if !WINDOWS
        // Resolve directory aliases before testing whether output is inside the store.
        string alias = Path.build_filename (root, "alias");
        File.new_for_path (alias).make_symbolic_link (source);
        try { yield service.create (source, Path.build_filename (alias, "inside.zip"), secret); assert_not_reached (); }
        catch (IOError.INVALID_ARGUMENT e) { }
        assert_false (FileUtils.test (Path.build_filename (source, "inside.zip"), FileTest.EXISTS));
        FileUtils.unlink (alias);
        File.new_for_path (Path.build_filename (source, "linked")).make_symbolic_link (zip);
        try { yield service.create (source, Path.build_filename (root, "linked.zip"), secret); assert_not_reached (); }
        catch (IOError.INVALID_DATA e) { }
#endif
    } finally { secret.clear (); try { backup_remove_fixture (File.new_for_path (root)); } catch (Error e) { Test.fail_printf ("Cleanup: %s", e.message); } }
}

private async void backup_bad_manifest () throws Error {
    string root = DirUtils.make_tmp ("safestore-backup-malformed-XXXXXX");
    var secret = new SafeStore.SecretValue ("test password");
    var service = new SafeStore.Backups ();
    string[] paths = { "../escape", "/absolute", "C:/drive", "foo\\bar", "NUL.txt", "a/../../escape", "trailing.", "file:stream", "COM¹.txt", "CONOUT$", "ACCOUNTS.LOCK" };
    try {
        for (uint i = 0; i < paths.length; i++) {
            string zip = Path.build_filename (root, "%u.zip".printf (i));
            var key = new KeyFile ();
            key.set_integer ("Backup", "version", 1);
            key.set_string ("Backup", "created", "2026-01-01T00:00:00Z");
            key.set_integer ("Backup", "entries", 1);
            key.set_string ("Entry0", "path", paths[i]);
            key.set_boolean ("Entry0", "directory", true);
            key.set_uint64 ("Entry0", "size", 0);
            key.set_string ("Entry0", "sha256", "");
            var archive = new SafeStore.Archive (zip, true, secret.peek (), null);
            archive.add_text ("manifest.ini", key.to_data ()); archive.finish ();
            try { yield service.restore (zip, Path.build_filename (root, "output"), secret); assert_not_reached (); }
            catch (IOError.INVALID_DATA e) { }
            assert_false (FileUtils.test (Path.build_filename (root, "output"), FileTest.EXISTS));
        }
        for (int variant = 0; variant < 3; variant++) {
            string zip = Path.build_filename (root, "variant-%d.zip".printf (variant));
            var key = new KeyFile ();
            key.set_integer ("Backup", "version", 1);
            key.set_string ("Backup", "created", "2026-01-01T00:00:00Z");
            key.set_integer ("Backup", "entries", variant == 0 ? 2 : 1);
            for (int i = 0; i < (variant == 0 ? 2 : 1); i++) {
                string group = "Entry%d".printf (i);
                key.set_string (group, "path", variant == 0 ? (i == 0 ? "Foo" : "foo") : "dc.db");
                key.set_boolean (group, "directory", variant == 0);
                key.set_uint64 (group, "size", variant == 0 ? 0 : 3);
                key.set_string (group, "sha256", variant == 0 ? "" : string.nfill (64, '0'));
            }
            var archive = new SafeStore.Archive (zip, true, secret.peek (), null);
            archive.add_text ("manifest.ini", key.to_data ());
            if (variant == 2) archive.add_text ("data/00000000", "abc");
            archive.finish ();
            try { yield service.restore (zip, Path.build_filename (root, "output"), secret); assert_not_reached (); }
            catch (IOError.INVALID_DATA e) { }
            assert_false (FileUtils.test (Path.build_filename (root, "output"), FileTest.EXISTS));
        }
        string plain = Path.build_filename (root, "plain.zip");
        FileUtils.set_data (plain, Base64.decode ("UEsDBBQAAAAAAJJpU11pFXARDQAAAA0AAAAMAAAAbWFuaWZlc3QuaW5pbm90IGVuY3J5cHRlZFBLAQIUAxQAAAAAAJJpU11pFXARDQAAAA0AAAAMAAAAAAAAAAAAAACAAQAAAABtYW5pZmVzdC5pbmlQSwUGAAAAAAEAAQA6AAAANwAAAAAA"));
        try { yield service.verify (plain, secret); assert_not_reached (); } catch (IOError.INVALID_DATA e) { }
    } finally { secret.clear (); try { backup_remove_fixture (File.new_for_path (root)); } catch (Error e) { Test.fail_printf ("Cleanup: %s", e.message); } }
}

private void test_backup_roundtrip () {
    var loop = new MainLoop ();
    Error? failure = null;
    backup_roundtrip.begin ((obj, result) => {
        try { backup_roundtrip.end (result); } catch (Error e) { failure = e; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.message ("%s", failure.message);
    assert_true (failure == null);
}

private void test_backup_bad_manifest () {
    var loop = new MainLoop (); Error? failure = null;
    backup_bad_manifest.begin ((obj, result) => {
        try { backup_bad_manifest.end (result); } catch (Error e) { failure = e; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.message ("%s", failure.message);
    assert_true (failure == null);
}

void register_backup_tests () {
    Test.add_func ("/backup/roundtrip-and-failures", test_backup_roundtrip);
    Test.add_func ("/backup/reject-unsafe-manifests", test_backup_bad_manifest);
}
