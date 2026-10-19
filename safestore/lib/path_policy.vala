namespace SafeStore {

    public errordomain PathPolicyError {
        INVALID,
        UNSAFE_LAYOUT,
        NOT_EMPTY,
        NOT_A_VAULT
    }

    internal class PathPolicy : Object {

        private const int PRIVATE_MODE = 0700;

        public static string normalize (string path) {
            string clean = path.strip ();
            if (clean.length == 0) return "";
#if WINDOWS
            if (is_drive_mount (clean)) {
                return clean[0:1].ascii_up () + ":";
            }
#endif
            return Filename.canonicalize (clean);
        }

        private static bool same_or_nested (string candidate,
                                            string parent) {
            if (candidate.length == 0 || parent.length == 0) return false;
            var child_file = File.new_for_path (
                resolved_for_comparison (candidate));
            var parent_file = File.new_for_path (
                resolved_for_comparison (parent));
            return child_file.equal (parent_file)
                || child_file.has_prefix (parent_file);
        }

        public static void validate_layout (string vault_path,
                                            string mount_path,
                                            bool require_drive = true)
                                            throws PathPolicyError {
            string raw_vault = vault_path.strip ();
            string raw_mount = mount_path.strip ();
            if (raw_vault.length == 0 || raw_mount.length == 0) {
                throw new PathPolicyError.INVALID (
                    "Choose both the encrypted vault and mount folders.");
            }
            if (!Path.is_absolute (raw_vault)
                    || !(mount_is_absolute (raw_mount)
                        || (!require_drive && Path.is_absolute (raw_mount)))) {
                throw new PathPolicyError.INVALID (
                    "Vault and mount folders must use absolute paths.");
            }

            string vault = normalize (vault_path);
            string mount = normalize (mount_path);
#if WINDOWS
            if (require_drive && !is_drive_mount (mount)) {
                throw new PathPolicyError.INVALID (
                    "CryFS 1.x on Windows requires an unused drive letter, for example G:.");
            }
#endif
            if (same_or_nested (mount, vault)
                    || same_or_nested (vault, mount)) {
                throw new PathPolicyError.UNSAFE_LAYOUT (
                    "Vault and mount folders must be separate siblings, not nested.");
            }
        }

        public static void validate_mountpoint (string mount_path)
                                               throws Error {
            string mount = normalize (mount_path);
#if WINDOWS
            if (FileUtils.test (mount + "\\", FileTest.EXISTS)) {
                throw new PathPolicyError.NOT_EMPTY (
                    "The selected Windows drive letter is already in use.");
            }
            return;
#else
            if (!FileUtils.test (mount, FileTest.EXISTS)) return;
            if (!FileUtils.test (mount, FileTest.IS_DIR)) {
                throw new PathPolicyError.INVALID (
                    "The mount path exists but is not a folder.");
            }

            var directory = Dir.open (mount);
            if (directory.read_name () != null) {
                throw new PathPolicyError.NOT_EMPTY (
                    "The mount folder must be empty before mounting.");
            }
#endif
        }

        public static void validate_new_vault (string vault_path)
                                               throws Error {
            string vault = normalize (vault_path);
            if (!FileUtils.test (vault, FileTest.EXISTS)) return;
            if (!FileUtils.test (vault, FileTest.IS_DIR)) {
                throw new PathPolicyError.INVALID (
                    "The vault path exists but is not a folder.");
            }

            var directory = Dir.open (vault);
            if (directory.read_name () != null) {
                throw new PathPolicyError.NOT_EMPTY (
                    "A new vault folder must be empty.");
            }
        }

        public static void validate_existing_vault (string vault_path)
                                                    throws Error {
            string config = Path.build_filename (
                normalize (vault_path), "cryfs.config");
            if (!FileUtils.test (config, FileTest.IS_REGULAR)) {
                throw new PathPolicyError.NOT_A_VAULT (
                    "No cryfs.config was found in the selected vault folder.");
            }
        }

        // CryFS protects the contents at rest, but the backing directory and
        // the unmounted mountpoint still need ordinary OS access controls.
        // Refuse symlinks and directories belonging to another account, then
        // remove all group/other permissions before CryFS sees the path.
        public static void ensure_private_directory (string directory_path)
                                                     throws Error {
            string path = normalize (directory_path);
            if (DirUtils.create_with_parents (path, PRIVATE_MODE) != 0
                    && !FileUtils.test (path, FileTest.IS_DIR)) {
                throw new IOError.FAILED (
                    "Could not create private folder: %s", path);
            }
#if !WINDOWS
            int descriptor = Posix.open (
                path,
                Posix.O_RDONLY | Posix.O_DIRECTORY
                    | Posix.O_NOFOLLOW | Posix.O_CLOEXEC
            );
            if (descriptor < 0) {
                throw new PathPolicyError.INVALID (
                    "Private folder must be a real accessible directory: %s",
                    path);
            }
            Posix.Stat info;
            if (Posix.fstat (descriptor, out info) != 0
                    || !Posix.S_ISDIR (info.st_mode)) {
                Posix.close (descriptor);
                throw new PathPolicyError.INVALID (
                    "Private folder is not a directory: %s",
                    path);
            }
            if (info.st_uid != Posix.geteuid ()) {
                Posix.close (descriptor);
                throw new PathPolicyError.INVALID (
                    "Private folder is not owned by the current user: %s", path);
            }
            if ((info.st_mode & 07777) != PRIVATE_MODE
                    && Posix.fchmod (descriptor, PRIVATE_MODE) != 0) {
                Posix.close (descriptor);
                throw new IOError.PERMISSION_DENIED (
                    "Could not restrict private folder permissions: %s", path);
            }
            if (Posix.fstat (descriptor, out info) != 0
                    || !Posix.S_ISDIR (info.st_mode)
                    || info.st_uid != Posix.geteuid ()
                    || (info.st_mode & 07777) != PRIVATE_MODE) {
                Posix.close (descriptor);
                throw new IOError.PERMISSION_DENIED (
                    "Private folder permissions could not be verified: %s", path);
            }
            Posix.close (descriptor);
#endif
        }

        private static bool mount_is_absolute (string mount) {
#if WINDOWS
            return is_drive_mount (mount);
#else
            return Path.is_absolute (mount);
#endif
        }

#if WINDOWS
        private static bool is_drive_mount (string path) {
            string clean = path.strip ();
            if (clean.length == 3
                    && (clean.has_suffix ("\\") || clean.has_suffix ("/"))) {
                clean = clean[0:2];
            }
            if (clean.length != 2 || clean[1] != ':') return false;
            char letter = clean[0];
            return (letter >= 'A' && letter <= 'Z')
                || (letter >= 'a' && letter <= 'z');
        }
#else
        private static string resolved_for_comparison (string path) {
            string current = normalize (path);
            string missing = "";

            while (!FileUtils.test (current, FileTest.EXISTS)) {
                string parent = Path.get_dirname (current);
                if (parent == current) break;
                string basename = Path.get_basename (current);
                missing = missing.length == 0
                    ? basename
                    : Path.build_filename (basename, missing);
                current = parent;
            }

            string? resolved = Posix.realpath (current);
            if (resolved == null) return normalize (path);
            return missing.length == 0
                ? Filename.canonicalize (resolved)
                : Filename.canonicalize (
                    Path.build_filename (resolved, missing));
        }
#endif

#if WINDOWS
        private static string resolved_for_comparison (string path) {
            return normalize (path);
        }
#endif
    }
}
