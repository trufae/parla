# SafeStore

SafeStore manages encrypted-at-rest storage holding the Delta Chat accounts.
CryFS is the recommended backend; an explicitly weaker ZIP backend is
available for systems where a mountable encrypted filesystem is impractical.
SafeStore works only on the `DC_ACCOUNTS_PATH` location, so the paths are fully
predictable and shared with Parla:

1. `$DC_ACCOUNTS_PATH`, when set and non-empty;
2. otherwise the `accounts_path` key in Parla's `settings.ini`;
3. otherwise Parla's default accounts directory (the same fallback chain
   Parla uses when launching `deltachat-rpc-server`).

The resolved accounts path is exactly what the JSON-RPC server reads. CryFS
mounts its decrypted view there and stores ciphertext in `<accounts>.vault`.
ZIP extracts plaintext there and stores its archive in `<accounts>.zip`.
Neither location is configurable; `safestore status` prints the selected
backend, paths, availability, and state.

It is split into three parts:

- `lib/` — a GTK-free core library (`libsafestore-core`) with the vault,
  path-policy, mount-detection, and keyring logic. This is the intended
  integration point for Parla; it is currently built and run separately.
- `cli/` — the `safestore` command-line tool for scripted and automated use.
- `gui/` — the `safestore-gui` GTK4/libadwaita application.

## What it does

- Lists the supported backends, whether their required programs are available,
  their storage paths, operating model, and security limitations.
- Saves an explicit backend selection (`cryfs` or `zip`); CryFS remains the
  default and recommended choice.
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
- Supports CryFS idle unmounting.
- Mounts the decrypted view with `noexec` by default; Vala callers can opt in
  with `allow_executable_files`, and the CLI exposes `--allow-exec`.
- Rejects nested vault/mount paths and non-empty mount directories.
- On Unix, requires the encrypted vault, plaintext mountpoint, and CryFS
  integrity-state directory to belong to the invoking user, rejects symlinks,
  and enforces mode `0700` before mounting.
- Stores only non-secret backend/tool preferences and the idle-lock choice;
  vault and accounts locations are always derived from the accounts path.
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

Build requirements: Vala 0.56+, Meson/Ninja, GLib/GIO; GTK 4 and
libadwaita 1.5+ for the GUI; libsecret (optional) for the Linux keyring.

Runtime requirements:

- **CryFS stable 1.x**, preferably 1.0.3, including `cryfs` and
  `cryfs-unmount`. Distribution packages such as Ubuntu's 0.11.4 work for
  experimentation (same CLI, XChaCha20 since 0.11.0), but releases should
  pin and verify an exact 1.x version. CryFS 2.0 is an alpha with a
  different CLI story and must not be used.
- Linux: FUSE.
- macOS: macFUSE plus permission to load its system extension. Homebrew's
  core `cryfs` formula is Linux-only; use the
  [official CryFS tap](https://github.com/cryfs/homebrew-tap)
  (`brew install --cask macfuse && brew install cryfs/tap/cryfs`) or
  MacPorts (`sudo port install cryfs`).
- Windows (experimental upstream): the CryFS 1.x Windows package, Dokany
  2.2.0.1000, and the MSVC 2022 runtime. Stable CryFS 1.x mounts on an
  unused drive letter such as `G:`, not an arbitrary directory.
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
make                 # build
make test            # build and run tests
make clean           # clean compiled outputs
make install         # install under PREFIX, default /usr/local
make install PREFIX="$HOME/.local"
```

On macOS the Makefile reuses Parla's Homebrew GTK environment helper. On
Windows, build from an MSYS2 UCRT64 shell.

A nonstandard CryFS installation can be selected with
`SAFESTORE_CRYFS=/absolute/path/to/cryfs` or `--binary`; the same directory
must also contain `cryfs-unmount`.

## Command line

The `safestore` tool covers the whole lifecycle without the GUI. Commands
take no path arguments — everything follows the accounts path:

```sh
safestore backends       # list backends, availability, and security model
safestore status         # resolved paths + vault and mount state
safestore check          # encrypted vault, decrypted mount, or neither?
safestore create         # new vault, prompts for a password twice
safestore mount          # unlock; prompts without echoing
safestore --allow-exec mount   # permit direct execution inside the mount
safestore umount         # lock again
safestore --backend zip create
safestore --backend zip --shred umount
DC_ACCOUNTS_PATH=/elsewhere/accounts safestore mount   # alternate store
```

Exit codes are script-friendly: `0` yes/success, `1` no/failure, `2` usage
error; `check` additionally returns `3` when the accounts path is currently
decrypted/extracted and usable.

Passwords are never accepted as command-line arguments. The sources are:

- an interactive prompt with terminal echo disabled (the default),
- `--password-stdin` for scripts and other programs,
- `--keyring` to fetch the password from the OS secret store. On the first
  interactive unlock with `--keyring`, the password is saved there after a
  successful mount; `safestore forget` removes it again. Combined with the
  keyring, `safestore mount` needs no interaction at all, which is the
  intended path toward automatic unlocking from Parla.

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

Unlike the GUI, the CLI lets CryFS daemonize itself, so mounts survive the CLI
exiting. ZIP has no mount process: while unlocked, both its prior encrypted
snapshot and a full plaintext accounts tree exist. ZIP `umount` rewrites the
archive and therefore requests the password again.

## Library backend API

The GTK-free library exposes backend choice rather than requiring callers to
know tool-specific paths:

- `Backends.list(settings)` returns a `BackendInfo` for every backend, including
  its stable ID, availability/status, protection model, operating model, and
  derived vault path.
- `Backends.select(settings, kind)` changes the explicit selection;
  `Settings.save()` persists it.
- `EncryptedStore.info/exists/unlocked/create/unlock/lock` provide the
  backend-neutral one-shot lifecycle used by the CLI and available to Parla.
- `SecretValue` provides a short-lived, wipeable handoff container for GUI and
  CLI frontends; it does not itself prompt the user.
- `PlaintextEraser.inspect(settings)` reports whether overwrite removal is
  available and its limitations.

`CryfsController` remains available for GUI integrations that need to monitor
the foreground FUSE process and receive detailed state changes.

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

Non-secret preferences (selected backend, tool paths, overwrite-removal
choice, and CryFS idle-lock minutes; vault and accounts locations are derived,
never stored) go to
`$XDG_CONFIG_HOME/safestore/settings.ini` (or the platform's GLib
equivalent). CryFS rollback/integrity state is kept under
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
Extraction also uses private staging and rejects symbolic links and unexpected
top-level entries.

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
- A single-instance owner/lock so two Parla instances cannot race for the
  vault, plus the edge cases: RPC startup failure after mount, mount
  disappearing while running, busy files at shutdown, short shutdown grace
  periods.
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
