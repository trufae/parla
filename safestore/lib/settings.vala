namespace SafeStore {
    internal class Settings : Object {
        public string mount_path;
        public string vault_path;
        public string state_directory;
        public string backend;
        public string cryfs_binary;
        public string zip_binary;
        public string unzip_binary;
        public string shred_binary;
        public bool secure_delete;
        public int idle_minutes;
        public bool allow_executable_files;
        public MountMode mount_mode;

        public Settings (string accounts, string storage, BackendKind kind,
                         StoreOptions options) {
            mount_path = PathPolicy.normalize (accounts);
            vault_path = PathPolicy.normalize (storage);
            backend = kind.id ();
            state_directory = options.state_directory ?? vault_path + ".state";
            cryfs_binary = options.cryfs_binary;
            zip_binary = options.zip_binary;
            unzip_binary = options.unzip_binary;
            shred_binary = options.shred_binary;
            secure_delete = options.secure_delete;
            idle_minutes = options.idle_minutes;
            allow_executable_files = options.allow_executable_files;
            mount_mode = options.mount_mode;
        }
    }
}
