# SafeStore library and Parla integration plan

Parla will link a GTK-free Vala library for account storage protection on
Windows, Linux, and macOS. Users configure protection through Parla Settings,
including before creating or importing their first account. Parla manages
unlocking and locking during its normal lifecycle. An optional SafeStore CLI
uses the same library for diagnostics and recovery; normal operation does not
depend on running that CLI or the standalone GUI.

The library and lifecycle foundations are complete. A first implementation of
encrypted backup and restore from Settings (milestone 2.5) now lets users save
and test a recovery copy before experimenting with storage protection. Backend
qualification, recoverable migrations, and the rest of the Settings integration
follow. Backup does not require enabling encryption of the working accounts.

## Architecture and ownership

| Component | Responsibility |
| --- | --- |
| Parla Settings | User choices, password entry, progress, explanations, and recovery decisions. Available without an account or running RPC server. |
| Parla storage controller | Resolve the selected store; coordinate startup, reconnect, lock, quit, and restart; stop every account writer before storage operations. |
| SafeStore library | Inspect storage, own exclusive access, manage backend processes, verify results, migrate data, and recover interrupted operations. |
| Backend adapters | Implement the capabilities of each encryption format and operating-system filesystem runtime. |
| Optional SafeStore tools | Exercise the public API without duplicating storage logic. |

Link SafeStore statically into Parla initially. Backend executables and system
filesystem components may still run separately under library control. There is
no additional JSON-RPC service or permanent SafeStore daemon.

Pass an explicit store location into the library. It must not read Parla's
settings file, resolve a different path from the environment, or mutate global
environment variables. Share path resolution between Parla and the CLI through
an adapter that takes explicit inputs. Its precedence is nonempty
`DC_ACCOUNTS_PATH`, configured path, then the existing default/legacy fallback.

Separate the persistent store location from the working accounts path returned
after opening it. This accommodates Windows mount locations without making
Parla assume that every backend mounts at the same directory. Parla passes the
returned path to the Delta Chat server as `DC_ACCOUNTS_PATH`.

## Milestone 1 Build a reusable library and define the public API

Implementation complete for the foundation. The shared `safestore_dep` now
exports `libsafestore-1`, its header and VAPI; CLI/GUI consume the public facade,
and Parla links the dependency without enabling protection. See the
[current API and build options](../safestore/README.md#public-vala-api).

Implemented operations are explicit-path construction, async discovery and
classification, empty-store creation, unlock/lock, and optional credential
storage. Other operation capabilities remain unavailable. Copied options and secret handoff are implemented. Milestone 2 adds durable
ownership and managed sessions; detached mutation is now rejected. Full
migration/recovery transactions remain milestone 4. The larger contract below describes that target API.

Validation includes standalone and library-only builds, an installed public
consumer, the original 17 tests, new public API/ZIP tests, and the Parla build.
CI now builds and tests the standalone consumers on all three desktop systems;
macOS/Windows runtime qualification still belongs to milestone 3.


The original standalone build coupled its `safestore-core` target to both
frontends. The completed foundation separates that build as follows:

1. Put the common library target, sources, platform dependencies, and generated
   bindings in `safestore/lib/meson.build`. Both the root Parla build and the
   standalone SafeStore build include this definition. Keep the standalone
   `project()` in its wrapper; do not include it as a nested project.
2. Export one `safestore_dep` carrying the static library, public generated C
   header and VAPI, include paths, and transitive dependencies. Consumers must
   not compile SafeStore sources again or include private headers.
3. Make CLI, experimental GUI, tests, and development-file installation
   optional. A library-only build requires GLib/GIO plus the selected platform
   adapters, not GTK or libadwaita. Update the standalone Makefile accordingly.
4. Scope platform defines and libraries to the appropriate targets. Resolve
   SafeStore's `DARWIN` versus Parla's `MACOS` convention, and avoid treating
   every non-Windows/non-macOS target as Linux. Preserve existing Android and
   Sailfish builds without implying that encryption is supported there.
5. Define and document the public types and operation contracts below. Make
   backend controllers, executable argument builders, mount parsers, path
   policies, and plaintext erasure helpers internal.
6. Adapt the existing CLI and GUI to the public facade. Add a small independent
   Vala consumer that compiles and links using only `safestore_dep`, then link
   that dependency into Parla without enabling automatic storage mutations.

The first change delivers a reusable build, the documented API contract, and
adapters for currently supported operations. Later operations are advertised
as unavailable until implemented; no stub may report success or bypass the
required transaction machinery. Freeze the API only after the first consumer
and lifecycle implementation have exercised it.

Acceptance: standalone library-only and Parla builds work; existing SafeStore
tests pass; the independent consumer needs no private includes; Windows,
Linux, and macOS CI compile the public surface. If development files are
installed, a consumer outside the build tree must also compile using their
VAPI/header and pkg-config metadata.

## Public API contract

The implemented facade is documented in the SafeStore README. The table below
retains the target contracts for the remaining lifecycle and transaction work;
`Session` is now implemented. `ChangePlan`, progress and transaction-result types
remain unpublished until their transaction guarantees can be implemented.

| Type | Contract |
| --- | --- |
| `Store` | Bound to one explicit store location and injected backend/credential configuration. Serializes mutations and owns persistent store metadata. |
| `StoreStatus` | Immutable observed state, protection method, access state, verification result, and pending recovery/cleanup information. |
| `BackendInfo` | Stable method ID, availability reason, supported operations, protection model, platform prerequisites, and format/version support. |
| `Session` | Exclusive lease and verified working accounts path. Reports unexpected access loss. Remains alive while the core uses the store. |
| `ChangePlan` | Source generation, destination method/location, required space, recovery copy, and consequences of enable/migrate/disable/restore. Revalidated before execution. |
| `OperationProgress` | Phase, completed/total bytes when known, and whether cancellation can currently be honored. |
| `OperationResult` | Committed state, verification outcome, retained recovery copies, and remaining cleanup. Distinguishes a successful switch from complete cleanup. |
| `BackupOptions` / `BackupInfo` | Explicit destination, full/recovery-only scope, format version, included accounts, size estimate, source generation, and exclusions. Recovery-only is unavailable until the core supports a qualified export/import path. |
| `SecretValue` | Existing wipeable password container, with documented ownership and lifetime during asynchronous calls. |
| `CredentialStore` | Optional remember, retrieve, and forget operations, keyed by store identity rather than only its current path. |

Expose these operations through typed asynchronous Vala methods:

| Operation | Required behavior |
| --- | --- |
| `list_backends` | Discover capabilities and missing dependencies without changing preferences or storage. |
| `inspect` | Classify absent, ordinary, locked, unlocked, unavailable, or recovery-required storage. Does not create or unlock it. |
| `enable` | Explicitly protect a new/empty location or migrate an existing plaintext store. Existing data always uses the transaction engine. |
| `open` / `unlock` | Return a `Session` only after verifying the expected store and access path. Opening ordinary storage is explicit; failed unlock never falls back to ordinary storage. |
| `lock` | After the caller has stopped file users, flush and close access, verify completion, and release the session lease. Preserve observable failure state if locking fails. |
| `plan_change` | Preflight enable, method change, disable, or restore and describe space requirements and recovery consequences. |
| `change_method` | Execute a verified copy to a new store, then commit the selected method. Changing an ID alone is not migration. |
| `disable` | Migrate into verified ordinary storage while retaining a recoverable encrypted source until cleanup is explicitly handled. |
| `verify` | Return a verification report at a stated depth. Distinguish format detection, successful decryption, file verification, and account/database validation. |
| `backup` / `inspect_backup` / `verify_backup` / `restore` | Create a portable password-encrypted ZIP, inspect its encrypted manifest after unlocking, and report archive versus account-level verification separately. Restore into a fresh destination before replacing the active store. Available independently of working-store protection. |
| `inspect_recovery` / `recover` | Describe an interrupted transaction and resume or restore a validated state without guessing which directory is authoritative. |
| `cleanup_recovery_copy` | Remove an identified obsolete copy only after rechecking that a verified replacement exists. Never silently delete it during ordinary inspection. |

Password changes should use a backend capability where supported, or the same
migration engine otherwise. Forgetting a saved password only removes the
credential-store entry; it does not disable encryption or remove data.

All potentially blocking work is asynchronous and accepts `GLib.Cancellable`.
Signals and callbacks are delivered on the caller's documented main context.
Use structured errors such as wrong password, busy, unsupported format,
missing dependency, insufficient space, integrity failure, access lost, and
recovery required. Parla translates these into user-facing text.

Inspection may report encrypted storage detected but unverified; a filename,
configuration file, or existing drive letter is not proof of valid encryption
or a usable mount. An unavailable selected backend remains selected and
unavailable; it never becomes plaintext implicitly.

Cancellation before commit preserves the source. During a short commit section,
finish or durably record the transition before honoring cancellation. After
commit, return the committed result even if cleanup remains. Document repeated
calls and retries, and reject stale plans or overlapping mutations.

Keep passwords out of logs, arguments, settings, and inherited environment.
For an archive backend that needs credentials again at lock, decide at unlock
whether the session retains a wipeable secret or retrieves it from the OS
credential store. Automatic shutdown must not depend on an unexpected second
password prompt. Session destruction cannot perform asynchronous locking;
Parla must explicitly await closure.

## Milestone 2 Establish reliable state and lifecycle operations

Implemented: per-store versioned metadata; native ownership locks for accounts
and ciphertext; managed `Session` results with access-loss notification and a
retained wipeable credential; conservative legacy import; exact mount-source
and process checks; matching stable CryFS/unmount version checks; shared path
precedence; encrypted ZIP32 format recognition; durable ZIP commit/cleanup
phases. Detached and backend idle unmount operations are rejected. Frontends
read the store's recorded backend instead of global backend preferences.

Regression coverage includes process contention, wrong-password retry, mount
mismatch, working-directory replacement, corrupt metadata, legacy plaintext
conflicts, malformed/unencrypted ZIPs, missing/mismatched tools, and a process
killed after archive commit. That crash test verifies the complete archive
survives and refuses to archive the partly removed plaintext on retry.

Validation on Linux: 28 SafeStore checks, 24 Parla test targets, standalone
CLI/GUI and library-only builds, strict C compilation, and an installed public
API consumer. Windows, macOS, and unsupported-platform Vala branches type-check;
that is not native runtime or power-loss qualification.

Windows mutation fails closed until reliable native mount identity and durable
replacement are qualified in milestone 3. macOS runtime qualification also
remains there. Recovery detection and refusal are implemented; recovery execution
and verified retained-copy migrations remain milestone 4. Parla Settings and
automatic startup/shutdown protection remain milestone 5.

The requirements implemented by this milestone follow.

Replace global selected-backend preferences with versioned metadata per store.
Record a store identifier, active generation, backend/format version, and any
transaction state outside the mounted or extracted account tree. Keep secret
material out of this metadata. Import existing SafeStore layouts conservatively:
multiple candidate vaults, conflicting plaintext, or ambiguous state require
recovery instead of automatic selection.

Acquire exclusive ownership through a stable OS lock outside any directory
that can be unmounted, replaced, or deleted. Keep it for the active session;
Delta Chat's `accounts.lock` is an additional guard, not a replacement. Serialize
operations within the process as well as between Parla and optional tools.

Unify CryFS and ZIP lifecycle handling behind the facade. Verify the expected
mount/source/store identity and process health, monitor unexpected loss, and
preserve error details. Availability checks must cover required tools and
supported versions, including the unmount path. Do not enable backend-controlled
idle unmounting while the account server remains active; idle locking must use
the same coordinated Parla lifecycle.

The following blockers are addressed before exposing mutating Settings actions:

- Parla and SafeStore now use the same environment path precedence.
- ZIP status rejects arbitrary files and unencrypted archives.
- Interrupted ZIP cleanup requires recovery; a partial plaintext tree cannot
  overwrite the complete committed archive on retry.
- CryFS readiness requires the expected source, filesystem identity, and process.
- Windows presence-only checks cannot authorize access; mutations remain disabled.

Acceptance: regression cases for these failures pass; incorrect passwords,
missing tools, conflicting owners, unexpected mounts, and lost access leave
the original data and recovery state intact. Legacy ZipCrypto remains an
explicit compatibility method and is not the recommended protection choice.

## Milestone 2.5 Deliver encrypted backup and restore first

The first implementation is available in **Settings → General → Account Backups**:
full AES-256 ZIP creation, full archive verification, separate-folder restore,
offline account-opening validation and an explicit durable switch retaining the
old folder. SafeStore owns this through the public `Backups` API; Parla drains
pending RPC writes and awaits successful core exit before creating a snapshot.
A native lease also rejects a concurrent core or SafeStore owner. Publication
never replaces an existing backup. The encrypted versioned manifest includes
paths, file sizes and SHA-256 hashes. See the [current API and limits](../safestore/README.md).

Verified locally: Linux archive roundtrips and failure cases, shutdown flushing,
a disposable two-account real-core roundtrip with a draft and attachment, the Settings restore flow before
first account creation, and the application backup/reconnect/restore/switch path.
Windows/macOS implementations and packaging are present; native runtime,
removable-media/power-loss tests, independent archive review and deeper database
integrity validation remain release gates. Owned encrypted-session integration,
previewing backup/account inventory before extraction, and a structured resumable
transaction report remain follow-ups. No-history export remains separate.

The design requirements below remain the target for full milestone qualification;
they must not be read as claims that every remaining item is already delivered.
Keep the original milestone numbers so existing references remain meaningful.

### Settings flow and backup scope

Provide **Settings → Account Protection → Backups** with **Create Encrypted
Backup**, **Check Backup**, and **Restore Backup**. These actions work with an
ordinary accounts folder as well as an unlocked SafeStore session. Restore is
also reachable before the first account is created. A locked encrypted source
must be unlocked through Parla before producing this portable backup.

Create Backup defaults to all accounts under the effective `DC_ACCOUNTS_PATH`.
The UI shows the scope and estimated size, asks for a new backup password and
confirmation, then opens the native Save dialog for a dated `.zip` file anywhere
the user chooses, including a USB drive. The backup password is independent of
the working-store password. No CLI, external archive application, or FUSE runtime
is required. Password loss means the encrypted backup cannot be restored; state
this beside the password fields without implying a recovery code exists.

| Choice | Intended contents and promise |
| --- | --- |
| **Full backup** (default, implement first) | Every account's identity, credentials, keys, configuration, contacts, chats, locally stored messages, attachments and application data needed to restore it. Preserve manager metadata for the account set. Exclude only explicitly identified regenerable Parla caches and runtime lock files; account blobs and database WAL files are not generic cache. Messages or attachments absent locally cannot be promised in the backup. |
| **Account access only — no message history** (follow-up) | A much smaller recovery package with the account identity, credentials/transports, keys and configuration/security state required to resume account access. No local message history, message attachments or regenerable caches. Specify and test what happens to contacts, verified relationships, groups and avatars before offering this choice. Never describe it as a full backup or promise that old history can be downloaded again. |

Keep the second choice unavailable until its restore semantics are proven. It
must not delay the full-backup feature. A cache-size estimate must distinguish
regenerable UI data from irreplaceable account messages and attachments.

### Existing support and format choice

Parla currently exposes device transfer through `provide_backup`, `get_backup_qr`
and `get_backup`; it has no file-export/import UI. The
[core RPC API](https://js.jsonrpc.delta.chat/classes/RawClient.html#exportBackup)
also exposes `export_backup`, `import_backup` and self-key export/import.
The inspected core checkout, commit `7e070efc28f576a187226166434e3efe336f8829`,
exports a full account database and its blobs as TAR. Its backup passphrase
protects the database; blob files are appended separately to the TAR. Self-key
export contains keys, not a complete account configuration. See
[the inspected export implementation](https://github.com/chatmail/core/blob/7e070efc28f576a187226166434e3efe336f8829/src/imex.rs).
No no-history export option was found in these API/implementation paths. Probe
the actual core version/capabilities rather than assuming all installed engines
have the same behavior.

Use a distinct, versioned portable backup format with encryption covering the
whole payload, including attachments and the manifest. Do not reuse SafeStore's
weak ZipCrypto storage backend or rely on the core's database passphrase to
protect the outer archive. Evaluate linked
[libzip](https://libzip.org/) behind the Vala API: it supports Linux, Windows,
macOS and ZIP64, with
[AES-256 ZIP encryption](https://libzip.org/documentation/zip_file_set_encryption/).
Qualify encryption, password handling and decoding on all three platforms;
fail if the required encryption is unavailable, with no plaintext/ZipCrypto
fallback. The backup adapter can be qualified independently of mounted-store
backends and must not accidentally enable their currently disabled Windows
mutations.

Use generic outer entry names, keeping account names, paths and the file
inventory inside the encrypted payload. The manifest records format/core
versions, full versus recovery-only scope, accounts, exclusions, and content
hashes. Total archive size and generic ZIP metadata remain visible. Restoration
must be supported directly by Parla regardless of the OS archive utility's AES
support. Test ZIP64 for large stores and preflight the destination filesystem's
single-file limit (for example a FAT32 USB drive); explain size limitations
before starting rather than silently making an incomplete backup.

### Consistent creation and verifiable restoration

1. Acquire account-store ownership, serialize against migration/lock, and stop
   account writers through an application coordinator. For the initial exact
   accounts-folder backup, gracefully stop and await the RPC process before
   reading SQLite files and sidecars. Keep the source stable for the entire read.
   A later core-assisted live export requires a separately tested consistency
   contract across every account; copying a running database directory is not it.
2. Stream the complete snapshot into encrypted output. Never put a plaintext
   intermediate archive on the USB drive. Any necessary local staging must be
   private, tracked and covered by cleanup/recovery, with its protection state
   visible. Prefer streaming to avoid a second full plaintext copy.
3. Create a fresh temporary encrypted file beside the requested destination.
   Keep existing backups intact. Honor cancellation before publication, handle
   full disks and drive removal, and never change or prune the source accounts.
4. Close and synchronize output using qualified OS/filesystem primitives, then
   reopen it with the password and verify authentication, completeness and
   content hashes before publishing the final filename. Reopen the published
   file as well; do not mark an interrupted or unverified file as a good backup.
5. `Check Backup` verifies the archive without changing the live store. A deeper
   restore test extracts into a private disposable location and checks account
   enumeration, keys and database integrity with core networking disabled.
   Report **archive verified** and **restore tested** as separate results.
6. `Restore Backup` unlocks and inspects the file, shows its date, accounts and
   scope, and restores to a fresh private destination. Reject unsafe paths,
   symlinks, duplicate/colliding entries, excessive extraction sizes, missing
   inventory entries and unsupported versions. Open the restored accounts
   offline for validation; never restore over the active source tree.
7. Offer an explicit switch to the validated restored store, retaining the
   previous store and recording the switch recoverably. Rebind local paths and
   ownership metadata; do not restore stale session locks or an `unlocked`
   journal as a live session. This initial restore/switch path is required with
   backup; milestone 4 will reuse and extend it for encryption migrations.

SafeStore owns archive IO, encryption, manifests, verification and restore
staging through the direct Vala API. Parla owns Settings, file/password dialogs,
quiescing every writer and account-level validation. Backup of plain accounts
must not create metadata claiming that working-store encryption is enabled.
Backup availability is an independent capability; it must not depend on having
a qualified CryFS/FUSE mount implementation installed.

### Qualify the smaller recovery package separately

Prefer an upstream-supported no-history export/import contract. Determine the
minimum required state for each supported account type/core version, including
all configured transports and any credentials that cannot be reconstructed from
keys. Key export alone is insufficient. Do not implement this by deleting SQL
rows, dropping arbitrary blob folders, or invoking normal message deletion on
the user's accounts. Even pruning an isolated copy can leave broken references
or queued deletion/synchronization actions; any fallback needs a versioned,
core-aware transformation and dedicated restore tests.

Use disposable relay and classic-email accounts to demonstrate restoration on a
fresh installation: the identity/key fingerprints remain the same, necessary
authentication is restored or clearly requested, and sending/receiving succeeds.
Test verified contacts and group behavior explicitly. Account for revocable or
expired provider credentials and distinguish local restore verification from
an online connectivity test. Never contact servers while merely inspecting or
test-restoring a user's backup.

Acceptance: full backups of multiple accounts, attachments and database sidecars
restore on Windows, Linux and macOS, independently of the source storage method.
Test wrong passwords, tampering, truncation, full disks, unplugged media, process
death, cancellation, ZIP64, destination limits and existing backup preservation.
The source remains usable after every failed backup. Full backup creation,
verification and restoration ship together; the recovery-only option is enabled
only when its narrower account-recovery promise passes the separate tests.

## Milestone 3 Qualify platform implementations

Keep the public API identical across platforms. Separate encryption format
adapters from mount-runtime and credential-store adapters. Select at least one
qualified protection method for each supported desktop platform before calling
the feature cross-platform. A candidate backend is not supported merely because
its executable exists.

| Platform | Work required |
| --- | --- |
| Linux | Qualify the selected filesystem/backend combination, Secret Service behavior, permissions, locking, and packaged runtimes. Exercise AppImage, distribution packages, and Flatpak separately because mount access differs. |
| Windows | Qualify a backend with its required filesystem runtime; implement reliable volume/mount identity, private ACLs, locking, replacement/durability semantics, and credential storage. Handle drive and directory mount differences through the returned session path. |
| macOS | Qualify Keychain and signing/bundling; investigate Fusetta with a compatible encryption backend and provide a supported option where Fusetta is unavailable. Check permission, synchronization, and lock semantics on real hardware. |

[Fusetta](https://github.com/hsorbo/fusetta) currently describes itself as early,
requires macOS 27 and libfuse 3, and requires the user to enable its extension
once in System Settings. The existing
[CryFS 1.0.3 build](https://github.com/cryfs/cryfs/blob/1.0.3/src/fspp/fuse/CMakeLists.txt)
uses the older `fuse` package. This pairing needs compatibility work. Fusetta's
[synchronization handler](https://github.com/hsorbo/fusetta/blob/main/Extension/FSExtension/FUSEVolume.swift#L436)
also currently discards `fsync` errors; durability qualification must address
that before recommending it for account storage.

The backend choice is an explicit decision in this milestone. Evaluate
[securefs](https://github.com/netheril96/securefs), which documents support for
all three systems, alongside the existing CryFS integration and native macOS
encrypted images. Do not assume securefs is compatible with Fusetta. Require
real account workloads and backup restoration before selecting defaults.

Parla packages should carry or declare their required backend dependencies.
Guide unavoidable OS approval steps from Settings. Users must not need to run
mount commands or another application's GUI before or after a Parla session.
Do not silently substitute legacy ZIP when a filesystem runtime is unavailable.

Acceptance: record a tested OS/backend/runtime matrix and exact supported
versions. Validate SQLite WAL, exclusive access, flush/error propagation, clean
unmount, interrupted writes, and restore on each recommended combination.
Same-format backups should be tested across platforms where supported; method
changes must work between every advertised pair of available methods.

## Milestone 4 Implement migration and recovery transactions

Use one transaction engine for enable, change method, disable, and restore.
Extend the backup restore/switch machinery from milestone 2.5; keep its portable
archive format independent of the active working-store encryption method.

1. Hold exclusive ownership, stop writers, inspect source state, and check
   available space for the destination plus retained recovery data.
2. Write a durable journal identifying the source generation, fresh destination,
   operation phase, and authoritative copy. Revalidate any previously prepared
   plan before starting writes.
3. Copy the complete account store, preserving the source. Include all accounts,
   keys, blobs, manager metadata, and database sidecars needed for recovery.
   Reject or explicitly handle unsupported file types and unsafe paths. Avoid
   plaintext staging outside protected storage for filesystem backends.
4. Verify the file inventory and contents, account metadata, and database
   integrity. SafeStore can verify bytes and backend access; Parla's coordinator
   supplies Delta Chat validation while IO is disabled. Perform validation on a
   suitable copy when opening a database would mutate the candidate. Reopen the
   encrypted destination and test recovery from its backup before source cleanup.
5. Commit the active generation durably and atomically using platform-supported
   primitives. The journal must make crashes around the commit unambiguous.
6. Retain the old generation as a recovery copy and report its protection state.
   Cleanup is a separate recoverable phase. Do not remove old credentials while
   a retained recovery copy still needs them.

On restart, resume from the journal. Never archive a partly deleted working
directory over a verified archive. Once the new generation has accepted writes,
the old copy is stale; restoring it is an explicit recovery decision, not an
automatic rollback. Retained plaintext must be disclosed until cleanup finishes.
Deletion cannot promise removal from SSD history, snapshots, or external backups.

Acceptance: inject failure at every recorded transition, including extraction,
archive replacement, cleanup, metadata commit, and credential persistence.
Cancellation, process death, full disks, failed synchronization, and permission
errors must preserve a known recoverable copy without reporting false success.

## Milestone 5 Integrate Parla Settings and application lifecycle

Add a single application-owned storage controller. It holds the SafeStore
session and routes startup, reconnect, explicit lock, store changes, quit, and
restart through the same state machine. Replace the current force-exit-only
RPC stop with graceful shutdown and awaited process exit. A timeout or busy
file leaves a visible failure/recovery state, not a successful lock.

Before RPC startup, resolve and inspect the store, handle recovery if necessary,
unlock through Parla or the credential store, and verify the session. Start the
RPC server only with the returned accounts path. If RPC startup fails, keep
the UI usable and safely close the acquired session where possible.

Before locking or migration, stop UI writes, all account IO, event consumers,
media/transcription jobs, Webxdc activity, and other file users; await core
exit; then await SafeStore's verified lock. Audit controllable cache and
temporary-file locations and move sensitive ones into protected storage.
External exports and copies need clear scope in the user-facing explanation.

Expose Account Protection in Settings with enable, status/check, lock/unlock,
method change, disable, backup/recovery, and remember-password controls. Retain
the backup actions introduced in milestone 2.5 in this same section. Keep
backend internals under details. Separate protection enabled from currently
unlocked, and distinguish unverified status from a completed integrity check.
Method changes and disabling display their preflight plan and retain the old
setting until the transaction commits.

Make this section available before creating/importing the first account, with
a welcome-screen link to the same section. A locked startup must leave Settings
available without starting the core. Background startup waits for interactive
unlock when credentials are unavailable. Closing/hiding a window follows
Parla's existing background behavior; explicit quit goes through lock handling.

Existing folder switching, reconnect callbacks, preference reset, language
restart, invitation handling, and account import must not bypass the storage
controller. Resetting general preferences must preserve store identity and
protection metadata. A failure must never silently create a fresh plaintext
account manager.

Acceptance: a fresh installation can enable protection in Settings before the
first account; all normal startup/shutdown and protection actions work without
SafeStore's CLI/GUI; all profiles use the same managed store; failed operations
leave understandable, recoverable UI state. Verify keyboard navigation,
screen-reader labels, localization, and focus during progress/error dialogs.

## Milestone 6 Release checks and packaging

Keep fast API/state/transaction tests separate from real mount integration
tests. Use disposable fixtures and injected backends for deterministic failure
coverage; real filesystems are required to establish locking and durability.
Preserve the existing 17 SafeStore test cases, adapting environment-based tests
to explicit API inputs and portable temporary paths.

Exercise multiple accounts, attachments, Unicode/long paths, concurrent
instances, wrong passwords, missing runtimes, busy unmounts, corrupt metadata,
archive leftovers, suspended sessions, forced termination, and full disks.
Run restore tests from backups, including on a second machine. Maintain
separate evidence for ordinary process crashes and controlled power-loss tests.

Ship the static library inside Parla, optional CLI separately, and validated
backend/runtime dependencies through each packaging system. Make sure an update
that cannot open a store preserves it and reports the required compatible
version; never trigger an implicit format upgrade or bypass integrity checks.

Update [SafeStore's README](../safestore/README.md),
[onboarding](onboard.md), and [release readiness](release-readiness.md) as each
milestone lands. Publish API examples for discovery, first-time enable,
unlock/start/stop/lock, method changes, cancellation, and interrupted-operation
recovery. The first implementation change should contain only milestone 1;
subsequent changes add behavior through the same public API.
