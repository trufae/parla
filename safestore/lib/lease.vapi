namespace SafeStore {
    [Compact]
    [CCode (cname = "SafeStoreLease", cheader_filename = "lease.h",
            free_function = "safestore_lease_free")]
    internal class Lease {
        [CCode (cname = "safestore_lease_new")]
        public Lease (string path) throws GLib.Error;
    }
}
