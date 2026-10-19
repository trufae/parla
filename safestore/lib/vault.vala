namespace SafeStore {

    public errordomain StoreError {
        BUSY,
        INVALID_ARGUMENT,
        NOT_SUPPORTED,
        NOT_A_VAULT,
        ALREADY_MOUNTED,
        NOT_MOUNTED,
        WRONG_PASSWORD,
        BACKEND,
        MOUNT_FAILED,
        UNMOUNT_FAILED
    }

    // Synchronous, one-shot vault operations for command-line and scripted
    // use. Unlike CryfsController, mount() lets CryFS daemonize itself, so
    // the caller does not have to stay alive to keep the vault mounted.
    internal class Vault : Object {

        public static bool is_encrypted (string vault_path) {
            string config = Path.build_filename (
                PathPolicy.normalize (vault_path), "cryfs.config");
            return FileUtils.test (config, FileTest.IS_REGULAR);
        }

        public static MountInfo? mount_info (string mount_path) {
            return MountCheck.find (mount_path);
        }

        // Resolves the CryFS executable, throwing before any password is
        // requested when the backend is missing.
        public static string resolve_binary (string binary) throws Error {
            string? found = null;
            if (Path.is_absolute (binary)) {
                if (FileUtils.test (binary, FileTest.IS_EXECUTABLE)) {
                    found = binary;
                }
            } else {
                found = Environment.find_program_in_path (binary);
            }
            if (found == null) {
                throw new StoreError.BACKEND (
                    "CryFS executable not found (%s); install CryFS or "
                    + "point --binary or $SAFESTORE_CRYFS at it", binary);
            }
            return found;
        }

        public static string backend_version (string binary) throws Error {
            string? stdout_text;
            string? stderr_text;
            var process = new Subprocess (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                binary, "--version"
            );
            process.communicate_utf8 (
                null, null, out stdout_text, out stderr_text);
            string text = (stdout_text ?? "").strip ();
            if (text.length == 0) text = (stderr_text ?? "").strip ();
            if (!process.get_successful ()) {
                throw new StoreError.BACKEND (
                    "%s", text.length > 0 ? text : "CryFS returned an error.");
            }
            return text;
        }

        public static void mount (string binary,
                                  string vault_path,
                                  string mount_path,
                                  string password,
                                  bool create,
                                  int idle_minutes = 0,
                                  bool allow_executable_files = false,
                                  string state_directory = "")
                                  throws Error {
            string cryfs = resolve_binary (binary);
            PathPolicy.validate_layout (vault_path, mount_path);
            if (create) {
                PathPolicy.validate_new_vault (vault_path);
            } else {
                PathPolicy.validate_existing_vault (vault_path);
            }

            string vault = PathPolicy.normalize (vault_path);
            string mount = PathPolicy.normalize (mount_path);
            if (MountCheck.is_active (mount)) {
                throw new StoreError.ALREADY_MOUNTED (
                    "Something is already mounted at %s", mount);
            }
            PathPolicy.ensure_private_directory (vault);
#if !WINDOWS
            PathPolicy.ensure_private_directory (mount);
#endif
            PathPolicy.validate_mountpoint (mount);

            string[] argv = {};
            argv += cryfs;
            if (create) {
                argv += "--cipher";
                argv += "xchacha20-poly1305";
            }
            if (idle_minutes > 0) {
                argv += "--unmount-idle";
                argv += idle_minutes.to_string ();
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
            CryfsBackend.apply_environment (launcher, state_directory);
            var process = launcher.spawnv (argv);

            var stdin_pipe = process.get_stdin_pipe ();
            stdin_pipe.write_all ((password + "\n").data, null);
            stdin_pipe.close ();

            // In daemon mode the launched process exits once the filesystem
            // is mounted (or on failure), while a detached child keeps the
            // stdout/stderr pipes open; only drain them after a failure,
            // when EOF is guaranteed.
            process.wait ();
            if (!process.get_successful ()) {
                int status = process.get_if_exited ()
                    ? process.get_exit_status () : 1;
                string reason = CryfsBackend.exit_message (status);
                string details = read_all (process.get_stderr_pipe ());
                string message = details.length > 0
                    ? reason + ": " + details : reason;
                if (status == 11) {
                    throw new StoreError.WRONG_PASSWORD ("%s", message);
                }
                throw new StoreError.MOUNT_FAILED ("%s", message);
            }

            for (int attempt = 0; attempt < 40; attempt++) {
                if (MountCheck.is_active (mount)) return;
                Thread.usleep (250000);
            }
            throw new StoreError.MOUNT_FAILED (
                "CryFS exited successfully, but no mount appeared at %s",
                mount);
        }

        public static void unmount (string binary,
                                    string mount_path) throws Error {
            string unmount_binary = resolve_binary (
                CryfsBackend.unmount_binary_for (binary));
            string mount = PathPolicy.normalize (mount_path);
            if (!MountCheck.is_active (mount)) {
                throw new StoreError.NOT_MOUNTED (
                    "Nothing is mounted at %s", mount);
            }

            string? stdout_text;
            string? stderr_text;
            var process = new Subprocess (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                unmount_binary,
                "--immediate", mount
            );
            process.communicate_utf8 (
                null, null, out stdout_text, out stderr_text);
            if (!process.get_successful ()) {
                string reason = (stderr_text ?? "").strip ();
                throw new StoreError.UNMOUNT_FAILED (
                    "%s",
                    reason.length > 0
                        ? reason
                        : "CryFS unmount failed; close open files and retry.");
            }

            for (int attempt = 0; attempt < 50; attempt++) {
                if (!MountCheck.is_active (mount)) return;
                Thread.usleep (100000);
            }
            throw new StoreError.UNMOUNT_FAILED (
                "Unmount reported success, but %s is still mounted", mount);
        }

        private static string read_all (InputStream input) {
            var text = new StringBuilder ();
            var stream = new DataInputStream (input);
            try {
                string? line;
                while ((line = stream.read_line ()) != null) {
                    string clean = line.strip ();
                    if (clean.length == 0) continue;
                    if (text.len > 0) text.append_c ('\n');
                    text.append (clean);
                }
            } catch (Error error) {
                // Best-effort diagnostics only.
            }
            return text.str;
        }
    }
}
