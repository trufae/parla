namespace SafeStore {
    // Native archive lifecycle under Store's exclusive leases and phase journal.
    // Portable backups and working stores share the codec, not their identities
    // or publication policy. Legacy ZipCrypto is never read or rewritten here.
    internal class AesZipBackend : Object {
        private static void require_available (Settings settings) throws Error {
            if (!Archive.available ()) throw new StoreError.NOT_SUPPORTED ("Native AES-256 archive support is unavailable");
            PlaintextEraser.require_available (settings);
        }

        private static ArchiveSnapshot snapshot (Settings settings, Metadata metadata, bool next = false) throws Error {
            if (next && metadata.generation == uint64.MAX)
                throw new StoreError.RECOVERY_REQUIRED ("Store generation overflow");
            return new ArchiveSnapshot (settings.maximum_archive_bytes, metadata.id,
                metadata.generation + (next ? 1 : 0));
        }

        public static void create (Settings settings, Metadata metadata, string password) throws Error {
            require_available (settings);
            if (FileUtils.test (settings.vault_path, FileTest.EXISTS | FileTest.IS_SYMLINK))
                throw new StoreError.ALREADY_MOUNTED ("An encrypted store already exists at this location");
            ZipBackend.prepare_destination (settings.mount_path);
            bool rollback_safe = false;
            write (settings, metadata, password, true, ref rollback_safe);
        }

        public static void unlock (Settings settings, Metadata metadata, string password,
                                   ref bool rollback_safe) throws Error {
            rollback_safe = false;
            require_available (settings);
            ZipBackend.ensure_locked_destination (settings.mount_path);
            ArchiveSnapshot.inspect_store (settings.vault_path);
            var codec = snapshot (settings, metadata);
            string parent = Path.get_dirname (settings.mount_path);
            string staging = Path.build_filename (parent, ".safestore-unlock-" + Uuid.string_random ());
            bool created = false;
            bool exposed = false;
            try {
                // Authenticate everything before creating even an empty plaintext folder.
                BackupInfo info;
                try { info = codec.read (settings.vault_path, password, null); }
                catch (IOError.PERMISSION_DENIED error) {
                    throw new StoreError.WRONG_PASSWORD ("Could not decrypt the AES ZIP store");
                }
                ArchiveSnapshot.check_space (parent, info.bytes, null);
                Archive.make_private_directory (staging);
                created = true;
                codec.read (settings.vault_path, password, staging);
                ZipBackend.ensure_locked_destination (settings.mount_path);
                ZipBackend.remove_locked_destination (settings.mount_path);
                Archive.publish (staging, settings.mount_path);
                exposed = true;
                Archive.sync (parent, true);
            } catch (Error error) {
                if (created && !exposed) {
                    try { PlaintextEraser.erase_tree (staging, settings); Archive.sync (parent, true); }
                    catch (Error cleanup_error) {
                        throw new StoreError.RECOVERY_REQUIRED (
                            "Plaintext staging remains at %s: %s", staging, cleanup_error.message);
                    }
                }
                rollback_safe = !exposed;
                throw error;
            }
        }

        public static void lock (Settings settings, Metadata metadata, string password,
                                 Worker committed, ref bool rollback_safe) throws Error {
            rollback_safe = true;
            require_available (settings);
            ZipBackend.validate_plain_accounts (settings.mount_path);
            PlaintextEraser.validate_tree (settings.mount_path, settings);
            var guard = new Lease (Path.build_filename (settings.mount_path, "accounts.lock"));
            write (settings, metadata, password, false, ref rollback_safe);
            committed ();
            PlaintextEraser.erase_tree (settings.mount_path, settings);
            ZipBackend.create_locked_destination (settings.mount_path);
            Archive.sync (Path.build_filename (settings.mount_path, ".safestore-locked"), false);
            Archive.sync (settings.mount_path, true);
            Archive.sync (Path.get_dirname (settings.mount_path), true);
            guard = null;
        }

        private static void write (Settings settings, Metadata metadata, string password,
                                   bool creating, ref bool rollback_safe) throws Error {
            var codec = snapshot (settings, metadata, true);
            string parent = Path.get_dirname (settings.vault_path);
            // libzip's temporary output and headers remain inside this private directory.
            string staging = Path.build_filename (parent, ".safestore-encrypt-" + Uuid.string_random ());
            Archive.make_private_directory (staging);
            string temporary = Path.build_filename (staging, "store.zip");
            Error? failure = null;
            try {
                codec.write (settings.mount_path, temporary, password);
#if !WINDOWS
                if (FileUtils.chmod (temporary, 0600) != 0)
                    throw new IOError.PERMISSION_DENIED ("Could not restrict encrypted store permissions");
#endif
                Archive.sync (temporary, false);
                // A failure from this point may have published the new generation.
                rollback_safe = false;
                if (creating) Archive.publish (temporary, settings.vault_path);
                else Archive.replace (temporary, settings.vault_path);
                Archive.sync (parent, true);
                codec.read (settings.vault_path, password, null);
            } catch (Error error) { failure = error; }
            try {
                PlaintextEraser.erase_tree (staging, settings);
                Archive.sync (parent, true);
            } catch (Error error) {
                throw new StoreError.RECOVERY_REQUIRED ("Encrypted staging cleanup failed at %s: %s", staging, error.message);
            }
            if (failure != null) throw failure;
        }
    }
}
