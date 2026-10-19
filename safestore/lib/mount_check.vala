namespace SafeStore {
    internal class MountInfo : Object {
        public string source { get; construct; }
        public string fstype { get; construct; }
        public string identity { get; construct; }

        internal MountInfo (string source, string fstype, string identity = "") {
            Object (source: source, fstype: fstype, identity: identity);
        }

        public bool matches (string storage) {
            if (!source.has_prefix ("cryfs@") || identity.length == 0) return false;
            if (fstype != "fuse.cryfs" && fstype != "macfuse" && fstype != "osxfuse" && fstype != "fusefs") return false;
            string path = source.substring ("cryfs@".length);
            if (!Path.is_absolute (path)) return false;
            try { return PathPolicy.slot (path) == PathPolicy.slot (storage); }
            catch (Error error) { return false; }
        }
    }

    internal class MountCheck : Object {
        public static MountInfo require_exact (string accounts, string storage,
                                                string? identity = null) throws Error {
            var mount = find (accounts);
            if (mount == null || !mount.matches (storage)
                    || (identity != null && mount.identity != identity)) {
                throw new StoreError.ACCESS_LOST ("The expected encrypted filesystem is not mounted here");
            }
            return mount;
        }

        public static bool is_active (string path) throws Error { return find (path) != null; }

        public static MountInfo? find (string path) throws Error {
#if WINDOWS
            // Presence can only block an operation; it can never prove identity.
            return FileUtils.test (path + "\\", FileTest.IS_DIR)
                ? new MountInfo ("", "", "") : null;
#elif LINUX
            string contents;
            FileUtils.get_contents ("/proc/self/mountinfo", out contents);
            return parse_linux (contents, path);
#elif DARWIN
            string? output;
            string? errors;
            var process = new Subprocess (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE, "/sbin/mount");
            process.communicate_utf8 (null, null, out output, out errors);
            if (!process.get_successful ()) throw new IOError.FAILED ("Could not read the mount table");
            return parse_macos (output ?? "", path);
#else
            throw new StoreError.NOT_SUPPORTED ("Mount inspection is unsupported on this platform");
#endif
        }

#if LINUX || SAFESTORE_TESTS
        public static MountInfo? parse_linux (string contents, string path) throws Error {
            string wanted = PathPolicy.normalize (path);
            MountInfo? result = null;
            foreach (string line in contents.split ("\n")) {
                if (line.length == 0) continue;
                string[] fields = line.split (" ");
                if (fields.length < 7) throw new IOError.INVALID_DATA ("Malformed mount table");
                if (decode (fields[4]) != wanted) continue;
                if (result != null) throw new StoreError.RECOVERY_REQUIRED ("Stacked mounts require recovery");
                int separator = 6;
                while (separator < fields.length && fields[separator] != "-") separator++;
                if (separator + 3 >= fields.length) throw new IOError.INVALID_DATA ("Malformed mount identity");
                result = new MountInfo (decode (fields[separator + 2]), fields[separator + 1],
                    fields[0] + ":" + fields[2] + ":" + fields[3]);
            }
            return result;
        }

#endif
#if DARWIN || SAFESTORE_TESTS
        public static MountInfo? parse_macos (string contents, string path) throws Error {
            string marker = " on " + PathPolicy.normalize (path) + " (";
            MountInfo? result = null;
            foreach (string line in contents.split ("\n")) {
                int position = line.index_of (marker);
                if (position < 0) continue;
                if (result != null) throw new StoreError.RECOVERY_REQUIRED ("Stacked mounts require recovery");
                string source = line[0:position];
                string rest = line.substring (position + marker.length);
                int end = rest.index_of_char (',');
                if (end < 0) end = rest.index_of_char (')');
                if (end < 0) throw new IOError.INVALID_DATA ("Malformed mount table");
                // The device ID distinguishes replacement mounts with the same source.
                string identity = File.new_for_path (path).query_info (
                    "id::filesystem", FileQueryInfoFlags.NONE).get_attribute_string ("id::filesystem") ?? "";
                result = new MountInfo (source, rest[0:end].strip (), identity);
            }
            return result;
        }

#endif
#if LINUX || SAFESTORE_TESTS
        private static string decode (string path) {
            return path.replace ("\\040", " ").replace ("\\011", "\t")
                .replace ("\\012", "\n").replace ("\\134", "\\");
        }
#endif
    }
}
