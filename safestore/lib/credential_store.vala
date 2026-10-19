namespace SafeStore {
    /** Optional OS credential storage, keyed by the explicit ciphertext path. */
    public class CredentialStore : Object {
        private string storage_path;
        public bool available { get { return Keyring.available (); } }

        public CredentialStore (string storage_path) {
            this.storage_path = storage_path;
        }

        public async SecretValue? lookup () throws Error {
            SecretValue? result = null;
            yield run_worker (() => {
                string? value = Keyring.lookup (storage_path);
                if (value != null) result = new SecretValue (value);
            });
            return result;
        }

        public async void save (SecretValue supplied) throws Error {
            var secret = new SecretValue (supplied.peek ());
            try {
                yield run_worker (() => { Keyring.store (storage_path, secret.peek ()); });
            } finally { secret.clear (); }
        }

        public async bool forget () throws Error {
            bool removed = false;
            yield run_worker (() => { removed = Keyring.forget (storage_path); });
            return removed;
        }
    }
}
