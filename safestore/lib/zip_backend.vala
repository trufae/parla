namespace SafeStore {

    /**
     * Compatibility backend using Info-ZIP's legacy encryption.
     *
     * This is intentionally labelled weak: ZipCrypto does not hide names or
     * metadata and is not comparable to CryFS.  It exists for systems where a
     * mountable encrypted filesystem is unavailable.
     */
    internal class ZipBackend : Object {

        private const string MARKER_PREFIX = ".safestore-zip-marker-";
        private const string MARKER_CONTENT = "SafeStore ZIP backend v1\n";
        private const string LOCKED_NAME = ".safestore-locked";
        private const string LOCKED_CONTENT = "SafeStore ZIP vault is locked; do not remove this file.\n";

        [CCode (cname = "safestore_run_pty_password",
                cheader_filename = "pty_password.h")]
        private static extern bool run_with_password (
            [CCode (array_length = false, array_null_terminated = true)]
            string[] argv,
            string cwd,
            string password,
            bool confirm,
            out string output) throws Error;

        [CCode (cname = "safestore_acquire_accounts_guard",
                cheader_filename = "pty_password.h")]
        private static extern int acquire_accounts_guard (
            string lock_path) throws Error;

        [CCode (cname = "safestore_release_accounts_guard",
                cheader_filename = "pty_password.h")]
        private static extern void release_accounts_guard (int descriptor);

        public static bool password_channel_available () {
#if WINDOWS || SAFESTORE_UNSUPPORTED
            return false;
#else
            return true;
#endif
        }

        public static bool is_encrypted (Settings settings) {
            try { ZipFormat.validate (settings.vault_path); return true; }
            catch (Error error) { return false; }
        }

        public static bool plaintext_present (Settings settings) {
            try { ensure_locked_destination (settings.mount_path); return false; }
            catch (Error error) { return true; }
        }

        public static void ensure_available (Settings settings) throws Error {
            BackendInfo info = Backends.inspect (
                settings, BackendKind.ZIP);
            if (!info.available) {
                throw new StoreError.BACKEND (
                    "%s", info.status);
            }
            PlaintextEraser.require_available (settings);
        }

        public static string probe_tools (Settings settings) throws Error {
            string zip_version = tool_version (settings.zip_binary);
            if (!zip_version.ascii_down ().contains ("encryption")) {
                throw new StoreError.BACKEND (
                    "zip was found, but it does not report encryption support");
            }
            tool_version (settings.unzip_binary);
            foreach (string line in zip_version.split ("\n")) {
                string clean = line.strip ();
                if (clean.has_prefix ("This is Zip ")
                        || clean.ascii_down ().has_prefix ("zip ")) {
                    return clean;
                }
            }
            return "zip and unzip are usable with encryption support";
        }

        private static string tool_version (string binary) throws Error {
            string? stdout_text;
            string? stderr_text;
            var process = new Subprocess (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                binary, "-v");
            process.communicate_utf8 (
                null, null, out stdout_text, out stderr_text);
            string combined = ((stdout_text ?? "") + "\n"
                + (stderr_text ?? "")).strip ();
            if (!process.get_successful ()) {
                throw new StoreError.BACKEND (
                    "%s -v failed%s", binary,
                    combined.length > 0 ? ": " + combined : "");
            }
            return combined;
        }

        /** Create a password-protected initial snapshot and leave it unlocked. */
        public static void create (Settings settings,
                                   string password) throws Error {
            ensure_available (settings);
            string archive = settings.vault_path;
            if (FileUtils.test (archive, FileTest.EXISTS)) {
                throw new StoreError.ALREADY_MOUNTED (
                    "ZIP vault already exists at %s", archive);
            }
            prepare_destination (settings.mount_path);
            write_archive (settings, password);
        }

        /** Extract to staging, validate the format, then expose the accounts. */
        public static void unlock (Settings settings,
                                   string password, ref bool rollback_safe) throws Error {
            rollback_safe = false;
            ensure_available (settings);
            string archive = settings.vault_path;
            if (!is_encrypted (settings)) {
                throw new StoreError.NOT_A_VAULT (
                    "No ZIP vault was found at %s", archive);
            }
            ensure_locked_destination (settings.mount_path);
            ZipFormat.validate (archive);
            bool exposed = false;

            string parent = Path.get_dirname (settings.mount_path);
            string staging = unique_directory (parent, ".safestore-unlock-");
            try {
                string[] argv = {
                    settings.unzip_binary,
                    "-qq",
                    archive,
                    "-d",
                    staging
                };
                string process_output;
                try {
                    run_with_password (
                        argv, parent, password, false, out process_output);
                } catch (Error error) {
                    if (error.matches (
                            IOError.quark (), IOError.PERMISSION_DENIED)) {
                        throw new StoreError.WRONG_PASSWORD (
                            "Could not decrypt ZIP vault: %s", error.message);
                    }
                    throw new StoreError.BACKEND (
                        "Could not extract ZIP vault: %s", error.message);
                }

                string payload = validate_extraction (staging);
                remove_locked_destination (settings.mount_path);
                File.new_for_path (payload).move (
                    File.new_for_path (settings.mount_path),
                    FileCopyFlags.NONE);
                exposed = true;
            } catch (Error error) {
                try {
                    PlaintextEraser.erase_tree (staging, settings);
                } catch (Error cleanup_error) {
                    throw new StoreError.RECOVERY_REQUIRED (
                        "ZIP staging cleanup failed at %s: %s", staging, cleanup_error.message);
                }
                rollback_safe = !exposed;
                throw error;
            }
            if (FileUtils.test (staging, FileTest.EXISTS)) {
                // Only the validated marker remains after payload move.
                PlaintextEraser.erase_tree (staging, settings);
            }
        }

        /** Archive first; plaintext is removed only after atomic replacement. */
        public static void lock (Settings settings,
                                 string password, Worker committed, ref bool rollback_safe) throws Error {
            rollback_safe = true;
            ensure_available (settings);
            validate_plain_accounts (settings.mount_path);
            PlaintextEraser.validate_tree (
                settings.mount_path, settings);
            int guard = acquire_accounts_guard (Path.build_filename (
                settings.mount_path, "accounts.lock"));
            try {
                rollback_safe = false;
                write_archive (settings, password);
                committed ();
                PlaintextEraser.erase_tree (settings.mount_path, settings);
                create_locked_destination (settings.mount_path);
                PathPolicy.sync_directory (settings.mount_path);
                PathPolicy.sync_directory (Path.get_dirname (settings.mount_path));
            } finally {
                release_accounts_guard (guard);
            }
        }

        private static void write_archive (Settings settings,
                                           string password) throws Error {
            string accounts = PathPolicy.normalize (settings.mount_path);
            validate_plain_accounts (accounts);
            validate_no_symlinks (File.new_for_path (accounts));

            string parent = Path.get_dirname (accounts);
            string account_name = Path.get_basename (accounts);
            validate_entry_name (account_name);
            string marker_name = MARKER_PREFIX + Uuid.string_random ();
            string marker_path = Path.build_filename (parent, marker_name);
            string archive = settings.vault_path;
            string temporary = archive + ".tmp-" + Uuid.string_random () + ".zip";

            try {
                var marker = File.new_for_path (marker_path).create (
                    FileCreateFlags.PRIVATE);
                marker.write_all (MARKER_CONTENT.data, null);
                marker.close ();

                string[] argv = {
                    settings.zip_binary,
                    "-q",
                    "-r",
                    "-e",
                    temporary,
                    "--",
                    marker_name,
                    account_name
                };
                string process_output;
                run_with_password (
                    argv, parent, password, true, out process_output);
                verify_archive (
                    settings, temporary, parent, password);
#if !WINDOWS
                if (FileUtils.chmod (temporary, 0600) != 0) {
                    throw new IOError.PERMISSION_DENIED (
                        "Could not restrict ZIP archive permissions");
                }
#endif
                ZipFormat.validate (temporary);
                durable_replace (temporary, archive);
            } finally {
                if (FileUtils.test (marker_path, FileTest.EXISTS)) {
                    FileUtils.unlink (marker_path);
                }
                if (FileUtils.test (temporary, FileTest.EXISTS)) {
                    FileUtils.unlink (temporary);
                }
            }
        }

        private static void verify_archive (Settings settings,
                                            string archive,
                                            string cwd,
                                            string password) throws Error {
            string[] argv = {
                settings.unzip_binary,
                "-tqq",
                archive
            };
            string process_output;
            run_with_password (
                argv, cwd, password, false, out process_output);
        }

        private static void durable_replace (string source,
                                             string destination) throws Error {
#if WINDOWS
            File.new_for_path (source).move (
                File.new_for_path (destination),
                FileCopyFlags.OVERWRITE);
#else
            int descriptor = Posix.open (
                source, Posix.O_RDONLY | Posix.O_CLOEXEC);
            if (descriptor < 0 || Posix.fsync (descriptor) != 0) {
                if (descriptor >= 0) Posix.close (descriptor);
                throw new IOError.FAILED (
                    "Could not synchronize the new ZIP archive");
            }
            Posix.close (descriptor);
            if (FileUtils.rename (source, destination) != 0) {
                throw new IOError.FAILED (
                    "Could not atomically replace the ZIP vault");
            }
            string parent = Path.get_dirname (destination);
            descriptor = Posix.open (
                parent,
                Posix.O_RDONLY | Posix.O_DIRECTORY | Posix.O_CLOEXEC);
            if (descriptor < 0 || Posix.fsync (descriptor) != 0) {
                if (descriptor >= 0) Posix.close (descriptor);
                throw new IOError.FAILED (
                    "ZIP vault was replaced, but its directory could not be synchronized");
            }
            Posix.close (descriptor);
#endif
        }

        private static string validate_extraction (string staging)
                                                   throws Error {
            string? payload = null;
            bool marker_found = false;
            var directory = File.new_for_path (staging);
            var children = directory.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file ()) != null) {
                string name = child.get_name ();
                string path = Path.build_filename (staging, name);
                if (name.has_prefix (MARKER_PREFIX)
                        && !marker_found
                        && child.get_file_type () == FileType.REGULAR
                        && marker_matches (path)) {
                    marker_found = true;
                } else if (child.get_file_type () == FileType.DIRECTORY
                        && payload == null) {
                    payload = path;
                } else {
                    throw new StoreError.NOT_A_VAULT (
                        "ZIP vault contains an unexpected top-level entry");
                }
            }
            children.close ();
            if (!marker_found || payload == null) {
                throw new StoreError.NOT_A_VAULT (
                    "ZIP archive is not a SafeStore vault");
            }
            validate_no_symlinks (File.new_for_path (payload));
            return payload;
        }

        private static bool marker_matches (string path) {
            string content;
            try {
                FileUtils.get_contents (path, out content);
                return content == MARKER_CONTENT;
            } catch (Error error) {
                return false;
            }
        }

        private static void validate_no_symlinks (File file) throws Error {
            FileInfo info = file.query_info (
                FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (info.get_file_type () == FileType.SYMBOLIC_LINK) {
                throw new PathPolicyError.INVALID (
                    "ZIP vaults do not accept symbolic links: %s",
                    file.get_path ());
            }
            if (info.get_file_type () == FileType.REGULAR) return;
            if (info.get_file_type () != FileType.DIRECTORY) {
                throw new PathPolicyError.INVALID (
                    "ZIP vaults only accept regular files and directories: %s",
                    file.get_path ());
            }
            var children = file.enumerate_children (
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file ()) != null) {
                validate_entry_name (child.get_name ());
                validate_no_symlinks (file.get_child (child.get_name ()));
            }
            children.close ();
        }

        private static void validate_entry_name (string name) throws Error {
            for (int index = 0; index < name.length; index++) {
                uint8 byte = name.data[index];
                if (byte < 0x20 || byte == 0x7f) {
                    throw new PathPolicyError.INVALID (
                        "ZIP vault paths cannot contain control characters");
                }
            }
        }

        public static void validate_plain_accounts (string path) throws Error {
            string clean = PathPolicy.normalize (path);
            if (!FileUtils.test (clean, FileTest.IS_DIR)
                    || FileUtils.test (clean, FileTest.IS_SYMLINK)) {
                throw new StoreError.NOT_MOUNTED (
                    "Plaintext accounts folder is not unlocked: %s", clean);
            }
            string sentinel = Path.build_filename (clean, LOCKED_NAME);
            if (FileUtils.test (sentinel, FileTest.EXISTS)) {
                throw new StoreError.NOT_MOUNTED (
                    "ZIP vault is already locked");
            }
            PathPolicy.ensure_private_directory (clean);
        }

        public static void prepare_destination (string path) throws Error {
            string clean = PathPolicy.normalize (path);
            if (FileUtils.test (clean, FileTest.EXISTS)) {
                var directory = Dir.open (clean);
                if (directory.read_name () != null) {
                    throw new PathPolicyError.NOT_EMPTY (
                        "Accounts folder must be empty before creating a ZIP vault");
                }
            }
            PathPolicy.ensure_private_directory (clean);
        }

        public static void ensure_locked_destination (string path) throws Error {
            string clean = PathPolicy.normalize (path);
            if (FileUtils.test (clean, FileTest.IS_SYMLINK)) {
                throw new PathPolicyError.INVALID ("Accounts path must not be a symbolic link");
            }
            if (!FileUtils.test (clean, FileTest.EXISTS)) return;
            if (!FileUtils.test (clean, FileTest.IS_DIR)) {
                throw new PathPolicyError.INVALID (
                    "Accounts path is not a folder");
            }
            var directory = Dir.open (clean);
            string? first = directory.read_name ();
            if (first == null) return;
            if (first != LOCKED_NAME || directory.read_name () != null) {
                throw new PathPolicyError.NOT_EMPTY (
                    "Accounts folder contains plaintext data; refusing to overwrite it");
            }
            string sentinel = Path.build_filename (clean, LOCKED_NAME);
            var info = File.new_for_path (sentinel).query_info (
                "standard::type,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            string content;
            if (info.get_file_type () != FileType.REGULAR || info.get_size () != LOCKED_CONTENT.length) {
                throw new PathPolicyError.NOT_EMPTY ("Accounts placeholder contains unexpected data");
            }
            FileUtils.get_contents (sentinel, out content);
            if (content != LOCKED_CONTENT) {
                throw new PathPolicyError.NOT_EMPTY ("Accounts placeholder contains unexpected data");
            }
        }

        public static void remove_locked_destination (string path) throws Error {
            string clean = PathPolicy.normalize (path);
            if (!FileUtils.test (clean, FileTest.EXISTS)) return;
            string sentinel = Path.build_filename (clean, LOCKED_NAME);
            if (FileUtils.test (sentinel, FileTest.EXISTS)) {
                FileUtils.unlink (sentinel);
            }
            if (DirUtils.remove (clean) != 0) {
                throw new IOError.FAILED (
                    "Could not remove locked accounts placeholder");
            }
        }

        public static void create_locked_destination (string path) throws Error {
            PathPolicy.ensure_private_directory (path);
            string sentinel = Path.build_filename (path, LOCKED_NAME);
            FileUtils.set_contents (sentinel, LOCKED_CONTENT);
#if !WINDOWS
            FileUtils.chmod (sentinel, 0600);
#endif
        }

        private static string unique_directory (string parent,
                                                string prefix) throws Error {
            for (int attempt = 0; attempt < 20; attempt++) {
                string path = Path.build_filename (
                    parent, prefix + Uuid.string_random ());
                if (DirUtils.create (path, 0700) == 0) return path;
            }
            throw new IOError.FAILED (
                "Could not create a private staging folder beside the accounts path");
        }
    }
}
