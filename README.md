<p align="center">
  <img src="delta-gnome.png" width="96" alt="Parla logo"/>
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
- **Optional Markdown rendering** — **bold**, *italic*, ~~strikethrough~~, `inline code`, fenced code blocks, headings, and auto-linkified URLs.
- **In-chat search** (Ctrl+F) with real-time filtering and highlight.
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

- **Auto-discovery** of existing Delta Chat accounts from Delta Chat Desktop, Flatpak and Snap installations — no re-login needed.
- **Auto-discovery of `deltachat-rpc-server`** from `$PATH`, `~/.local/bin`, pip user installs, virtualenvs, and Flatpak runtimes.
- **Multi-account** switching from the settings dialog.
- **My Profile** dialog to edit display name, status and avatar.
- **End-to-end encryption** via Autocrypt, handled by the Delta Chat core.

### Settings

- Double-click action on a message: Reply / React ❤️ / React 👍 / Open profile / None.
- Toggle Markdown rendering.
- Toggle Shift+Enter vs Enter to send.
- Toggle desktop notifications for incoming messages when the window is unfocused.

### Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New chat | `Ctrl+N` |
| New group | `Ctrl+G` |
| Quick chat switcher | `Ctrl+K` |
| Search in conversation | `Ctrl+F` |
| Focus compose entry | `Ctrl+L` |
| Refresh | `Ctrl+R` |
| Settings | `Ctrl+,` |
| Close window | `Ctrl+W` |
| Quit | `Ctrl+Q` |
| Close dialog / viewer / search | `Esc` |

## Build

```sh
# Install dependencies (Ubuntu)
sudo apt install valac meson libgtk-4-dev libadwaita-1-dev libjson-glib-dev

# Install the RPC backend
pip install deltachat-rpc-server

# Build & run
make ; make run
```

<details>
<summary>Other distros</summary>

**Fedora:** `sudo dnf install vala meson gtk4-devel libadwaita-devel json-glib-devel`

**Arch:** `sudo pacman -S vala meson gtk4 libadwaita json-glib`

**FlatPak:** `flatpak install io.github.trufae.Parla.flatpak`
</details>

## Contributing

Early-stage project &mdash; contributions welcome! Open areas: Flatpak packaging, theming, richer notifications, accessibility polish, and more message types.

## License

GPLv3 &mdash; see [LICENSE](LICENSE).

Built on [Delta Chat](https://delta.chat), [GNOME](https://gnome.org) and [libadwaita](https://gnome.pages.gitlab.gnome.org/libadwaita/).
