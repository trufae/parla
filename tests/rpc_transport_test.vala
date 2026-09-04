using Dc;

private string test_executable;

private int run_fake_server (string mode, string? environment_output = null) {
    if (environment_output != null) {
        try {
            FileUtils.set_contents (environment_output,
                Environment.get_variable ("LD_LIBRARY_PATH") ?? "");
        } catch (Error e) {
            stderr.printf ("fake RPC server: %s\\n", e.message);
            return 3;
        }
    }
    string? line;
    while ((line = stdin.read_line ()) != null) {
        try {
            var parser = new Json.Parser ();
            parser.load_from_data (line);
            var request = parser.get_root ().get_object ();
            int64 id = request.get_int_member ("id");
            string method = request.get_string_member ("method");

            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("jsonrpc");
            builder.add_string_value ("2.0");
            builder.set_member_name ("id");
            builder.add_int_value (id);
            builder.set_member_name ("result");
            if (method == "get_system_info") {
                builder.begin_object ();
                builder.end_object ();
            } else {
                builder.add_string_value (method);
            }
            builder.end_object ();

            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            stdout.printf ("%s\n", generator.to_data (null));
            stdout.flush ();

            /* Complete the handshake, then leave stdin unread so a request
               larger than the pipe capacity would block a synchronous UI. */
            if (mode == "stall") {
                while (true) Thread.usleep (1000 * 1000);
            }
        } catch (Error e) {
            stderr.printf ("fake RPC server: %s\n", e.message);
            return 2;
        }
    }
    return 0;
}

private string[] fake_server_argv (string mode) {
    return { test_executable, "--fake-rpc-server", mode };
}

#if !WINDOWS
private string[] fake_server_argv_with_environment_output (string path) {
    return { test_executable, "--fake-rpc-server", "normal", path };
}
#endif

private async void delay (uint milliseconds) {
    Timeout.add (milliseconds, delay.callback);
    yield;
}

private class BatchState : Object {
    public int remaining;
    public Error? error = null;
    public int wrong_results = 0;

    public BatchState (int count) {
        remaining = count;
    }
}

private void begin_echo (RpcTransport transport, string method,
                         string payload, BatchState state) {
    transport.call.begin (method, Params.begin ().add_string (payload).build (),
        (obj, result) => {
            try {
                var response = transport.call.end (result);
                if (response == null || response.get_string () != method) {
                    state.wrong_results++;
                }
            } catch (Error e) {
                if (state.error == null) state.error = e;
            }
            state.remaining--;
        });
}

private async void nonblocking_write_async () throws Error {
    var transport = new RpcTransport ();
    yield transport.start (fake_server_argv ("stall"));

    bool call_finished = false;
    Error? call_error = null;
    string payload = string.nfill (2 * 1024 * 1024, 'x');
    int64 started = get_monotonic_time ();
    transport.call.begin ("blocked", Params.begin ().add_string (payload).build (),
        (obj, result) => {
            try {
                transport.call.end (result);
            } catch (Error e) {
                call_error = e;
            }
            call_finished = true;
        });

    yield delay (75);
    int64 elapsed = get_monotonic_time () - started;
    assert (elapsed < 1000 * 1000);
    assert (!call_finished);

    transport.stop ();
    yield delay (75);
    assert (call_finished);
    assert (call_error != null);
}

private async void serialized_writes_async () throws Error {
    var transport = new RpcTransport ();
    yield transport.start (fake_server_argv ("normal"));

    const int CALLS = 32;
    var state = new BatchState (CALLS);
    string payload = string.nfill (128 * 1024, 'q');
    for (int i = 0; i < CALLS; i++) {
        begin_echo (transport, "echo_%d".printf (i), payload, state);
    }

    for (int waited = 0; state.remaining > 0 && waited < 10000; waited += 10) {
        yield delay (10);
    }
    assert (state.remaining == 0);
    assert (state.error == null);
    assert (state.wrong_results == 0);
    transport.stop ();
}

private async void stale_generation_async () throws Error {
    var transport = new RpcTransport ();
    int disconnects = 0;
    transport.disconnected.connect ((reason) => { disconnects++; });

    yield transport.start (fake_server_argv ("normal"));
    transport.stop ();
    yield transport.start (fake_server_argv ("normal"));
    yield delay (200);

    assert (transport.is_connected);
    assert (disconnects == 0);
    transport.stop ();
}

private void test_nonblocking_write () {
    var loop = new MainLoop ();
    Error? failure = null;
    nonblocking_write_async.begin ((obj, result) => {
        try {
            nonblocking_write_async.end (result);
        } catch (Error e) {
            failure = e;
        }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.message ("%s", failure.message);
    assert (failure == null);
}

private void test_serialized_writes () {
    var loop = new MainLoop ();
    Error? failure = null;
    serialized_writes_async.begin ((obj, result) => {
        try {
            serialized_writes_async.end (result);
        } catch (Error e) {
            failure = e;
        }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.message ("%s", failure.message);
    assert (failure == null);
}

private void test_stale_generation () {
    var loop = new MainLoop ();
    Error? failure = null;
    stale_generation_async.begin ((obj, result) => {
        try {
            stale_generation_async.end (result);
        } catch (Error e) {
            failure = e;
        }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.message ("%s", failure.message);
    assert (failure == null);
}

#if !WINDOWS
private async void external_server_uses_host_libraries_async () throws Error {
    string output = Path.build_filename (Environment.get_tmp_dir (),
        "parla-rpc-transport-env-%u".printf (Random.next_int ()));
    string? old_appdir = Environment.get_variable ("APPDIR");
    string? old_library_path = Environment.get_variable ("LD_LIBRARY_PATH");
    Environment.set_variable ("APPDIR", "/tmp/parla-AppDir", true);
    Environment.set_variable ("LD_LIBRARY_PATH", "/tmp/parla-AppDir/usr/lib", true);

    try {
        var transport = new RpcTransport ();
        yield transport.start (fake_server_argv_with_environment_output (output));
        transport.stop ();
        string contents;
        FileUtils.get_contents (output, out contents);
        assert (contents == "");
    } finally {
        FileUtils.remove (output);
        if (old_appdir != null) Environment.set_variable ("APPDIR", old_appdir, true);
        else Environment.unset_variable ("APPDIR");
        if (old_library_path != null)
            Environment.set_variable ("LD_LIBRARY_PATH", old_library_path, true);
        else Environment.unset_variable ("LD_LIBRARY_PATH");
    }
}

private void test_external_server_uses_host_libraries () {
    var loop = new MainLoop ();
    Error? failure = null;
    external_server_uses_host_libraries_async.begin ((obj, result) => {
        try {
            external_server_uses_host_libraries_async.end (result);
        } catch (Error e) {
            failure = e;
        }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) Test.message ("%s", failure.message);
    assert (failure == null);
}
#endif

public int main (string[] args) {
    if (args.length >= 3 && args[1] == "--fake-rpc-server") {
        return run_fake_server (args[2], args.length > 3 ? args[3] : null);
    }

    test_executable = args[0];
    Test.init (ref args);
    Test.add_func ("/rpc-transport/nonblocking-write", test_nonblocking_write);
    Test.add_func ("/rpc-transport/serialized-writes", test_serialized_writes);
    Test.add_func ("/rpc-transport/stale-generation", test_stale_generation);
#if !WINDOWS
    Test.add_func ("/rpc-transport/external-server-uses-host-libraries",
        test_external_server_uses_host_libraries);
#endif
    return Test.run ();
}
