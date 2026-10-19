namespace SafeStore {
    [Compact]
    [CCode (cname = "SafeStoreSecretMemory",
            cheader_filename = "pty_password.h",
            ref_function = "safestore_secret_memory_ref",
            unref_function = "safestore_secret_memory_unref")]
    internal class SecretMemory {
        [CCode (cname = "safestore_secret_memory_new")]
        public SecretMemory (string value);

        [CCode (cname = "safestore_secret_memory_peek")]
        public unowned string peek ();

        [CCode (cname = "safestore_secret_memory_clear")]
        public void clear ();
    }
}
