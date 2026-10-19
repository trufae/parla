namespace SafeStore {
    /** Authenticated contents of a full, portable accounts-folder backup. */
    public class BackupInfo : Object {
        public string created_at { get; internal set; }
        public uint files { get; internal set; }
        public uint64 bytes { get; internal set; }
        public string? restored_path { get; internal set; }
        internal BackupInfo () { }
    }

    internal class BackupEntry : Object {
        public string path;
        public bool directory;
        public uint64 size;
        public string digest;
        public BackupEntry (string path, bool directory, uint64 size = 0, string digest = "") {
            this.path = path; this.directory = directory; this.size = size; this.digest = digest;
        }
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
        private const uint MAX_ENTRIES = 100000;
        private const uint64 MAX_MANIFEST = 32 * 1024 * 1024;
        // A limit on untrusted expansion, configurable by callers for larger stores.
        public uint64 maximum_restore_bytes { get; set; default = 1024ULL * 1024 * 1024 * 1024; }
        private uint64 restore_limit;

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
            restore_limit = maximum_restore_bytes;
            busy = true;
        }

        // Portable relative names only: reject traversal, Windows device names,
        // streams, drive letters, and ambiguous case/Unicode aliases on restore.
        internal static void validate_path (string path) throws Error {
            if (path.length == 0 || path.length > 4096 || !path.validate ())
                throw new IOError.INVALID_DATA ("Invalid backup path");
            foreach (string part in path.split ("/")) {
                if (part == "" || part.length > 255 || part == "." || part == ".." || part.has_suffix (".") || part.has_suffix (" "))
                    throw new IOError.INVALID_DATA ("Unsafe backup path: %s", path);
                for (int i = 0; i < part.length; i++) {
                    if ((uint8) part[i] < 32 || "\\:*?\"<>|".index_of_char (part[i]) >= 0)
                        throw new IOError.INVALID_DATA ("Non-portable backup path: %s", path);
                }
                string stem = part.normalize (-1, NormalizeMode.ALL_COMPOSE).up ().split (".")[0];
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || stem == "CONIN$" || stem == "CONOUT$" ||
                    (stem.length == 4 && (stem.has_prefix ("COM") || stem.has_prefix ("LPT")) && stem[3] >= '0' && stem[3] <= '9'))
                    throw new IOError.INVALID_DATA ("Reserved backup path: %s", path);
            }
            if (path.casefold () == "accounts.lock") throw new IOError.INVALID_DATA ("A backup must not contain the runtime lock");
        }

        private static string native_path (string root, string relative) {
            return Path.build_filename (root, relative.replace ("/", Path.DIR_SEPARATOR_S));
        }

        private static FileInfo regular_info (File file, Cancellable? cancel) throws Error {
            var info = file.query_info ("standard::type,standard::is-symlink,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancel);
            if (info.get_is_symlink () || (info.get_file_type () != FileType.REGULAR && info.get_file_type () != FileType.DIRECTORY))
                throw new IOError.INVALID_DATA ("Backup source contains a link or special file: %s", file.get_parse_name ());
            return info;
        }

        private static string hash_file (File file, Cancellable? cancel) throws Error {
            var input = file.read (cancel);
            var hash = new Checksum (ChecksumType.SHA256);
            uint8[] buffer = new uint8[65536];
            ssize_t count;
            while ((count = input.read (buffer, cancel)) > 0) hash.update (buffer, count);
            input.close (cancel);
            return hash.get_string ();
        }

        private void inventory (string root, string relative, GenericArray<BackupEntry> entries,
                                Cancellable? cancel, uint depth = 0) throws Error {
            if (depth > 64) throw new IOError.INVALID_DATA ("Backup folders are nested too deeply");
            var folder = File.new_for_path (relative == "" ? root : native_path (root, relative));
            if (regular_info (folder, cancel).get_file_type () != FileType.DIRECTORY)
                throw new IOError.INVALID_ARGUMENT ("The accounts path must be a directory");
            var children = folder.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancel);
            FileInfo? child;
            while ((child = children.next_file (cancel)) != null) {
                string name = relative == "" ? child.get_name () : relative + "/" + child.get_name ();
                if (name == "accounts.lock") continue;
                validate_path (name);
                if (entries.length >= MAX_ENTRIES) throw new IOError.NO_SPACE ("Too many files in this backup");
                var file = File.new_for_path (native_path (root, name));
                var info = regular_info (file, cancel);
                bool directory = info.get_file_type () == FileType.DIRECTORY;
                entries.add (new BackupEntry (name, directory, directory ? 0 : info.get_size (),
                    directory ? "" : hash_file (file, cancel)));
                if (directory) inventory (root, name, entries, cancel, depth + 1);
            }
            children.close (cancel);
        }

        private static string manifest (GenericArray<BackupEntry> entries, string date) {
            var key = new KeyFile ();
            key.set_integer ("Backup", "version", 1);
            key.set_string ("Backup", "created", date);
            key.set_integer ("Backup", "entries", (int) entries.length);
            for (uint i = 0; i < entries.length; i++) {
                string group = "Entry%u".printf (i);
                var entry = entries[i];
                key.set_string (group, "path", entry.path);
                key.set_boolean (group, "directory", entry.directory);
                key.set_uint64 (group, "size", entry.size);
                key.set_string (group, "sha256", entry.digest);
            }
            return key.to_data ();
        }

        private GenericArray<BackupEntry> read_manifest (Archive archive, out BackupInfo info) throws Error {
            var key = new KeyFile ();
            key.load_from_data (archive.read_text ("manifest.ini", MAX_MANIFEST), -1, KeyFileFlags.NONE);
            if (key.get_integer ("Backup", "version") != 1)
                throw new IOError.NOT_SUPPORTED ("Unsupported backup version");
            int count = key.get_integer ("Backup", "entries");
            if (count < 0 || count > MAX_ENTRIES) throw new IOError.INVALID_DATA ("Invalid backup entry count");
            info = new BackupInfo ();
            info.created_at = key.get_string ("Backup", "created");
            if (new DateTime.from_iso8601 (info.created_at, null) == null)
                throw new IOError.INVALID_DATA ("Invalid backup date");
            var entries = new GenericArray<BackupEntry> ();
            var names = new HashTable<string, bool> (str_hash, str_equal);
            var directories = new HashTable<string, bool> (str_hash, str_equal);
            var zip_names = new HashTable<string, bool> (str_hash, str_equal);
            zip_names.insert ("manifest.ini", true);
            for (int i = 0; i < count; i++) {
                string group = "Entry%d".printf (i);
                string path = key.get_string (group, "path");
                validate_path (path);
                string alias = path.normalize ().casefold ();
                if (names.contains (alias)) throw new IOError.INVALID_DATA ("Duplicate or ambiguous backup path");
                names.insert (alias, true);
                // Parents must precede their children; never create implicit paths.
                int slash = path.last_index_of ("/");
                if (slash >= 0 && !directories.contains (path.substring (0, slash)))
                    throw new IOError.INVALID_DATA ("Missing backup parent directory");
                bool directory = key.get_boolean (group, "directory");
                uint64 size = key.get_uint64 (group, "size");
                string digest = key.get_string (group, "sha256");
                if (directory) {
                    if (size != 0 || digest != "") throw new IOError.INVALID_DATA ("Invalid directory entry");
                    directories.insert (path, true);
                } else {
                    if (digest.length != 64) throw new IOError.INVALID_DATA ("Invalid backup digest");
                    foreach (char c in digest.to_utf8 ()) {
                        if (c == 0) break;
                        if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f'))
                            throw new IOError.INVALID_DATA ("Invalid backup digest");
                    }
                    if (size > restore_limit - info.bytes)
                        throw new IOError.NO_SPACE ("Backup exceeds the restore size limit");
                    info.bytes += size;
                    info.files++;
                    zip_names.insert ("data/%08d".printf (i), true);
                }
                entries.add (new BackupEntry (path, directory, size, digest));
            }
            if (archive.count () != zip_names.size ()) throw new IOError.INVALID_DATA ("Unexpected archive entries");
            for (uint64 i = 0; i < archive.count (); i++) {
                if (!zip_names.remove (archive.name (i))) throw new IOError.INVALID_DATA ("Duplicate or unexpected archive entry");
            }
            return entries;
        }

        private BackupInfo read_now (string path, SecretValue password, string? destination, Cancellable? cancel) throws Error {
            var archive = new Archive (path, false, password.peek (), cancel);
            BackupInfo info;
            var entries = read_manifest (archive, out info);
            for (uint i = 0; i < entries.length; i++) {
                if (cancel != null) cancel.set_error_if_cancelled ();
                var entry = entries[i];
                string? target = destination == null ? null : native_path (destination, entry.path);
                if (entry.directory) {
                    if (target != null) Archive.make_private_directory (target);
                } else {
                    string digest = archive.read_file ("data/%08u".printf (i), target, entry.size);
                    if (digest != entry.digest) throw new IOError.INVALID_DATA ("Backup content does not match its encrypted manifest");
                    if (target != null) Archive.sync (target, false);
                }
                if (i % 32 == 0 || i + 1 == entries.length) report (destination == null ? "verify" : "restore", i + 1, entries.length);
            }
            if (destination != null) {
                for (uint i = entries.length; i > 0; i--) {
                    if (entries[i - 1].directory) Archive.sync (native_path (destination, entries[i - 1].path), true);
                }
                Archive.sync (destination, true);
                Archive.sync (Path.get_dirname (destination), true);
                info.restored_path = destination;
            }
            return info;
        }

        private static void check_space (string directory, uint64 bytes, Cancellable? cancel) throws Error {
            var info = File.new_for_path (directory).query_filesystem_info ("filesystem::free", cancel);
            if (info.has_attribute ("filesystem::free") && info.get_attribute_uint64 ("filesystem::free") < bytes)
                throw new IOError.NO_SPACE ("There is not enough free space at the selected destination");
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
                    if (regular_info (File.new_for_path (root), cancel).get_file_type () != FileType.DIRECTORY)
                        throw new IOError.INVALID_ARGUMENT ("The accounts folder does not exist");
                    // Use the same stable ownership slot as Store; never unlink locks.
                    string control = root + ".safestore";
                    if (!FileUtils.test (control, FileTest.EXISTS)) Archive.make_private_directory (control);
                    if (regular_info (File.new_for_path (control), cancel).get_file_type () != FileType.DIRECTORY)
                        throw new IOError.INVALID_DATA ("Invalid store ownership directory");
                    var owner = new Lease (Path.build_filename (control, "owner.lock"));
                    var core = new Lease (Path.build_filename (root, "accounts.lock"));
                    string temporary = Path.build_filename (Path.get_dirname (target), ".parla-backup-" + Uuid.string_random () + ".zip");
                    try {
                        report ("scan");
                        var entries = new GenericArray<BackupEntry> ();
                        inventory (root, "", entries, cancel);
                        if (entries.length == 0) throw new IOError.INVALID_DATA ("There are no accounts to back up");
                        uint64 bytes = 0;
                        foreach (var entry in entries.data) {
                            if (entry.size > restore_limit - bytes) throw new IOError.NO_SPACE ("Accounts exceed the backup size limit");
                            bytes += entry.size;
                        }
                        string contents = manifest (entries, new DateTime.now_utc ().format_iso8601 ());
                        if (contents.length > MAX_MANIFEST) throw new IOError.NO_SPACE ("Backup manifest is too large");
                        // Conservative space for uncompressible input and ZIP overhead.
                        check_space (Path.get_dirname (target), bytes + bytes / 100 + entries.length * 1024ULL + contents.length * 2ULL + 4096, cancel);
                        var archive = new Archive (temporary, true, secret.peek (), cancel);
                        archive.add_text ("manifest.ini", contents);
                        for (uint i = 0; i < entries.length; i++) {
                            if (!entries[i].directory) archive.add_file ("data/%08u".printf (i), native_path (root, entries[i].path));
                        }
                        report ("encrypt");
                        archive.finish ();
                        Archive.sync (temporary, false);
                        result = read_now (temporary, secret, null, cancel);
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
            try { yield run_worker (() => { result = read_now (path, secret, null, cancel); }); }
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
                    var verified = read_now (path, secret, null, cancel);
                    if (cancel != null) cancel.set_error_if_cancelled ();
                    check_space (Path.get_dirname (new_directory), verified.bytes, cancel);
                    Archive.make_private_directory (new_directory);
                    try { result = read_now (path, secret, new_directory, cancel); }
                    catch (Error e) {
                        throw new IOError.FAILED ("%s\nAn incomplete restore remains at %s. Your current accounts were not changed.", e.message, new_directory);
                    }
                });
            } finally { secret.clear (); busy = false; }
            return result;
        }
    }
}
