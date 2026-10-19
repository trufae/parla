# SafeStore

SafeStore is an experimental Vala library for encrypted account storage.
Parla links it directly through its Vala API. Automatic protection of the working
accounts folder is still planned; see the [remaining milestones](../docs/safestore-plan.md).

**Settings → General → Account Backups** now provides **Create Encrypted Backup**,
**Check Backup**, and **Restore Backup**. Save a full password-encrypted `.zip`
anywhere on a local filesystem, including a USB drive. No separate program or
command is needed. All account files and attachments are encrypted with WinZip
AES-256 through libzip; this is independent of the legacy working-store ZIP adapter.
Use a long, unique password and keep it safely: there is no password recovery.

Creation pauses messaging, drains queued RPC requests, closes stdin, waits for
successful core exit, and acquires native ownership locks before reading files.
The archive is authenticated and every file hash verified before publication.
Existing backups are never overwritten. Source data is kept unchanged. Checking
an archive does not stop messaging. Restore creates a separate private plaintext
folder; an explicit **Use Restored Accounts** action checks its layout, opens every
account with the core offline, durably selects that folder, and reconnects Parla.
The previous account folder is retained. Restore is available before the first account.

Current limits: full backups only; a no-history account-access export remains a
separate follow-up. This first integration covers ordinary accounts folders;
backup while a managed SafeStore session holds its lease waits for the future
session integration. An external `DC_ACCOUNTS_PATH` override prevents switching
folders, but checking and restoring a separate copy still work. Unsupported core
metadata is rejected without deleting the backup or restored files. A failed or
cancelled extraction can leave a private incomplete plaintext folder; its path is
reported. Archive checks establish byte integrity, not database semantic integrity
or guaranteed future server access. Native Windows/macOS and removable-drive
failure qualification remains required before a cross-platform release claim.

The encrypted manifest stores original relative paths, directories, sizes, SHA-256
hashes, a UTC creation date and format version 1. ZIP members use opaque names;
ZIP metadata still reveals entry counts and compressed/uncompressed sizes. The
reader limits the manifest to 32 MiB, inventory to 100,000 entries and default
expanded data to 1 TiB; rejects traversal, links, case/Unicode collisions and
Windows device names; and requires AES-256 on every entry. These ZIPs should be
restored with Parla to reconstruct their paths.

The GTK-free `SafeStore.Backups` API exposes async `create(accounts_path,
destination, SecretValue, Cancellable?)`, `verify(path, SecretValue, Cancellable?)`
and `restore(path, new_directory, SecretValue, Cancellable?)`. `BackupInfo` reports
creation date, file count, bytes and the restored path. `progress(phase, completed,
total)` runs on the operation's calling main context, as does completion. Use an
instance on one main context at a time; concurrent operations return BUSY.
Callers must stop and await **all** writers before `create`; native leases are an
additional guard. Verification does not require access to the current store.
Before restore, callers can use `validate_restore_destination(accounts_path,
new_directory)` to reject a location inside the live store, including aliases.
The maximum restore size can be configured before an operation. Cancellation is
honored before publication; a published backup is never reported as cancelled.
If directory synchronization fails after publication, the error identifies the
saved backup and states that durable storage could not be confirmed.

The optional standalone tools manage storage holding the Delta Chat accounts.
CryFS is the current filesystem adapter; legacy ZIP is an explicitly weaker
compatibility option. Platform qualification is still required before release.
Parla and the standalone tools share this `DC_ACCOUNTS_PATH` precedence:

1. `$DC_ACCOUNTS_PATH`, when set and non-empty;
2. otherwise the `accounts_path` key in Parla's `settings.ini`;
3. otherwise Parla's default accounts directory (the same fallback chain
   Parla uses when launching `deltachat-rpc-server`).

Parla passes explicit paths to the library. The shared `AccountsLocation`
resolver takes explicit environment/configuration/default inputs. CryFS
mounts its decrypted view there and stores ciphertext in `<accounts>.vault`.
ZIP extracts plaintext there and stores its archive in `<accounts>.zip`.
These standalone-tool locations follow the resolved accounts path; `safestore status` prints the selected
backend, paths, availability, and state.

The source is split into:

- `lib/` — the GTK-free `libsafestore-1` static library, public header and VAPI.
  Parla and both standalone tools consume the same Meson dependency.
- `frontend/` — account-path discovery and non-secret preferences for the
  standalone tools. These are not part of the library.
- `cli/` — the `safestore` command-line tool for scripted and automated use.
- `gui/` — the `safestore-gui` GTK4/libadwaita application.

## What it does

- Lists the supported backends, whether their required programs are available,
  their operating model and security limitations.
- Records each store's ID, method, locations, generation, and operation phase
  beside the accounts folder. Existing stores select their recorded method.
- Creates a new CryFS vault using XChaCha20-Poly1305.
- Unlocks an existing vault after checking for `cryfs.config`.
- Detects vault state from the platform mount table, distinguishing an
  encrypted vault, the decrypted view of a mounted vault
  (`cryfs@<vault>` on `fuse.cryfs`), and a plain directory.
- Refuses to run when CryFS is not installed, before asking for a password.
- Sends the password to CryFS through a private stdin pipe. It is never
  placed in command-line arguments, environment variables, settings, or
  the activity log.
- Optionally remembers vault passwords in the operating system's secret
  store (Secret Service via libsecret on Linux, the login keychain on
  macOS), never in a plain file on disk. Windows has no keyring backend
  yet and always prompts.
- Verifies that the mount actually appears instead of trusting console
  text, and locks with the strict `cryfs-unmount --immediate` path.
- Holds native account and ciphertext ownership locks throughout each session.
- Monitors working-directory identity, mount source/identity, and process loss.
- Rejects backend-controlled idle unmounting: callers must stop writers first.
- Mounts the decrypted view with `noexec` by default; Vala callers can opt in
  with `allow_executable_files`, and the CLI exposes `--allow-exec`.
- Rejects nested vault/mount paths and non-empty mount directories.
- On Unix, requires the encrypted vault, plaintext mountpoint, and CryFS
  integrity-state directory to belong to the invoking user, rejects symlinks,
  and enforces mode `0700` before mounting.
- Stores non-secret tool preferences separately from per-store identity.
- Refuses ambiguous legacy layouts and interrupted operations until recovery.
- With the ZIP backend, writes and verifies a new encrypted archive before
  atomically replacing the previous archive and removing plaintext. Unlocking
  happens in a private staging directory before the accounts path is exposed.
- Passes ZIP passwords through a private pseudo-terminal only after terminal
  echo is disabled. It never uses Info-ZIP's insecure `-P` argument.
- Leaves a non-secret `.safestore-locked` placeholder at the accounts path so
  Delta Chat cannot silently create a fresh account manager while ZIP data is
  locked.
- Optionally invokes `shred` on each regular plaintext file before removal.
  This is best-effort and is not guaranteed on SSDs, copy-on-write filesystems,
  snapshots, journals, swap, or backups.

## Requirements

Build requirements: Vala 0.56+, Meson/Ninja, GLib/GIO 2.66+, libzip 1.7+
with AES encryption support on desktop platforms; GTK 4 and
libadwaita 1.5+ for the GUI; libsecret (optional) for the Linux keyring.

Runtime requirements:

- **CryFS stable 1.x**, with `cryfs` and `cryfs-unmount` reporting the same
  release version. Older releases, prereleases, and missing/mismatched unmount
  helpers are rejected. Exact release/runtime qualification is milestone 3.
- Linux: FUSE.
- macOS: macFUSE plus permission to load its system extension. Homebrew's
  core `cryfs` formula is Linux-only; use the
  [official CryFS tap](https://github.com/cryfs/homebrew-tap)
  (`brew install --cask macfuse && brew install cryfs/tap/cryfs`) or
  MacPorts (`sudo port install cryfs`).
- Windows: the library and native ownership lock have Windows implementations,
  but storage mutations remain unavailable until mount identity, private ACLs,
  replacement durability, and backend operation are qualified in milestone 3.
  An existing drive or directory never proves an encrypted mount.
- ZIP backend on Unix: Info-ZIP-compatible `zip` and `unzip`, both discoverable
  in `PATH` (or configured explicitly), plus pseudo-terminal support. The ZIP
  backend is unavailable on Windows for now because SafeStore cannot provide
  its required private interactive password channel there.
- Optional overwrite removal: a `shred`-compatible executable. Availability is
  reported separately and ZIP locking refuses to claim overwrite removal when
  it is missing.

## Build and run

From this directory:

```sh
make test
make run
```

`make run` configures Meson when needed, compiles SafeStore, and starts the
GUI (`safestore-gui`). The CLI is built alongside it as
`builddir/safestore`.

Other useful targets:

```sh
make                 # library, CLI and tests; no GTK dependency
make library         # library only
make GUI=true        # also build the experimental GUI
make test            # build and run tests
make clean           # clean compiled outputs
make install         # install under PREFIX, default /usr/local
make install PREFIX="$HOME/.local"
make install INSTALL_DEVEL=true  # also install library/header/VAPI/pkg-config
```

On macOS the Makefile reuses Parla's Homebrew GTK environment helper. On
Windows, build from an MSYS2 UCRT64 shell.

A nonstandard CryFS installation can be selected with
`SAFESTORE_CRYFS=/absolute/path/to/cryfs` or `--binary`; the same directory
must also contain `cryfs-unmount`.

## Command line

The `safestore` tool exposes the prototype create/unlock/lock operations.
Commands take no path arguments; everything follows the accounts path:

```sh
safestore backends       # list backends, availability, and security model
safestore status         # resolved paths + vault and mount state
safestore check          # encrypted vault, decrypted mount, or neither?
safestore create         # new vault, prompts for a password twice
safestore mount          # unlock; prompts without echoing
safestore --allow-exec mount   # permit direct execution inside the mount
safestore umount         # verify an already-locked store; cannot close another owner
safestore --backend zip create
safestore --backend zip --shred mount
DC_ACCOUNTS_PATH=/elsewhere/accounts safestore mount   # alternate store
```

Exit codes are script-friendly: `0` yes/success, `1` no/failure, `2` usage
error; `check` additionally returns `3` when the accounts path is currently
ordinary plaintext. Both `check` and `status` return `4` for recovery-required
state. An active session in another process is conservatively classified as
active or interrupted, never as safely locked. Classification is not an
integrity check.

Passwords are never accepted as command-line arguments. The sources are:

- an interactive prompt with terminal echo disabled (the default),
- `--password-stdin` for scripts and other programs,
- `--keyring` to fetch the password from the OS secret store. On the first
  interactive unlock with `--keyring`, the password is saved there after a
  successful mount; `safestore forget` removes it again. Combined with the
  keyring, unlocking needs no password prompt. The CLI still holds the session
  until Enter/EOF. Parla will call the Vala API directly.

Password prompting is deliberately a frontend responsibility. The GTK-free
library never opens a terminal, displays a dialog, or invokes the SafeStore CLI:

- the CLI reads from its own terminal with echo disabled (or from its explicit
  stdin/keyring modes);
- GUI callers use a native masked password widget. `safestore-gui` uses
  `Gtk.PasswordEntry`, reads its unowned text view, and clears the widget
  immediately;
- both hand the value to the library through `SecretValue`, whose mutable
  allocation is locked against swapping when supported and explicitly wiped
  after use;
- the library then passes it to CryFS over a private stdin pipe or to Info-ZIP
  over the private pseudo-terminal. It never places it in argv or the
  environment.

Both tools hold managed sessions. CLI `create`/`mount` stay alive until Enter
or EOF, then lock before exiting. Stop all account writers before closing that
input. A second CLI cannot take ownership or remotely close the first. Forced
termination leaves an operation phase requiring recovery; it does not constitute
a clean lock. ZIP retains the password in the session, so closure needs no
second prompt. Backend idle unmount and detached mutation are unsupported.

## Public Vala API

`lib/meson.build` defines `safestore_dep`, shared by Parla and the standalone
wrapper. Consumers use the generated `safestore-1.vapi` and `safestore-1.h`;
backend controllers, process arguments, mount parsers and erasure helpers are
internal. No GTK dependency, JSON-RPC service, or SafeStore helper process is
required by this interface. Backend executables still run under library control.

Construct `Store(accounts_path, storage_path, backend, options)` with absolute,
non-overlapping paths. Construction validates the layout without creating it.
The working accounts path and ciphertext location are independent. `StoreOptions`
is copied, so changing a caller's options cannot redirect an in-flight operation.
The core reads neither Parla settings nor `DC_ACCOUNTS_PATH`/`SAFESTORE_*` variables,
and does not change the parent process environment. Bare executable names use
normal executable search paths. `state_directory` defaults to `<storage>.state`;
the standalone adapter explicitly preserves its previous CryFS state location.

| Public API | Current contract |
| --- | --- |
| `Store.list_backends()` / `probe()` | Async tool/version discovery. `BackendInfo` describes availability, limitations and supported `Operation` flags. Every current adapter is experimental. |
| `Store.open_existing(accounts, options)` | Reads per-store metadata and returns the recorded backend/location, or null for an unrecorded location. Never guesses another backend. |
| `Store.inspect()` | Async, read-only classification with `AccessState`, store ID/generation, recovery state, and session ownership. ZIP recognition validates an encrypted SafeStore ZIP32 structure; CryFS recognition finds its configuration. Neither authenticates ciphertext; `integrity_verified` remains false. |
| `Store.create_empty(secret)` | Creates only at an empty location, records its identity, and returns an owned `Session`. Does not migrate existing accounts. |
| `Store.unlock(secret)` | Returns a `Session` after verifying access. Imports an unambiguous locked legacy store. Never creates missing ciphertext or overwrites conflicting plaintext. |
| `Store.lock(secret?)` | Uses the session's retained secret; a different supplied password is rejected. The caller must first stop and await all writers. Releases ownership only after verified closure. Repeating a successful lock is harmless; abandoned sessions need recovery. |
| `Session` | Store ID/generation, verified `accounts_path`, `active`, and `access_lost(reason)`. Loss invalidates the session; callers must stop file access immediately. |
| `Store.state_changed` / `output` | Lifecycle state and backend diagnostics on the caller's main context. `UNKNOWN` is the initial state. Backend errors remain observable. |
| `Store.removal_info()` | Availability and limitations of best-effort overwrite removal. |
| `SecretValue` | Wipeable password handoff. Mutation calls copy it before their first suspension; callers may clear their input immediately after starting a call. The operation clears its private copy on completion or error; a successful session retains a separate wipeable copy until closure or access loss. |
| `CredentialStore(storage_path)` | Optional async `lookup`, `save`, and `forget` using the existing OS keyring adapters. Lookup returns a `SecretValue` the caller must clear. |

For an existing store:

```vala
var store = yield SafeStore.Store.open_existing (accounts_path);
if (store == null) {
    // Show first-time protection choices; never create implicitly.
    return;
}
var status = yield store.inspect ();
if (status.recovery_required) {
    // Preserve every copy and present recovery details.
    return;
}
var session = yield store.unlock (secret);
secret.clear ();
session.access_lost.connect ((reason) => {
    // Immediately stop account IO and show the failure.
});
// Start the account server with session.accounts_path.
// Later, stop every writer and await server exit before:
yield store.lock ();
```

Call a Store from one GLib main context. Blocking backend work runs off that
context, and callbacks return to its thread-default context. Concurrent lifecycle
operations on an instance are rejected as `StoreError.BUSY`. Stable native lock
files serialize distinct instances and processes for both the account location
and ciphertext location. Keep the Store alive while unlocked and explicitly
await locking; finalization cannot perform async closure. Ownership coordinates
local cooperating processes, not independently synced copies on other machines.

`MountMode.MANAGED` is required for mutations; `DETACHED` is rejected. ZIP has
no filesystem process. `process_active` conservatively includes busy operations,
owned sessions, and observed exposed storage; it is not proof of usable access.
`idle_minutes` must remain zero. Coordinated idle closure belongs to Parla's
future lifecycle controller.

`GLib.Cancellable` is supported by inspection, probing and lifecycle calls.
Cancellation is honored before a mutation begins. Once an existing backend
starts mutating, the operation runs to completion and reports its actual result;
it cannot yet offer transactional interruption or byte-level progress. Credential
operations also run asynchronously but currently have no cancellation parameter.
Errors use `StoreError`, `PathPolicyError`, and GLib I/O/process error domains.
Password buffers cannot guarantee that GTK, GLib, the OS and backend programs
never make additional copies.

`ENABLE`, `DISABLE`, `CHANGE_BACKEND`, `VERIFY`, `BACKUP`, `RESTORE`, and `RECOVER`
are advertised as unsupported. There are no success-returning stubs. Transaction
plans/results, progress, recovery execution, and migrations remain future work.
The 0.1 API remains experimental; Windows mutations and native platform runtime
qualification are still pending.

A standalone library-only build is:

```sh
meson setup build-lib safestore -Dcli=false -Dgui=false -Dtests=false
meson compile -C build-lib
```

Run that command from the Parla root. Add `-Dinstall_devel=true` to install the
static library, public header, VAPI, `.deps` and `safestore-1.pc`. An installed
consumer uses `dependency('safestore-1', static: true)` in Meson, or
`valac --pkg safestore-1 consumer.vala`. For a nonstandard prefix, supply the
installed VAPI directory with `--vapidir` and the pkg-config directory through
`PKG_CONFIG_PATH`. No private header or source file is needed.

The standalone build exposes `-Dcli`, `-Dgui`, `-Dtests`, and `-Dinstall_devel`.
GUI defaults off; CLI and tests default on. Public consumer tests exercise the
same generated dependency as Parla; separate white-box tests compile internal
helpers solely to preserve their existing coverage. Linux, macOS and Windows CI
compile both consumers. A successful build does not qualify an encryption
backend for production on that OS; Windows ZIP remains unavailable.

## Using the GUI

The Locations group shows the derived vault and mount folders; they cannot
be edited. To operate on a different store, launch the GUI with
`DC_ACCOUNTS_PATH` set.

1. Select a backend. Read the availability and protection text; prefer CryFS.
2. For a new empty vault, press **Create** and enter the password twice.
3. Press **Unlock** for an existing selected-backend vault.
4. Work only through the accounts path.
5. Close Parla and every other application using the accounts, then press
   **Lock** before
   exiting.

The GUI runs CryFS in the foreground and watches the process. It also refuses
to close while ZIP plaintext is unlocked. Force-killing during writes or ZIP
replacement can damage the active data. The **Copy Accounts Path** button
copies the path for manual `DC_ACCOUNTS_PATH` experiments.

## Stored state

Versioned per-store metadata lives in `<accounts>.safestore/store.ini`, outside
the working tree. It records a UUID, backend/format, accounts/ciphertext paths,
generation and phase (`creating`, `opening`, `unlocked`, `locking`, `cleanup`,
`locked`). Unix updates synchronize the file and parent directory before
proceeding. Never delete this directory to bypass a recovery state.

Stable ownership files are `<accounts>.safestore/owner.lock` and
`<ciphertext>.safestore.lock`. They are never unlinked by the library. A missing
owner after a crash does not make an `unlocked` or in-progress phase safe to use.
ZIP records `cleanup` after committing the complete archive and before removing
plaintext; retries cannot archive the remaining partial tree over that archive.
Recovery execution is milestone 4; current operations preserve ambiguous copies
and refuse to proceed. Keep metadata and CryFS integrity state with backups.

For ordinary account directories the control directory must stay beside the
accounts path. Windows drive mounts require an explicit `control_directory`
outside the drive; mutations there still await platform qualification.

Non-secret tool and removal preferences live in
`$XDG_CONFIG_HOME/safestore/settings.ini` (or the platform GLib equivalent).
The previous global backend and idle-unmount preferences no longer control
stores. CryFS rollback/integrity state for standalone tools remains under
`safestore/cryfs-state/` in the GLib user-data directory.

The password is not saved to disk by SafeStore itself. With `--keyring` it
is handed to the operating system's secret store, which keeps it encrypted
under the user's login session. GTK, GLib, the operating system, and CryFS
will necessarily hold password/key material in process memory while
unlocking or using the filesystem; this prototype cannot guarantee locked
or zeroized memory.

## Security model

### CryFS

CryFS encrypts file contents, names, sizes, metadata, and directory
structure; only encrypted blocks persist in the vault directory. This
protects **data at rest**: a clean lock, shutdown, stolen powered-off disk,
or a copied/synced vault directory, with modification detection through
CryFS authenticated encryption and local state.

It does **not** protect against malware or an attacker on the unlocked
machine, memory/swap/hibernation extraction, files copied out of the
mounted view, or plaintext that applications spill outside the mount
(caches, thumbnails, logs, crash dumps). User-facing wording must say
"encrypted account storage at rest," never "no plaintext anywhere."

On Unix, SafeStore relies on FUSE's default owner-only mount access and never
requests `allow_other` or `allow_root`. Directory mode `0700` additionally
protects the ciphertext and the mountpoint from other local accounts. These
controls are not a security boundary against a hostile system administrator:
root can impersonate the user, inspect process memory, or change the running
system. Run SafeStore as the desktop user, not through `sudo`.

The decrypted mount uses FUSE's `noexec` option by default. This prevents
direct execution of programs from the vault, but does not prevent an
interpreter from reading a script stored there. Callers must explicitly set
`allow_executable_files` (or pass CLI option `--allow-exec`) to opt out.

### ZIP compatibility backend

The ZIP backend uses the legacy ZipCrypto encryption implemented by the
external `zip` program. It is substantially weaker than CryFS: file names,
directory layout, sizes, timestamps, and other archive metadata are visible,
and ZipCrypto is not modern authenticated encryption. A strong password does
not make it equivalent to CryFS. It is an explicit compatibility option, not
the recommended backend.

While unlocked, the full accounts tree is ordinary plaintext. The previous
encrypted ZIP snapshot also remains, so storage is duplicated. On lock,
SafeStore creates and password-verifies a temporary archive, synchronizes it,
atomically replaces `<accounts>.zip`, and only then removes the plaintext.
Extraction uses private staging and rejects symbolic links, unencrypted entries,
conflicting headers, unsafe names and unexpected top-level entries. The adapter
currently accepts ZIP32 only; ZIP64 fails closed before archive replacement.
After archive commit the durable cleanup phase prevents retries from overwriting
the complete snapshot with partly removed plaintext.

Before ZIP locking, SafeStore attempts to acquire Delta Chat's `accounts.lock`
with the same non-blocking file-lock mechanism used by the core. If Parla or
another RPC server still owns it, locking is refused before archiving. This is
a safety check, not a replacement for lifecycle coordination: Parla must stop
the RPC server and wait for it before asking SafeStore to lock.

ZIP passwords are never passed with `zip -P` or `unzip -P`; those options put
the secret in the process argument list. SafeStore gives each process a
private controlling pseudo-terminal, waits for its password prompt with echo
disabled, and writes the password there. Platforms without that facility
report ZIP as unavailable.

Optional `shred` support overwrites regular files before unlinking them and
refuses multiply-linked files. It only reduces exposure on some traditional
filesystems. It cannot guarantee erasure from flash media, copy-on-write
storage, filesystem journals, snapshots, swap, hibernation images, or backups.

Rules that must hold in any integration:

- Passwords never enter argv, environment variables, settings, or logs.
- Creation and unlock are separate actions; unlock never silently creates
  a vault at a typoed path.
- Never automatically pass `--allow-filesystem-upgrade`,
  `--allow-replaced-filesystem`, or `--allow-integrity-violations`. Those
  belong in an explicit recovery workflow after a backup. CryFS exit codes
  distinguish wrong passwords, format issues, and integrity violations;
  keep those distinctions in the UI.
- No home-grown cryptography: SafeStore delegates encryption to CryFS or
  Info-ZIP and only controls their process lifecycle. A
  future "password plus recovery code" envelope is a new cryptographic
  format and needs independent review before it exists.

## Important safety rules

- Keep backups of the complete encrypted vault: the whole CryFS directory
  including `cryfs.config`, or the complete `<accounts>.zip` file.
- Only sync the encrypted vault — never the plaintext mount — and never
  mount the same synced vault on two machines at once. Lock first and let
  sync finish before unlocking elsewhere.
- A forgotten password means lost data unless it is stored in the keyring
  or a password manager; there is no recovery system.
- Test with disposable data first.

## Parla integration plan

The integration point is before `deltachat-rpc-server` starts:

1. Resolve the accounts path (and with it the vault and mount locations)
   through the shared `DC_ACCOUNTS_PATH` chain.
2. Inspect the selected backend. For CryFS, verify mount identity; for ZIP,
   distinguish the locked placeholder from an extracted plaintext tree.
3. Unlock via keyring, or prompt only in an interactive session.
4. Wait for verified mount readiness, then start the RPC server with
   `DC_ACCOUNTS_PATH` set to the mounted path.
5. On lock/quit: stop UI writes, shut the RPC server down and wait for it,
   strictly unmount CryFS or durably replace the ZIP and remove plaintext,
   verify the result, and only then report locked.

Migration must copy — not move — the existing accounts directory into a
freshly verified vault, validate everything, and keep the plaintext backup
until an encrypted backup has passed a restore test.

Remaining work before this is a supported Parla feature:

- Windows: a Credential Manager keyring backend and mount detection via
  volume APIs (a drive letter existing proves nothing today).
- Pin and verify an exact CryFS 1.x version; decide bundled vs. system
  packaging, and reject unsupported versions instead of just showing them.
- Connect the library session/ownership and access-loss signals to Parla: RPC
  startup failure, disappearing mounts, busy files at shutdown, and shutdown
  grace periods must all pass through the application storage controller.
- Provide byte-level progress and cancellation for large ZIP account stores.
- Plaintext-footprint audit (Delta Chat WAL/blobs, thumbnails, search
  indexes, crash dumps) — move controllable caches into the mount.
- Real-hardware testing on macOS (keychain backend, macFUSE approval) and
  Windows; power-loss and crash tests at controlled write points.
- A documented backup/recovery procedure users can perform without Parla.

## Project layout

```text
safestore/
├── data/               desktop launcher
├── lib/                core library: vault, keyring, path and mount logic
├── frontend/           standalone preferences and account-path discovery
├── cli/                safestore command-line tool
├── gui/                safestore-gui GTK application
├── tests/              path/layout safety tests
├── Makefile            build/run/test convenience targets
├── meson.build         standalone Meson project
└── README.md           this guide
```

## References

- [CryFS tutorial](https://www.cryfs.org/tutorial) and
  [design](https://www.cryfs.org/howitworks)
- [CryFS stable releases](https://github.com/cryfs/cryfs/releases)
- [gocryptfs](https://github.com/rfjakob/gocryptfs) (possible alternative
  Linux backend; rclone crypt and EncFS were evaluated and rejected)
