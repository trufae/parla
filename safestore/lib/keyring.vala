namespace SafeStore {

    // Stores vault passwords in the operating system's secret store so
    // unlocking can be automated without ever writing the password to disk
    // in plain text. Entries are keyed by the normalized vault path.
    //
    // Backends: the login keychain through /usr/bin/security on macOS, the
    // Secret Service through libsecret elsewhere when available. There is no
    // Windows Credential Manager backend yet; available() reports false and
    // callers must fall back to prompting.
    internal class Keyring : Object {

        private const string SERVICE = "io.github.trufae.SafeStore";

#if DARWIN
        public static bool available () {
            return FileUtils.test (
                "/usr/bin/security", FileTest.IS_EXECUTABLE);
        }

        public static void store (string vault_path,
                                  string password) throws Error {
            string vault = PathPolicy.normalize (vault_path);
            // Interactive mode reads the command from stdin, so the
            // password never appears in the process argument list.
            string command = "add-generic-password -U -a %s -s %s -w %s\n"
                .printf (quote (vault), quote (SERVICE), quote (password));
            var process = new Subprocess (
                SubprocessFlags.STDIN_PIPE
                | SubprocessFlags.STDOUT_PIPE
                | SubprocessFlags.STDERR_PIPE,
                "/usr/bin/security", "-i"
            );
            string? stdout_text;
            string? stderr_text;
            process.communicate_utf8 (
                command, null, out stdout_text, out stderr_text);
            string errors = (stderr_text ?? "").strip ();
            if (!process.get_successful () || errors.length > 0) {
                throw new IOError.FAILED (
                    "Keychain store failed: %s",
                    errors.length > 0 ? errors : "security exited with an error");
            }
        }

        public static string? lookup (string vault_path) throws Error {
            string vault = PathPolicy.normalize (vault_path);
            var process = new Subprocess (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                "/usr/bin/security", "find-generic-password",
                "-a", vault, "-s", SERVICE, "-w"
            );
            string? stdout_text;
            string? stderr_text;
            process.communicate_utf8 (
                null, null, out stdout_text, out stderr_text);
            if (!process.get_successful ()) return null;
            string secret = (stdout_text ?? "").chomp ();
            return secret.length > 0 ? secret : null;
        }

        public static bool forget (string vault_path) throws Error {
            string vault = PathPolicy.normalize (vault_path);
            var process = new Subprocess (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                "/usr/bin/security", "delete-generic-password",
                "-a", vault, "-s", SERVICE
            );
            string? stdout_text;
            string? stderr_text;
            process.communicate_utf8 (
                null, null, out stdout_text, out stderr_text);
            return process.get_successful ();
        }

        private static string quote (string value) {
            var quoted = new StringBuilder ("\"");
            for (int i = 0; i < value.length; i++) {
                char character = value[i];
                if (character == '"' || character == '\\') {
                    quoted.append_c ('\\');
                }
                quoted.append_c (character);
            }
            quoted.append_c ('"');
            return quoted.str;
        }
#elif HAVE_LIBSECRET
        private static Secret.Schema? schema_instance;

        private static Secret.Schema schema () {
            if (schema_instance == null) {
                schema_instance = new Secret.Schema (
                    SERVICE,
                    Secret.SchemaFlags.NONE,
                    "vault", Secret.SchemaAttributeType.STRING
                );
            }
            return schema_instance;
        }

        public static bool available () {
            return true;
        }

        public static void store (string vault_path,
                                  string password) throws Error {
            string vault = PathPolicy.normalize (vault_path);
            Secret.password_store_sync (
                schema (),
                Secret.COLLECTION_DEFAULT,
                "SafeStore vault %s".printf (vault),
                password,
                null,
                "vault", vault
            );
        }

        public static string? lookup (string vault_path) throws Error {
            return Secret.password_lookup_sync (
                schema (), null,
                "vault", PathPolicy.normalize (vault_path));
        }

        public static bool forget (string vault_path) throws Error {
            return Secret.password_clear_sync (
                schema (), null,
                "vault", PathPolicy.normalize (vault_path));
        }
#else
        public static bool available () {
            return false;
        }

        public static void store (string vault_path,
                                  string password) throws Error {
            throw new IOError.NOT_SUPPORTED (
                "SafeStore was built without keyring support.");
        }

        public static string? lookup (string vault_path) throws Error {
            return null;
        }

        public static bool forget (string vault_path) throws Error {
            return false;
        }
#endif
    }
}
