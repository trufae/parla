# Onboarding & the Delta Chat engine

Parla talks to a `deltachat-rpc-server` binary (the "engine") over JSON-RPC on
stdio. For Parla to work, that binary must exist and be executable. This document
describes the onboarding contract so that:

- **packagers** know how to ship Parla so it works out of the box, and
- **everyone else** gets a working app from a fresh, unpackaged install with at
  most one click.

See also [`rpc-server.md`](rpc-server.md) for the deeper build/packaging guidance
(Flatpak modules, cargo vendoring, distro dependencies).

## Set up the first profile

Once the engine is ready, Parla shows the profile choices directly on its welcome
screen when no configured profile exists:

- **Create new profile** — choose a display name and a chatmail relay.
- **Import from another device** — link this device to an existing profile using
  the setup code from another device on the same network.
- **Use classic email address** — sign in with an existing email account.
- **Use invitation code** — create a profile from a `dcaccount:` link or QR code.

Cancelling setup leaves these choices available. Removing the last configured
profile returns to the same screen. Once a profile is ready, Parla shows its chat
list; additional profiles can still be added through **Profiles → Add Profile**.

## How Parla finds the engine

In the default `Auto` mode, Parla resolves `deltachat-rpc-server` in this order,
and uses the first match:

1. `PARLA_RPC_SERVER` environment variable, if set and executable.
2. Next to the Parla executable, or under the same install prefix:
   - `<prefix>/libexec/parla/deltachat-rpc-server`
   - `<prefix>/lib/parla/deltachat-rpc-server`
   - `/app/bin/deltachat-rpc-server` and `/app/libexec/parla/deltachat-rpc-server`
     (Flatpak)
3. `deltachat-rpc-server` on `PATH`.
4. `~/.local/bin/deltachat-rpc-server` or `~/.cargo/bin/deltachat-rpc-server`.
5. **Parla-managed fallback:** `~/.local/share/parla/bin/deltachat-rpc-server`
   — the copy Parla downloads for itself (see below).

`Custom` mode is an explicit user choice configured in Settings and bypasses
this list.

## For packagers: make Parla self-contained

A proper package should provide the engine through any location **above** the
managed fallback (steps 1–4). When it does, Parla never touches the network and
the download UI never appears. Pick whichever fits your distro:

- **Depend on a packaged `deltachat-rpc-server`** that lands on `PATH`. Known
  examples: Arch `extra/deltachat-rpc-server`, FreeBSD `net/deltachat-rpc-server`.
- **Bundle it in a Parla-owned path** if you keep helpers out of `PATH`:
  `/usr/libexec/parla/deltachat-rpc-server` or `/usr/lib/parla/deltachat-rpc-server`.
- **Flatpak:** install it as `/app/bin/deltachat-rpc-server` (or
  `/app/libexec/parla/deltachat-rpc-server`). Let Flatpak update the engine with
  the app — do not rely on Parla's runtime download inside a sandbox.
- **Environment override:** set `PARLA_RPC_SERVER=/path/to/deltachat-rpc-server`
  (useful for testing or unusual layouts).

Because any of these wins over the managed fallback, a packaged Parla is fully
functional on first launch with zero clicks and never self-downloads.

## For unpackaged installs: one-click setup

When none of steps 1–4 find a binary (typical for a build-from-source or a bare
download), Parla shows a welcome screen with a single **Download & start** button.
One click:

1. Detects the host architecture.
2. Resolves the latest `chatmail/core` release.
3. Downloads the matching binary into `~/.local/share/parla/bin/`, marks it
   executable, and starts the server — no terminal, no manual `chmod`, no Settings
   spelunking.

The same install/update actions are available in **Settings → Advanced → Chatmail Core**:

- **Check for Updates**, then **Install** — download the latest engine into the managed directory.
- **Check for Updates** — compare the running engine against the latest release.
- **Check for Updates on Startup** — when enabled (default), Parla quietly
  checks for a newer release at launch *only* when it is running its own managed
  binary, and shows a non-blocking "Update available" notification with an action.
  It never swaps the binary silently. Disable this to suppress all startup update
  network calls.

## Architecture → release asset

Parla downloads the upstream Linux release asset named
`deltachat-rpc-server-<arch>-linux` (raw, uncompressed ELF binaries):

| Host arch | Asset                              |
|-----------|------------------------------------|
| `x86_64`  | `deltachat-rpc-server-x86_64-linux`  |
| `aarch64` | `deltachat-rpc-server-aarch64-linux` |
| `armv7l`  | `deltachat-rpc-server-armv7l-linux`  |
| `armv6l`  | `deltachat-rpc-server-armv6l-linux`  |
| `i686`    | `deltachat-rpc-server-i686-linux`    |

If no prebuilt asset matches the host architecture, Parla skips the one-click
download and points the user at manual installation
(see [`rpc-server.md`](rpc-server.md)).
