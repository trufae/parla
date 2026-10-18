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
