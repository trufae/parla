namespace SafeStore {
    internal class Metadata : Object {
        public string id;
        public BackendKind backend;
        public string accounts;
        public string storage;
        public uint64 generation = 0;
        public string phase = "creating";

        public Metadata (Settings settings) {
            id = Uuid.string_random ();
            backend = settings.backend == "zip" ? BackendKind.ZIP : BackendKind.CRYFS;
            accounts = settings.mount_path;
            storage = settings.vault_path;
        }

        public static Metadata? load (string directory) throws Error {
            string path = Path.build_filename (directory, "store.ini");
            if (FileUtils.test (directory, FileTest.IS_SYMLINK)
                    || FileUtils.test (path, FileTest.IS_SYMLINK)) {
                throw new StoreError.RECOVERY_REQUIRED ("Store metadata must not be a symbolic link");
            }
            var file = new KeyFile ();
            try { file.load_from_file (path, KeyFileFlags.NONE); }
            catch (FileError.NOENT error) { return null; }
            try {
                if (file.get_integer ("Store", "schema") != 1) {
                    throw new StoreError.NOT_SUPPORTED ("Unsupported store metadata version");
                }
                var result = (Metadata) Object.new (typeof (Metadata));
                result.id = file.get_string ("Store", "id");
                result.backend = BackendKind.parse (file.get_string ("Store", "backend"));
                result.accounts = file.get_string ("Store", "accounts");
                result.storage = file.get_string ("Store", "storage");
                result.generation = file.get_uint64 ("Store", "generation");
                result.phase = file.get_string ("Store", "phase");
                string expected = result.backend == BackendKind.ZIP ? "safestore-zip-v1" : "cryfs-1";
                if (!Uuid.string_is_valid (result.id)
                        || file.get_string ("Store", "format") != expected
                        || !(result.phase in new string[] {
                            "creating", "opening", "unlocked", "locking", "cleanup", "locked", "recovery" })) {
                    throw new StoreError.RECOVERY_REQUIRED ("Invalid store metadata");
                }
                PathPolicy.validate_layout (result.storage, result.accounts, false);
                return result;
            } catch (KeyFileError error) {
                throw new StoreError.RECOVERY_REQUIRED ("Incomplete store metadata: %s", error.message);
            }
        }

        public void save (string directory) throws Error {
#if WINDOWS
            throw new StoreError.NOT_SUPPORTED ("Durable Windows store transitions are not qualified yet");
#else
            var file = new KeyFile ();
            file.set_integer ("Store", "schema", 1);
            file.set_string ("Store", "id", id);
            file.set_string ("Store", "backend", backend.id ());
            file.set_string ("Store", "format", backend == BackendKind.ZIP ? "safestore-zip-v1" : "cryfs-1");
            file.set_string ("Store", "accounts", accounts);
            file.set_string ("Store", "storage", storage);
            file.set_uint64 ("Store", "generation", generation);
            file.set_string ("Store", "phase", phase);
            FileUtils.set_contents_full (Path.build_filename (directory, "store.ini"),
                file.to_data (), -1, FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
#endif
        }

        public void match (Settings settings) throws Error {
            if (accounts != settings.mount_path || storage != settings.vault_path
                    || backend.id () != settings.backend) {
                throw new StoreError.RECOVERY_REQUIRED (
                    "This account location belongs to a different store configuration; changing methods requires migration");
            }
        }
    }
}
