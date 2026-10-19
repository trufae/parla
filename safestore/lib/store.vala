namespace SafeStore {
    [Flags]
    public enum Operation {
        NONE = 0, INSPECT, PROBE, CREATE_EMPTY, UNLOCK, LOCK,
        ENABLE, DISABLE, CHANGE_BACKEND, VERIFY, BACKUP, RESTORE, RECOVER
    }

    /** Detached mounts are for short-lived tools; applications use MANAGED. */
    public enum MountMode { MANAGED, DETACHED }

    /** Copied at construction. No environment variables or preferences are read. */
    public class StoreOptions : Object {
        public string cryfs_binary { get; set; default = "cryfs"; }
        public string zip_binary { get; set; default = "zip"; }
        public string unzip_binary { get; set; default = "unzip"; }
        public string shred_binary { get; set; default = "shred"; }
        public string? state_directory { get; set; }
        public bool secure_delete { get; set; default = false; }
        public int idle_minutes { get; set; default = 0; }
        public bool allow_executable_files { get; set; default = false; }
        public MountMode mount_mode { get; set; default = MountMode.MANAGED; }
    }

    /** Classification only. Recognizing a file never proves its encryption. */
    public class StoreStatus : Object {
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

    /**
     * Experimental, GTK-free facade over the existing backends.
     *
     * Both paths are explicit. Construction, inspection and probing do not
     * create folders. Call methods from one main context and keep the Store
     * alive until locked. Operations are serialized per instance only; durable
     * cross-process ownership and recovery are a subsequent milestone.
     */
    public class Store : Object {
        private Settings settings;
        private CryfsController controller = new CryfsController ();
        private bool busy = false;
        private bool exposed = false;

        public string accounts_path { get { return settings.mount_path; } }
        public string storage_path { get { return settings.vault_path; } }
        public BackendKind backend { get; private set; }
        public StoreState state { get; private set; default = StoreState.UNKNOWN; }
        public string detail { get; private set; default = "Storage has not been checked"; }
        public bool process_active {
            get { return busy || controller.process_active || exposed; }
        }
        public signal void state_changed (StoreState state, string detail);
        public signal void output (string line);

        public Store (string accounts_path, string storage_path,
                      BackendKind backend, StoreOptions? options = null)
                      throws Error {
            var config = options ?? new StoreOptions ();
            if (config.idle_minutes < 0 || config.idle_minutes > 1440) {
                throw new StoreError.INVALID_ARGUMENT ("Idle minutes must be between 0 and 1440");
            }
            if (backend != BackendKind.CRYFS && backend != BackendKind.ZIP) {
                throw new StoreError.INVALID_ARGUMENT ("Unknown backend");
            }
            PathPolicy.validate_layout (storage_path, accounts_path, false);
            string state_path = config.state_directory ?? storage_path + ".state";
            // The local CryFS integrity state must survive unmounting.
            PathPolicy.validate_layout (state_path, accounts_path, false);
            PathPolicy.validate_layout (state_path, storage_path, false);
            this.backend = backend;
            settings = new Settings (accounts_path, storage_path, backend, config);
            controller.output.connect ((line) => output (line));
            controller.state_changed.connect ((next, message) => {
                if (next == StoreState.MOUNTED) exposed = true;
                else if (next == StoreState.LOCKED) exposed = false;
                transition (next, message);
            });
        }

        public async BackendInfo[] list_backends (Cancellable? cancellable = null)
                                                  throws Error {
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

        public async StoreStatus inspect (Cancellable? cancellable = null) throws Error {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            StoreStatus? result = null;
            yield run_worker (() => { result = inspect_now (); });
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            if (!busy) exposed = result.plaintext_exposed || result.mount_present;
            return result;
        }

        private StoreStatus inspect_now () {
            var result = new StoreStatus ();
            if (backend == BackendKind.ZIP) {
                result.recognized = ZipBackend.is_encrypted (settings);
                result.plaintext_exposed = ZipBackend.is_unlocked (settings);
            } else {
                result.recognized = Vault.is_encrypted (storage_path);
                var mount = Vault.mount_info (accounts_path);
                result.mount_present = mount != null;
                result.plaintext_exposed = mount != null && mount.is_cryfs ();
            }
            result.detail = result.plaintext_exposed
                ? "Plaintext appears to be exposed; integrity is unverified"
                : (result.mount_present ? "A mount is present; ownership is unverified"
                    : (result.recognized ? "Storage candidate found; encryption and integrity are unverified"
                        : "No recognized encrypted storage found"));
            return result;
        }

        /** Only an empty/new store. Enabling protection on existing data is unavailable. */
        public async void create_empty (SecretValue secret, Cancellable? cancellable = null)
                                         throws Error {
            yield operate (Operation.CREATE_EMPTY, secret, cancellable);
        }

        /** Never creates a missing store. */
        public async void unlock (SecretValue secret, Cancellable? cancellable = null)
                                  throws Error {
            yield operate (Operation.UNLOCK, secret, cancellable);
        }

        /** ZIP currently requires a password again when locking. */
        public async void lock (SecretValue? secret = null, Cancellable? cancellable = null)
                                throws Error {
            yield operate (Operation.LOCK, secret, cancellable);
        }

        private async void operate (Operation operation, SecretValue? supplied,
                                    Cancellable? cancellable) throws Error {
            if (busy) throw new StoreError.BUSY ("A store operation is already active");
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            // Copy before the first yield; callers may clear their handoff buffer.
            var secret = new SecretValue (supplied != null ? supplied.peek () : "");
            busy = true;
            try {
                BackendInfo info = yield probe (cancellable);
                if (!info.supports (operation)) {
                    throw new StoreError.NOT_SUPPORTED ("%s", info.status);
                }
                bool needs_password = operation != Operation.LOCK || backend == BackendKind.ZIP;
                unowned string password = secret.peek ();
                if (needs_password && password.length == 0) {
                    throw new StoreError.WRONG_PASSWORD ("Password cannot be empty");
                }
                if (password.contains ("\n") || password.contains ("\r")) {
                    throw new StoreError.INVALID_ARGUMENT ("Passwords cannot contain line breaks");
                }
                if (backend == BackendKind.ZIP) {
                    for (int i = 0; i < password.length; i++) {
                        if ((uint8) password[i] < 0x20 || password[i] == 0x7f) {
                            throw new StoreError.INVALID_ARGUMENT ("ZIP passwords cannot contain control characters");
                        }
                    }
                }
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                transition (operation == Operation.LOCK ? StoreState.STOPPING
                    : StoreState.STARTING, operation == Operation.LOCK
                    ? "Locking storage…" : "Opening storage…");
                if (backend == BackendKind.CRYFS && settings.mount_mode == MountMode.MANAGED) {
                    if (operation == Operation.LOCK) {
                        yield controller.unmount (settings.cryfs_binary, accounts_path);
                    } else {
                        controller.mount (settings.cryfs_binary, storage_path,
                            accounts_path, secret.peek (), settings.idle_minutes,
                            operation == Operation.CREATE_EMPTY,
                            settings.allow_executable_files, settings.state_directory);
                        yield await_mount ();
                    }
                } else {
                    yield run_worker (() => {
                        if (operation == Operation.CREATE_EMPTY) {
                            EncryptedStore.create (settings, secret.peek (), settings.allow_executable_files);
                        } else if (operation == Operation.UNLOCK) {
                            EncryptedStore.unlock (settings, secret.peek (), settings.allow_executable_files);
                        } else {
                            EncryptedStore.lock (settings, secret.peek ());
                        }
                    });
                }
                exposed = operation != Operation.LOCK;
                transition (exposed ? StoreState.MOUNTED : StoreState.LOCKED,
                    exposed ? "Storage is unlocked" : "Storage is locked");
            } catch (Error error) {
                StoreStatus? status = null;
                yield run_worker (() => { status = inspect_now (); });
                exposed = status.plaintext_exposed || status.mount_present;
                transition (StoreState.ERROR, error.message);
                throw error;
            } finally {
                secret.clear ();
                busy = false;
                state_changed (state, detail);
            }
        }

        private async void await_mount () throws Error {
            if (controller.state == StoreState.STARTING) {
                SourceFunc resume = await_mount.callback;
                ulong handler = controller.state_changed.connect ((next, message) => {
                    if (next != StoreState.STARTING) resume ();
                });
                yield;
                controller.disconnect (handler);
            }
            if (controller.state != StoreState.MOUNTED) {
                throw new StoreError.MOUNT_FAILED ("%s", controller.detail);
            }
        }

        private void transition (StoreState next, string message) {
            state = next;
            detail = message;
            state_changed (state, detail);
        }
    }
}
