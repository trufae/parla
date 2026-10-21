namespace SafeStore {
    [Compact]
    [CCode (cname = "SafeStoreArchive", cheader_filename = "backup_archive.h", free_function = "safestore_archive_free")]
    internal class Archive {
        [CCode (cname = "safestore_archive_available")]
        public static bool available ();
        [CCode (cname = "safestore_archive_new")]
        public Archive (string path, bool create, string password, GLib.Cancellable? cancel) throws GLib.Error;
        [CCode (cname = "safestore_archive_add_file")]
        public bool add_file (string name, string path) throws GLib.Error;
        [CCode (cname = "safestore_archive_add_text")]
        public bool add_text (string name, string text) throws GLib.Error;
        [CCode (cname = "safestore_archive_finish")]
        public bool finish () throws GLib.Error;
        [CCode (cname = "safestore_archive_count")]
        public int64 count ();
        [CCode (cname = "safestore_archive_name")]
        public string name (uint64 index) throws GLib.Error;
        [CCode (cname = "safestore_archive_size")]
        public uint64 size (string name) throws GLib.Error;
        [CCode (cname = "safestore_archive_read_text")]
        public string read_text (string name, uint64 limit) throws GLib.Error;
        [CCode (cname = "safestore_archive_read_file")]
        public string read_file (string name, string? destination, uint64 expected_size) throws GLib.Error;
        [CCode (cname = "safestore_backup_sync")]
        public static bool sync (string path, bool directory) throws GLib.Error;
        [CCode (cname = "safestore_backup_publish")]
        public static bool publish (string source, string destination) throws GLib.Error;
        [CCode (cname = "safestore_archive_replace")]
        public static bool replace (string source, string destination) throws GLib.Error;
        [CCode (cname = "safestore_backup_mkdir")]
        public static bool make_private_directory (string path) throws GLib.Error;
        [CCode (cname = "safestore_backup_resolve_directory")]
        public static string resolve_directory (string path) throws GLib.Error;
    }
}
