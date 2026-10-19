namespace SafeStore {
    [Flags]
    public enum Operation {
        NONE = 0, INSPECT, PROBE, CREATE_EMPTY, UNLOCK, LOCK,
        ENABLE, DISABLE, CHANGE_BACKEND, VERIFY, BACKUP, RESTORE, RECOVER
    }

    /** DETACHED is retained for compatibility but cannot mutate a store safely. */
    public enum MountMode { MANAGED, DETACHED }

    /** Copied at construction. No environment variables or preferences are read. */
    public class StoreOptions : Object {
        public string cryfs_binary { get; set; default = "cryfs"; }
        public string zip_binary { get; set; default = "zip"; }
        public string unzip_binary { get; set; default = "unzip"; }
        public string shred_binary { get; set; default = "shred"; }
        public string? state_directory { get; set; }
        public string? control_directory { get; set; }
        public bool secure_delete { get; set; default = false; }
        public int idle_minutes { get; set; default = 0; }
        public bool allow_executable_files { get; set; default = false; }
        public MountMode mount_mode { get; set; default = MountMode.MANAGED; }
    }

    public enum AccessState { ABSENT, PLAIN, LOCKED, UNLOCKED, RECOVERY_REQUIRED, UNKNOWN }

    /** Classification only. Recognizing a file never proves its encryption. */
    public class StoreStatus : Object {
        public AccessState access { get; internal set; default = AccessState.UNKNOWN; }
        public string? store_id { get; internal set; }
        public uint64 generation { get; internal set; }
        public bool has_metadata { get; internal set; }
        public bool recovery_required { get; internal set; }
        public bool session_owned { get; internal set; }
        public bool recognized { get; internal set; }
        public bool plaintext_exposed { get; internal set; }
        public bool mount_present { get; internal set; }
        public bool integrity_verified { get { return false; } }
        public string detail { get; internal set; }
        internal StoreStatus () { }
    }

    internal delegate void Worker () throws Error;

    // Resume on the caller's thread-default context, including private contexts.
    // In-flight prototype operations cannot safely be interrupted. Cancellation
    // is checked by callers before mutation, never reported after a commit.
    internal async void run_worker (owned Worker work) throws Error {
        var context = MainContext.ref_thread_default ();
        Error? failure = null;
        SourceFunc resume = run_worker.callback;
        new Thread<void*> ("safestore", () => {
            try { work (); } catch (Error error) { failure = error; }
            var source = new IdleSource ();
            source.set_callback (() => { resume (); return Source.REMOVE; });
            source.attach (context);
            return null;
        });
        yield;
        if (failure != null) throw failure;
    }

    /** A live lease. Keep Store alive and await lock(); dropping it is not a clean lock. */
    public class Session : Object {
        public string store_id { get; private set; }
        public uint64 generation { get; private set; }
        public string accounts_path { get; private set; }
        public bool active { get; private set; default = true; }
        public signal void access_lost (string reason);
        internal SecretValue secret;
        internal string root_identity;
        internal string mount_identity;

        internal Session (Metadata metadata, SecretValue password, string root, string mount) {
            store_id = metadata.id;
            generation = metadata.generation;
            accounts_path = metadata.accounts;
            secret = new SecretValue (password.peek ());
            root_identity = root;
            mount_identity = mount;
        }
        internal void end (string? reason = null) {
            active = false;
            secret.clear ();
            if (reason != null) {
                var source = new IdleSource ();
                source.set_callback (() => { access_lost (reason); return Source.REMOVE; });
                source.attach (MainContext.ref_thread_default ());
            }
        }
    }

    public class Store : Object {
        private Settings settings;
        private CryfsController controller = new CryfsController ();
        private Lease? accounts_lease;
        private Lease? storage_lease;
        private Metadata? metadata;
        private Source? monitor;
        private bool busy = false;
        private bool exposed = false;
        public Session? session { get; private set; }
        public string accounts_path { get { return settings.mount_path; } }
        public string storage_path { get { return settings.vault_path; } }
        public string metadata_path { owned get { return Path.build_filename (settings.control_directory, "store.ini"); } }
        public BackendKind backend { get; private set; }
        public StoreState state { get; private set; default = StoreState.UNKNOWN; }
        public string detail { get; private set; default = "Storage has not been checked"; }
        public bool process_active { get { return busy || controller.process_active || session != null || exposed; } }
        public signal void state_changed (StoreState state, string detail);
        public signal void output (string line);

        public Store (string accounts_path, string storage_path, BackendKind backend,
                      StoreOptions? options = null) throws Error {
            var config = options ?? new StoreOptions ();
            if (backend != BackendKind.CRYFS && backend != BackendKind.ZIP) {
                throw new StoreError.INVALID_ARGUMENT ("Unknown backend");
            }
            if (config.idle_minutes != 0) {
                throw new StoreError.NOT_SUPPORTED ("Idle locking must be coordinated after stopping account writers");
            }
            PathPolicy.validate_layout (storage_path, accounts_path, false);
            settings = new Settings (accounts_path, storage_path, backend, config);
            PathPolicy.validate_layout (settings.state_directory, settings.mount_path, false);
            PathPolicy.validate_layout (settings.state_directory, settings.vault_path, false);
            PathPolicy.validate_layout (settings.control_directory, settings.mount_path, false);
            PathPolicy.validate_layout (settings.control_directory, settings.vault_path, false);
            this.backend = backend;
            controller.output.connect ((line) => output (line));
            controller.state_changed.connect ((next, message) => {
                if (next == StoreState.ERROR && session != null && session.active && !busy) {
                    record_loss.begin (message);
                }
            });
        }

        internal static string control_path (string accounts, StoreOptions options) throws Error {
            string canonical = PathPolicy.slot (accounts);
#if WINDOWS
            if (canonical.length == 2 && canonical[1] == ':') {
                if (options.control_directory == null) {
                    throw new StoreError.INVALID_ARGUMENT ("A drive mount requires an explicit metadata directory");
                }
                return PathPolicy.slot (options.control_directory);
            }
#endif
            if (options.control_directory != null && options.control_directory != canonical + ".safestore") {
                throw new StoreError.INVALID_ARGUMENT ("Store metadata must stay beside the accounts path");
            }
            return canonical + ".safestore";
        }

        /** Load the store's recorded method and location without using global preferences. */
        public static async Store? open_existing (string accounts_path, StoreOptions? options = null,
                                                 Cancellable? cancellable = null) throws Error {
            var config = options ?? new StoreOptions ();
            string accounts = PathPolicy.slot (accounts_path);
            string directory = control_path (accounts, config);
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            Metadata? saved = null;
            yield run_worker (() => { saved = Metadata.load (directory); });
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            if (saved == null) return null;
            if (saved.accounts != accounts) throw new StoreError.RECOVERY_REQUIRED ("Store metadata belongs to another accounts path");
            return new Store (accounts, saved.storage, saved.backend, config);
        }

        public async BackendInfo[] list_backends (Cancellable? cancellable = null) throws Error {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            BackendInfo[] result = {};
            yield run_worker (() => { result = Backends.list (settings); });
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            return result;
        }
        public async BackendInfo probe (Cancellable? cancellable = null) throws Error {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            BackendInfo? result = null;
            yield run_worker (() => { result = Backends.selected (settings); });
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            return result;
        }
        public EraseInfo removal_info () { return PlaintextEraser.inspect (settings); }

        private bool has_other_candidate () {
            string[] candidates = { accounts_path + ".zip", accounts_path + ".vault" };
            foreach (string candidate in candidates) {
                if (candidate != storage_path && (FileUtils.test (candidate, FileTest.EXISTS)
                        || FileUtils.test (candidate, FileTest.IS_SYMLINK))) return true;
            }
            return false;
        }

        private void validate_format () throws Error {
            if (backend == BackendKind.ZIP) ZipFormat.validate (storage_path);
            else if (!Vault.is_encrypted (storage_path)) throw new StoreError.NOT_A_VAULT ("No CryFS configuration was found");
        }

        private StoreStatus inspect_now (bool owned) {
            var result = new StoreStatus ();
            try {
                if (owned) verify_session ();
                var saved = Metadata.load (settings.control_directory);
                result.has_metadata = saved != null;
                if (saved != null) {
                    result.store_id = saved.id;
                    result.generation = saved.generation;
                    saved.match (settings);
                }
                var mount = MountCheck.find (accounts_path);
                result.mount_present = mount != null;
                result.plaintext_exposed = mount != null || ZipBackend.plaintext_present (settings);
                bool candidate = FileUtils.test (storage_path, FileTest.EXISTS)
                    || FileUtils.test (storage_path, FileTest.IS_SYMLINK);
                if (candidate) { validate_format (); result.recognized = true; }
                if (has_other_candidate ()) throw new StoreError.RECOVERY_REQUIRED ("Multiple storage candidates require recovery");
                if (saved != null && saved.phase != "locked" && !(owned && saved.phase == "unlocked")) {
                    throw new StoreError.RECOVERY_REQUIRED ("Storage has an active or interrupted operation: %s", saved.phase);
                }
                if (mount != null && (!owned || !mount.matches (storage_path))) {
                    throw new StoreError.RECOVERY_REQUIRED ("The accounts mount is not owned by this session");
                }
                if (!owned && result.plaintext_exposed && (saved != null || candidate)) {
                    throw new StoreError.RECOVERY_REQUIRED ("Plaintext conflicts with encrypted storage; preserve both copies");
                }
                if (saved != null && !result.recognized) throw new StoreError.RECOVERY_REQUIRED ("The recorded ciphertext is missing");
                result.session_owned = owned;
                result.access = owned ? AccessState.UNLOCKED
                    : (result.recognized ? AccessState.LOCKED
                        : (result.plaintext_exposed ? AccessState.PLAIN : AccessState.ABSENT));
                result.detail = owned ? "This session owns the unlocked store"
                    : (result.recognized ? "Encrypted storage format detected; integrity remains unverified"
                        : "No encrypted store is configured");
            } catch (Error error) {
                result.recovery_required = true;
                result.access = AccessState.RECOVERY_REQUIRED;
                result.detail = error.message;
            }
            return result;
        }

        public async StoreStatus inspect (Cancellable? cancellable = null) throws Error {
            if (busy) throw new StoreError.BUSY ("A store operation is already active");
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            bool owned = session != null && session.active;
            StoreStatus? result = null;
            busy = true;
            try {
                yield run_worker (() => { result = inspect_now (owned); });
                if (cancellable != null) cancellable.set_error_if_cancelled ();
            } finally {
                busy = false;
            }
            if (owned && result.recovery_required) yield record_loss (result.detail);
            exposed = result.plaintext_exposed;
            transition (result.recovery_required ? StoreState.ERROR
                : (owned ? StoreState.MOUNTED : (result.recognized ? StoreState.LOCKED : StoreState.UNKNOWN)), result.detail);
            return result;
        }

        public async Session create_empty (SecretValue secret, Cancellable? cancellable = null) throws Error {
            yield operate (Operation.CREATE_EMPTY, secret, cancellable);
            return session;
        }
        public async Session unlock (SecretValue secret, Cancellable? cancellable = null) throws Error {
            yield operate (Operation.UNLOCK, secret, cancellable);
            return session;
        }
        /** Uses the session's retained wipeable credential. Password changes are a separate operation. */
        public async void lock (SecretValue? secret = null, Cancellable? cancellable = null) throws Error {
            yield operate (Operation.LOCK, secret, cancellable);
        }

        private void acquire () throws Error {
            if (accounts_lease != null) return;
            PathPolicy.ensure_durable_directory (settings.control_directory);
            try {
                accounts_lease = new Lease (Path.build_filename (settings.control_directory, "owner.lock"));
                string parent = Path.get_dirname (storage_path);
                if (!FileUtils.test (parent, FileTest.EXISTS)) PathPolicy.ensure_durable_directory (parent);
                storage_lease = new Lease (storage_path + ".safestore.lock");
            } catch (Error error) {
                storage_lease = null;
                accounts_lease = null;
                if (error is IOError.WOULD_BLOCK || error is IOError.BUSY) {
                    throw new StoreError.BUSY ("Another session owns this account store");
                }
                throw error;
            }
        }
        private void release () { storage_lease = null; accounts_lease = null; }
        private void save_phase (string phase) throws Error {
            metadata.phase = phase;
            metadata.save (settings.control_directory);
        }
        private static string directory_identity (string path) throws Error {
            var info = File.new_for_path (path).query_info ("standard::type,id::file", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            string identity = info.get_attribute_string ("id::file") ?? "";
            if (info.get_file_type () != FileType.DIRECTORY || identity.length == 0) {
                throw new StoreError.ACCESS_LOST ("The working accounts directory is unavailable");
            }
            return identity;
        }
        private void verify_session () throws Error {
            if (session == null || !session.active) throw new StoreError.RECOVERY_REQUIRED ("There is no live owned session");
            var current = Metadata.load (settings.control_directory);
            if (current == null) throw new StoreError.ACCESS_LOST ("Store metadata disappeared");
            current.match (settings);
            if (current.id != session.store_id || current.generation != session.generation || current.phase != "unlocked") {
                throw new StoreError.ACCESS_LOST ("Store identity or generation changed");
            }
            if (directory_identity (accounts_path) != session.root_identity) throw new StoreError.ACCESS_LOST ("The working directory was replaced");
            if (backend == BackendKind.CRYFS) {
                if (!controller.process_active) throw new StoreError.ACCESS_LOST ("The filesystem process has exited");
                MountCheck.require_exact (accounts_path, storage_path, session.mount_identity);
            } else {
                if (MountCheck.find (accounts_path) != null
                        || FileUtils.test (Path.build_filename (accounts_path, ".safestore-locked"), FileTest.EXISTS)) {
                    throw new StoreError.ACCESS_LOST ("The working ZIP directory changed unexpectedly");
                }
            }
        }

        private async void operate (Operation operation, SecretValue? supplied, Cancellable? cancellable) throws Error {
            if (busy) throw new StoreError.BUSY ("A store operation is already active");
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            if (settings.mount_mode == MountMode.DETACHED) {
                throw new StoreError.NOT_SUPPORTED ("Detached operations cannot retain exclusive ownership; use a managed session");
            }
            bool locking = operation == Operation.LOCK;
            if (!locking && session != null) throw new StoreError.BUSY ("A session already owns the store");
            if (locking && session != null && supplied != null && supplied.peek () != session.secret.peek ()) {
                throw new StoreError.INVALID_ARGUMENT ("Lock uses the session password; changing passwords requires migration");
            }
            var secret = new SecretValue (locking && session != null ? session.secret.peek ()
                : (supplied != null ? supplied.peek () : ""));
            busy = true;
            bool begun = false;
            bool rollback_safe = false;
            string previous_phase = locking ? "unlocked" : "locked";
            try {
                if (!locking || session != null) {
                    BackendInfo info = yield probe (cancellable);
                    if (!info.supports (operation)) throw new StoreError.NOT_SUPPORTED ("%s", info.status);
                }
                if (!locking && (secret.peek ().length == 0 || secret.peek ().contains ("\n") || secret.peek ().contains ("\r"))) {
                    throw new StoreError.WRONG_PASSWORD ("A nonempty password without line breaks is required");
                }
                if (backend == BackendKind.ZIP) {
                    unowned string password = secret.peek ();
                    for (int i = 0; i < password.length; i++) {
                        if ((uint8) password[i] < 0x20 || password[i] == 0x7f) throw new StoreError.INVALID_ARGUMENT ("ZIP passwords cannot contain control characters");
                    }
                }
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                yield run_worker (() => {
                    acquire ();
                    var saved = Metadata.load (settings.control_directory);
                    if (saved != null) saved.match (settings);
                    if (session == null) metadata = saved;
                    if (has_other_candidate ()) throw new StoreError.RECOVERY_REQUIRED ("Multiple ciphertext candidates require recovery");
                    if (locking && session != null) {
                        verify_session ();
                    } else {
                        if (metadata != null && metadata.phase != "locked") throw new StoreError.RECOVERY_REQUIRED ("An active or interrupted operation needs recovery");
                        if (MountCheck.find (accounts_path) != null) throw new StoreError.RECOVERY_REQUIRED ("An unowned filesystem occupies the accounts path");
                        if (operation == Operation.CREATE_EMPTY) {
                            if (metadata != null || FileUtils.test (storage_path, FileTest.EXISTS) || FileUtils.test (storage_path, FileTest.IS_SYMLINK)) {
                                throw new StoreError.ALREADY_MOUNTED ("Encrypted storage already exists");
                            }
                            PathPolicy.validate_mountpoint (accounts_path);
                        } else {
                            validate_format ();
                            ZipBackend.ensure_locked_destination (accounts_path);
                        }
                    }
                });
                if (locking && session == null) {
                    if (metadata == null) throw new StoreError.RECOVERY_REQUIRED ("Import this legacy store by unlocking it first");
                    exposed = false;
                    release ();
                    transition (StoreState.LOCKED, "The store is already locked");
                    return;
                }
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                if (metadata == null) metadata = new Metadata (settings);
                begun = true; // A failed durable write may already have replaced the file.
                yield run_worker (() => { save_phase (locking ? "locking" : (operation == Operation.CREATE_EMPTY ? "creating" : "opening")); });
                transition (locking ? StoreState.STOPPING : StoreState.STARTING, locking ? "Locking storage…" : "Opening storage…");
                if (backend == BackendKind.ZIP) {
                    yield run_worker (() => {
                        if (operation == Operation.CREATE_EMPTY) ZipBackend.create (settings, secret.peek ());
                        else if (!locking) ZipBackend.unlock (settings, secret.peek (), ref rollback_safe);
                        else ZipBackend.lock (settings, secret.peek (), () => {
                            metadata.generation++;
                            save_phase ("cleanup");
                        }, ref rollback_safe);
                    });
                } else if (locking) {
                    try { yield controller.unmount (settings.cryfs_binary, storage_path, accounts_path, session.mount_identity); }
                    catch (Error error) {
                        try {
                            MountCheck.require_exact (accounts_path, storage_path, session.mount_identity);
                            rollback_safe = controller.process_active;
                        } catch (Error identity_error) { }
                        throw error;
                    }
                } else {
                    controller.mount (settings.cryfs_binary, storage_path, accounts_path, secret.peek (),
                        operation == Operation.CREATE_EMPTY, settings.allow_executable_files, settings.state_directory);
                    yield await_mount ();
                }
                if (locking) {
                    yield run_worker (() => {
                        if (MountCheck.find (accounts_path) != null) throw new StoreError.UNMOUNT_FAILED ("The accounts path remains mounted");
                        ZipBackend.ensure_locked_destination (accounts_path);
                        save_phase ("locked");
                    });
                    stop_monitor ();
                    session.end ();
                    session = null;
                    exposed = false;
                    release ();
                    transition (StoreState.LOCKED, "Storage is locked");
                } else {
                    string root = "";
                    string mount_id = "";
                    yield run_worker (() => {
                        root = directory_identity (accounts_path);
                        if (backend == BackendKind.CRYFS) mount_id = MountCheck.require_exact (accounts_path, storage_path).identity;
                        if (operation == Operation.CREATE_EMPTY) metadata.generation++;
                        save_phase ("unlocked");
                    });
                    session = new Session (metadata, secret, root, mount_id);
                    exposed = true;
                    start_monitor ();
                    transition (StoreState.MOUNTED, "This session owns the unlocked store");
                }
            } catch (Error error) {
                if (begun) {
                    if (!locking && backend == BackendKind.CRYFS && error is StoreError.WRONG_PASSWORD && !controller.process_active) {
                        try { rollback_safe = MountCheck.find (accounts_path) == null; } catch (Error ignored) { }
                    }
                    if (rollback_safe) {
                        try { yield run_worker (() => { save_phase (previous_phase); }); }
                        catch (Error journal_error) {
                            rollback_safe = false;
                            output ("Recovery state could not be synchronized: " + journal_error.message);
                        }
                    }
                    // Keep the last durable operation phase on failure. In
                    // particular, cleanup means the complete archive was committed.
                    if (!rollback_safe && session != null) { stop_monitor (); session.end (error.message); }
                } else if (session != null && session.active
                        && (error is StoreError.ACCESS_LOST || error is StoreError.RECOVERY_REQUIRED)) {
                    stop_monitor ();
                    session.end (error.message);
                }
                if (session == null && !controller.process_active) release ();
                transition (StoreState.ERROR, error.message);
                throw error;
            } finally {
                secret.clear ();
                busy = false;
                state_changed (state, detail);
            }
        }

        private void start_monitor () {
            stop_monitor ();
            monitor = new TimeoutSource (500);
            monitor.set_callback (() => {
                if (!busy && session != null && session.active) check_access.begin ();
                return Source.CONTINUE;
            });
            monitor.attach (MainContext.ref_thread_default ());
        }
        private void stop_monitor () { if (monitor != null) { monitor.destroy (); monitor = null; } }
        private async void check_access () {
            busy = true;
            string? failure = null;
            try { yield run_worker (() => { verify_session (); }); }
            catch (Error error) { failure = error.message; }
            busy = false;
            if (failure != null) yield record_loss (failure);
        }
        private async void record_loss (string reason) {
            if (busy || session == null || !session.active) return;
            busy = true;
            stop_monitor ();
            session.end (reason);
            // The persisted unlocked phase already requires recovery without
            // its live owner. Preserve it and any externally changed metadata.
            busy = false;
            transition (StoreState.ERROR, "Storage access was lost; recovery is required: " + reason);
        }
        private async void await_mount () throws Error {
            if (controller.state == StoreState.STARTING) {
                SourceFunc resume = await_mount.callback;
                ulong handler = controller.state_changed.connect ((next, message) => { if (next != StoreState.STARTING) resume (); });
                yield;
                controller.disconnect (handler);
            }
            if (controller.state != StoreState.MOUNTED) {
                if (controller.last_exit_status == 11) throw new StoreError.WRONG_PASSWORD ("%s", controller.detail);
                throw new StoreError.MOUNT_FAILED ("%s", controller.detail);
            }
        }
        private void transition (StoreState next, string message) { state = next; detail = message; state_changed (state, detail); }
    }
}
