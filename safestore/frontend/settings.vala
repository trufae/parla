namespace SafeStore {

    internal class ToolSettings : StoreOptions {

        // Standalone-tool preferences. Parla supplies its own explicit paths
        // directly to Store and does not instantiate this adapter.
        public string vault_path {
            owned get {
                if (recorded_storage != null) return recorded_storage;
                if (backend == "zip-aes") return AccountsPath.mount_path () + ".aes.zip";
                return backend == "zip"
                    ? AccountsPath.zip_path () : AccountsPath.vault_path ();
            }
        }
        public string mount_path {
            owned get { return AccountsPath.mount_path (); }
        }
        public string backend { get; set; default = "cryfs"; }

        private string? recorded_storage;
        public async Store open_store (bool require_selected = false, string? binary_override = null) throws Error {
            Store? existing = yield Store.open_existing (mount_path, this);
            if (existing != null) {
                if (require_selected && existing.backend.id () != backend) {
                    throw new StoreError.NOT_SUPPORTED ("Changing an existing store's method requires migration");
                }
                backend = existing.backend.id ();
                recorded_storage = existing.storage_path;
            } else {
                recorded_storage = null;
            }
            if (binary_override != null) {
                if (backend == "zip-aes") throw new StoreError.INVALID_ARGUMENT ("AES ZIP uses the native library, not an external executable");
                if (backend == "zip") zip_binary = binary_override;
                else cryfs_binary = binary_override;
            }
            return new Store (mount_path, vault_path, BackendKind.parse (backend), this);
        }

        public ToolSettings () {
            cryfs_binary = Environment.get_variable ("SAFESTORE_CRYFS") ?? "cryfs";
            zip_binary = Environment.get_variable ("SAFESTORE_ZIP") ?? "zip";
            unzip_binary = Environment.get_variable ("SAFESTORE_UNZIP") ?? "unzip";
            shred_binary = Environment.get_variable ("SAFESTORE_SHRED") ?? "shred";
            backend = "cryfs";
            secure_delete = false;
            idle_minutes = 0;
            state_directory = Path.build_filename (
                Environment.get_user_data_dir (), "safestore", "cryfs-state");
            load ();
        }

        private static string config_path () {
            return Path.build_filename (
                Environment.get_user_config_dir (),
                "safestore",
                "settings.ini"
            );
        }

        private void load () {
            var keyfile = new KeyFile ();
            try {
                keyfile.load_from_file (config_path (), KeyFileFlags.NONE);
            } catch (Error error) {
                return;
            }

            cryfs_binary = read_string (
                keyfile, "cryfs_binary", cryfs_binary);
            zip_binary = read_string (keyfile, "zip_binary", zip_binary);
            unzip_binary = read_string (keyfile, "unzip_binary", unzip_binary);
            shred_binary = read_string (
                keyfile, "shred_binary", shred_binary);
            secure_delete = read_boolean (
                keyfile, "secure_delete", secure_delete);
            // Backend-controlled idle unmounting bypasses writer coordination.
            idle_minutes = 0;
        }

        public void save () {
            var keyfile = new KeyFile ();
            keyfile.set_string ("SafeStore", "cryfs_binary", cryfs_binary);
            keyfile.set_string ("SafeStore", "zip_binary", zip_binary);
            keyfile.set_string ("SafeStore", "unzip_binary", unzip_binary);
            keyfile.set_string ("SafeStore", "shred_binary", shred_binary);
            keyfile.set_boolean (
                "SafeStore", "secure_delete", secure_delete);

            try {
                string parent = Path.get_dirname (config_path ());
                DirUtils.create_with_parents (parent, 0700);
                keyfile.save_to_file (config_path ());
            } catch (Error error) {
                warning ("Could not save SafeStore settings: %s", error.message);
            }
        }

        private static string read_string (KeyFile keyfile,
                                           string key,
                                           string fallback) {
            try {
                return keyfile.get_string ("SafeStore", key);
            } catch (Error error) {
                return fallback;
            }
        }

        private static bool read_boolean (KeyFile keyfile,
                                          string key,
                                          bool fallback) {
            try {
                return keyfile.get_boolean ("SafeStore", key);
            } catch (Error error) {
                return fallback;
            }
        }
    }
}
