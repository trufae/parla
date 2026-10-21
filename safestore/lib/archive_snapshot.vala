namespace SafeStore {
    internal class SnapshotEntry : Object {
        public string path;
        public bool directory;
        public uint64 size;
        public string digest;
        public SnapshotEntry (string path, bool directory, uint64 size = 0, string digest = "") {
            this.path = path; this.directory = directory; this.size = size; this.digest = digest;
        }
    }

    // Shared synchronous codec. Callers own leases, staging and publication, and
    // run this off the UI thread. Portable backup v1 remains byte-format compatible;
    // working stores use a distinct encrypted manifest bound to a store generation.
    internal class ArchiveSnapshot : Object {
        private const uint MAX_ENTRIES = 100000;
        private const uint64 MAX_MANIFEST = 32 * 1024 * 1024;
        private string? store_id;
        private uint64 generation;
        private uint64 maximum_bytes;
        private string manifest_name { get { return store_id == null ? "manifest.ini" : "store.ini"; } }
        private string header_group { get { return store_id == null ? "Backup" : "Store"; } }
        public signal void progress (string phase, uint completed, uint total);

        public ArchiveSnapshot (uint64 maximum_bytes, string? store_id = null, uint64 generation = 0) {
            this.maximum_bytes = maximum_bytes;
            this.store_id = store_id;
            this.generation = generation;
        }

        // Structural recognition only. Authentication requires read().
        public static void inspect_store (string path) throws Error {
            if (regular_info (File.new_for_path (path), null).get_file_type () != FileType.REGULAR)
                throw new StoreError.NOT_A_VAULT ("Not a regular AES ZIP store");
            var archive = new Archive (path, false, "", null);
            if (archive.count () < 1 || archive.count () > MAX_ENTRIES + 1)
                throw new StoreError.NOT_A_VAULT ("Invalid AES ZIP store entry count");
            var names = new HashTable<string, bool> (str_hash, str_equal);
            for (uint64 i = 0; i < archive.count (); i++) {
                string name = archive.name (i);
                if (names.contains (name) || (name != "store.ini" && !Regex.match_simple ("^data/[0-9]{8}$", name)))
                    throw new StoreError.NOT_A_VAULT ("Unexpected AES ZIP store entry");
                names.insert (name, true);
                uint64 size = archive.size (name); // Every member must be AES-256.
                if (name == "store.ini" && size > MAX_MANIFEST)
                    throw new StoreError.NOT_A_VAULT ("AES ZIP store manifest is too large");
            }
            if (!names.contains ("store.ini")) throw new StoreError.NOT_A_VAULT ("AES ZIP store manifest is missing");
        }

        // Write to a fresh private path, then authenticate and hash every entry.
        public BackupInfo write (string root, string path, string password, Cancellable? cancel = null) throws Error {
            progress ("scan", 0, 0);
            var entries = new GenericArray<SnapshotEntry> ();
            inventory (root, "", entries, cancel);
            if (entries.length == 0 && store_id == null) throw new IOError.INVALID_DATA ("There are no accounts to back up");
            uint64 bytes = 0;
            foreach (var entry in entries.data) {
                if (entry.size > maximum_bytes - bytes) throw new IOError.NO_SPACE ("Accounts exceed the backup size limit");
                bytes += entry.size;
            }
            string contents = manifest (entries, new DateTime.now_utc ().format_iso8601 ());
            if (contents.length > MAX_MANIFEST) throw new IOError.NO_SPACE ("Backup manifest is too large");
            // Conservative space for uncompressible input and ZIP overhead.
            uint64 overhead = bytes / 100 + entries.length * 1024ULL + contents.length * 2ULL + 4096;
            if (bytes > uint64.MAX - overhead) throw new IOError.NO_SPACE ("Archive size estimate overflows");
            check_space (Path.get_dirname (path), bytes + overhead, cancel);
            var archive = new Archive (path, true, password, cancel);
            archive.add_text (manifest_name, contents);
            for (uint i = 0; i < entries.length; i++) {
                if (!entries[i].directory) archive.add_file ("data/%08u".printf (i), native_path (root, entries[i].path));
            }
            progress ("encrypt", 0, 0);
            archive.finish ();
            Archive.sync (path, false);
            return read (path, password, null, cancel);
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

        public static FileInfo regular_info (File file, Cancellable? cancel) throws Error {
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

        private void inventory (string root, string relative, GenericArray<SnapshotEntry> entries,
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
                entries.add (new SnapshotEntry (name, directory, directory ? 0 : info.get_size (),
                    directory ? "" : hash_file (file, cancel)));
                if (directory) inventory (root, name, entries, cancel, depth + 1);
            }
            children.close (cancel);
        }

        private string manifest (GenericArray<SnapshotEntry> entries, string date) {
            var key = new KeyFile ();
            key.set_integer (header_group, "version", 1);
            if (store_id != null) {
                key.set_string (header_group, "id", store_id);
                key.set_uint64 (header_group, "generation", generation);
            }
            key.set_string (header_group, "created", date);
            key.set_integer (header_group, "entries", (int) entries.length);
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

        private GenericArray<SnapshotEntry> read_manifest (Archive archive, out BackupInfo info) throws Error {
            var key = new KeyFile ();
            key.load_from_data (archive.read_text (manifest_name, MAX_MANIFEST), -1, KeyFileFlags.NONE);
            if (key.get_integer (header_group, "version") != 1)
                throw new IOError.NOT_SUPPORTED ("Unsupported backup version");
            if (store_id != null && (key.get_string (header_group, "id") != store_id
                    || key.get_uint64 (header_group, "generation") != generation))
                throw new StoreError.RECOVERY_REQUIRED ("Encrypted store identity or generation does not match its metadata");
            int count = key.get_integer (header_group, "entries");
            if (count < 0 || count > MAX_ENTRIES) throw new IOError.INVALID_DATA ("Invalid backup entry count");
            info = new BackupInfo ();
            info.created_at = key.get_string (header_group, "created");
            if (new DateTime.from_iso8601 (info.created_at, null) == null)
                throw new IOError.INVALID_DATA ("Invalid backup date");
            var entries = new GenericArray<SnapshotEntry> ();
            var names = new HashTable<string, bool> (str_hash, str_equal);
            var directories = new HashTable<string, bool> (str_hash, str_equal);
            var zip_names = new HashTable<string, bool> (str_hash, str_equal);
            zip_names.insert (manifest_name, true);
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
                    if (size > maximum_bytes - info.bytes)
                        throw new IOError.NO_SPACE ("Backup exceeds the restore size limit");
                    info.bytes += size;
                    info.files++;
                    zip_names.insert ("data/%08d".printf (i), true);
                }
                entries.add (new SnapshotEntry (path, directory, size, digest));
            }
            if (archive.count () != zip_names.size ()) throw new IOError.INVALID_DATA ("Unexpected archive entries");
            for (uint64 i = 0; i < archive.count (); i++) {
                if (!zip_names.remove (archive.name (i))) throw new IOError.INVALID_DATA ("Duplicate or unexpected archive entry");
            }
            return entries;
        }

        public BackupInfo read (string path, string password, string? destination, Cancellable? cancel = null) throws Error {
            if (regular_info (File.new_for_path (path), cancel).get_file_type () != FileType.REGULAR)
                throw new IOError.INVALID_DATA ("The archive must be a regular file");
            var archive = new Archive (path, false, password, cancel);
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
                if (i % 32 == 0 || i + 1 == entries.length) progress (destination == null ? "verify" : "restore", i + 1, entries.length);
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

        public static void check_space (string directory, uint64 bytes, Cancellable? cancel) throws Error {
            var info = File.new_for_path (directory).query_filesystem_info ("filesystem::free", cancel);
            if (info.has_attribute ("filesystem::free") && info.get_attribute_uint64 ("filesystem::free") < bytes)
                throw new IOError.NO_SPACE ("There is not enough free space at the selected destination");
        }

    }
}
