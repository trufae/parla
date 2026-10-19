namespace SafeStore {

    public errordomain StoreError {
        RECOVERY_REQUIRED,
        ACCESS_LOST,
        BUSY,
        INVALID_ARGUMENT,
        NOT_SUPPORTED,
        NOT_A_VAULT,
        ALREADY_MOUNTED,
        NOT_MOUNTED,
        WRONG_PASSWORD,
        BACKEND,
        MOUNT_FAILED,
        UNMOUNT_FAILED
    }

    internal class Vault : Object {

        public static bool is_encrypted (string vault_path) {
            string config = Path.build_filename (
                PathPolicy.normalize (vault_path), "cryfs.config");
            return FileUtils.test (config, FileTest.IS_REGULAR)
                && !FileUtils.test (config, FileTest.IS_SYMLINK);
        }

        public static string backend_version (string binary) throws Error {
            string? stdout_text;
            string? stderr_text;
            var process = new Subprocess (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                binary, "--version"
            );
            process.communicate_utf8 (
                null, null, out stdout_text, out stderr_text);
            string text = (stdout_text ?? "").strip ();
            if (text.length == 0) text = (stderr_text ?? "").strip ();
            if (!process.get_successful ()) {
                throw new StoreError.BACKEND (
                    "%s", text.length > 0 ? text : "CryFS returned an error.");
            }
            return text;
        }

    }
}
