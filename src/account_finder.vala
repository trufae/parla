namespace Dc {

    /**
     * Locates existing DeltaChat installations, config files, and the RPC server binary.
     * Supports Flatpak, native, and openclaw-deltachat configurations.
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

            /* openclaw-deltachat config files */
            find_openclaw_configs (results);

            return results;
        }

        /**
         * Find the best data directory to start the RPC server in.
         * Prefers Flatpak > native > openclaw > fallback.
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
                Environment.get_home_dir (), ".config", "openclaw-deltachat"
            );
            DirUtils.create_with_parents (fallback, 0700);
            return fallback;
        }

        /**
         * Try to read credentials from the first found openclaw-deltachat config.
         * Returns an Account with email/password if found, null otherwise.
         */
        public static Account? get_credentials_from_config () {
            string[] config_candidates = {
                Environment.get_variable ("OPENCLAW_DELTACHAT_CONFIG") ?? "",
                Environment.get_variable ("DELTACHAT_CONFIG") ?? "",
                Path.build_filename (Environment.get_home_dir (),
                    ".openclaw", "extensions", "deltachat", "deltachat-config.json"),
                Path.build_filename (Environment.get_home_dir (),
                    "prg", "openclaw-deltachat", "deltachat-config.json"),
                "deltachat-config.json"
            };

            foreach (string candidate in config_candidates) {
                if (candidate.length == 0) continue;

                string path = expand_home (candidate);
                if (!Path.is_absolute (path)) {
                    path = Path.build_filename (Environment.get_current_dir (), path);
                }

                if (!FileUtils.test (path, FileTest.EXISTS)) continue;

                var account = parse_openclaw_config (path);
                if (account != null) return account;
            }

            return null;
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

        private static void find_openclaw_configs (GenericArray<FoundInstallation> results) {
            string[] candidates = {
                Path.build_filename (Environment.get_home_dir (),
                    ".openclaw", "extensions", "deltachat", "deltachat-config.json"),
                Path.build_filename (Environment.get_home_dir (),
                    "prg", "openclaw-deltachat", "deltachat-config.json"),
            };

            /* Also check env vars */
            string? env1 = Environment.get_variable ("OPENCLAW_DELTACHAT_CONFIG");
            string? env2 = Environment.get_variable ("DELTACHAT_CONFIG");

            string[] all_candidates = {};
            if (env1 != null && env1.length > 0) all_candidates += expand_home (env1);
            if (env2 != null && env2.length > 0) all_candidates += expand_home (env2);
            foreach (string c in candidates) all_candidates += c;

            foreach (string path in all_candidates) {
                if (!FileUtils.test (path, FileTest.EXISTS)) continue;

                var account = parse_openclaw_config (path);
                if (account == null) continue;

                var inst = new FoundInstallation ();
                inst.label = "OpenClaw config (%s)".printf (Path.get_basename (
                    Path.get_dirname (path)));
                inst.data_path = Path.get_dirname (path);
                inst.email = account.email;
                inst.password = account.password;
                inst.source = "openclaw";
                results.add (inst);
            }
        }

        private static Account? parse_openclaw_config (string path) {
            try {
                string contents;
                FileUtils.get_contents (path, out contents);

                var parser = new Json.Parser ();
                parser.load_from_data (contents);

                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return null;

                var obj = root.get_object ();
                if (!obj.has_member ("accounts")) return null;

                var accounts_node = obj.get_member ("accounts");
                if (accounts_node.get_node_type () != Json.NodeType.ARRAY) return null;

                var accounts = accounts_node.get_array ();
                if (accounts.get_length () == 0) return null;

                var first = accounts.get_object_element (0);
                string? email = null;
                string? password = null;

                if (first.has_member ("email"))
                    email = first.get_string_member ("email");
                else if (first.has_member ("addr"))
                    email = first.get_string_member ("addr");

                if (first.has_member ("mail_pw"))
                    password = first.get_string_member ("mail_pw");
                else if (first.has_member ("password"))
                    password = first.get_string_member ("password");

                if (email == null || email.length == 0) return null;

                var account = new Account ();
                account.email = email;
                account.password = password ?? "";

                if (first.has_member ("display_name") &&
                    !first.get_member ("display_name").is_null ()) {
                    account.display_name = first.get_string_member ("display_name");
                }

                return account;
            } catch (Error e) {
                return null;
            }
        }

        private static string expand_home (string path) {
            if (path == "~") return Environment.get_home_dir ();
            if (path.has_prefix ("~/")) {
                return Path.build_filename (
                    Environment.get_home_dir (), path.substring (2));
            }
            return path;
        }
    }
}
