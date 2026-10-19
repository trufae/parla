namespace SafeStore {
    /** Shared precedence policy; callers supply environment and preferences. */
    public class AccountsLocation : Object {
        public static string normalize (string value) {
            string path = value.strip ();
            while (path.length > 1 && (path.has_suffix ("/") || path.has_suffix ("\\"))) {
                if (path.length == 3 && path[1] == ':') break;
                path = path[0:path.length - 1];
            }
            return path;
        }

        public static string resolve (string? environment_path, string? configured_path,
                                      string default_path) {
            string environment = normalize (environment_path ?? "");
            if (environment.length > 0) return environment;
            string configured = normalize (configured_path ?? "");
            return configured.length > 0 ? configured : normalize (default_path);
        }
    }
}
