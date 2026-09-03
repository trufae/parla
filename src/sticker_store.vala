namespace Dc {

    /** One sticker file in the store, decoded from its file name. */
    public class Sticker : Object {
        public string file_name;    /* full name inside the stickers dir */
        public string pack;
        public string emoji;        /* "" when not set */
        public string display_name; /* original file name */

        public Sticker (string file_name, string pack, string emoji,
                        string display_name) {
            this.file_name = file_name;
            this.pack = pack;
            this.emoji = emoji;
            this.display_name = display_name;
        }
    }

    /**
     * Flat on-disk sticker storage: a single <parla data dir>/stickers
     * directory where each sticker file, regardless of media format, is named
     * "<pack>__<emoji>__<original name>", so the pack and the associated
     * emoji live in the file name and changing either is a rename. A pack
     * exists exactly while at least one file carries its prefix.
     */
    public class StickerStore : Object {

        private const string SEP = "__";

        public static string get_stickers_dir () {
            return Path.build_filename (
                AccountFinder.get_parla_data_dir (), "stickers");
        }

        public static string sticker_path (string file_name) {
            return Path.build_filename (get_stickers_dir (), file_name);
        }

        public static bool is_sticker_filename (string name) {
            string[] parts = name.split (SEP, 3);
            return parts.length == 3 && parts[0].length > 0
                && parts[2].length > 0;
        }

        /** Decode "<pack>__<emoji>__<name>"; null for foreign files. */
        public static Sticker? parse (string file_name) {
            if (!is_sticker_filename (file_name)) return null;
            string[] parts = file_name.split (SEP, 3);
            if (parts.length != 3 || parts[0].length == 0 ||
                parts[2].length == 0) {
                return null;
            }
            return new Sticker (file_name, parts[0], parts[1], parts[2]);
        }

        /** Alphabetical list of the packs named by the sticker files. */
        public static string[] list_packs () {
            var found = new GLib.GenericArray<string> ();
            foreach (Sticker sticker in list_all ()) {
                if (!contains (found, sticker.pack)) found.add (sticker.pack);
            }
            found.sort ((a, b) => strcmp (a, b));
            string[] result = {};
            foreach (string pack in found) result += pack;
            return result;
        }

        /** Stickers of one pack, sorted by display name. */
        public static Sticker[] list_stickers (string pack) {
            Sticker[] result = {};
            foreach (Sticker sticker in list_all ()) {
                if (sticker.pack == pack) result += sticker;
            }
            return result;
        }

        /** Pack name stripped and made safe for the file-name encoding
            (no path separators, no "__"); null when nothing remains. */
        public static string? sanitize_pack_name (string name) {
            string clean = name.strip ()
                .replace ("/", "-").replace ("\\", "-").replace ("_", "-");
            return clean.length > 0 && clean != "." && clean != ".."
                ? clean : null;
        }

        /** Rename a pack by moving every sticker into the new name. When
            the destination pack already holds a same-named sticker it is
            the same content (names are checksums), so the source duplicate
            is dropped and the packs merge. */
        public static void rename_pack (string pack,
                                        string new_pack) throws Error {
            if (pack == new_pack) return;
            foreach (Sticker sticker in list_stickers (pack)) {
                if (!move_sticker (sticker, new_pack)) {
                    delete_sticker (sticker);
                }
            }
        }

        /** Deleting every sticker of a pack deletes the pack itself. */
        public static void delete_pack (string pack) {
            foreach (Sticker sticker in list_stickers (pack)) {
                delete_sticker (sticker);
            }
        }

        /** Copy a file into a pack. The file names are content checksums,
            so a same-named sticker already in the pack is the same sticker:
            returns false and copies nothing. */
        public static bool add_sticker (string pack,
                                        string source_path) throws Error {
            string display = Path.get_basename (source_path);
            if (has_display_name (pack, display)) return false;
            DirUtils.create_with_parents (get_stickers_dir (), 0755);
            var src = File.new_for_path (source_path);
            var dst = File.new_for_path (
                sticker_path (build_file_name (pack, "", display)));
            src.copy (dst, FileCopyFlags.NONE);
            return true;
        }

        /** Rename a sticker into another pack, keeping its emoji. Returns
            false when the destination already holds this sticker. */
        public static bool move_sticker (Sticker sticker,
                                         string dest_pack) throws Error {
            if (has_display_name (dest_pack, sticker.display_name)) {
                return false;
            }
            string new_name = build_file_name (dest_pack, sticker.emoji,
                                               sticker.display_name);
            rename (sticker.file_name, new_name);
            sticker.pack = dest_pack;
            sticker.file_name = new_name;
            return true;
        }

        /** Re-encode the sticker file name with a new emoji. */
        public static void set_emoji (Sticker sticker,
                                      string emoji) throws Error {
            string new_name = build_file_name (sticker.pack, emoji,
                                               sticker.display_name);
            rename (sticker.file_name, new_name);
            sticker.emoji = emoji;
            sticker.file_name = new_name;
        }

        public static void delete_sticker (Sticker sticker) {
            FileUtils.unlink (sticker_path (sticker.file_name));
        }

        private static GLib.GenericArray<Sticker> list_all () {
            var found = new GLib.GenericArray<Sticker> ();
            try {
                var dir = Dir.open (get_stickers_dir ());
                string? name;
                while ((name = dir.read_name ()) != null) {
                    var sticker = parse (name);
                    if (sticker != null) found.add (sticker);
                }
            } catch (Error e) { /* no stickers dir yet */ }
            found.sort ((a, b) => strcmp (a.display_name, b.display_name));
            return found;
        }

        private static string build_file_name (string pack, string emoji,
                                               string display) {
            return pack + SEP + emoji + SEP + display;
        }

        private static void rename (string from, string to) throws Error {
            if (from == to) return;
            if (FileUtils.rename (sticker_path (from),
                                  sticker_path (to)) != 0) {
                throw new IOError.FAILED (
                    "Could not rename %s".printf (from));
            }
        }

        private static bool has_display_name (string pack, string display) {
            foreach (Sticker sticker in list_stickers (pack)) {
                if (sticker.display_name == display) return true;
            }
            return false;
        }

        private static bool contains (GLib.GenericArray<string> items,
                                      string value) {
            foreach (string item in items) {
                if (item == value) return true;
            }
            return false;
        }
    }
}
