namespace SafeStore {

    public class Cli : Object {

        private const string USAGE = """Usage: safestore [options] <command>

SafeStore always works on the Delta Chat accounts location: the plaintext
path is $DC_ACCOUNTS_PATH when set, otherwise the accounts path the Parla
JSON-RPC server will use. CryFS stores "<accounts>.vault"; ZIP stores
"<accounts>.zip". Run "safestore status" to see the resolved paths.

Commands:
  backends       List encryption backends, availability, and security model
  check          Classify a storage candidate, without verifying integrity (exit 0),
                 plaintext (exit 3), recovery required (exit 4), or neither (exit 1)
  status         Show the resolved paths and the vault and mount state
  create         Create and hold a new store; Enter/EOF locks it before exit
  mount          Hold an unlocked session; Enter/EOF locks it before exit
  umount         Verify closure; cannot close a session owned by another process
  forget         Remove the stored vault password from the keyring
  version        Show status for the selected encryption backend

Options:
      --backend NAME      Select a method for a new store; existing stores keep theirs
  -b, --binary PATH       Main executable for the selected backend
      --unzip-binary PATH unzip executable for the ZIP backend
      --shred              Best-effort overwrite of ZIP plaintext before removal
      --shred-binary PATH shred-compatible executable
  -k, --keyring           Read the password from the system keyring; after a
                          successful interactive unlock, store it there
  -p, --password-stdin    Read the password from standard input (for scripts)
  -i, --idle MINUTES      Only 0 is supported; locking requires stopping writers
      --allow-exec        CryFS: allow direct execution inside the mount
  -q, --quiet             Print errors only
  -h, --help              Show this help

Passwords are never accepted on the command line and never written to disk
in plain text; the optional keyring entry lives in the OS secret service.
""";

        private ToolSettings settings;
        private Store store;
        private CredentialStore credentials;
        private bool backend_requested = false;
        private bool use_keyring = false;
        private bool password_stdin = false;
        private bool allow_executable_files = false;
        private bool quiet = false;
        private int idle_minutes = -1;
        private string? binary_override = null;

        public static int main (string[] args) {
            var loop = new MainLoop ();
            int result = 1;
            var cli = new Cli ();
            Idle.add (() => {
                cli.run.begin (args, (obj, res) => {
                    result = cli.run.end (res);
                    loop.quit ();
                });
                return Source.REMOVE;
            });
            loop.run ();
            return result;
        }

        private async int run (string[] args) {
            settings = new ToolSettings ();

            string[] rest = {};
            for (int i = 1; i < args.length; i++) {
                string arg = args[i];
                switch (arg) {
                case "-h":
                case "--help":
                    stdout.printf ("%s", USAGE);
                    return 0;
                case "-k":
                case "--keyring":
                    use_keyring = true;
                    break;
                case "-p":
                case "--password-stdin":
                    password_stdin = true;
                    break;
                case "--allow-exec":
                    allow_executable_files = true;
                    break;
                case "-q":
                case "--quiet":
                    quiet = true;
                    break;
                case "-b":
                case "--binary":
                    if (++i >= args.length) return usage_error ("--binary needs a path");
                    binary_override = args[i];
                    break;
                case "--backend":
                    if (++i >= args.length) return usage_error ("--backend needs a name");
                    try {
                        settings.backend = BackendKind.parse (args[i]).id ();
                        backend_requested = true;
                    } catch (Error error) {
                        return usage_error (error.message);
                    }
                    break;
                case "--unzip-binary":
                    if (++i >= args.length) return usage_error ("--unzip-binary needs a path");
                    settings.unzip_binary = args[i];
                    break;
                case "--shred":
                    settings.secure_delete = true;
                    break;
                case "--shred-binary":
                    if (++i >= args.length) return usage_error ("--shred-binary needs a path");
                    settings.shred_binary = args[i];
                    break;
                case "-i":
                case "--idle":
                    if (++i >= args.length) return usage_error ("--idle needs a number of minutes");
                    idle_minutes = int.parse (args[i]);
                    if (idle_minutes < 0) return usage_error ("--idle must be zero or positive");
                    break;
                default:
                    if (arg.has_prefix ("-")) {
                        return usage_error ("Unknown option: " + arg);
                    }
                    rest += arg;
                    break;
                }
            }

            if (rest.length == 0) return usage_error ("Missing command");
            string command = rest[0];
            if (rest.length > 1) {
                return usage_error (
                    "Commands take no path arguments; the vault and mount "
                    + "locations follow DC_ACCOUNTS_PATH");
            }

            try {
                settings.mount_mode = MountMode.MANAGED;
                settings.allow_executable_files = allow_executable_files;
                if (idle_minutes >= 0) settings.idle_minutes = idle_minutes;
                store = yield settings.open_store (backend_requested, binary_override);
                credentials = new CredentialStore (store.storage_path);
                switch (command) {
                case "backends":
                case "list-backends":
                    return yield cmd_backends ();
                case "check":
                    return yield cmd_check ();
                case "status":
                    return yield cmd_status ();
                case "create":
                    return yield cmd_mount (true);
                case "mount":
                case "unlock":
                    return yield cmd_mount (false);
                case "umount":
                case "unmount":
                case "lock":
                    return yield cmd_umount ();
                case "forget":
                    return yield cmd_forget ();
                case "version":
                    return yield cmd_version ();
                default:
                    return usage_error ("Unknown command: " + command);
                }
            } catch (Error error) {
                stderr.printf ("safestore: %s\n", error.message);
                if (error is StoreError.WRONG_PASSWORD && use_keyring) {
                    stderr.printf (
                        "The stored keyring password may be outdated; "
                        + "run \"safestore forget\" and retry.\n");
                }
                return 1;
            }
        }

        private int usage_error (string message) {
            stderr.printf ("safestore: %s\n%s", message, USAGE);
            return 2;
        }

        private void report (string message) {
            if (!quiet) stdout.printf ("%s\n", message);
        }

        private async int cmd_check () throws Error {
            var status = yield store.inspect ();
            report (status.detail);
            return status.recovery_required ? 4 : (status.plaintext_exposed ? 3 : (status.recognized ? 0 : 1));
        }

        private async int cmd_status () throws Error {
            BackendInfo selected = yield store.probe ();
            var status = yield store.inspect ();
            report ("backend: %s (%s)".printf (selected.name,
                selected.available ? "available; experimental" : "unavailable"));
            report ("backend status: " + selected.status);
            report ("accounts: %s (from %s)".printf (
                store.accounts_path, AccountsPath.source ()));
            report ("storage: " + store.storage_path);
            report (status.detail);
            if (settings.backend == "zip") report (store.removal_info ().status);
            return status.recovery_required ? 4 : (status.recognized ? 0 : 1);
        }

        private async int cmd_mount (bool create) throws Error {

            // Fail on a missing backend before bothering the user for a
            // password.
            BackendInfo backend = yield store.probe ();
            if (!backend.available) {
                throw new StoreError.BACKEND ("%s", backend.status);
            }

            bool from_keyring = false;
            string? password = null;
            if (!create && use_keyring) {
                if (!credentials.available) {
                    stderr.printf (
                        "safestore: built without keyring support; "
                        + "falling back to a password prompt.\n");
                } else {
                    var saved = yield credentials.lookup ();
                    if (saved != null) {
                        password = saved.peek ();
                        saved.clear ();
                        from_keyring = true;
                    }
                }
            }
            if (password == null) {
                password = obtain_password (create, create);
                if (password == null) return 1;
            }

            var secret = new SecretValue (password);
            password = "";

            try {
                if (create) yield store.create_empty (secret);
                else yield store.unlock (secret);
                store.session.access_lost.connect ((reason) => {
                    stderr.printf ("safestore: access lost; stop account writers: %s\n", reason);
                });
                report ((create ? "Vault created and unlocked at %s"
                                : "Vault unlocked at %s").printf (
                    store.accounts_path));

                if (use_keyring && !from_keyring && credentials.available) {
                    try {
                        yield credentials.save (secret);
                        report ("Password stored in the system keyring.");
                    } catch (Error error) {
                        stderr.printf ("safestore: could not remember the password: %s\n", error.message);
                    }
                }
                settings.save ();
                report ("This process holds the store lease. Press Enter (or close input) to lock and exit.");
                yield wait_for_close ();
                yield store.lock ();
                report ("Storage locked; the session is closed.");
            } finally {
                secret.clear ();
            }
            return 0;
        }

        private async void wait_for_close () {
            var context = MainContext.ref_thread_default ();
            SourceFunc resume = wait_for_close.callback;
            new Thread<void*> ("safestore-console", () => {
                stdin.read_line ();
                var source = new IdleSource ();
                source.set_callback (() => { resume (); return Source.REMOVE; });
                source.attach (context);
                return null;
            });
            yield;
        }

        private async int cmd_umount () throws Error {
            yield store.lock ();
            report ("The store is locked.");
            return 0;
        }

        private async int cmd_backends () throws Error {
            foreach (BackendInfo info in (yield store.list_backends ())) {
                report ("%s%s — %s".printf (
                    info.id,
                    info.id == settings.backend ? " (selected)" : "",
                    info.available ? "available" : "unavailable"));
                report ("  %s".printf (info.status));
                report ("  Protection: %s".printf (info.protection));
                report ("  Operation: %s".printf (info.operation));
            }
            EraseInfo erase = store.removal_info ();
            report ("shred — %s".printf (erase.status));
            report ("  Warning: %s".printf (erase.warning));
            return 0;
        }

        private async int cmd_version () throws Error {
            BackendInfo info = yield store.probe ();
            stdout.printf ("%s: %s\n", info.name, info.status);
            return info.available ? 0 : 1;
        }

        private async int cmd_forget () throws Error {
            if (yield credentials.forget ()) {
                report ("Stored password removed from the keyring.");
                return 0;
            }
            report ("No stored password found for this vault.");
            return 1;
        }

        private string? obtain_password (bool confirm,
                                         bool new_password) {
            if (password_stdin) {
                string? line = stdin.read_line ();
                return check_password (line, new_password);
            }

            string? password = prompt_password (
                new_password ? "New vault password" : "Vault password");
            password = check_password (password, new_password);
            if (password == null) return null;

            if (confirm) {
                string? repeated = prompt_password ("Confirm password");
                if (repeated != password) {
                    stderr.printf ("safestore: the passwords do not match.\n");
                    return null;
                }
            }
            return password;
        }

        private string? check_password (string? password,
                                        bool new_password) {
            if (password == null || password.length == 0) {
                stderr.printf ("safestore: the password cannot be empty.\n");
                return null;
            }
            if (password.contains ("\n") || password.contains ("\r")) {
                stderr.printf (
                    "safestore: passwords cannot contain line breaks.\n");
                return null;
            }
            if (settings.backend == "zip") {
                for (int i = 0; i < password.length; i++) {
                    uint8 byte = password.data[i];
                    if (byte < 0x20 || byte == 0x7f) {
                        stderr.printf (
                            "safestore: ZIP passwords cannot contain control characters.\n");
                        return null;
                    }
                }
            }
            if (new_password && password.char_count () < 12) {
                stderr.printf (
                    "safestore: use at least 12 characters for a new vault "
                    + "password.\n");
                return null;
            }
            return password;
        }

        private string? prompt_password (string label) {
#if WINDOWS
            stderr.printf (
                "safestore: secure interactive password input is not "
                + "available on this platform; use --password-stdin "
                + "or --keyring.\n");
            return null;
#else
            if (!Posix.isatty (Posix.STDIN_FILENO)) {
                stderr.printf (
                    "safestore: no terminal available; use --password-stdin "
                    + "or --keyring.\n");
                return null;
            }
            stderr.printf ("%s: ", label);
            Posix.termios saved;
            if (Posix.tcgetattr (Posix.STDIN_FILENO, out saved) != 0) {
                stderr.printf (
                    "safestore: cannot read terminal settings; refusing "
                    + "an unsafe password prompt.\n");
                return null;
            }
            Posix.termios silent = saved;
            silent.c_lflag &= ~Posix.ECHO;
            if (Posix.tcsetattr (
                    Posix.STDIN_FILENO, Posix.TCSAFLUSH, silent) != 0) {
                stderr.printf (
                    "safestore: cannot disable terminal echo; refusing "
                    + "an unsafe password prompt.\n");
                return null;
            }
            string? line = stdin.read_line ();
            if (Posix.tcsetattr (
                    Posix.STDIN_FILENO, Posix.TCSAFLUSH, saved) != 0) {
                stderr.printf (
                    "\nsafestore: warning: failed to restore terminal echo.\n");
                return null;
            }
            stderr.printf ("\n");
            return line;
#endif
        }
    }
}
