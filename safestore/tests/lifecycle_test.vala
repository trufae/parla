private string lifecycle_executable;

private void remove_test_tree (File file) throws Error {
    var info = file.query_info ("standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
    if (info.get_file_type () == FileType.DIRECTORY) {
        var children = file.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file ()) != null) remove_test_tree (file.get_child (child.get_name ()));
        children.close ();
    }
    file.delete ();
}

private string archive_digest (string path) throws Error {
    uint8[] contents;
    FileUtils.get_data (path, out contents);
    return Checksum.compute_for_data (ChecksumType.SHA256, contents);
}

private void test_mount_identity () {
    try {
        string root = DirUtils.make_tmp ("safestore-mount-XXXXXX");
        string accounts = Path.build_filename (root, "accounts");
        string storage = Path.build_filename (root, "vault");
        DirUtils.create (accounts, 0700);
        string line = "25 1 0:42 / %s rw - fuse.cryfs cryfs@%s rw\n".printf (accounts, storage);
        var info = SafeStore.MountCheck.parse_linux (line, accounts);
        assert_nonnull (info);
        assert_true (info.matches (storage));
        assert_false (info.matches (storage + "-other"));
        assert_false (new SafeStore.MountInfo ("", "", "existing-drive").matches (storage));
        assert_false (new SafeStore.MountInfo ("cryfs@" + storage, "tmpfs", "25").matches (storage));
        try { SafeStore.MountCheck.parse_linux (line + line, accounts); assert_not_reached (); }
        catch (SafeStore.StoreError.RECOVERY_REQUIRED error) { }
        try { SafeStore.MountCheck.parse_linux ("invalid\n", accounts); assert_not_reached (); }
        catch (IOError.INVALID_DATA error) { }
        var mac = SafeStore.MountCheck.parse_macos ("cryfs@%s on %s (macfuse, local)\n".printf (storage, accounts), accounts);
        assert_nonnull (mac);
        assert_true (mac.matches (storage));
        remove_test_tree (File.new_for_path (root));
    } catch (Error error) { Test.fail_printf ("Mount identity: %s", error.message); }
}

private void test_shared_precedence () {
    assert_true (SafeStore.AccountsLocation.resolve (" /env/accounts/ ", "/configured", "/default") == "/env/accounts");
    assert_true (SafeStore.AccountsLocation.resolve ("  ", "/configured/", "/default") == "/configured");
    assert_true (SafeStore.AccountsLocation.resolve (null, "", "/default/") == "/default");
    assert_true (SafeStore.AccountsLocation.normalize (" X:\\ ") == "X:\\");
}

private void test_native_lease () {
    try {
        string root = DirUtils.make_tmp ("safestore-lease-XXXXXX");
        string path = Path.build_filename (root, "owner.lock");
        SafeStore.Lease? owner = new SafeStore.Lease (path);
        try { new SafeStore.Lease (path); assert_not_reached (); }
        catch (Error error) { assert_true (error is IOError.WOULD_BLOCK || error is IOError.BUSY); }
        var child = new Subprocess (SubprocessFlags.NONE, lifecycle_executable, "--probe-lease", path);
        child.wait ();
        assert_cmpint (child.get_exit_status (), CompareOperator.EQ, 3);
        owner = null;
        child = new Subprocess (SubprocessFlags.NONE, lifecycle_executable, "--probe-lease", path);
        child.wait ();
        assert_true (child.get_successful ());
        remove_test_tree (File.new_for_path (root));
    } catch (Error error) { Test.fail_printf ("Lease: %s", error.message); }
}

private async void test_sessions (SafeStore.BackendKind kind = SafeStore.BackendKind.ZIP) throws Error {
    string root = DirUtils.make_tmp ("safestore-session-XXXXXX");
    string accounts = Path.build_filename (root, "accounts");
    string storage = Path.build_filename (root, "store.zip");
    var store = new SafeStore.Store (accounts, storage, kind);
    if (!(yield store.probe ()).available) { Test.skip ("ZIP runtime unavailable"); remove_test_tree (File.new_for_path (root)); return; }
    var secret = new SafeStore.SecretValue ("disposable lifecycle password");
    var session = yield store.create_empty (secret);
    assert_true (session.active);
    assert_true (Uuid.string_is_valid (session.store_id));
    var status = yield store.inspect ();
    assert_true (status.has_metadata && status.session_owned && !status.recovery_required);
    var competitor = new SafeStore.Store (accounts, storage, kind);
    try { yield competitor.unlock (secret); assert_not_reached (); }
    catch (SafeStore.StoreError.BUSY error) { }
    var child = new Subprocess (SubprocessFlags.NONE, lifecycle_executable, "--probe-lease",
        Path.build_filename (Path.get_dirname (store.metadata_path), "owner.lock"));
    yield child.wait_async ();
    assert_cmpint (child.get_exit_status (), CompareOperator.EQ, 3);
    FileUtils.set_contents (Path.build_filename (accounts, "payload"), "complete account fixture");
    // No second password prompt is needed, and a changed password cannot replace it.
    var wrong = new SafeStore.SecretValue ("different password");
    try { yield store.lock (wrong); assert_not_reached (); }
    catch (SafeStore.StoreError.INVALID_ARGUMENT error) { }
    // Delta Chat's additional guard must keep a failed lock retryable.
    SafeStore.Lease? writer = new SafeStore.Lease (Path.build_filename (accounts, "accounts.lock"));
    bool refused = false;
    try { yield store.lock (); }
    catch (Error error) { refused = true; }
    assert_true (refused && session.active);
    status = yield store.inspect ();
    assert_true (status.session_owned && !status.recovery_required);
    writer = null;
    yield store.lock ();
    assert_false (session.active);
    assert_true (session.secret.peek () == "");
    var saved = yield SafeStore.Store.open_existing (accounts);
    assert_nonnull (saved);
    assert_true (saved.backend == kind && saved.storage_path == store.storage_path);
    status = yield saved.inspect ();
    assert_true (status.store_id == session.store_id && status.generation > session.generation);
    try { yield saved.unlock (wrong); assert_not_reached (); }
    catch (SafeStore.StoreError.WRONG_PASSWORD error) { }
    status = yield saved.inspect ();
    assert_false (status.recovery_required);
    yield saved.unlock (secret);
    yield saved.lock ();
    yield saved.lock (); // Idempotent, with ownership and state rechecked.
    // Another candidate must not be selected by changing a global preference.
    DirUtils.create (accounts + ".vault", 0700);
    string before = archive_digest (storage);
    try { yield saved.unlock (secret); assert_not_reached (); }
    catch (SafeStore.StoreError.RECOVERY_REQUIRED error) { }
    assert_true (archive_digest (storage) == before);
    status = yield saved.inspect ();
    assert_true (status.recovery_required);
    secret.clear ();
    wrong.clear ();
    remove_test_tree (File.new_for_path (root));
}

private async void test_lost_directory (SafeStore.BackendKind kind = SafeStore.BackendKind.ZIP) throws Error {
    string root = DirUtils.make_tmp ("safestore-loss-XXXXXX");
    string accounts = Path.build_filename (root, "accounts");
    var store = new SafeStore.Store (accounts, accounts + ".zip", kind);
    if (!(yield store.probe ()).available) { Test.skip ("ZIP runtime unavailable"); remove_test_tree (File.new_for_path (root)); return; }
    var secret = new SafeStore.SecretValue ("disposable lifecycle password");
    var session = yield store.create_empty (secret);
    bool reported = false;
    SourceFunc resume = test_lost_directory.callback;
    session.access_lost.connect ((message) => { reported = true; resume (); });
    assert_true (FileUtils.rename (accounts, accounts + "-preserved") == 0);
    yield;
    assert_true (reported && !session.active);
    assert_true (FileUtils.test (accounts + "-preserved", FileTest.IS_DIR));
    string before = archive_digest (accounts + ".zip");
    try { yield store.lock (); assert_not_reached (); }
    catch (SafeStore.StoreError.RECOVERY_REQUIRED error) { }
    assert_true (archive_digest (accounts + ".zip") == before);
    var status = yield store.inspect ();
    assert_true (status.recovery_required);
    secret.clear ();
    remove_test_tree (File.new_for_path (root));
}

private async void crash_during_cleanup (string root, SafeStore.BackendKind kind) throws Error {
    string accounts = Path.build_filename (root, "accounts");
    var options = new SafeStore.StoreOptions ();
    options.secure_delete = true;
    options.shred_binary = Path.build_filename (root, "crash-shred");
    var store = new SafeStore.Store (accounts, accounts + ".zip", kind, options);
    var secret = new SafeStore.SecretValue ("disposable lifecycle password");
    yield store.create_empty (secret);
    FileUtils.set_contents (Path.build_filename (accounts, "first"), "first complete account");
    FileUtils.set_contents (Path.build_filename (accounts, "second"), "second complete account");
    yield store.lock ();
    assert_not_reached ();
}

private async void test_interrupted_cleanup (SafeStore.BackendKind kind = SafeStore.BackendKind.ZIP) throws Error {
#if WINDOWS
    Test.skip ("ZIP is unavailable on Windows");
#else
    string root = DirUtils.make_tmp ("safestore-crash-XXXXXX");
    string accounts = Path.build_filename (root, "accounts");
    string storage = accounts + ".zip";
    var store = new SafeStore.Store (accounts, storage, kind);
    if (!(yield store.probe ()).available) { Test.skip ("ZIP runtime unavailable"); remove_test_tree (File.new_for_path (root)); return; }
    string tool = Path.build_filename (root, "crash-shred");
    // Only the disposable child that invokes this helper is killed.
    FileUtils.set_contents (tool, "#!/bin/sh\nkill -KILL \"$PPID\"\nexit 1\n");
    FileUtils.chmod (tool, 0700);
    var child = new Subprocess (SubprocessFlags.NONE, lifecycle_executable, "--crash-cleanup", root, kind.id ());
    yield child.wait_async ();
    assert_false (child.get_successful ());
    var metadata = SafeStore.Metadata.load (Path.get_dirname (store.metadata_path));
    assert_nonnull (metadata);
    assert_true (metadata.phase == "cleanup");
    // Model a partly deleted working tree left after the complete archive commit.
    FileUtils.unlink (Path.build_filename (accounts, "first"));
    string before = archive_digest (storage);
    var status = yield store.inspect ();
    assert_true (status.recovery_required && status.plaintext_exposed);
    var secret = new SafeStore.SecretValue ("disposable lifecycle password");
    try { yield store.lock (secret); assert_not_reached (); }
    catch (SafeStore.StoreError.RECOVERY_REQUIRED error) { }
    try { yield store.unlock (secret); assert_not_reached (); }
    catch (SafeStore.StoreError.RECOVERY_REQUIRED error) { }
    assert_true (archive_digest (storage) == before);
    // Validate the retained archive in a separate disposable destination.
    string recovered = Path.build_filename (root, "recovered");
    var settings = new SafeStore.Settings (recovered, storage, kind, new SafeStore.StoreOptions ());
    bool rollback_safe = false;
    if (kind == SafeStore.BackendKind.ZIP_AES) SafeStore.AesZipBackend.unlock (settings, metadata, secret.peek (), ref rollback_safe);
    else SafeStore.ZipBackend.unlock (settings, secret.peek (), ref rollback_safe);
    string contents;
    FileUtils.get_contents (Path.build_filename (recovered, "first"), out contents);
    assert_true (contents == "first complete account");
    FileUtils.get_contents (Path.build_filename (recovered, "second"), out contents);
    assert_true (contents == "second complete account");
    secret.clear ();
    remove_test_tree (File.new_for_path (root));
#endif
}

private async void lifecycle_case (int index) throws Error {
    if (index == 0) yield test_sessions ();
    else if (index == 1) yield test_lost_directory ();
    else if (index == 2) yield test_interrupted_cleanup ();
    else if (index == 3) yield test_legacy_and_metadata ();
    else if (index == 4) yield test_sessions (SafeStore.BackendKind.ZIP_AES);
    else if (index == 5) yield test_lost_directory (SafeStore.BackendKind.ZIP_AES);
    else yield test_interrupted_cleanup (SafeStore.BackendKind.ZIP_AES);
}

private async void test_legacy_and_metadata () throws Error {
    string root = DirUtils.make_tmp ("safestore-legacy-XXXXXX");
    string accounts = Path.build_filename (root, "accounts");
    string storage = accounts + ".zip";
    var store = new SafeStore.Store (accounts, storage, SafeStore.BackendKind.ZIP);
    if (!(yield store.probe ()).available) { Test.skip ("ZIP runtime unavailable"); remove_test_tree (File.new_for_path (root)); return; }
    var settings = new SafeStore.Settings (accounts, storage, SafeStore.BackendKind.ZIP, new SafeStore.StoreOptions ());
    // Old layouts have ciphertext but no per-store metadata.
    SafeStore.ZipBackend.create (settings, PASSWORD);
    FileUtils.set_contents (Path.build_filename (accounts, "payload"), "legacy account data");
    bool rollback_safe = false;
    SafeStore.ZipBackend.lock (settings, PASSWORD, () => {}, ref rollback_safe);
    string digest = archive_digest (storage);
    FileUtils.set_contents (Path.build_filename (accounts, "conflict"), "preserve this plaintext");
    var status = yield store.inspect ();
    assert_true (status.recovery_required);
    var secret = new SafeStore.SecretValue (PASSWORD);
    try { yield store.unlock (secret); assert_not_reached (); }
    catch (SafeStore.PathPolicyError.NOT_EMPTY error) { }
    assert_true (archive_digest (storage) == digest);
    assert_false (FileUtils.test (store.metadata_path, FileTest.EXISTS));
    FileUtils.unlink (Path.build_filename (accounts, "conflict"));
    // A marker name alone must never authorize deleting arbitrary data.
    string marker = Path.build_filename (accounts, ".safestore-locked");
    string original;
    FileUtils.get_contents (marker, out original);
    FileUtils.set_contents (marker, "unrelated user data");
    try { yield store.unlock (secret); assert_not_reached (); }
    catch (SafeStore.PathPolicyError.NOT_EMPTY error) { }
    assert_true (archive_digest (storage) == digest);
    FileUtils.set_contents (marker, original);
    yield store.unlock (secret);
    yield store.lock ();
    digest = archive_digest (storage);
    var metadata = new KeyFile ();
    metadata.load_from_file (store.metadata_path, KeyFileFlags.NONE);
    metadata.set_integer ("Store", "schema", 999);
    metadata.save_to_file (store.metadata_path);
    status = yield store.inspect ();
    assert_true (status.recovery_required);
    try { yield store.unlock (secret); assert_not_reached (); }
    catch (SafeStore.StoreError.NOT_SUPPORTED error) { }
    assert_true (archive_digest (storage) == digest);
    secret.clear ();
    remove_test_tree (File.new_for_path (root));
}

private void test_zip_recognition () {
#if WINDOWS
    Test.skip ("ZIP runtime unavailable on Windows");
#else
    try {
        string root = DirUtils.make_tmp ("safestore-format-XXXXXX");
        string accounts = Path.build_filename (root, "accounts");
        var settings = new SafeStore.Settings (accounts, accounts + ".zip", SafeStore.BackendKind.ZIP, new SafeStore.StoreOptions ());
        if (!SafeStore.Backends.selected (settings).available) { Test.skip ("ZIP runtime unavailable"); remove_test_tree (File.new_for_path (root)); return; }
        SafeStore.ZipBackend.create (settings, PASSWORD);
        assert_true (SafeStore.ZipBackend.is_encrypted (settings));
        uint8[] original;
        FileUtils.get_data (settings.vault_path, out original);
        uint8[] damaged = original.copy ();
        // Changing only the local encryption flag must disagree with the directory.
        damaged[6] = 0;
        FileUtils.set_data (settings.vault_path, damaged);
        assert_false (SafeStore.ZipBackend.is_encrypted (settings));
        // Reject ZIP64 rather than truncate sizes/entry counts.
        damaged = original.copy ();
        damaged[damaged.length - 12] = 0xff;
        damaged[damaged.length - 11] = 0xff;
        FileUtils.set_data (settings.vault_path, damaged);
        assert_false (SafeStore.ZipBackend.is_encrypted (settings));
        FileUtils.unlink (settings.vault_path);
        // An ordinary ZIP with a forged SafeStore marker is still unencrypted.
        string marker = Path.build_filename (root, ".safestore-zip-marker-fake");
        FileUtils.set_contents (marker, "SafeStore ZIP backend v1\n");
        var launcher = new SubprocessLauncher (SubprocessFlags.NONE);
        launcher.set_cwd (root);
        var zip = launcher.spawnv ({ settings.zip_binary, "-qr", settings.vault_path, ".safestore-zip-marker-fake", "accounts" });
        zip.wait_check ();
        assert_false (SafeStore.ZipBackend.is_encrypted (settings));
        remove_test_tree (File.new_for_path (root));
    } catch (Error error) { Test.fail_printf ("ZIP recognition: %s", error.message); }
#endif
}

private void test_backend_requirements () {
    try {
        assert_true (SafeStore.Backends.stable_cryfs_version ("CryFS Version 1.0.3\n") == "1.0.3");
        foreach (string version in new string[] { "CryFS Version 0.11.4", "CryFS Version 1.0.3-alpha", "CryFS Version 2.0.0" }) {
            try { SafeStore.Backends.stable_cryfs_version (version); assert_not_reached (); }
            catch (SafeStore.StoreError.NOT_SUPPORTED error) { }
        }
#if !WINDOWS
        string root = DirUtils.make_tmp ("safestore-tools-XXXXXX");
        var settings = new SafeStore.Settings (root + "/accounts", root + "/vault", SafeStore.BackendKind.CRYFS, new SafeStore.StoreOptions ());
        settings.cryfs_binary = root + "/cryfs";
        FileUtils.set_contents (settings.cryfs_binary, "#!/bin/sh\necho 'CryFS Version 1.0.3'\n");
        FileUtils.chmod (settings.cryfs_binary, 0700);
        var info = SafeStore.Backends.selected (settings);
        assert_false (info.available);
        assert_true (info.status.contains ("cryfs-unmount"));
        string unmount = root + "/cryfs-unmount";
        FileUtils.set_contents (unmount, "#!/bin/sh\necho 'CryFS Version 1.0.2'\n");
        FileUtils.chmod (unmount, 0700);
        assert_false (SafeStore.Backends.selected (settings).available);
        FileUtils.set_contents (unmount, "#!/bin/sh\necho 'CryFS Version 1.0.3'\n");
        FileUtils.chmod (unmount, 0700);
        assert_true (SafeStore.Backends.selected (settings).available);
        remove_test_tree (File.new_for_path (root));
#endif
    } catch (Error error) { Test.fail_printf ("Backend requirements: %s", error.message); }
}
private void run_lifecycle_case (int index) {
    var loop = new MainLoop ();
    Error? failure = null;
    lifecycle_case.begin (index, (obj, res) => {
        try { lifecycle_case.end (res); } catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.fail_printf ("Lifecycle: %s", failure.message);
}

int lifecycle_child (string[] args) {
    if (args[1] == "--probe-lease") {
        try { var lease = new SafeStore.Lease (args[2]); return lease != null ? 0 : 1; }
        catch (Error error) { return 3; }
    }
    if (args[1] == "--crash-cleanup") {
        var loop = new MainLoop ();
        int result = 1;
        crash_during_cleanup.begin (args[2], args.length > 3 && args[3] == "zip-aes" ? SafeStore.BackendKind.ZIP_AES : SafeStore.BackendKind.ZIP, (obj, res) => {
            try { crash_during_cleanup.end (res); }
            catch (Error error) { stderr.printf ("%s\n", error.message); result = 2; }
            loop.quit ();
        });
        loop.run ();
        return result;
    }
    return 2;
}

void register_lifecycle_tests (string executable) {
    lifecycle_executable = Filename.canonicalize (executable);
    Test.add_func ("/lifecycle/mount-identity", test_mount_identity);
    Test.add_func ("/lifecycle/shared-path-precedence", test_shared_precedence);
    Test.add_func ("/lifecycle/process-lease", test_native_lease);
    Test.add_func ("/lifecycle/sessions", () => run_lifecycle_case (0));
    Test.add_func ("/lifecycle/access-loss", () => run_lifecycle_case (1));
    Test.add_func ("/lifecycle/interrupted-cleanup", () => run_lifecycle_case (2));
    Test.add_func ("/lifecycle/legacy-metadata", () => run_lifecycle_case (3));
    Test.add_func ("/lifecycle/aes-sessions", () => run_lifecycle_case (4));
    Test.add_func ("/lifecycle/aes-access-loss", () => run_lifecycle_case (5));
    Test.add_func ("/lifecycle/aes-interrupted-cleanup", () => run_lifecycle_case (6));
    Test.add_func ("/lifecycle/zip-recognition", test_zip_recognition);
    Test.add_func ("/lifecycle/backend-requirements", test_backend_requirements);
}
