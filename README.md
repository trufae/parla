<p align="center">
  <img src="https://delta.chat/assets/logos/delta-chat.svg" width="80" alt="Delta Chat logo"/>
</p>

<h1 align="center">Delta Chat GNOME</h1>

<p align="center">
  A native GNOME client for <a href="https://delta.chat">Delta Chat</a> &mdash; chat over email, decentralized and end-to-end encrypted.
</p>

<p align="center">
  <img alt="GTK4" src="https://img.shields.io/badge/GTK4-4.0+-4a86cf?style=flat-square&logo=gnome&logoColor=white"/>
  <img alt="Vala" src="https://img.shields.io/badge/Vala-0.56+-a56de2?style=flat-square"/>
  <img alt="libadwaita" src="https://img.shields.io/badge/libadwaita-1.0+-e66100?style=flat-square&logo=gnome&logoColor=white"/>
  <img alt="License" src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square"/>
  <img alt="Version" src="https://img.shields.io/badge/version-0.1.0-green?style=flat-square"/>
</p>

---

## Overview

**deltachat-gnome** is a lightweight, native GNOME desktop client for the Delta Chat messaging network. It uses [deltachat-rpc-server](https://github.com/nickvergessen/deltachat-core-rust) as its backend, communicating over JSON-RPC via stdio, and renders a modern libadwaita interface with chat bubbles, file attachments, image previews, and real-time message delivery.

Built entirely in **Vala** with **GTK4** and **libadwaita**, it follows GNOME HIG conventions and feels right at home on a GNOME desktop.

## Features

- **Adaptive split-view layout** &mdash; sidebar chat list + message pane, responsive on mobile and desktop
- **Message bubbles** &mdash; incoming/outgoing styling with sender names, timestamps, and new-message highlights
- **File attachments** &mdash; send and receive files with inline image previews for photos
- **Chat search** &mdash; filter your chat list in real time
- **New chat creation** &mdash; start a conversation by entering an email address
- **Chat info dialog** &mdash; view members, encryption status, and avatars
- **Right-click context menus** &mdash; chat info & delete actions
- **Real-time updates** &mdash; incoming messages appear instantly via long-polling
- **Auto-discovery** &mdash; finds existing Delta Chat accounts from Desktop (Flatpak/native/Snap) and OpenClaw configurations
- **End-to-end encryption** &mdash; powered by Delta Chat's Autocrypt implementation

## Screenshots

> *Coming soon*

## Dependencies

| Package | Minimum version |
|---------|----------------|
| GLib | 2.0 |
| GIO | 2.0 |
| GTK4 | 4.0 |
| libadwaita | 1.0 |
| json-glib | 1.0 |
| Vala compiler (`valac`) | 0.56 |
| Meson | 0.59 |
| deltachat-rpc-server | latest |

### Installing dependencies

**Fedora:**
```sh
sudo dnf install vala meson gtk4-devel libadwaita-devel json-glib-devel
```

**Debian / Ubuntu:**
```sh
sudo apt install valac meson libgtk-4-dev libadwaita-1-dev libjson-glib-dev
```

**Arch Linux:**
```sh
sudo pacman -S vala meson gtk4 libadwaita json-glib
```

### Installing deltachat-rpc-server

```sh
pip install deltachat-rpc-server
```

Or grab a binary from the [Delta Chat releases](https://github.com/nickvergessen/deltachat-core-rust/releases) and place it in your `$PATH`.

## Building

```sh
# Quick build
./build.sh

# Or manually with Meson
meson setup builddir
meson compile -C builddir
```

## Running

```sh
./builddir/deltachat-gnome
```

The application will automatically:

1. Locate `deltachat-rpc-server` in `$PATH`, `~/.local/bin`, virtualenvs, or Flatpak installations
2. Discover existing Delta Chat accounts from Desktop or OpenClaw configurations
3. Connect and start syncing messages

### Configuration

To configure a new account, create a `deltachat-config.json`:

```json
{
  "accounts": [
    {
      "email": "you@example.com",
      "password": "your-app-password"
    }
  ]
}
```

Searched locations (in order):
- `$OPENCLAW_DELTACHAT_CONFIG`
- `$DELTACHAT_CONFIG`
- `~/.openclaw/extensions/deltachat/deltachat-config.json`
- `./deltachat-config.json`

## Architecture

```
src/
 ├── main.vala              # Entry point
 ├── application.vala       # Adw.Application + CSS theming
 ├── window.vala            # Main window with split-view layout
 ├── rpc_client.vala        # JSON-RPC client for deltachat-rpc-server
 ├── account_finder.vala    # Auto-discovers accounts & RPC server binary
 ├── models.vala            # Data models (Account, ChatEntry, Message)
 ├── chat_row.vala          # Chat list row widget
 ├── message_row.vala       # Message bubble widget
 ├── compose_bar.vala       # Text input + file attach + send button
 └── chat_info_dialog.vala  # Chat details dialog (members, encryption)
```

The app spawns `deltachat-rpc-server` as a subprocess and communicates via **JSON-RPC 2.0** over stdin/stdout. All network operations are asynchronous using GLib's async/yield pattern.

## Contributing

Contributions are welcome! This is an early-stage project (v0.1.0) &mdash; there's plenty to do:

- [ ] Group chat creation UI
- [ ] Settings / account management dialog
- [ ] Desktop notifications
- [ ] Message quoting & reactions
- [ ] Flatpak packaging
- [ ] Keyboard shortcuts
- [ ] Dark/light theme toggle
- [ ] Contact list management

## License

This project is free software. See the [LICENSE](LICENSE) file for details.

## Credits

- [Delta Chat](https://delta.chat) &mdash; the decentralized messaging protocol
- [GNOME](https://gnome.org) &mdash; the desktop environment and platform
- [libadwaita](https://gnome.pages.gitlab.gnome.org/libadwaita/) &mdash; adaptive GNOME widgets
