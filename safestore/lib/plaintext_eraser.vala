namespace SafeStore {

    public class EraseInfo : Object {
        public bool shred_available { get; construct; }
        public string status { get; construct; }
        public string warning { get; construct; }

        public EraseInfo (bool available, string status) {
            Object (
                shred_available: available,
                status: status,
                warning: "Overwrite deletion is best-effort only. SSD wear "
                    + "levelling, copy-on-write filesystems, snapshots, swap, "
                    + "journals, and backups may retain plaintext."
            );
        }
    }

    /** Removes ZIP plaintext without ever following symbolic links. */
    internal class PlaintextEraser : Object {

        public static EraseInfo inspect (Settings settings) {
            bool available = Backends.executable_available (
                settings.shred_binary);
            return new EraseInfo (
                available,
                available
                    ? "Available: regular files can be overwritten before removal"
                    : "Unavailable: shred executable was not found"
            );
        }

        public static void erase_tree (string path,
                                       Settings settings) throws Error {
            string root = PathPolicy.normalize (path);
            if (!FileUtils.test (root, FileTest.EXISTS)
                    && !FileUtils.test (root, FileTest.IS_SYMLINK)) return;
            require_available (settings);
            erase (File.new_for_path (root), settings);
        }

        public static void require_available (Settings settings) throws Error {
            if (settings.secure_delete && !inspect (settings).shred_available) {
                throw new StoreError.BACKEND (
                    "Overwrite deletion was requested, but %s was not found",
                    settings.shred_binary);
            }
        }

        public static void validate_tree (string path,
                                          Settings settings) throws Error {
            require_available (settings);
            if (!settings.secure_delete) return;
            validate_file (File.new_for_path (
                PathPolicy.normalize (path)));
        }

        private static void validate_file (File file) throws Error {
            FileInfo info = file.query_info (
                FileAttribute.STANDARD_TYPE + "," + FileAttribute.UNIX_NLINK,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (info.get_file_type () == FileType.REGULAR
                    && info.has_attribute (FileAttribute.UNIX_NLINK)
                    && info.get_attribute_uint32 (
                        FileAttribute.UNIX_NLINK) > 1) {
                throw new IOError.FAILED (
                    "Refusing to overwrite multiply-linked file: %s",
                    file.get_path ());
            }
            if (info.get_file_type () != FileType.DIRECTORY) return;
            var children = file.enumerate_children (
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file ()) != null) {
                validate_file (file.get_child (child.get_name ()));
            }
            children.close ();
        }

        private static void erase (File file,
                                   Settings settings) throws Error {
            FileInfo info = file.query_info (
                FileAttribute.STANDARD_TYPE + "," + FileAttribute.UNIX_NLINK,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileType type = info.get_file_type ();
            if (type == FileType.DIRECTORY) {
                var children = file.enumerate_children (
                    FileAttribute.STANDARD_NAME,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? child;
                while ((child = children.next_file ()) != null) {
                    erase (file.get_child (child.get_name ()), settings);
                }
                children.close ();
                file.delete ();
                return;
            }
            if (type == FileType.REGULAR && settings.secure_delete) {
                if (info.has_attribute (FileAttribute.UNIX_NLINK)
                        && info.get_attribute_uint32 (
                            FileAttribute.UNIX_NLINK) > 1) {
                    throw new IOError.FAILED (
                        "Refusing to overwrite multiply-linked file: %s",
                        file.get_path ());
                }
                string? path = file.get_path ();
                if (path == null) {
                    throw new IOError.INVALID_ARGUMENT (
                        "Cannot overwrite a non-local file");
                }
                string? stdout_text;
                string? stderr_text;
                var process = new Subprocess (
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                    settings.shred_binary, "-f", "-u", "--", path);
                process.communicate_utf8 (
                    null, null, out stdout_text, out stderr_text);
                if (!process.get_successful ()) {
                    string reason = (stderr_text ?? "").strip ();
                    throw new IOError.FAILED (
                        "Could not overwrite %s: %s",
                        path,
                        reason.length > 0 ? reason : "shred failed");
                }
                return;
            }
            file.delete ();
        }
    }
}
