private SafeStore.Settings test_settings () {
    string accounts = Path.build_filename (Environment.get_tmp_dir (), "safestore-unit-accounts");
    try { return new SafeStore.Settings (accounts, accounts + ".zip",
        SafeStore.BackendKind.CRYFS, new SafeStore.StoreOptions ()); }
    catch (Error error) { assert_not_reached (); }
}

private const string PASSWORD = "a-long-disposable-password";

private SafeStore.BackendInfo find_backend (SafeStore.Settings settings,
                                            string id) {
    foreach (SafeStore.BackendInfo info in SafeStore.Backends.list (settings)) {
        if (info.id == id) return info;
    }
    assert_not_reached ();
}

private void test_backend_listing () {
    var settings = test_settings ();
    var cryfs = find_backend (settings, "cryfs");
    var zip = find_backend (settings, "zip");
    var aes = find_backend (settings, "zip-aes");
    assert_true (cryfs.name.length > 0);
    assert_true (cryfs.protection.contains ("XChaCha20"));
    assert_true (zip.name.contains ("ZIP"));
    assert_true (zip.protection.contains ("Weak"));
    assert_true (zip.operation.contains ("plaintext"));
    assert_true (aes.protection.contains ("AES-256"));
    assert_true (aes.operation.contains ("plaintext"));
    assert_true (aes.kind == SafeStore.BackendKind.ZIP_AES);
    assert_false (aes.supports (SafeStore.Operation.CHANGE_BACKEND));
}

private void test_selection () {
    var settings = test_settings ();
    settings.backend = SafeStore.BackendKind.ZIP.id ();
    assert_true (settings.backend == "zip");
    assert_true (settings.vault_path.has_suffix (".zip"));
    try {
        assert_true (
            SafeStore.Backends.selected (settings).id == "zip");
    } catch (Error error) {
        Test.fail_printf ("Could not inspect selected backend: %s",
                          error.message);
    }
    try {
        assert_true (
            SafeStore.BackendKind.parse ("cryfs")
                == SafeStore.BackendKind.CRYFS);
    } catch (Error error) {
        Test.fail_printf ("Could not parse backend: %s", error.message);
    }
}

private void test_secret_value () {
    var secret = new SafeStore.SecretValue (PASSWORD);
    assert_true (secret.peek () == PASSWORD);
    secret.clear ();
    assert_true (secret.peek ().length == 0);
    // Repeated clearing must be harmless.
    secret.clear ();
}

private void test_zip_roundtrip () {
#if WINDOWS
    Test.skip ("private pseudo-terminal is not available on Windows");
#else
    string? root = null;
    try {
        root = DirUtils.make_tmp ("safestore-zip-test-XXXXXX");
        string accounts = Path.build_filename (root, "accounts");
        var settings = new SafeStore.Settings (accounts, accounts + ".zip",
            SafeStore.BackendKind.ZIP, new SafeStore.StoreOptions ());
        settings.backend = "zip";
        settings.secure_delete = false;
        var info = find_backend (settings, "zip");
        if (!info.available) {
            Test.skip (info.status);
            return;
        }

        SafeStore.ZipBackend.create (settings, PASSWORD);
        string account = Path.build_filename (accounts, "account-id");
        assert_true (DirUtils.create (account, 0700) == 0);
        FileUtils.set_contents (
            Path.build_filename (accounts, "accounts.toml"), "manifest\n");
        FileUtils.set_contents (
            Path.build_filename (account, "dc.db"), "database\n");

        bool rollback_safe = false;
        SafeStore.ZipBackend.lock (settings, PASSWORD, () => {}, ref rollback_safe);
        assert_true (FileUtils.test (
            settings.vault_path, FileTest.IS_REGULAR));
        Posix.Stat archive_info;
        assert_true (Posix.lstat (
            settings.vault_path, out archive_info) == 0);
        assert_true ((archive_info.st_mode & 0777) == 0600);
        assert_true (FileUtils.test (
            Path.build_filename (accounts, ".safestore-locked"),
            FileTest.IS_REGULAR));
        assert_true (!FileUtils.test (
            Path.build_filename (account, "dc.db"), FileTest.EXISTS));

        bool wrong_password_failed = false;
        try {
            SafeStore.ZipBackend.unlock (
                settings, "a-different-wrong-password", ref rollback_safe);
        } catch (Error error) {
            wrong_password_failed = true;
        }
        assert_true (wrong_password_failed);
        assert_true (FileUtils.test (
            Path.build_filename (accounts, ".safestore-locked"),
            FileTest.IS_REGULAR));
        assert_true (!FileUtils.test (
            Path.build_filename (account, "dc.db"), FileTest.EXISTS));
        var root_directory = Dir.open (root);
        string? root_entry;
        while ((root_entry = root_directory.read_name ()) != null) {
            assert_true (!root_entry.has_prefix (".safestore-unlock-"));
        }

        SafeStore.ZipBackend.unlock (settings, PASSWORD, ref rollback_safe);
        string restored;
        FileUtils.get_contents (
            Path.build_filename (account, "dc.db"), out restored);
        assert_true (restored == "database\n");

        SafeStore.PlaintextEraser.erase_tree (accounts, settings);
        FileUtils.unlink (settings.vault_path);
        assert_true (DirUtils.remove (root) == 0);
    } catch (Error error) {
        Test.fail_printf ("ZIP roundtrip failed: %s", error.message);
    }
#endif
}

private void test_overwrite_removal () {
#if WINDOWS
    Test.skip ("shred backend is unavailable on Windows");
#else
    string? root = null;
    try {
        var settings = test_settings ();
        settings.secure_delete = true;
        if (!SafeStore.PlaintextEraser.inspect (settings).shred_available) {
            Test.skip ("shred executable is unavailable");
            return;
        }
        root = DirUtils.make_tmp ("safestore-shred-test-XXXXXX");
        string secret = Path.build_filename (root, "secret");
        string alias = Path.build_filename (root, "alias");
        FileUtils.set_contents (secret, "disposable secret\n");
        assert_true (Posix.link (secret, alias) == 0);

        bool hardlink_rejected = false;
        try {
            SafeStore.PlaintextEraser.validate_tree (root, settings);
        } catch (Error error) {
            hardlink_rejected = true;
        }
        assert_true (hardlink_rejected);
        assert_true (FileUtils.test (secret, FileTest.IS_REGULAR));
        assert_true (FileUtils.unlink (alias) == 0);

        SafeStore.PlaintextEraser.erase_tree (root, settings);
        assert_true (!FileUtils.test (root, FileTest.EXISTS));
    } catch (Error error) {
        Test.fail_printf ("Overwrite-removal test failed: %s", error.message);
    }
#endif
}

void register_backend_tests () {
    Test.add_func ("/backends/listing", test_backend_listing);
    Test.add_func ("/backends/selection", test_selection);
    Test.add_func ("/backends/secret-value", test_secret_value);
    Test.add_func ("/backends/zip-roundtrip", test_zip_roundtrip);
    Test.add_func ("/backends/overwrite-removal", test_overwrite_removal);
}
