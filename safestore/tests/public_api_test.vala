private void delete_fixture (File file) throws Error {
    var info = file.query_info ("standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
    if (info.get_file_type () == FileType.DIRECTORY) {
        var children = file.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file ()) != null) delete_fixture (file.get_child (child.get_name ()));
        children.close ();
    }
    file.delete ();
}

// Deliberately imports only the generated public VAPI and header.
private async void exercise_api () throws Error {
    string root = DirUtils.make_tmp ("safestore-api-XXXXXX");
    string accounts = Path.build_filename (root, "accounts");
    string storage = Path.build_filename (root, "accounts.zip");
    var options = new SafeStore.StoreOptions ();
    options.zip_binary = Path.build_filename (root, "missing-zip");
    options.cryfs_binary = Path.build_filename (root, "missing-cryfs");
    var store = new SafeStore.Store (accounts, storage, SafeStore.BackendKind.ZIP, options);
    // The instance snapshots options, including executable paths.
    options.zip_binary = "zip";
    assert_false (FileUtils.test (accounts, FileTest.EXISTS));
    assert_false (FileUtils.test (storage, FileTest.EXISTS));

    var info = yield store.probe ();
    assert_false (info.available);
    assert_true (info.experimental);
    assert_true (info.supports (SafeStore.Operation.INSPECT));
    assert_false (info.supports (SafeStore.Operation.DISABLE));
    assert_false (info.supports (SafeStore.Operation.ENABLE));
    assert_false (info.supports (SafeStore.Operation.CHANGE_BACKEND));
    assert_false (info.supports (SafeStore.Operation.RECOVER));
    var status = yield store.inspect ();
    assert_false (status.recognized);
    assert_false (status.integrity_verified);
    assert_false (status.plaintext_exposed);
    // Arbitrary regular files are not encrypted stores.
    FileUtils.set_contents (storage, "this is not encrypted");
    status = yield store.inspect ();
    assert_false (status.recognized);
    assert_true (status.recovery_required);
    assert_false (status.integrity_verified);
    assert_true (FileUtils.unlink (storage) == 0);

    var cancelled = new Cancellable ();
    cancelled.cancel ();
    var secret = new SafeStore.SecretValue ("disposable long password");
    try {
        yield store.create_empty (secret, cancelled);
        assert_not_reached ();
    } catch (IOError.CANCELLED error) { }
    assert_false (FileUtils.test (accounts, FileTest.EXISTS));
    assert_false (FileUtils.test (storage, FileTest.EXISTS));

    // Two mutating calls cannot enter the same instance concurrently.
    bool completed = false;
    Error? first_error = null;
    SourceFunc resume = exercise_api.callback;
    store.unlock.begin (secret, null, (obj, result) => {
        try { store.unlock.end (result); }
        catch (Error error) { first_error = error; }
        completed = true;
        resume ();
    });
    try {
        yield store.unlock (secret);
        assert_not_reached ();
    } catch (SafeStore.StoreError.BUSY error) { }
    if (!completed) yield;
    assert_true (first_error is SafeStore.StoreError.NOT_SUPPORTED);
    assert_false (store.process_active);
    secret.clear ();
    assert_true (DirUtils.remove (root) == 0);
}

private async void exercise_zip (SafeStore.BackendKind kind) throws Error {
    string root = DirUtils.make_tmp ("safestore-api-zip-XXXXXX");
    string accounts = Path.build_filename (root, "accounts");
    string storage = Path.build_filename (root, "store.zip");
    var options = new SafeStore.StoreOptions ();
    if (kind == SafeStore.BackendKind.ZIP_AES) {
        options.zip_binary = options.unzip_binary = Path.build_filename (root, "no-external-tools");
    }
    var store = new SafeStore.Store (accounts, storage, kind, options);
    var info = yield store.probe ();
    if (!info.available) {
        Test.skip (info.status);
        assert_true (DirUtils.remove (root) == 0);
        return;
    }
    var secret = new SafeStore.SecretValue ("a disposable public API password");
    try {
        // Unlock must not create a missing archive or accounts folder.
        bool rejected = false;
        try { yield store.unlock (secret); }
        catch (Error error) { rejected = true; }
        assert_true (rejected);
        assert_false (FileUtils.test (accounts, FileTest.EXISTS));
        assert_false (FileUtils.test (storage, FileTest.EXISTS));

        Error? create_error = null;
        SourceFunc resume = exercise_zip.callback;
        var handoff = new SafeStore.SecretValue (secret.peek ());
        store.create_empty.begin (handoff, null, (obj, result) => {
            try { store.create_empty.end (result); }
            catch (Error error) { create_error = error; }
            resume ();
        });
        handoff.clear ();
        yield;
        if (create_error != null) throw create_error;
        assert_cmpint (store.state, CompareOperator.EQ, SafeStore.StoreState.MOUNTED);
        string payload = Path.build_filename (accounts, "account-fixture");
        FileUtils.set_contents (payload, "disposable account data");
        yield store.lock (secret);
        assert_false (store.process_active);
        assert_false (FileUtils.test (payload, FileTest.EXISTS));
        rejected = false;
        var wrong = new SafeStore.SecretValue ("an incorrect password");
        try { yield store.unlock (wrong); }
        catch (Error error) { rejected = true; }
        finally { wrong.clear (); }
        assert_true (rejected);
        assert_false (FileUtils.test (payload, FileTest.EXISTS));

        yield store.unlock (secret);
        string restored;
        FileUtils.get_contents (payload, out restored);
        assert_true (restored == "disposable account data");
        yield store.lock (secret);
        assert_false (store.process_active);
        assert_true (FileUtils.unlink (Path.build_filename (accounts, ".safestore-locked")) == 0);
        assert_true (DirUtils.remove (accounts) == 0);
        assert_true (FileUtils.unlink (storage) == 0);
        delete_fixture (File.new_for_path (root));
    } finally { secret.clear (); }
}

private async void exercise (int backend) throws Error {
    if (backend != 0) yield exercise_zip (backend == 1 ? SafeStore.BackendKind.ZIP : SafeStore.BackendKind.ZIP_AES);
    else yield exercise_api ();
}

private void run_test (int backend) {
    // Catch accidental use of the default context in worker completions.
    var context = new MainContext ();
    context.push_thread_default ();
    var loop = new MainLoop (context);
    Error? failure = null;
    exercise.begin (backend, (obj, result) => {
        assert_true (context.is_owner ());
        try { exercise.end (result); }
        catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    context.pop_thread_default ();
    if (failure != null) Test.fail_printf ("Public API: %s", failure.message);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/safestore/public-api", () => run_test (0));
    Test.add_func ("/safestore/public-zip-roundtrip", () => run_test (1));
    Test.add_func ("/safestore/public-aes-zip-roundtrip", () => run_test (2));
    return Test.run ();
}
