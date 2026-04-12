<p align="center">
  <img src="delta-gnome.png" width="96" alt="Delta Chat GNOME logo"/>
</p>

<h1 align="center">Delta Chat GNOME</h1>

<p align="center">
  Native GNOME client for <a href="https://delta.chat">Delta Chat</a> &mdash; chat over email, decentralized and encrypted.
</p>

<p align="center">
  <a href="https://github.com/trufae/deltachat-gnome/actions/workflows/build.yml"><img alt="CI" src="https://github.com/trufae/deltachat-gnome/actions/workflows/build.yml/badge.svg"/></a>
  <a href="https://github.com/trufae/deltachat-gnome/releases/latest"><img alt="Flatpak" src="https://img.shields.io/badge/Flatpak-download-4a86cf?style=flat-square&logo=flatpak&logoColor=white"/></a>
  <img alt="License" src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square"/>
  <img alt="GTK4 + libadwaita" src="https://img.shields.io/badge/GTK4-libadwaita-4a86cf?style=flat-square&logo=gnome&logoColor=white"/>
  <img alt="Vala" src="https://img.shields.io/badge/lang-Vala-a56de2?style=flat-square"/>
</p>

---

Lightweight **Vala** + **GTK4** + **libadwaita** desktop client that talks to [deltachat-rpc-server](https://github.com/deltachat/deltachat-core-rust) over JSON-RPC. Follows GNOME HIG, works on desktop and mobile.

**Highlights:** adaptive split-view layout, message bubbles, file attachments with image previews, chat search, real-time delivery, end-to-end encryption via Autocrypt, and auto-discovery of existing Delta Chat accounts.

## Build

```sh
# Install dependencies (Debian/Ubuntu)
sudo apt install valac meson libgtk-4-dev libadwaita-1-dev libjson-glib-dev

# Install the RPC backend
pip install deltachat-rpc-server

# Build & run
meson setup builddir && meson compile -C builddir
./builddir/deltachat-gnome
```

<details>
<summary>Other distros</summary>

**Fedora:** `sudo dnf install vala meson gtk4-devel libadwaita-devel json-glib-devel`

**Arch:** `sudo pacman -S vala meson gtk4 libadwaita json-glib`
</details>

The app auto-discovers `deltachat-rpc-server` from `$PATH`, `~/.local/bin`, virtualenvs, or Flatpak, and picks up existing accounts from Delta Chat Desktop or OpenClaw configurations.

## Contributing

Early-stage project &mdash; contributions welcome! Open areas: group chat creation, settings UI, notifications, Flatpak packaging, keyboard shortcuts.

## License

GPLv3 &mdash; see [LICENSE](LICENSE).

Built on [Delta Chat](https://delta.chat), [GNOME](https://gnome.org) and [libadwaita](https://gnome.pages.gitlab.gnome.org/libadwaita/).
