namespace SafeStore {
    // Bounded ZIP32 structural inspection, following PKWARE APPNOTE 4.3/4.4:
    // https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
    // This recognizes encrypted SafeStore entries; it is not authentication.
    internal class ZipFormat : Object {
        private static uint16 u16 (uint8[] data, int offset) {
            return (uint16) (data[offset] | ((uint16) data[offset + 1] << 8));
        }
        private static uint32 u32 (uint8[] data, int offset) {
            return (uint32) u16 (data, offset) | ((uint32) u16 (data, offset + 2) << 16);
        }
        private static uint8[] read_at (FileInputStream input, int64 offset, int size) throws Error {
            input.seek (offset, SeekType.SET);
            var data = new uint8[size];
            size_t actual;
            input.read_all (data, out actual);
            if (actual != size) throw new StoreError.NOT_A_VAULT ("Truncated ZIP archive");
            return data;
        }
        private static string name_at (FileInputStream input, int64 offset, int size) throws Error {
            var data = read_at (input, offset, size);
            var name = new StringBuilder ();
            foreach (uint8 value in data) {
                if (value < 0x20 || value == 0x7f || value == '\\' || value == ':') {
                    throw new StoreError.NOT_A_VAULT ("Unsafe ZIP entry name");
                }
                name.append_c ((char) value);
            }
            string result = name.str;
            if (result.length == 0 || result.has_prefix ("/")) {
                throw new StoreError.NOT_A_VAULT ("Unsafe ZIP entry name");
            }
            foreach (string part in result.split ("/")) {
                if (part == "." || part == "..") throw new StoreError.NOT_A_VAULT ("Unsafe ZIP path");
            }
            if (result.contains ("//")) throw new StoreError.NOT_A_VAULT ("Ambiguous ZIP path");
            return result;
        }

        public static void validate (string path) throws Error {
            var file = File.new_for_path (path);
            var info = file.query_info ("standard::type,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (info.get_file_type () != FileType.REGULAR || info.get_size () < 22) {
                throw new StoreError.NOT_A_VAULT ("Not a regular SafeStore ZIP archive");
            }
            int64 size = info.get_size ();
            var input = file.read ();
            int tail_size = (int) int64.min (size, 65557);
            var tail = read_at (input, size - tail_size, tail_size);
            int end = -1;
            for (int i = tail.length - 22; i >= 0; i--) {
                if (u32 (tail, i) == 0x06054b50 && i + 22 + u16 (tail, i + 20) == tail.length) {
                    end = i;
                    break;
                }
            }
            if (end < 0) throw new StoreError.NOT_A_VAULT ("ZIP directory is missing");
            uint count = u16 (tail, end + 10);
            uint32 directory_size = u32 (tail, end + 12);
            uint32 directory_offset = u32 (tail, end + 16);
            if (count == 0xffff || directory_size == uint32.MAX || directory_offset == uint32.MAX) {
                throw new StoreError.NOT_SUPPORTED ("ZIP64 needs a separately qualified adapter");
            }
            if (u16 (tail, end + 4) != 0 || u16 (tail, end + 6) != 0
                    || u16 (tail, end + 8) != count || count < 2
                    || (uint64) directory_offset + directory_size != size - tail_size + end) {
                throw new StoreError.NOT_A_VAULT ("Invalid or split ZIP directory");
            }
            int64 position = directory_offset;
            bool marker = false;
            string? root = null;
            var names = new HashTable<string, bool> (str_hash, str_equal);
            for (uint i = 0; i < count; i++) {
                if (position + 46 > (int64) directory_offset + directory_size) {
                    throw new StoreError.NOT_A_VAULT ("Truncated ZIP directory");
                }
                var header = read_at (input, position, 46);
                if (u32 (header, 0) != 0x02014b50) throw new StoreError.NOT_A_VAULT ("Invalid ZIP entry");
                int length = u16 (header, 28);
                int extra = u16 (header, 30);
                int comment = u16 (header, 32);
                if (position + 46 + length + extra + comment > (int64) directory_offset + directory_size) {
                    throw new StoreError.NOT_A_VAULT ("Invalid ZIP entry length");
                }
                string name = name_at (input, position + 46, length);
                uint16 flags = u16 (header, 8);
                uint16 method = u16 (header, 10);
                uint mode = u32 (header, 38) >> 16;
                bool directory = name.has_suffix ("/");
                if (names.contains (name) || (!directory && (flags & 1) == 0)
                        || (flags & (1 << 6)) != 0 || (method != 0 && method != 8)
                        || u16 (header, 34) != 0 || (mode & 0170000) == 0120000) {
                    throw new StoreError.NOT_A_VAULT ("ZIP entries are duplicated, unsafe, or not encrypted");
                }
                names.insert (name, true);
                uint32 local_offset = u32 (header, 42);
                uint32 compressed = u32 (header, 20);
                if (!directory && compressed < 12) throw new StoreError.NOT_A_VAULT ("Missing ZIP encryption header");
                if (local_offset == uint32.MAX || compressed == uint32.MAX || u32 (header, 24) == uint32.MAX) {
                    throw new StoreError.NOT_SUPPORTED ("ZIP64 entry is not supported");
                }
                if ((uint64) local_offset + 30 > directory_offset) throw new StoreError.NOT_A_VAULT ("Invalid ZIP offset");
                var local = read_at (input, local_offset, 30);
                if (u32 (local, 0) != 0x04034b50 || u16 (local, 6) != flags || u16 (local, 8) != method
                        || u16 (local, 26) != length
                        || (uint64) local_offset + 30 + length + u16 (local, 28) + compressed > directory_offset
                        || name_at (input, (int64) local_offset + 30, length) != name) {
                    throw new StoreError.NOT_A_VAULT ("ZIP local and directory entries disagree");
                }
                if (!name.contains ("/") && name.has_prefix (".safestore-zip-marker-")) {
                    if (marker || u32 (header, 24) != "SafeStore ZIP backend v1\n".length) {
                        throw new StoreError.NOT_A_VAULT ("Invalid SafeStore ZIP marker");
                    }
                    marker = true;
                } else {
                    string first = name.split ("/")[0];
                    if (!name.contains ("/") || (root != null && root != first)) {
                        throw new StoreError.NOT_A_VAULT ("ZIP has conflicting account trees");
                    }
                    root = first;
                }
                position += 46 + length + extra + comment;
            }
            input.close ();
            if (!marker || root == null || position != (int64) directory_offset + directory_size) {
                throw new StoreError.NOT_A_VAULT ("Not an encrypted SafeStore ZIP layout");
            }
        }
    }
}
