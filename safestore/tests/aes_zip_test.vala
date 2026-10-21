// The shared native codec is exercised on every desktop platform, including
// Windows where the higher-level Store lifecycle remains gated.
private void test_aes_snapshot () {
    string? root = null;
    try {
        root = DirUtils.make_tmp ("safestore-aes-codec-XXXXXX");
        string source = Path.build_filename (root, "accounts");
        string zip = Path.build_filename (root, "store.zip");
        string output = Path.build_filename (root, "restored");
        DirUtils.create_with_parents (Path.build_filename (source, "one", "blobs"), 0700);
        DirUtils.create_with_parents (Path.build_filename (source, "two", "empty"), 0700);
        FileUtils.set_contents (Path.build_filename (source, "accounts.toml"), "manager metadata");
        FileUtils.set_contents (Path.build_filename (source, "one", "dc.db"), "first database");
        FileUtils.set_contents (Path.build_filename (source, "one", "dc.db-wal"), "uncheckpointed data");
        FileUtils.set_contents (Path.build_filename (source, "one", "blobs", "private-name.txt"), "attachment");
        FileUtils.set_contents (Path.build_filename (source, "two", "dc.db"), "second database");
        FileUtils.set_contents (Path.build_filename (source, "accounts.lock"), "runtime lock excluded");
        string id = Uuid.string_random ();
        var codec = new SafeStore.ArchiveSnapshot (1024 * 1024, id, 7);
        var secret = new SafeStore.SecretValue ("unicode café 密碼\nwith a newline");
        var info = codec.write (source, zip, secret.peek ());
        assert_cmpuint (info.files, CompareOperator.EQ, 5);
        SafeStore.ArchiveSnapshot.inspect_store (zip);
        var archive = new SafeStore.Archive (zip, false, secret.peek (), null);
        for (uint64 i = 0; i < archive.count (); i++) {
            string name = archive.name (i);
            assert_true (name == "store.ini" || Regex.match_simple ("^data/[0-9]{8}$", name));
            archive.size (name); // Requires AES-256 on every member; read() authenticates.
        }
        archive = null;
        SafeStore.Archive.make_private_directory (output);
        codec.read (zip, secret.peek (), output);
        string contents;
        FileUtils.get_contents (Path.build_filename (output, "one", "dc.db-wal"), out contents);
        assert_cmpstr (contents, CompareOperator.EQ, "uncheckpointed data");
        FileUtils.get_contents (Path.build_filename (output, "one", "blobs", "private-name.txt"), out contents);
        assert_cmpstr (contents, CompareOperator.EQ, "attachment");
        assert_true (FileUtils.test (Path.build_filename (output, "two", "empty"), FileTest.IS_DIR));
        assert_false (FileUtils.test (Path.build_filename (output, "accounts.lock"), FileTest.EXISTS));

        // A backup, another store, and an older generation cannot substitute for this store.
        var other = new SafeStore.ArchiveSnapshot (1024 * 1024, Uuid.string_random (), 7);
        try { other.read (zip, secret.peek (), null); assert_not_reached (); }
        catch (SafeStore.StoreError.RECOVERY_REQUIRED error) { }
        other = new SafeStore.ArchiveSnapshot (1024 * 1024, id, 8);
        try { other.read (zip, secret.peek (), null); assert_not_reached (); }
        catch (SafeStore.StoreError.RECOVERY_REQUIRED error) { }
        var backup = new SafeStore.ArchiveSnapshot (1024 * 1024);
        try { backup.read (zip, secret.peek (), null); assert_not_reached (); } catch (Error error) { }
        string portable = Path.build_filename (root, "backup.zip");
        backup.write (source, portable, secret.peek ());
        try { SafeStore.ArchiveSnapshot.inspect_store (portable); assert_not_reached (); } catch (Error error) { }
        try { codec.read (portable, secret.peek (), null); assert_not_reached (); } catch (Error error) { }
        try { SafeStore.ZipFormat.validate (zip); assert_not_reached (); } catch (Error error) { }
        secret.clear ();
    } catch (Error error) { Test.fail_printf ("AES codec: %s", error.message); }
    finally { if (root != null) { try { remove_test_tree (File.new_for_path (root)); } catch (Error error) { Test.fail (); } } }
}

private async void aes_store_failures () throws Error {
    string root = DirUtils.make_tmp ("safestore-aes-failures-XXXXXX");
    string accounts = Path.build_filename (root, "accounts");
    string zip = accounts + ".aes.zip";
    var options = new SafeStore.StoreOptions ();
    options.maximum_archive_bytes = 16;
    options.zip_binary = options.unzip_binary = "/missing/not-needed";
    var store = new SafeStore.Store (accounts, zip, SafeStore.BackendKind.ZIP_AES, options);
    if (!(yield store.probe ()).available) { Test.skip ("AES store lifecycle unavailable"); remove_test_tree (File.new_for_path (root)); return; }
    var secret = new SafeStore.SecretValue ("native password with 密碼 and\nnewline");
    try {
        var cancelled = new Cancellable (); cancelled.cancel ();
        try { yield store.create_empty (secret, cancelled); assert_not_reached (); } catch (IOError.CANCELLED error) { }
        assert_false (FileUtils.test (zip, FileTest.EXISTS));
        assert_false (FileUtils.test (accounts, FileTest.EXISTS));
        var session = yield store.create_empty (secret);
        // Empty stores really round-trip, before account creation.
        yield store.lock ();
        yield store.unlock (secret);
        string payload = Path.build_filename (accounts, "dc.db");
        FileUtils.set_contents (payload, "original");
        yield store.lock ();
        session = yield store.unlock (secret);
        string before = archive_digest (zip);
        FileUtils.set_contents (payload, "too much data for the configured size limit");
        try { yield store.lock (); assert_not_reached (); } catch (IOError.NO_SPACE error) { }
        assert_true (session.active);
        assert_cmpstr (archive_digest (zip), CompareOperator.EQ, before);
        string contents;
        FileUtils.get_contents (payload, out contents);
        assert_true (contents.has_prefix ("too much data"));
        assert_false ((yield store.inspect ()).recovery_required);
        FileUtils.set_contents (payload, "repaired");
        yield store.lock ();
        uint8[] original;
        FileUtils.get_data (zip, out original);
        string metadata_text;
        FileUtils.get_contents (store.metadata_path, out metadata_text);
        var metadata = SafeStore.Metadata.load (Path.get_dirname (store.metadata_path));
        // Ciphertext substitution and tampering must not create plaintext output.
        for (int variant = 0; variant < 5; variant++) {
            if (variant == 0) {
                var damaged = original.copy ();
                damaged[64] ^= 0x80;
                FileUtils.set_data (zip, damaged);
            } else if (variant == 1) {
                FileUtils.set_data (zip, original[0:original.length / 2]);
            } else if (variant < 4) {
                metadata.id = variant == 2 ? Uuid.string_random () : session.store_id;
                if (variant == 3) metadata.generation++;
                metadata.save (Path.get_dirname (store.metadata_path));
            } else {
                // Valid AES ciphertext with data that disagrees with its manifest.
                var input = new SafeStore.Archive (zip, false, secret.peek (), null);
                string manifest = input.read_text ("store.ini", 65536);
                input = null;
                string mismatch = Path.build_filename (root, "mismatch.zip");
                var output = new SafeStore.Archive (mismatch, true, secret.peek (), null);
                output.add_text ("store.ini", manifest);
                output.add_text ("data/00000000", "tampered");
                output.finish ();
                SafeStore.Archive.replace (mismatch, zip);
            }
            var candidate = yield SafeStore.Store.open_existing (accounts, options);
            try { yield candidate.unlock (secret); assert_not_reached (); } catch (Error error) { }
            assert_false (FileUtils.test (payload, FileTest.EXISTS));
            var children = Dir.open (root); string? name;
            while ((name = children.read_name ()) != null) assert_false (name.has_prefix (".safestore-unlock-"));
            FileUtils.set_data (zip, original);
            FileUtils.set_contents (store.metadata_path, metadata_text);
        }
        store = yield SafeStore.Store.open_existing (accounts, options);
        yield store.unlock (secret);
        FileUtils.get_contents (payload, out contents);
        assert_cmpstr (contents, CompareOperator.EQ, "repaired");
        yield store.lock ();
        before = archive_digest (zip);
        // Metadata loss cannot implicitly re-import a store with a fresh identity.
        FileUtils.unlink (store.metadata_path);
        assert_true ((yield store.inspect ()).recovery_required);
        try { yield store.unlock (secret); assert_not_reached (); }
        catch (SafeStore.StoreError.RECOVERY_REQUIRED error) { }
        assert_cmpstr (archive_digest (zip), CompareOperator.EQ, before);
    } finally {
        secret.clear ();
        try { remove_test_tree (File.new_for_path (root)); } catch (Error error) { Test.fail_printf ("Cleanup: %s", error.message); }
    }
}

private void test_aes_store_failures () {
    var loop = new MainLoop (); Error? failure = null;
    aes_store_failures.begin ((obj, result) => {
        try { aes_store_failures.end (result); } catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.fail_printf ("AES store: %s", failure.message);
}

void register_aes_zip_tests () {
    Test.add_func ("/aes-zip/portable-codec", test_aes_snapshot);
    Test.add_func ("/aes-zip/store-failures", test_aes_store_failures);
}
