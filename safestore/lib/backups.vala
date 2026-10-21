namespace SafeStore {
    /** Authenticated contents of a full, portable accounts-folder backup. */
    public class BackupInfo : Object {
        public string created_at { get; internal set; }
        public uint files { get; internal set; }
        public uint64 bytes { get; internal set; }
        public string? restored_path { get; internal set; }
        internal BackupInfo () { }
    }

    /**
     * Full AES-256 ZIP backups, independent of the working-store backend.
     * Callers MUST stop all writers and await core process exit before create().
     * Native leases also reject another core or SafeStore owner. Operations run
     * off the caller's main context. Passwords are borrowed for the async call.
     * Restore only creates a NEW directory; it never replaces a live store.
     */
    public class Backups : Object {
        public static bool available { get { return Archive.available (); } }
        public bool busy { get; private set; }
        public signal void progress (string phase, uint completed, uint total);
        private MainContext context;
        // A limit on untrusted expansion, configurable by callers for larger stores.
        public uint64 maximum_restore_bytes { get; set; default = 1024ULL * 1024 * 1024 * 1024; }
        private ArchiveSnapshot snapshot;

        public Backups () { context = MainContext.ref_thread_default (); }

        private void report (string phase, uint done = 0, uint total = 0) {
            var source = new IdleSource ();
            source.set_callback (() => { progress (phase, done, total); return Source.REMOVE; });
            source.attach (context);
        }

        private void enter (SecretValue password, Cancellable? cancel) throws Error {
            if (busy) throw new IOError.BUSY ("A backup operation is already running");
            if (!available) throw new IOError.NOT_SUPPORTED ("AES-256 backups are unavailable in this build");
            if (password.peek ().length == 0) throw new IOError.INVALID_ARGUMENT ("Enter a backup password");
            if (cancel != null) cancel.set_error_if_cancelled ();
            context = MainContext.ref_thread_default ();
            snapshot = new ArchiveSnapshot (maximum_restore_bytes);
            snapshot.progress.connect ((phase, done, total) => report (phase, done, total));
            busy = true;
        }

        /** Reject a restore destination inside an application's live store,
         * including directory aliases. Call before restore while choosing a folder. */
        public async void validate_restore_destination (string accounts_path, string new_directory) throws Error {
            yield run_worker (() => {
                if (!FileUtils.test (accounts_path, FileTest.EXISTS)) return;
                string root = Archive.resolve_directory (accounts_path);
                string target = Path.build_filename (Archive.resolve_directory (Path.get_dirname (new_directory)), Path.get_basename (new_directory));
#if WINDOWS
                root = root.casefold ();
                target = target.casefold ();
#endif
                if (target == root || target.has_prefix (root + Path.DIR_SEPARATOR_S))
                    throw new IOError.INVALID_ARGUMENT ("Choose a restore location outside the current accounts folder");
            });
        }

        /** Creates and verifies before publishing. Existing destinations are never replaced.
         * Keep the source quiescent until completion. File names are inside the encrypted manifest.
         */
        public async BackupInfo create (string accounts_path, string destination, SecretValue password,
                                        Cancellable? cancel = null) throws Error {
            enter (password, cancel);
            var secret = new SecretValue (password.peek ());
            BackupInfo? result = null;
            try {
                yield run_worker (() => {
                    string root = Archive.resolve_directory (accounts_path);
                    string target = Path.build_filename (Archive.resolve_directory (Path.get_dirname (destination)), Path.get_basename (destination));
                    string compare_root = root;
                    string compare_target = target;
#if WINDOWS
                    compare_root = root.casefold ();
                    compare_target = target.casefold ();
#endif
                    if (Path.get_dirname (root) == root || compare_target == compare_root || compare_target.has_prefix (compare_root + Path.DIR_SEPARATOR_S))
                        throw new IOError.INVALID_ARGUMENT ("Save the backup outside the accounts folder");
                    if (FileUtils.test (target, FileTest.EXISTS | FileTest.IS_SYMLINK))
                        throw new IOError.EXISTS ("A file already exists there. Choose a new backup filename; existing backups are never replaced.");
                    if (ArchiveSnapshot.regular_info (File.new_for_path (root), cancel).get_file_type () != FileType.DIRECTORY)
                        throw new IOError.INVALID_ARGUMENT ("The accounts folder does not exist");
                    // Use the same stable ownership slot as Store; never unlink locks.
                    string control = root + ".safestore";
                    if (!FileUtils.test (control, FileTest.EXISTS)) Archive.make_private_directory (control);
                    if (ArchiveSnapshot.regular_info (File.new_for_path (control), cancel).get_file_type () != FileType.DIRECTORY)
                        throw new IOError.INVALID_DATA ("Invalid store ownership directory");
                    var owner = new Lease (Path.build_filename (control, "owner.lock"));
                    var core = new Lease (Path.build_filename (root, "accounts.lock"));
                    string temporary = Path.build_filename (Path.get_dirname (target), ".parla-backup-" + Uuid.string_random () + ".zip");
                    try {
                        result = snapshot.write (root, temporary, secret.peek (), cancel);
                        if (cancel != null) cancel.set_error_if_cancelled ();
                        Archive.publish (temporary, target);
                        // Once published, cancellation must not misreport a successful commit.
                        try { Archive.sync (Path.get_dirname (target), true); }
                        catch (Error e) {
                            throw new IOError.FAILED ("The verified backup was saved at %s, but the drive could not confirm durable storage: %s", target, e.message);
                        }
                    } finally {
                        FileUtils.unlink (temporary);
                    }
                    // Retain both compact leases through all archive reads/publication.
                    owner = null; core = null;
                });
            } finally { secret.clear (); busy = false; }
            return result;
        }

        /** Authenticates every entry and compares every file hash, without extracting. */
        public async BackupInfo verify (string path, SecretValue password, Cancellable? cancel = null) throws Error {
            enter (password, cancel);
            var secret = new SecretValue (password.peek ());
            BackupInfo? result = null;
            try { yield run_worker (() => { result = snapshot.read (path, secret.peek (), null, cancel); }); }
            finally { secret.clear (); busy = false; }
            return result;
        }

        /** Restores into a new private folder. On failure the incomplete folder is retained
         * for inspection, and its location is included in the error. Existing data is untouched.
         * The caller must validate the application schema before activating this folder.
         */
        public async BackupInfo restore (string path, string new_directory, SecretValue password,
                                         Cancellable? cancel = null) throws Error {
            enter (password, cancel);
            var secret = new SecretValue (password.peek ());
            BackupInfo? result = null;
            try {
                yield run_worker (() => {
                    // Authenticate before creating any plaintext output.
                    var verified = snapshot.read (path, secret.peek (), null, cancel);
                    if (cancel != null) cancel.set_error_if_cancelled ();
                    ArchiveSnapshot.check_space (Path.get_dirname (new_directory), verified.bytes, cancel);
                    Archive.make_private_directory (new_directory);
                    try { result = snapshot.read (path, secret.peek (), new_directory, cancel); }
                    catch (Error e) {
                        throw new IOError.FAILED ("%s\nAn incomplete restore remains at %s. Your current accounts were not changed.", e.message, new_directory);
                    }
                });
            } finally { secret.clear (); busy = false; }
            return result;
        }
    }
}
