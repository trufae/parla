# Delta Chat RPC Server Packaging

Parla talks to `deltachat-rpc-server` over JSON-RPC on stdin/stdout. The
server is provided by the Chatmail/Delta Chat core project:

- Source: https://github.com/chatmail/core/tree/main/deltachat-rpc-server
- Releases: https://github.com/chatmail/core/releases
- PyPI binary wheels: https://pypi.org/project/deltachat-rpc-server/
- JSON-RPC install docs: https://py.delta.chat/jsonrpc/install.html

The upstream install options are:

- Install the Python wheel with `pip install deltachat-rpc-server`.
- Build from source with
  `cargo install --git https://github.com/chatmail/core/ deltachat-rpc-server`.
- Download a release asset such as `deltachat-rpc-server-x86_64-linux`,
  rename it to `deltachat-rpc-server`, make it executable, and put it in
  `PATH`.

For the end-to-end onboarding contract (one-click setup, the Parla-managed
download fallback, and how to package Parla so it never self-downloads), see
[`onboard.md`](onboard.md).

## Updating the packaged core

From the repository root, use the Python 3-backed helper to query or update
the Android, Flatpak and Sailfish OS pins together:

```sh
./version-chatmail.sh        # show current pins and latest stable release
./version-chatmail.sh latest # update to the latest stable release
./version-chatmail.sh 2.64.0 # update to a specific release
```

The updater resolves Android's source commit from the release tag and updates
the Flatpak URLs, Sailfish version (including the RPM spec), and all Linux
binary checksums from GitHub's published SHA-256 digests. It validates the
release assets and file patterns before writing any changes. Review the diff
and verify an Android arm64 build before releasing. Historical audit references
in `CORE.md` retain the version that was audited.

## Runtime Resolution

Parla does not scan Delta Chat Desktop internals. `Auto` mode uses, in order:

- `PARLA_RPC_SERVER`, if set and executable.
- A server installed next to Parla or under the same prefix, for example
  `/app/bin/deltachat-rpc-server`, `/usr/libexec/parla/deltachat-rpc-server`,
  or `/usr/lib/parla/deltachat-rpc-server`.
- `deltachat-rpc-server` from `PATH`.
- User installs in `~/.local/bin` or `~/.cargo/bin`.

Parla stores accounts in its own XDG data directory and does not reuse Delta Chat
Desktop's account store.

## Startup update checks

Parla normally checks for new Parla releases on startup and checks for new
Chatmail Core releases when running its own managed Core binary. Both follow
**Settings → Advanced → Chatmail Core → Check for Updates on Startup**.

Flatpak, Snap and distro maintainers can disable both checks
when updates are delivered by their package manager:

```sh
meson setup builddir -Dupdate_checks=false
```

The Meson option defaults to `true`. Setting it to `false` suppresses both
startup checks even if an existing profile has the startup preference enabled.
The Flatpak manifest disables it.

Launchers and package wrappers can override both checks with one environment
variable, without changing the saved preference:

```sh
PARLA_CHECK_UPDATES=0 parla # disable both startup checks
PARLA_CHECK_UPDATES=1 parla # enable both startup checks
```

`true`/`false`, `yes`/`no`, and `on`/`off` are also accepted, ignoring case and
surrounding whitespace. An unset, empty or unrecognized value uses the normal
build policy and saved preference. A recognized value overrides the Meson
option and the saved startup preference for that process. The Settings switch
shows the effective state and is unavailable while overridden or when the
build disables checks.

Core checks still require a Parla-managed binary. A fixed `-Drpc_server_path`
or Android build always disables automatic Core checks and updates, even with
`PARLA_CHECK_UPDATES=1`. These controls only affect automatic startup checks;
manual checks and first-run Core installation retain their existing behavior.
Use `-Drpc_server_path=/path/to/deltachat-rpc-server` as well when the package
must pin the engine and disable its installer.

## Flatpak

The current manifest installs a pinned upstream binary release into `/app/bin`.
That makes the Flatpak self-contained and matches Parla's default resolver.

For Flathub or distro-grade reproducibility, the preferred long-term package is
to build `deltachat-rpc-server` from `chatmail/core` source as a separate module:

- Use `org.freedesktop.Sdk.Extension.rust-stable` or the Rust toolchain
  available in the chosen SDK.
- Pin the `chatmail/core` tag or commit.
- Generate and commit Cargo sources with `flatpak-cargo-generator`, or otherwise
  vendor dependencies so the Flatpak build does not need network access.
- Install only the final executable as `/app/bin/deltachat-rpc-server` or
  `/app/libexec/parla/deltachat-rpc-server`.

Avoid downloading executable updates at application runtime. Let Flatpak update
the bundled server together with Parla.

## Distro Packages

Distribution packages should either depend on a packaged
`deltachat-rpc-server` or ship the binary in a Parla-owned path:

- Preferred package dependency: `deltachat-rpc-server`.
- If the distro keeps helper executables out of `PATH`, install it as
  `/usr/libexec/parla/deltachat-rpc-server` or
  `/usr/lib/parla/deltachat-rpc-server`.
- Do not depend on Delta Chat Desktop just to obtain the JSON-RPC server.

Known packaged examples include Arch Linux `extra/deltachat-rpc-server` and the
FreeBSD `net/deltachat-rpc-server` port.

## Android

Android APKs bundle an arm64 Android/Bionic core in the APK native library
directory. Linux arm64 binaries are not interchangeable with Android binaries.
The in-app downloader and custom-binary selector are disabled on Android:
Android 10+ cannot execute downloads from writable app storage. Update the APK
to update its core. See [Android packaging](../dist/android/README.md).
