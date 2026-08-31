namespace Dc {

    /**
     * JSON-RPC transport for deltachat-rpc-server over stdio.
     * Owns the subprocess, request ids, pending calls, and read loop.
     */
    public class RpcTransport : Object {

        private Subprocess? process = null;
#if WINDOWS
        private void* win_process = null;
#endif
        private DataInputStream? reader = null;
        private OutputStream? writer = null;
        private InputStream? err_pipe = null;
        private int next_id = 1;
        private GenericArray<PendingCall> pending = new GenericArray<PendingCall> ();
        private ThreadPool<PendingWrite>? write_pool = null;
        private uint connection_generation = 0;
        private Cancellable? io_cancellable = null;
        private string last_stderr = "";

        public signal void disconnected (string reason);

        public bool is_connected { get; private set; default = false; }

        [CCode (cheader_filename = "sigpipe_compat.h", cname = "parla_ignore_sigpipe")]
        private static extern void ignore_sigpipe ();

        construct {
            /* A child may close its stdin while the writer is active. Convert
               that condition into EPIPE instead of terminating the process. */
            ignore_sigpipe ();
            try {
                /* GUnixOutputStream may perform the first write of an async
                   operation synchronously. A single worker is therefore the
                   only portable way to keep pipe backpressure off GTK while
                   preserving JSON-RPC request order. */
                write_pool = new ThreadPool<PendingWrite>.with_owned_data (
                    perform_write, 1, false);
            } catch (Error e) {
                warning ("RPC writer thread: %s", e.message);
            }
        }

        public async void start (string[] argv, string? cwd = null,
                                   string? accounts_path = null) throws Error {
            /* Retrying on this transport must first invalidate every callback
               belonging to the previous subprocess. */
            if (io_cancellable != null || process != null || reader != null ||
                writer != null) {
                stop ();
            }

            uint generation = ++connection_generation;
            var cancellable = new Cancellable ();
            io_cancellable = cancellable;
            last_stderr = "";
            try {
#if WINDOWS
                /* GSubprocess pipes never reach a console child on Windows;
                   spawn through the CreateProcessW wrapper instead. */
                void* spawned;
                OutputStream? child_in;
                InputStream? child_out;
                InputStream? child_err;
                Platform.spawn_hidden (argv, cwd,
                    accounts_path != null ? "DC_ACCOUNTS_PATH" : null,
                    accounts_path,
                    out spawned, out child_in, out child_out, out child_err);
                win_process = spawned;
                writer = child_in;
                reader = new DataInputStream (child_out);
                err_pipe = child_err;
#else
                var flags = SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE
                            | SubprocessFlags.STDERR_PIPE;
                var launcher = new SubprocessLauncher (flags);
                if (cwd != null) {
                    launcher.set_cwd (cwd);
                }
                if (accounts_path != null) {
                    launcher.setenv ("DC_ACCOUNTS_PATH", accounts_path, true);
                }
                process = SubprocessUtil.spawnv (launcher, argv);
                writer = process.get_stdin_pipe ();
                reader = new DataInputStream (process.get_stdout_pipe ());
                err_pipe = process.get_stderr_pipe ();
#endif
            } catch (Error e) {
                finish_generation (generation, "RPC server failed to start", false);
                throw e;
            }

            var connection_reader = reader;
            var connection_writer = writer;
            var connection_err = err_pipe;
            if (connection_reader == null || connection_writer == null ||
                connection_err == null) {
                finish_generation (generation, "RPC server pipes are unavailable", false);
                throw new IOError.NOT_CONNECTED ("RPC server pipes are unavailable");
            }
            connection_reader.set_newline_type (DataStreamNewlineType.LF);

            drain_stderr.begin (generation, connection_err);
            read_loop.begin (generation, connection_reader, cancellable);

            /* A server whose pipes are dead would otherwise stall this call
               forever; fail the handshake so the UI can show an error. */
            bool timed_out = false;
            uint handshake_timeout = Timeout.add_seconds (20, () => {
                if (!generation_is_active (generation)) return false;
                timed_out = true;
                finish_generation (
                    generation, "RPC server is not responding", false);
                return false;
            });
            try {
                yield call ("get_system_info", Params.begin ().build ());
                if (!timed_out) Source.remove (handshake_timeout);
                if (!generation_is_active (generation)) {
                    throw new IOError.NOT_CONNECTED (
                        "RPC connection changed during startup");
                }
            } catch (Error e) {
                if (!timed_out) Source.remove (handshake_timeout);
                if (generation_is_active (generation)) {
                    finish_generation (generation, "RPC server failed to start", false);
                }
                yield nap (200);
                if (last_stderr.length > 0) {
                    throw new IOError.FAILED ("%s", last_stderr);
                }
                throw e;
            }
            is_connected = true;
        }

        public void stop () {
            finish_generation (
                connection_generation, "RPC client stopped", false);
        }

        private void finish_generation (uint generation, string reason,
                                        bool emit_disconnected) {
            if (!generation_is_active (generation)) return;

            is_connected = false;
            var cancellable = io_cancellable;
            io_cancellable = null;
            writer = null;
            reader = null;
            err_pipe = null;
            if (cancellable != null) cancellable.cancel ();
            fail_pending (reason, generation);

            if (process != null) {
                process.force_exit ();
                process = null;
            }
#if WINDOWS
            if (win_process != null) {
                Platform.process_terminate (win_process);
                Platform.process_free (win_process);
                win_process = null;
            }
#endif
            if (emit_disconnected) disconnected (reason);
        }

        private bool generation_is_active (uint generation) {
            return generation == connection_generation &&
                   io_cancellable != null &&
                   !io_cancellable.is_cancelled ();
        }

        public async Json.Node? call (string method, Json.Node params) throws Error {
            uint generation = connection_generation;
            var connection_writer = writer;
            var cancellable = io_cancellable;
            if (connection_writer == null || reader == null ||
                cancellable == null || !generation_is_active (generation)) {
                throw new IOError.NOT_CONNECTED ("RPC client not connected");
            }

            int id = next_id++;
            var pc = new PendingCall (id, generation);
            var resume_source = new IdleSource ();
            resume_source.set_callback (call.callback);
            pc.resume_source = resume_source;
            pending.add (pc);
            queue_request (pc, method, params, connection_writer, cancellable);

            yield;

            remove_pending (id, generation);

            if (pc.error_msg != null) {
                throw new IOError.FAILED ("RPC %s: %s", method, pc.error_msg);
            }
            return pc.result;
        }

        private async void drain_stderr (uint generation, InputStream pipe) {
            try {
                var err_stream = new DataInputStream (pipe);
                string? line;
                size_t len;
                while ((line = yield err_stream.read_line_utf8_async (
                            Priority.DEFAULT, null, out len)) != null) {
                    if (generation != connection_generation) return;
                    last_stderr = line.strip ();
                }
            } catch (Error e) {
                /* ignore */
            }
        }

        private async void read_loop (uint generation, DataInputStream stream,
                                      Cancellable cancellable) {
            string reason = "RPC server closed";
            try {
                while (generation_is_active (generation)) {
                    size_t len;
                    string? line = yield stream.read_line_utf8_async (
                        Priority.DEFAULT, cancellable, out len);
                    if (!generation_is_active (generation)) return;
                    if (line == null) break;
                    if (line.strip ().length == 0) continue;

                    var parser = new Json.Parser ();
                    parser.load_from_data (line);
                    var root = parser.get_root ();
                    if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                        continue;

                    var obj = root.get_object ();
                    if (!obj.has_member ("id")) continue;

                    int resp_id = (int) obj.get_int_member ("id");
                    PendingCall? pc = find_pending (resp_id, generation);
                    if (pc == null) continue;

                    if (obj.has_member ("error") &&
                        !obj.get_member ("error").is_null ()) {
                        var err = obj.get_object_member ("error");
                        pc.error_msg = err.has_member ("message")
                            ? err.get_string_member ("message")
                            : "Unknown RPC error";
                    } else if (obj.has_member ("result")) {
                        var result_member = obj.get_member ("result");
                        pc.result = (result_member != null) ? result_member.copy () : null;
                    }

                    resume_pending (pc);
                }
            } catch (Error e) {
                if (!generation_is_active (generation) ||
                    e is IOError.CANCELLED) return;
                warning ("RPC read loop error: %s", e.message);
                reason = "RPC read failed: " + e.message;
            }

            if (generation_is_active (generation)) {
                finish_generation (generation, reason, true);
            }
        }

        private void queue_request (PendingCall pc, string method, Json.Node params,
                                    OutputStream stream,
                                    Cancellable cancellable) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("jsonrpc"); b.add_string_value ("2.0");
            b.set_member_name ("id");      b.add_int_value (pc.id);
            b.set_member_name ("method");  b.add_string_value (method);
            b.set_member_name ("params");  b.add_value (params);
            b.end_object ();

            var gen = new Json.Generator ();
            gen.set_root (b.get_root ());
            size_t json_len;
            string json = gen.to_data (out json_len);
            string line = json + "\n";

            var request = new PendingWrite (
                this, pc, stream, cancellable, line);
            if (write_pool == null) {
                fail_write (request, "RPC writer is unavailable");
                return;
            }

            /* Build the callback on the main thread. The worker only publishes
               its result and attaches this already-owned source. */
            var completed = new IdleSource ();
            completed.set_callback (() => {
                request.acquire_on_main ();
                request.transport.write_completed (request);
                return Source.REMOVE;
            });
            request.completion_source = completed;
            request.release_to_worker ();
            try {
                write_pool.add (request);
            } catch (Error e) {
                request.discard_completion ();
                fail_write (request, "RPC writer failed: " + e.message);
            }
        }

        private static void perform_write (owned PendingWrite request) {
            request.acquire_in_worker ();
            if (request.cancellable.is_cancelled ()) {
                request.error_msg = "RPC connection changed";
            } else {
                try {
                    size_t written;
                    bool complete = request.stream.write_all (
                        request.line.data, out written, request.cancellable);
                    if (!complete || written != request.line.length) {
                        throw new IOError.FAILED ("Incomplete RPC request write");
                    }
                    request.stream.flush (request.cancellable);
                } catch (Error e) {
                    request.error_msg = "RPC write failed: " + e.message;
                }
            }

            var completed = (owned) request.completion_source;
            request.completion_source = null;
            request.release_from_worker ();
            if (completed != null) completed.attach (MainContext.default ());
        }

        private void write_completed (PendingWrite request) {
            if (request.error_msg == null) return;
            if (generation_is_active (request.pending.generation)) {
                finish_generation (request.pending.generation,
                                   request.error_msg, true);
            } else {
                fail_write (request, "RPC connection changed");
            }
        }

        private void fail_write (PendingWrite request, string reason) {
            if (request.pending.resume_source == null) return;
            request.pending.error_msg = reason;
            resume_pending (request.pending);
        }

        private int index_of_pending (int id, uint generation) {
            for (int i = 0; i < pending.length; i++) {
                if (pending[i].id == id && pending[i].generation == generation)
                    return i;
            }
            return -1;
        }

        private PendingCall? find_pending (int id, uint generation) {
            int i = index_of_pending (id, generation);
            return i >= 0 ? pending[i] : null;
        }

        private void remove_pending (int id, uint generation) {
            int i = index_of_pending (id, generation);
            if (i >= 0) pending.remove_index (i);
        }

        private void fail_pending (string reason, uint generation) {
            for (int i = 0; i < pending.length; i++) {
                if (pending[i].generation != generation) continue;
                /* A null source means the read loop already delivered this
                   call's response and queued its continuation. */
                if (pending[i].resume_source == null) continue;
                pending[i].error_msg = reason;
                resume_pending (pending[i]);
            }
        }

        private void resume_pending (PendingCall pc) {
            var source = (owned) pc.resume_source;
            pc.resume_source = null;
            if (source != null) source.attach (MainContext.default ());
        }

        private async void nap (uint ms) {
            Timeout.add (ms, nap.callback);
            yield;
        }
    }

    private class PendingCall {
        public int id;
        public uint generation;
        public Source? resume_source = null;
        public Json.Node? result = null;
        public string? error_msg = null;

        public PendingCall (int id, uint generation) {
            this.id = id;
            this.generation = generation;
        }
    }

    private class PendingWrite {
        public RpcTransport transport;
        public PendingCall pending;
        public OutputStream stream;
        public Cancellable cancellable;
        public string line;
        public string? error_msg = null;
        public Source? completion_source = null;
        /* Publish request data before queueing and the write result before
           scheduling its main-context completion callback. */
        public int handoff_phase = 0;

        public PendingWrite (RpcTransport transport, PendingCall pending,
                             OutputStream stream,
                             Cancellable cancellable, string line) {
            this.transport = transport;
            this.pending = pending;
            this.stream = stream;
            this.cancellable = cancellable;
            this.line = line;
        }

        public void release_to_worker () {
            AtomicInt.set (ref handoff_phase, 1);
        }

        public void acquire_in_worker () {
            assert (AtomicInt.get (ref handoff_phase) == 1);
        }

        public void release_from_worker () {
            AtomicInt.set (ref handoff_phase, 2);
        }

        public void acquire_on_main () {
            assert (AtomicInt.get (ref handoff_phase) == 2);
        }

        public void discard_completion () {
            completion_source = null;
        }
    }
}
