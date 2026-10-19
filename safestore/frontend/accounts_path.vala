namespace SafeStore {

    /**
     * Resolves the Delta Chat accounts location exactly like Parla resolves
     * the DC_ACCOUNTS_PATH it hands to deltachat-rpc-server, so the vault
     * and mount locations are fully predictable:
     *
     *   1. $DC_ACCOUNTS_PATH when set and non-empty,
     *   2. the accounts_path key in Parla's settings.ini,
     *   3. Parla's data directory plus "accounts", keeping the legacy
     *      config-dir location when it already holds accounts.
     *
     * The mount point IS the accounts path — the decrypted view is what the
     * RPC server reads — and the encrypted vault sits beside it as
     * "<accounts>.vault".
     */
    internal class AccountsPath : Object {

        public static string resolve () {
            string env = environment_path ();
            if (env.length > 0) return env;
            string configured = parla_configured_path ();
            if (configured.length > 0) return configured;
            return Path.build_filename (parla_data_dir (), "accounts");
        }

        /** Where the resolved path came from, for status output. */
        public static string source () {
            if (environment_path ().length > 0) return "DC_ACCOUNTS_PATH";
            if (parla_configured_path ().length > 0) return "Parla settings";
            return "Parla default";
        }

        public static string mount_path () {
            return resolve ();
        }

        public static string vault_path () {
            string accounts = resolve ();
#if WINDOWS
            // A drive-letter mount has no parent folder to hold the vault;
            // keep the ciphertext under Parla's data directory instead.
            if (accounts.length <= 3 && accounts.length >= 2
                    && accounts[1] == ':') {
                return Path.build_filename (
                    parla_data_dir (), "accounts.vault");
            }
#endif
            return accounts + ".vault";
        }

        /** Archive used by the weak, non-mounted ZIP backend. */
        public static string zip_path () {
            return resolve () + ".zip";
        }

        private static string environment_path () {
            string? env = Environment.get_variable ("DC_ACCOUNTS_PATH");
            return env != null ? normalize (env) : "";
        }

        // Mirrors Parla's normalize_accounts_path: trim and strip trailing
        // separators while preserving "X:\" drive roots.
        private static string normalize (string value) {
            string path = value.strip ();
            while (path.length > 1
                   && (path.has_suffix ("/") || path.has_suffix ("\\"))) {
                if (path.length == 3 && path[1] == ':') break;
                path = path[0:path.length - 1];
            }
            return path;
        }

        private static string parla_configured_path () {
            string config = Path.build_filename (
                Environment.get_user_config_dir (), "parla", "settings.ini");
            var keyfile = new KeyFile ();
            try {
                keyfile.load_from_file (config, KeyFileFlags.NONE);
                return normalize (
                    keyfile.get_string ("General", "accounts_path"));
            } catch (Error error) {
                return "";
            }
        }

        // Mirrors Parla's AccountFinder.get_parla_data_dir without creating
        // the directory: early Parla accounts under the user config dir are
        // kept in place.
        private static string parla_data_dir () {
            string data_dir = Path.build_filename (
                Environment.get_user_data_dir (), "parla");
            string old_config_dir = Path.build_filename (
                Environment.get_user_config_dir (), "parla");
            string data_accounts = Path.build_filename (data_dir, "accounts");
            string old_accounts = Path.build_filename (
                old_config_dir, "accounts");
            if (!FileUtils.test (data_accounts, FileTest.IS_DIR)
                    && FileUtils.test (old_accounts, FileTest.IS_DIR)) {
                return old_config_dir;
            }
            return data_dir;
        }
    }
}
