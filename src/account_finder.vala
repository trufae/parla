namespace Dc {

    /**
     * Locates existing DeltaChat installations and the RPC server binary.
     * Supports Flatpak, native, and Snap installations.
     */
    public class AccountFinder {

        /* ---- RPC server binary resolution ---- */

        /**
         * Find the deltachat-rpc-server binary. Returns the argv array to spawn it,
         * or null if not found.
         */
        public static string[]? find_rpc_server () {
            /* 1. PATH lookup */
            string? in_path = Environment.find_program_in_path ("deltachat-rpc-server");
            if (in_path != null) {
                return new string[] { in_path };
            }

            /* 2. Common venv location */
            string venv_bin = Path.build_filename (
                Environment.get_home_dir (), ".venv", "deltachat", "bin", "deltachat-rpc-server"
            );
            if (FileUtils.test (venv_bin, FileTest.IS_EXECUTABLE)) {
                return new string[] { venv_bin };
            }

            /* 3. venv via python */
            string venv_py = Path.build_filename (
                Environment.get_home_dir (), ".venv", "deltachat", "bin", "python"
            );
            if (FileUtils.test (venv_py, FileTest.IS_EXECUTABLE)) {
                if (FileUtils.test (venv_bin, FileTest.EXISTS)) {
                    return new string[] { venv_py, venv_bin };
                }
                return new string[] { venv_py, "-m", "deltachat_rpc_server" };
            }

            /* 4. pip --user install */
            string local_bin = Path.build_filename (
                Environment.get_home_dir (), ".local", "bin", "deltachat-rpc-server"
            );
            if (FileUtils.test (local_bin, FileTest.IS_EXECUTABLE)) {
                return new string[] { local_bin };
            }

            /* 5. Inside Flatpak DeltaChat Desktop installation */
            string? flatpak_rpc = find_flatpak_rpc_server ();
            if (flatpak_rpc != null) {
                return new string[] { flatpak_rpc };
            }

            return null;
        }

        /* ---- Installation discovery ---- */

        /**
         * Scan the system for existing DeltaChat data directories and config files.
         * Returns a list of found installations with whatever metadata we can extract.
         */
        public static GenericArray<FoundInstallation> find_installations () {
            var results = new GenericArray<FoundInstallation> ();

            /* Flatpak desktop app */
            string flatpak_dir = Path.build_filename (
                Environment.get_home_dir (),
                ".var", "app", "chat.delta.desktop", "config", "DeltaChat"
            );
            check_deltachat_dir (results, flatpak_dir, "Delta Chat Desktop (Flatpak)");

            /* Native / distro-packaged desktop app */
            string native_dir = Path.build_filename (
                Environment.get_home_dir (), ".config", "DeltaChat"
            );
            check_deltachat_dir (results, native_dir, "Delta Chat Desktop (native)");

            /* XDG_CONFIG_HOME override */
            string? xdg = Environment.get_variable ("XDG_CONFIG_HOME");
            if (xdg != null && xdg.length > 0) {
                string xdg_dir = Path.build_filename (xdg, "DeltaChat");
                if (xdg_dir != native_dir) {
                    check_deltachat_dir (results, xdg_dir, "Delta Chat Desktop (XDG)");
                }
            }

            /* Snap */
            string snap_dir = Path.build_filename (
                Environment.get_home_dir (),
                "snap", "deltachat-desktop", "current", ".config", "DeltaChat"
            );
            check_deltachat_dir (results, snap_dir, "Delta Chat Desktop (Snap)");

            return results;
        }

        /**
         * Find the best data directory to start the RPC server in.
         * Prefers Flatpak > native > fallback.
         */
        public static string get_default_data_dir () {
            var installations = find_installations ();
            for (int i = 0; i < installations.length; i++) {
                var inst = installations[i];
                if (inst.data_path.length > 0 &&
                    FileUtils.test (inst.data_path, FileTest.IS_DIR)) {
                    return inst.data_path;
                }
            }
            /* Fallback: create in user config */
            string fallback = Path.build_filename (
                Environment.get_home_dir (), ".config", "deltachat-gnome"
            );
            DirUtils.create_with_parents (fallback, 0700);
            return fallback;
        }

        /* ---- Private helpers ---- */

        /**
         * Search for deltachat-rpc-server binary inside a Flatpak DeltaChat
         * Desktop installation (user or system).
         */
        private static string? find_flatpak_rpc_server () {
            /* Relative path inside the Flatpak app files */
            string[] arch_variants = {
                "stdio-rpc-server-linux-x64",
                "stdio-rpc-server-linux-arm64",
            };

            string[] flatpak_roots = {
                Path.build_filename (
                    Environment.get_home_dir (),
                    ".local", "share", "flatpak", "app",
                    "chat.delta.desktop", "x86_64", "stable", "active", "files"),
                Path.build_filename (
                    "/var", "lib", "flatpak", "app",
                    "chat.delta.desktop", "x86_64", "stable", "active", "files"),
            };

            foreach (string root in flatpak_roots) {
                foreach (string arch in arch_variants) {
                    string candidate = Path.build_filename (
                        root, "delta", "resources", "app",
                        "node_modules", "@deltachat", arch,
                        "deltachat-rpc-server");
                    if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE)) {
                        return candidate;
                    }
                }
                /* Also check dc-core path */
                string dc_core = Path.build_filename (
                    root, "dc-core", "deltachat-rpc-server",
                    "npm-package", "platform_package",
                    "x86_64-unknown-linux-gnu", "deltachat-rpc-server");
                if (FileUtils.test (dc_core, FileTest.IS_EXECUTABLE)) {
                    return dc_core;
                }
            }

            return null;
        }

        private static void check_deltachat_dir (GenericArray<FoundInstallation> results,
                                                  string dir_path, string label) {
            if (!FileUtils.test (dir_path, FileTest.IS_DIR)) return;

            string accounts_dir = Path.build_filename (dir_path, "accounts");
            if (!FileUtils.test (accounts_dir, FileTest.IS_DIR)) return;

            var inst = new FoundInstallation ();
            inst.label = label;
            inst.data_path = dir_path;
            inst.source = "desktop";

            /* Try to read accounts.toml for email addresses */
            string toml_path = Path.build_filename (dir_path, "accounts.toml");
            if (FileUtils.test (toml_path, FileTest.EXISTS)) {
                string? email = parse_accounts_toml_email (toml_path, accounts_dir);
                if (email != null) inst.email = email;
            }

            results.add (inst);
        }

        /**
         * Parse accounts.toml to extract the configured email address.
         * accounts.toml is a simple TOML file listing account UUIDs.
         * The actual email is in each account's dc.db, but we can list
         * what accounts exist.
         */
        private static string? parse_accounts_toml_email (string toml_path,
                                                           string accounts_dir) {
            try {
                string contents;
                FileUtils.get_contents (toml_path, out contents);

                /* Look for selected_account or first account UUID dir */
                /* accounts.toml format:
                 * selected_account = "uuid-here"
                 * [accounts."uuid-here"]
                 * ...
                 */
                string? selected = null;
                foreach (string line in contents.split ("\n")) {
                    string trimmed = line.strip ();
                    if (trimmed.has_prefix ("selected_account")) {
                        int eq = trimmed.index_of ("=");
                        if (eq >= 0) {
                            selected = trimmed.substring (eq + 1).strip ()
                                .replace ("\"", "").replace ("'", "");
                        }
                        break;
                    }
                }

                if (selected != null && selected.length > 0) {
                    /* Check if this account directory exists and has dc.db */
                    string acct_dir = Path.build_filename (accounts_dir, selected);
                    string db_path = Path.build_filename (acct_dir, "dc.db");
                    if (FileUtils.test (db_path, FileTest.EXISTS)) {
                        return "(account: %s)".printf (selected.substring (0, 8));
                    }
                }
            } catch (Error e) {
                /* Ignore parse errors */
            }
            return null;
        }

        /**
         * Find and activate a configured account, or create one from
         * credentials. Returns the account id (>0) on success, or 0 with
         * a human-readable status in `out description`.
         */
        public static async int ensure_configured (RpcClient rpc,
                out string? description, out string? toast_msg) {
            description = null;
            toast_msg = null;
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node == null) return 0;
                var accounts = accounts_node.get_array ();

                for (uint i = 0; i < accounts.get_length (); i++) {
                    var acct = accounts.get_object_element (i);
                    int id = (int) acct.get_int_member ("id");
                    if (yield rpc.is_configured (id)) {
                        rpc.account_id = id;
                        yield rpc.select_account (id);
                        yield rpc.start_io (id);
                        return id;
                    }
                }

                var installations = find_installations ();
                if (installations.length > 0) {
                    var sb = new StringBuilder ("Found installations:\n");
                    for (int j = 0; j < installations.length; j++) {
                        var inst = installations[j];
                        sb.append ("\xe2\x80\xa2 %s".printf (inst.label));
                        if (inst.email != null) sb.append (" (%s)".printf (inst.email));
                        sb.append ("\n");
                    }
                    description = sb.str + "\nAdd an account from Settings to connect.";
                } else {
                    description =
                        "No Delta Chat accounts found.\n" +
                        "Add an account from Settings to connect.";
                }
            } catch (Error e) {
                toast_msg = "Account setup error: " + e.message;
            }
            return 0;
        }
    }
}
