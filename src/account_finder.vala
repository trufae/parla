namespace Dc {

    public enum RpcServerSource {
        AUTO = 0,
        CUSTOM = 1
    }

    /**
     * Locates standalone, Parla-owned or distro-provided
     * deltachat-rpc-server binaries.
     */
    public class AccountFinder {

        private const string RPC_BIN = "deltachat-rpc-server";
        /* On-disk file name: Windows binaries carry the .exe suffix. */
#if WINDOWS
        private const string RPC_BIN_FILE = "deltachat-rpc-server.exe";
#else
        private const string RPC_BIN_FILE = "deltachat-rpc-server";
#endif

        /**
         * Return an absolute path to deltachat-rpc-server, or null if none found.
         *
         * Custom mode is exclusive so broken explicit choices can be surfaced
         * instead of silently falling back.
         */
        public static string? find_rpc_server (string? custom_path = null,
                                               RpcServerSource source = RpcServerSource.AUTO) {
            switch (source) {
            case RpcServerSource.CUSTOM:
                return is_executable (custom_path) ? custom_path : null;
            case RpcServerSource.AUTO:
            default:
                return find_standalone_rpc_server ();
            }
        }

        private static string? find_standalone_rpc_server () {
            string? env_path = Environment.get_variable ("PARLA_RPC_SERVER");
            if (env_path != null && env_path.length > 0) {
                return is_executable (env_path) ? env_path : null;
            }

            string? exe_path = Platform.get_executable_path ();
            if (exe_path != null) {
                string exe_dir = Path.get_dirname (exe_path);
                string prefix = Path.get_dirname (exe_dir);
                string[] packaged = {
                    Path.build_filename (exe_dir, RPC_BIN_FILE),
                    Path.build_filename (prefix, "libexec", "parla", RPC_BIN_FILE),
                    Path.build_filename (prefix, "lib", "parla", RPC_BIN_FILE),
                    Path.build_filename ("/app", "bin", RPC_BIN_FILE),
                    Path.build_filename ("/app", "libexec", "parla", RPC_BIN_FILE),
                };
                foreach (string candidate in packaged) {
                    if (is_executable (candidate)) return candidate;
                }
            }

            /* PATH covers distro packages and local installs. */
            string? in_path = Environment.find_program_in_path (RPC_BIN);
            if (in_path != null) return in_path;

            string home = Environment.get_home_dir ();

            string[] user_bins = {
                Path.build_filename (home, ".local", "bin", RPC_BIN_FILE),
                Path.build_filename (home, ".cargo", "bin", RPC_BIN_FILE),
            };
            foreach (string candidate in user_bins) {
                if (is_executable (candidate)) return candidate;
            }

            /* Last resort: a server Parla downloaded into its own data dir.
               Anything packaged or system-provided above wins over this. */
            string managed = get_managed_rpc_path ();
            if (FileUtils.test (managed, FileTest.EXISTS) &&
                !FileUtils.test (managed, FileTest.IS_EXECUTABLE)) {
                FileUtils.chmod (managed, 0755);
            }
            if (is_executable (managed)) return managed;

            return null;
        }

        /**
         * Path to the Parla-managed (self-downloaded) server binary. Kept here
         * so discovery and RpcInstaller agree on a single location.
         */
        public static string get_managed_rpc_path () {
            return Path.build_filename (get_parla_data_dir (), "bin", RPC_BIN_FILE);
        }

        private static bool is_executable (string? path) {
            return path != null && path.length > 0
                && FileUtils.test (path, FileTest.IS_EXECUTABLE);
        }

        /**
         * Return Parla's private Delta Chat data directory. Existing early
         * Parla accounts under ~/.config/parla are kept in place.
         */
        public static string get_parla_data_dir () {
            string data_dir = Path.build_filename (
                Environment.get_user_data_dir (), "parla");
            string old_config_dir = Path.build_filename (
                Environment.get_user_config_dir (), "parla");

            string data_accounts = Path.build_filename (data_dir, "accounts");
            string old_accounts = Path.build_filename (old_config_dir, "accounts");
            if (!FileUtils.test (data_accounts, FileTest.IS_DIR) &&
                FileUtils.test (old_accounts, FileTest.IS_DIR)) {
                return old_config_dir;
            }

            DirUtils.create_with_parents (data_dir, 0700);
            return data_dir;
        }

        public static string get_data_dir () {
            return get_parla_data_dir ();
        }

        /**
         * Activate a configured account on startup. If `preferred_addr` is
         * non-empty and matches a configured account, that one is chosen;
         * otherwise the first configured account is used. Returns its id
         * (>0) on success, or 0 with a human-readable status in
         * `description`.
         */
        public static async int ensure_configured (RpcClient rpc,
                string preferred_addr,
                out string? description, out string? toast_msg) {
            description = null;
            toast_msg = null;
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node != null) {
                    var accounts = accounts_node.get_array ();
                    int first_id = 0;
                    int preferred_id = 0;
                    string want = preferred_addr.down ().strip ();
                    for (uint i = 0; i < accounts.get_length (); i++) {
                        var acct = accounts.get_object_element (i);
                        int id = (int) acct.get_int_member ("id");
                        if (!(yield rpc.is_configured (id))) continue;
                        if (first_id == 0) first_id = id;
                        if (want.length > 0 && preferred_id == 0) {
                            foreach (string addr in yield rpc.get_account_addresses (id)) {
                                if (addr.down ().strip () == want) {
                                    preferred_id = id;
                                    break;
                                }
                            }
                        }
                    }
                    int chosen = preferred_id > 0 ? preferred_id : first_id;
                    if (chosen > 0) {
                        rpc.account_id = chosen;
                        yield rpc.select_account (chosen);
                        return chosen;
                    }
                }
                description = "No profiles configured.";
            } catch (Error e) {
                toast_msg = "Account setup error: " + e.message;
            }
            return 0;
        }
    }
}
