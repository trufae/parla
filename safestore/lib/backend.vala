namespace SafeStore {

    /** A stable backend identifier saved in settings and accepted by the CLI. */
    public enum BackendKind {
        CRYFS,
        ZIP;

        public string id () {
            return this == ZIP ? "zip" : "cryfs";
        }

        public static BackendKind parse (string value) throws Error {
            switch (value.ascii_down ()) {
            case "cryfs": return CRYFS;
            case "zip": return ZIP;
            default:
                throw new StoreError.BACKEND (
                    "Unknown encryption backend: %s", value);
            }
        }
    }

    /** Runtime capability and security information suitable for a CLI or UI. */
    public class BackendInfo : Object {
        public BackendKind kind { get; construct; }
        public string id { get; construct; }
        public string name { get; construct; }
        public bool available { get; construct; }
        public string status { get; construct; }
        public string protection { get; construct; }
        public string operation { get; construct; }
        public bool experimental { get { return true; } }
        public Operation supported_operations {
            get {
                return Operation.INSPECT | Operation.PROBE
                    | (available ? Operation.CREATE_EMPTY | Operation.UNLOCK
                        | Operation.LOCK : Operation.NONE);
            }
        }

        public bool supports (Operation operation) {
            return (supported_operations & operation) == operation;
        }

        public BackendInfo (BackendKind kind,
                            string name,
                            bool available,
                            string status,
                            string protection,
                            string operation) {
#if SAFESTORE_UNSUPPORTED
            available = false;
            status = "SafeStore operations are not supported on this platform";
#endif
            Object (
                kind: kind,
                id: kind.id (),
                name: name,
                available: available,
                status: status,
                protection: protection,
                operation: operation
            );
        }
    }

    /** Backend discovery is deliberately side-effect free. */
    internal class Backends : Object {

        public static BackendInfo[] list (Settings settings) {
            BackendInfo[] result = {};
            result += inspect_cryfs (settings);
            result += inspect_zip (settings);
            return result;
        }

        public static BackendInfo selected (Settings settings) throws Error {
            BackendKind wanted = BackendKind.parse (settings.backend);
            return inspect (settings, wanted);
        }

        public static BackendInfo inspect (Settings settings,
                                           BackendKind kind) {
            return kind == BackendKind.ZIP
                ? inspect_zip (settings) : inspect_cryfs (settings);
        }

        public static bool executable_available (string binary) {
            if (Path.is_absolute (binary)) {
                return FileUtils.test (binary, FileTest.IS_EXECUTABLE);
            }
            return Environment.find_program_in_path (binary) != null;
        }

        internal static string stable_cryfs_version (string output) throws Error {
            foreach (string line in output.split ("\n")) {
                string clean = line.strip ();
                if (Regex.match_simple ("^(CryFS Version|cryfs) 1\\.[0-9]+\\.[0-9]+$", clean)) {
                    return clean.substring (clean.last_index_of_char (' ') + 1);
                }
            }
            throw new StoreError.NOT_SUPPORTED ("A stable CryFS 1.x release is required");
        }

        private static BackendInfo inspect_cryfs (Settings settings) {
            bool available = executable_available (settings.cryfs_binary);
            string status = available
                ? "Installed; stable CryFS 1.x is required"
                : "Unavailable: CryFS executable was not found";
            if (available) {
                try {
                    string version = stable_cryfs_version (Vault.backend_version (settings.cryfs_binary));
                    string unmount = CryfsBackend.unmount_binary_for (settings.cryfs_binary);
                    if (!executable_available (unmount)) {
                        throw new StoreError.BACKEND ("Matching cryfs-unmount executable was not found");
                    }
                    if (stable_cryfs_version (Vault.backend_version (unmount)) != version) {
                        throw new StoreError.BACKEND ("CryFS and cryfs-unmount versions do not match");
                    }
                    status = "CryFS " + version;
                } catch (Error error) {
                    available = false;
                    status = "Unavailable: " + error.message;
                }
            }
#if WINDOWS
            available = false;
            status = "Unavailable: Windows mount identity and durable transitions are not qualified";
#endif
            return new BackendInfo (
                BackendKind.CRYFS,
                "CryFS",
                available,
                status,
                "Strong encrypted filesystem: XChaCha20-Poly1305; hides "
                    + "file names, sizes, contents, and directory structure.",
                "Mounts a decrypted filesystem while unlocked; ciphertext "
                    + "remains in the vault directory."
            );
        }

        private static BackendInfo inspect_zip (Settings settings) {
            bool zip = executable_available (settings.zip_binary);
            bool unzip = executable_available (settings.unzip_binary);
            bool pty = ZipBackend.password_channel_available ();
            bool available = zip && unzip && pty;
            string status;
            if (!zip) status = "Unavailable: zip executable was not found";
            else if (!unzip) {
                status = "Unavailable: unzip executable was not found";
            } else if (!pty) {
                status = "Unavailable: no private interactive password channel "
                    + "on this platform";
            } else {
                try {
                    status = "Available: " + ZipBackend.probe_tools (settings);
                } catch (Error error) {
                    available = false;
                    status = "Unavailable: " + error.message;
                }
            }
            return new BackendInfo (
                BackendKind.ZIP,
                "ZIP archive (weaker)",
                available,
                status,
                "Weak legacy ZipCrypto. File names and archive metadata remain "
                    + "visible; use only as an explicit compatibility option.",
                "Extracts a full plaintext copy while unlocked and rewrites the "
                    + "archive when locking. Passwords use a private pseudo-terminal."
            );
        }
    }

    internal class CryfsBackend : Object {

        public static string exit_message (int status) {
            switch (status) {
            case 0: return "CryFS exited; vault is locked";
            case 10: return "CryFS rejected the command-line options";
            case 11: return "Wrong vault password";
            case 12: return "CryFS rejected an empty password";
            case 13: return "Vault format is newer than this CryFS version";
            case 14: return "Vault requires an explicit filesystem upgrade";
            case 15: return "Vault uses an unsupported cipher";
            case 16: return "Encrypted vault folder is inaccessible";
            case 17: return "Mount location is inaccessible";
            case 18: return "Encrypted vault is inside the mount location";
            case 19: return "Selected folder is not a valid CryFS vault";
            case 20: return "CryFS detected a replaced filesystem";
            case 21: return "CryFS detected a changed encryption key";
            case 22: return "CryFS integrity setup does not match";
            case 23: return "Vault is configured for a single client";
            case 24: return "CryFS detected an earlier integrity violation";
            case 25: return "CryFS detected a filesystem integrity violation";
            default:
                return "CryFS exited with status %d".printf (status);
            }
        }

        public static string unmount_binary_for (string cryfs_binary) {
            string directory = Path.get_dirname (cryfs_binary);
            string basename = Path.get_basename (cryfs_binary);
            if (directory == "." && basename == cryfs_binary) {
                return "cryfs-unmount";
            }
#if WINDOWS
            string executable = basename.ascii_down ();
            if (executable.has_suffix (".exe")) {
                return Path.build_filename (
                    directory, "cryfs-unmount.exe");
            }
#endif
            return Path.build_filename (directory, "cryfs-unmount");
        }

        public static void apply_environment (SubprocessLauncher launcher,
                                              string state_directory)
                                              throws Error {
            PathPolicy.ensure_private_directory (state_directory);
            launcher.setenv ("CRYFS_FRONTEND", "noninteractive", true);
            launcher.setenv ("CRYFS_NO_UPDATE_CHECK", "true", true);
            launcher.setenv ("CRYFS_LOCAL_STATE_DIR", state_directory, true);
        }
    }
}
