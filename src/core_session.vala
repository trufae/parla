namespace Dc {
    /** Shared frontend backend. Use from one GLib main context; async RPC and
     * update calls require that context to be running. The core owns the account
     * store lock, so close one frontend before opening another on the same data.
     */
    public class CoreSession : Object {
        public SettingsManager settings { get; private set; }
        public RpcClient rpc { get; private set; }
        public string? server_path { get; private set; }

        public CoreSession () {
            settings = new SettingsManager ();
            settings.load ();
            rpc = new RpcClient ();
        }

        public void reset_rpc () {
            rpc.stop ();
            rpc = new RpcClient ();
            server_path = null;
        }

        public async void start () throws Error {
            server_path = AccountFinder.find_rpc_server (
                settings.effective_rpc_server_path (),
                settings.effective_rpc_server_source ());
            if (server_path == null)
                throw new IOError.NOT_FOUND (_("RPC server not found"));
            rpc.account_id = 0;
            rpc.self_email = null;
            yield rpc.start ({ server_path }, AccountFinder.get_data_dir (),
                             settings.effective_accounts_path ());
        }

        /** Select the saved default profile and start IO for all profiles.
         * An empty store is valid: the frontend can then offer account setup.
         */
        public async void prepare_accounts (out string? description,
                                             out string? notice) {
            yield AccountFinder.ensure_configured (rpc,
                settings.default_account_addr, out description, out notice);
            if (rpc.account_id <= 0) return;
            try {
                yield start_io ();
            } catch (Error e) {
                notice = _("Connection setup error: ") + e.message;
            }
        }

        public async void apply_auto_download_limit () throws Error {
            var node = yield rpc.get_all_accounts ();
            if (node == null) return;
            var accounts = node.get_array ();
            for (uint i = 0; i < accounts.get_length (); i++) {
                int id = (int) json_int (accounts.get_object_element (i), "id");
                if (id > 0) yield rpc.batch_set_config ("download_limit",
                    settings.auto_download_limit.to_string (), id);
            }
        }

        public async void start_io () throws Error {
            yield apply_auto_download_limit ();
            yield rpc.start_io_for_all_accounts ();
        }

        /** Best-effort checks respect the same build, environment and saved
         * policy in every frontend. Return an available version, or null.
         * Checking never installs or replaces a running engine.
         */
        public async string? check_parla_update () {
            if (!settings.startup_update_checks_enabled ()) return null;
            try {
                string tag = yield RpcInstaller.fetch_latest_tag ("trufae/parla");
                if (settings.startup_update_checks_enabled () &&
                    RpcInstaller.is_newer_version (tag, Parla.VERSION)) return tag;
            } catch (Error e) { /* Optional network check. */ }
            return null;
        }

        public async string? check_core_update () {
            if (!settings.rpc_auto_update_enabled () ||
                server_path != AccountFinder.get_managed_rpc_path ()) return null;
            string? installed = yield RpcInstaller.installed_version ();
            if (installed == null || !settings.rpc_auto_update_enabled ()) return null;
            try {
                string tag = yield RpcInstaller.fetch_latest_tag ();
                if (settings.rpc_auto_update_enabled () &&
                    RpcInstaller.is_newer_version (tag, installed))
                    return RpcInstaller.extract_version (tag);
            } catch (Error e) { /* Optional network check. */ }
            return null;
        }
    }
}
