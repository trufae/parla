namespace Dc {
    /** Validate the core's generated accounts.toml before allowing it to open an
     * imported folder. Fail closed on unknown syntax: the original backup is
     * always retained, so a future reader can support a newer core format. */
    public class AccountBackup : Object {
        public static int[] validate_layout (string root) throws Error {
            var metadata = File.new_for_path (Path.build_filename (root, "accounts.toml"));
            var metadata_info = metadata.query_info ("standard::type,standard::is-symlink,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (metadata_info.get_is_symlink () || metadata_info.get_file_type () != FileType.REGULAR || metadata_info.get_size () > 1024 * 1024)
                throw new IOError.INVALID_DATA (_("Invalid account metadata file"));
            string text;
            size_t length;
            FileUtils.get_contents (metadata.get_path (), out text, out length);
            if (length != text.length || !text.validate ()) throw new IOError.INVALID_DATA (_("Invalid account metadata text"));
            var integer = new Regex ("^(selected_account|next_id|id) = ([0-9]+)$");
            var quoted = new Regex ("^(dir|uuid) = \"([0-9a-fA-F-]+)\"$");
            var order = new Regex ("^(accounts_order = \\[)?[0-9, \\t]*\\]?$");
            int[] ids = {};
            var seen = new HashTable<string, bool> (str_hash, str_equal);
            var fields = new HashTable<string, bool> (str_hash, str_equal);
            bool in_account = false;
            bool in_order = false;
            bool has_selected = false, has_next = false;
            int selected = 0;
            string? directory = null;
            string? uuid = null;
            foreach (string raw in text.split ("\n")) {
                string line = raw.strip ();
                if (line == "" || line.has_prefix ("#")) continue;
                if (!in_account && (in_order || line.has_prefix ("accounts_order = ["))) {
                    if (!order.match (line)) throw new IOError.INVALID_DATA (_("Unsupported account ordering metadata"));
                    in_order = !line.has_suffix ("]");
                    continue;
                }
                if (!in_account && line == "accounts = []")
                    throw new IOError.INVALID_ARGUMENT (_("There are no accounts to back up yet"));
                if (line == "[[accounts]]") {
                    if (in_account) validate_account (root, fields, directory, uuid);
                    in_account = true;
                    fields.remove_all ();
                    directory = null; uuid = null;
                    continue;
                }
                MatchInfo match;
                if (integer.match (line, 0, out match)) {
                    string key = match.fetch (1);
                    int64 value = int64.parse (match.fetch (2));
                    if (value < 0 || value > int.MAX || fields.contains (key) || (in_account != (key == "id")))
                        throw new IOError.INVALID_DATA (_("Invalid account identifier"));
                    fields.insert (key, true);
                    if (key == "id") {
                        if (value == 0 || seen.contains (line)) throw new IOError.INVALID_DATA (_("Duplicate account identifier"));
                        seen.insert (line, true); ids += (int) value;
                    } else if (key == "selected_account") { has_selected = true; selected = (int) value; }
                    else has_next = true;
                } else if (in_account && quoted.match (line, 0, out match)) {
                    string key = match.fetch (1), value = match.fetch (2);
                    if (fields.contains (key) || !Uuid.string_is_valid (value))
                        throw new IOError.INVALID_DATA (_("Invalid account folder metadata"));
                    fields.insert (key, true);
                    if (key == "dir") {
                        if (seen.contains (value.down ())) throw new IOError.INVALID_DATA (_("Duplicate account folder"));
                        seen.insert (value.down (), true); directory = value;
                    } else uuid = value;
                } else {
                    throw new IOError.NOT_SUPPORTED (_("This account metadata format is not supported for backup restore"));
                }
            }
            if (in_account) validate_account (root, fields, directory, uuid);
            if (!has_selected || !has_next || in_order || ids.length == 0)
                throw new IOError.INVALID_DATA (_("No complete accounts were found in this folder"));
            bool found = selected == 0;
            foreach (int id in ids) if (id == selected) found = true;
            if (!found) throw new IOError.INVALID_DATA (_("The selected account is missing"));
            return ids;
        }

        private static void validate_account (string root, HashTable<string, bool> fields,
                                             string? directory, string? uuid) throws Error {
            if (!fields.contains ("id") || directory == null || uuid == null || directory.down () != uuid.down ())
                throw new IOError.INVALID_DATA (_("Incomplete account metadata"));
            var folder = File.new_for_path (Path.build_filename (root, directory));
            var folder_info = folder.query_info ("standard::type,standard::is-symlink", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (folder_info.get_is_symlink () || folder_info.get_file_type () != FileType.DIRECTORY)
                throw new IOError.INVALID_DATA (_("Invalid account directory"));
            var db = File.new_for_path (Path.build_filename (root, directory, "dc.db"));
            var info = db.query_info ("standard::type,standard::is-symlink", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (info.get_is_symlink () || info.get_file_type () != FileType.REGULAR)
                throw new IOError.INVALID_DATA (_("An account database is missing or is not a regular file"));
        }

        public static async void validate_with_core (string path, SettingsManager settings) throws Error {
            int[] ids = validate_layout (path);
            string? server = AccountFinder.find_rpc_server (settings.effective_rpc_server_path (), settings.effective_rpc_server_source ());
            if (server == null) throw new IOError.NOT_FOUND (_("Install Chatmail Core in Settings before using this restored folder"));
            var probe = new RpcClient ();
            try {
                yield probe.start ({server}, AccountFinder.get_data_dir (), path);
                // No start_io: restoration validation must not contact mail servers.
                var accounts = yield probe.get_all_accounts ();
                if (accounts == null || accounts.get_node_type () != Json.NodeType.ARRAY || accounts.get_array ().get_length () != ids.length)
                    throw new IOError.INVALID_DATA (_("Chatmail Core could not open every restored account"));
                foreach (int id in ids) {
                    yield probe.is_configured (id);
                    yield probe.get_config ("addr", id);
                }
                yield probe.stop_gracefully ();
            } finally { probe.stop (); }
        }
    }
}
