<p align="center">
  <img src="parla.png" width="96" alt="Parla logo"/>
</p>

<h1 align="center">Parla</h1>

<p align="center">
  A <a href="https://delta.chat">Delta Chat</a> client for GNOME &mdash; chat over email, decentralized and encrypted.
</p>

<p align="center">
  <a href="https://github.com/trufae/parla/actions/workflows/build.yml"><img alt="CI" src="https://github.com/trufae/parla/actions/workflows/build.yml/badge.svg"/></a>
  <a href="https://github.com/trufae/parla/releases/latest"><img alt="Flatpak" src="https://img.shields.io/badge/Flatpak-download-4a86cf?style=flat-square&logo=flatpak&logoColor=white"/></a>
  <img alt="License" src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square"/>
  <img alt="GTK4 + libadwaita" src="https://img.shields.io/badge/GTK4-libadwaita-4a86cf?style=flat-square&logo=gnome&logoColor=white"/>
  <img alt="Vala" src="https://img.shields.io/badge/lang-Vala-a56de2?style=flat-square"/>
</p>

---

Lightweight **Vala** + **GTK4** + **libadwaita** desktop client that talks to [deltachat-rpc-server](https://github.com/deltachat/deltachat-core-rust) over JSON-RPC. Follows GNOME HIG, works on desktop and mobile form factors.

## Features

### Messaging

- **Rich compose bar** — multi-line text, file attachments via picker or drag-and-drop, paste images or files straight from the clipboard.
- **Reply, edit, delete, forward** — full message actions via right-click; delete-for-self or delete-for-everyone on your own messages.
- **Emoji reactions** — quick-pick 👍 ❤️ 😂 😮 😢 👎 shown as badges on the message.
- **Pinned messages** — pin any message in a chat; a pinned-messages bar at the top of the conversation lets you jump back to them.
- **Reply previews** — quoted sender and text preview (capped at 3 lines) above the compose entry and inside bubbles.
- **Inline image previews** with a full-screen viewer (click to open, right-click to save, Escape to close).
- **Optional Markdown rendering** — **bold**, *italic*, ~~strikethrough~~, `inline code`, fenced code blocks, headings, tables, and auto-linkified URLs.
- **In-chat search** (Ctrl+F, Command+F on macOS) with real-time filtering and highlight.
- **Save attachments** to disk from the message context menu.

### Chats

- **Adaptive split-view** sidebar + conversation, collapsing to a single pane on narrow windows with a back button.
- **Chat list** with avatars, unread dots and badges, last-message preview, smart timestamps (time / weekday / date), pinned indicator and muted styling.
- **Pin, mute, delete** chats from the sidebar context menu; view chat info (members, avatar, type) in a dedicated dialog.
- **Contact requests** surfaced with their own badge.
- **Sidebar search** to filter chats by name.
- **Quick switcher** fuzzy chat search, Enter to open the top match.
- **New 1:1 chat** via contact picker, and **new group** with name, avatar and member selection.

### Accounts & profile

- **Private Parla account store** in Parla's XDG data directory.
- **Auto-discovery of standalone `deltachat-rpc-server`** from the Parla bundle, distro packages, `$PATH`, `~/.local/bin`, and `~/.cargo/bin`.
- **Multi-account** switching from the settings dialog.
- **My Profile** dialog to edit display name, status and avatar.
- **End-to-end encryption** via Autocrypt, handled by the Delta Chat core.

### Settings

- Double-click action on a message: Reply / React ❤️ / React 👍 / Open profile / None.
- Choose whether Markdown is rendered, stripped, or shown as-is.
- Toggle Shift+Enter vs Enter to send.
- Toggle desktop notifications for incoming messages when the window is unfocused.
- Choose the JSON-RPC server source: Parla/system auto-discovery or a custom binary.

### Keyboard shortcuts

| Action | Other platforms | macOS |
| --- | --- | --- |
| New chat | `Ctrl+N` | `Command+N` |
| New group | `Ctrl+G` | `Command+G` |
| New channel | `Ctrl+Shift+G` | `Command+Shift+G` |
| Quick chat switcher | `Ctrl+K` | `Command+K` |
| Account menu | `Ctrl+Shift+A` | `Command+Shift+A` |
| Next conversation | `Ctrl+Page Down` | `Command+Page Down` |
| Previous conversation | `Ctrl+Page Up` | `Command+Page Up` |
| Search in conversation | `Ctrl+F` | `Command+F` |
| Open chat info | `Ctrl+I` | `Command+I` |
| Focus compose entry | `Esc` | `Esc` |
| Refresh | `Ctrl+R` | `Command+R` |
| Toggle sidebar | `Ctrl+S` | `Command+S` |
| Compact sidebar | `Ctrl+Shift+S` | `Command+Shift+S` |
| Settings | `Ctrl+,` | `Command+,` |
| Close window | `Ctrl+W` | `Command+W` |
| Quit | `Ctrl+Q` | `Command+Q` |
| Close dialog / viewer / search | `Esc` | `Esc` |

## Build

```sh
# Install dependencies (Ubuntu)
sudo apt install valac meson libgtk-4-dev libadwaita-1-dev libjson-glib-dev

# Install the RPC backend for source builds
pip install deltachat-rpc-server
# Or: cargo install --git https://github.com/chatmail/core/ deltachat-rpc-server

# Build & run
make run
```

<details>
<summary>Other distros</summary>

**Fedora:** `sudo dnf install vala meson gtk4-devel libadwaita-devel json-glib-devel`

**Arch:** `sudo pacman -S vala meson gtk4 libadwaita json-glib`

**Flatpak:** `flatpak install io.github.trufae.Parla.flatpak`

**AppImage:** `make appimage`
</details>

<details>
<summary>macOS</summary>

```sh
brew install meson ninja vala pkgconf gtk4 libadwaita json-glib librsvg webp-pixbuf-loader glib-networking adwaita-icon-theme

# Install the RPC backend for source builds.
pip install deltachat-rpc-server
# Or: cargo install --git https://github.com/chatmail/core/ deltachat-rpc-server

make run   # builds and runs dist/macos/Parla.app
make app   # creates dist/macos/Parla.app
make macos # creates Parla-<version>-<arch>.zip
```

`make app` bundles Homebrew GTK/libadwaita libraries. The RPC backend is not
bundled by default; set `PARLA_BUNDLE_RPC_SERVER=/absolute/path/to/deltachat-rpc-server`
only for a local bundle that should include a specific backend binary.
</details>

<details>
<summary>Windows</summary>

Build inside an [MSYS2](https://www.msys2.org) UCRT64 shell:

```sh
pacman -S zip mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-meson \
  mingw-w64-ucrt-x86_64-vala mingw-w64-ucrt-x86_64-gtk4 \
  mingw-w64-ucrt-x86_64-libadwaita mingw-w64-ucrt-x86_64-json-glib \
  mingw-w64-ucrt-x86_64-glib-networking mingw-w64-ucrt-x86_64-adwaita-icon-theme \
  mingw-w64-ucrt-x86_64-librsvg mingw-w64-ucrt-x86_64-webp-pixbuf-loader \
  mingw-w64-ucrt-x86_64-ntldd

bash scripts/windows/bundle.sh   # creates dist/windows/parla-<version>-windows-<arch>.zip
```

The script builds with meson and bundles the GTK/libadwaita runtime
(DLLs, GSettings schemas, icon themes, pixbuf loaders, TLS module) into
a self-contained folder, then zips it. CI publishes this zip for every
release.
</details>

See [docs/rpc-server.md](docs/rpc-server.md) for how Parla finds the JSON-RPC
server and how to package it for Flatpak or distro packages.

## Contributing

Early-stage project &mdash; contributions welcome! Open areas: Flatpak packaging, theming, richer notifications, accessibility polish, and more message types.

## License

GPLv3 &mdash; see [LICENSE](LICENSE).

Built on [Delta Chat](https://delta.chat), [GNOME](https://gnome.org) and [libadwaita](https://gnome.pages.gitlab.gnome.org/libadwaita/).
