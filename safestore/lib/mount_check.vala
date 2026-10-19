namespace SafeStore {

    // Details of an active mount, taken from the platform mount table.
    // For a mounted CryFS vault the source is "cryfs@<vault path>" and the
    // filesystem type is "fuse.cryfs" (Linux) or the macFUSE type (macOS).
    // Windows only exposes that the drive letter exists, so source and
    // fstype stay empty there.
    internal class MountInfo : Object {

        public string source { get; construct; }
        public string fstype { get; construct; }

        internal MountInfo (string source, string fstype) {
            Object (source: source, fstype: fstype);
        }

        public bool is_cryfs () {
            return fstype.contains ("cryfs")
                || source.has_prefix ("cryfs@");
        }


    }

    internal class MountCheck : Object {

        public static bool is_active (string mount_path) {
            return find (mount_path) != null;
        }

        public static MountInfo? find (string mount_path) {
#if WINDOWS
            string wanted = PathPolicy.normalize (mount_path);
            if (FileUtils.test (wanted + "\\", FileTest.IS_DIR)) {
                return new MountInfo ("", "");
            }
            return null;
#elif LINUX
            string contents;
            try {
                FileUtils.get_contents ("/proc/self/mountinfo", out contents);
            } catch (Error error) {
                return null;
            }
            string wanted = PathPolicy.normalize (mount_path);
            foreach (string line in contents.split ("\n")) {
                string[] fields = line.split (" ");
                if (fields.length < 5
                        || decode_mount_path (fields[4]) != wanted) {
                    continue;
                }
                // Optional fields sit between the mount options and a "-"
                // separator; the filesystem type and source follow it.
                string fstype = "";
                string source = "";
                for (int i = 6; i < fields.length; i++) {
                    if (fields[i] != "-") continue;
                    if (i + 1 < fields.length) fstype = fields[i + 1];
                    if (i + 2 < fields.length) {
                        source = decode_mount_path (fields[i + 2]);
                    }
                    break;
                }
                return new MountInfo (source, fstype);
            }
            return null;
#elif DARWIN
            try {
                string? stdout_text;
                string? stderr_text;
                var process = new Subprocess (
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                    "/sbin/mount"
                );
                process.communicate_utf8 (
                    null, null, out stdout_text, out stderr_text);
                if (!process.get_successful ()) return null;
                string wanted = PathPolicy.normalize (mount_path);
                string marker = " on %s (".printf (wanted);
                foreach (string line in (stdout_text ?? "").split ("\n")) {
                    int position = line.index_of (marker);
                    if (position < 0) continue;
                    string source = line[0:position];
                    string rest = line.substring (
                        position + marker.length);
                    int end = rest.index_of_char (',');
                    if (end < 0) end = rest.index_of_char (')');
                    string fstype = end > 0
                        ? rest[0:end].strip () : rest.strip ();
                    return new MountInfo (source, fstype);
                }
            } catch (Error error) {
                return null;
            }
            return null;
#else
            return null;
#endif
        }

#if LINUX
        private static string decode_mount_path (string path) {
            return path
                .replace ("\\040", " ")
                .replace ("\\011", "\t")
                .replace ("\\012", "\n")
                .replace ("\\134", "\\");
        }
#endif
    }
}
