namespace SafeStore {

    public enum StoreState {
        UNKNOWN,
        LOCKED,
        STARTING,
        MOUNTED,
        STOPPING,
        ERROR
    }

    internal class CryfsController : Object {

        public signal void output (string line);
        public signal void state_changed (StoreState state, string detail);

        public StoreState state { get; private set; default = StoreState.LOCKED; }
        public string detail { get; private set; default = "Vault is locked"; }
        public bool process_active {
            get { return cryfs_process != null; }
        }

        public int last_exit_status { get; private set; default = -1; }
        private Subprocess? cryfs_process;
        private uint process_generation = 0;
        private bool expected_exit = false;

        public void mount (string binary,
                           string vault_path,
                           string mount_path,
                           string password,
                           bool create,
                           bool allow_executable_files = false,
                                  string state_directory = "") throws Error {
            if (cryfs_process != null
                    || state == StoreState.STARTING
                    || state == StoreState.MOUNTED
                    || state == StoreState.STOPPING) {
                throw new IOError.BUSY ("A vault operation is already active.");
            }

            PathPolicy.validate_layout (vault_path, mount_path);
            if (create) {
                PathPolicy.validate_new_vault (vault_path);
            } else {
                PathPolicy.validate_existing_vault (vault_path);
            }
            string vault = PathPolicy.normalize (vault_path);
            string mount = PathPolicy.normalize (mount_path);
            if (MountCheck.is_active (mount)) {
                throw new IOError.BUSY (
                    "Something is already mounted at %s", mount);
            }
            PathPolicy.ensure_private_directory (vault);
#if !WINDOWS
            PathPolicy.ensure_private_directory (mount);
#endif
            PathPolicy.validate_mountpoint (mount);

            string starting_detail = create
                ? "Creating and mounting vault…"
                : "Unlocking vault…";
            output (
                create
                    ? "Creating a CryFS vault with XChaCha20-Poly1305."
                    : "Starting CryFS."
            );

            string[] argv = {};
            argv += binary;
            argv += "-f";
            if (create) {
                argv += "--cipher";
                argv += "xchacha20-poly1305";
            }
#if !WINDOWS
            if (!allow_executable_files) {
                argv += "-o";
                argv += "noexec";
            }
#endif
            argv += vault;
            argv += mount;

            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDIN_PIPE
                | SubprocessFlags.STDOUT_PIPE
                | SubprocessFlags.STDERR_PIPE
            );
            try {
                CryfsBackend.apply_environment (launcher, state_directory);
            } catch (Error error) {
                transition (
                    StoreState.ERROR,
                    "Could not create private CryFS state directory"
                );
                throw error;
            }

            Subprocess process;
            try {
                process = launcher.spawnv (argv);
            } catch (Error error) {
                transition (StoreState.ERROR, "Could not start CryFS");
                throw error;
            }

            last_exit_status = -1;
            cryfs_process = process;
            transition (StoreState.STARTING, starting_detail);
            expected_exit = false;
            uint generation = ++process_generation;
            drain_stream.begin (
                process.get_stdout_pipe (), generation, false);
            drain_stream.begin (
                process.get_stderr_pipe (), generation, true);
            watch_process.begin (process, generation);

            try {
                var writer = new DataOutputStream (process.get_stdin_pipe ());
                writer.put_string (password);
                writer.put_byte ('\n');
                writer.close ();
                password = "";
            } catch (Error error) {
                password = "";
                transition (StoreState.ERROR, "Could not send password to CryFS");
                throw error;
            }

            confirm_mount.begin (
                process, generation, mount, vault);
        }

        private async void confirm_mount (Subprocess process,
                                          uint generation,
                                          string mount_path,
                                          string vault_path) {
            bool mounted = false;
            for (int attempt = 0;
                 attempt < 40
                    && generation == process_generation
                    && cryfs_process == process;
                 attempt++) {
                try {
                    var found = MountCheck.find (mount_path);
                    if (found != null) {
                        MountCheck.require_exact (mount_path, vault_path);
                        mounted = true;
                        break;
                    }
                } catch (Error error) {
                    transition (StoreState.ERROR, error.message);
                    return;
                }
                yield delay (250);
            }
            if (mounted && cryfs_process == process
                    && state == StoreState.STARTING) {
                transition (
                    StoreState.MOUNTED,
                    "The expected vault is mounted"
                );
                output ("Vault mounted successfully.");
            } else if (state == StoreState.ERROR || cryfs_process == null) {
                output ("Mount failed: " + detail);
            } else {
                transition (
                    StoreState.ERROR,
                    "CryFS is running, but no mount appeared within 10 seconds"
                );
                output (detail + "; use Lock to clean up.");
            }
        }

        public async void unmount (string binary, string storage_path,
                                   string mount_path, string mount_identity) throws Error {
            MountCheck.require_exact (mount_path, storage_path, mount_identity);
            if (cryfs_process == null) {
                throw new IOError.NOT_CONNECTED (
                    "No SafeStore-managed vault is mounted.");
            }

            transition (StoreState.STOPPING, "Locking vault…");
            expected_exit = true;
            output ("Requesting a clean CryFS unmount.");

            string unmount_binary = CryfsBackend.unmount_binary_for (binary);
            string? stdout_text;
            string? stderr_text;
            Subprocess process;
            try {
                process = new Subprocess (
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                    unmount_binary, "--immediate", mount_path
                );
                yield process.communicate_utf8_async (
                    null, null, out stdout_text, out stderr_text);
            } catch (Error error) {
                expected_exit = false;
                transition (StoreState.MOUNTED, "Vault is still mounted");
                throw error;
            }

            append_multiline (stdout_text ?? "");
            append_multiline (stderr_text ?? "");
            if (!process.get_successful ()) {
                expected_exit = false;
                transition (
                    StoreState.MOUNTED,
                    "Unmount failed; close files using the vault and retry"
                );
                string reason = (stderr_text ?? "").strip ();
                throw new IOError.BUSY (
                    "%s", reason.length > 0 ? reason : "CryFS unmount failed.");
            }

            for (int attempt = 0;
                 attempt < 50 && cryfs_process != null;
                 attempt++) {
                yield delay (100);
            }
            if (cryfs_process != null) {
                transition (
                    StoreState.ERROR,
                    "Unmount command succeeded, but CryFS did not exit"
                );
                throw new IOError.TIMED_OUT ("%s", detail);
            }
            if (MountCheck.find (mount_path) != null) {
                transition (StoreState.ERROR, "CryFS exited but a mount remains");
                throw new StoreError.UNMOUNT_FAILED ("The accounts path is still mounted");
            }
            transition (StoreState.LOCKED, "Vault is locked");
            output ("Vault locked cleanly.");
        }

        private async void drain_stream (InputStream input,
                                         uint generation,
                                         bool is_error) {
            var stream = new DataInputStream (input);
            stream.set_newline_type (DataStreamNewlineType.ANY);
            try {
                while (generation == process_generation) {
                    size_t length;
                    string? line = yield stream.read_line_utf8_async (
                        Priority.DEFAULT, null, out length);
                    if (line == null) break;
                    string clean = line.strip ();
                    if (clean.length > 0) output (clean);
                }
            } catch (Error error) {
                if (generation == process_generation) {
                    output (
                        (is_error ? "CryFS error output ended: "
                                  : "CryFS output ended: ")
                        + error.message
                    );
                }
            }
        }

        private async void watch_process (Subprocess process,
                                          uint generation) {
            try {
                yield process.wait_async ();
            } catch (Error error) {
                if (generation == process_generation) {
                    output ("Could not monitor CryFS: " + error.message);
                }
            }
            if (generation != process_generation
                    || cryfs_process != process) return;

            cryfs_process = null;
            bool was_expected = expected_exit;
            expected_exit = false;
            if (was_expected || state == StoreState.STOPPING) {
                // unmount() verifies disappearance before reporting LOCKED.
                return;
            }

            int status = 1;
            if (process.get_if_exited ()) status = process.get_exit_status ();
            last_exit_status = status;
            transition (StoreState.ERROR, "CryFS access was lost: " + CryfsBackend.exit_message (status));
        }

        private void transition (StoreState new_state, string new_detail) {
            state = new_state;
            detail = new_detail;
            state_changed (state, detail);
        }

        private void append_multiline (string text) {
            foreach (string line in text.split ("\n")) {
                string clean = line.strip ();
                if (clean.length > 0) output (clean);
            }
        }

        private static async void delay (uint milliseconds) {
            SourceFunc callback = delay.callback;
            var source = new TimeoutSource (milliseconds);
            source.set_callback (() => {
                callback ();
                return Source.REMOVE;
            });
            source.attach (MainContext.ref_thread_default ());
            yield;
        }
    }
}
