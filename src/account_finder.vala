namespace Dc {

    /**
     * Locates Delta Chat Desktop installations and the deltachat-rpc-server
     * binary via a small fixed list of well-known paths. No filesystem
     * scanning — startup stays fast and predictable.
     */
    public class AccountFinder {

        private const string RPC_BIN = "deltachat-rpc-server";

        /**
         * Return an absolute path to deltachat-rpc-server, or null if none found.
         *
         * When `override_path` is non-empty, it is used exclusively: if it is
         * not executable, null is returned so the caller can surface a
         * "configured path is broken" error instead of silently falling back
         * to the scan.
         */
        public static string? find_rpc_server (string? override_path = null) {
            if (override_path != null && override_path.length > 0) {
                return FileUtils.test (override_path, FileTest.IS_EXECUTABLE) ? override_path : null;
            }

            /* PATH first — covers distro packages, /usr/local, and ~/.local/bin
             * when the user has it exported. */
            string? in_path = Environment.find_program_in_path (RPC_BIN);
            if (in_path != null) return in_path;

            string home = Environment.get_home_dir ();

            /* pip --user or manual install. */
            string user_bin = Path.build_filename (home, ".local", "bin", RPC_BIN);
            if (FileUtils.test (user_bin, FileTest.IS_EXECUTABLE)) return user_bin;

            /* Electron-bundled binary inside a Delta Chat Desktop install.
             * All installs share the same node_modules layout; only the root
             * and the arch suffix differ. */
            string[] app_roots = {
                "/opt/DeltaChat/resources/app.asar.unpacked",
                Path.build_filename (home, ".local", "share", "flatpak", "app",
                                     "chat.delta.desktop", "current", "active",
                                     "files", "delta", "resources", "app"),
                "/var/lib/flatpak/app/chat.delta.desktop/current/active/files/delta/resources/app",
                "/snap/deltachat-desktop/current/resources/app.asar.unpacked",
            };
            string[] arch_dirs = {
                "stdio-rpc-server-linux-x64",
                "stdio-rpc-server-linux-arm64",
            };
            foreach (string root in app_roots) {
                foreach (string arch in arch_dirs) {
                    string candidate = Path.build_filename (
                        root, "node_modules", "@deltachat", arch, RPC_BIN);
                    if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE)) {
                        return candidate;
                    }
                }
            }
            return null;
        }

        /**
         * Return a Delta Chat Desktop data directory to reuse, or create
         * and return a private fallback under ~/.config/parla.
         */
        public static string get_data_dir () {
            string home = Environment.get_home_dir ();
            string[] candidates = {
                Path.build_filename (home, ".var", "app",
                                     "chat.delta.desktop", "config", "DeltaChat"),
                Path.build_filename (home, ".config", "DeltaChat"),
                Path.build_filename (home, "snap", "deltachat-desktop",
                                     "current", ".config", "DeltaChat"),
            };
            foreach (string dir in candidates) {
                string accounts = Path.build_filename (dir, "accounts");
                if (FileUtils.test (accounts, FileTest.IS_DIR)) return dir;
            }
            string fallback = Path.build_filename (home, ".config", "parla");
            DirUtils.create_with_parents (fallback, 0700);
            return fallback;
        }

        /**
         * Activate the first configured account. Returns its id (>0) on
         * success, or 0 with a human-readable status in `description`.
         */
        public static async int ensure_configured (RpcClient rpc,
                out string? description, out string? toast_msg) {
            description = null;
            toast_msg = null;
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node != null) {
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
                }
                description =
                    "No Delta Chat accounts configured.\n" +
                    "Add an account from Settings to connect.";
            } catch (Error e) {
                toast_msg = "Account setup error: " + e.message;
            }
            return 0;
        }
    }
}
