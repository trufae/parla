# Screen reader support

How Parla is exposed to screen readers on each platform, and what the
Windows/macOS bundles must ship for that to work at all.

## How GTK accessibility works per platform

GTK 4 keeps an internal accessibility tree (roles, labels, states) and
exposes it through a platform backend chosen at runtime from the
backends compiled into GTK:

- **Linux**: the AT-SPI backend, always compiled in, talks to the
  AT-SPI bus over D-Bus. Orca works with stock distro GTK; nothing
  special is needed in our packages.
- **Windows**: screen readers (NVDA, JAWS, Narrator) consume
  **UI Automation**. GTK only speaks UI Automation through its
  **AccessKit** backend (GTK >= 4.18, build option
  `-Daccesskit=enabled`, implemented by the `accesskit-c` library).
  A GTK built without it exposes *nothing*: the window is an empty
  rectangle to a screen reader, no matter what the app does.
- **macOS**: same situation — VoiceOver is only reachable through the
  AccessKit backend (bridged to NSAccessibility).

The backend is selected automatically: in a win32-only GTK build with
AccessKit compiled in, AccessKit is the only real backend and is used
by default; no `GTK_A11Y` environment variable is needed.
`GTK_A11Y=help` prints the backends a given build carries, which is
the quickest way to check a bundle.

## Windows bundle contract

MSYS2's stock `gtk4` package is built **without** the AccessKit
backend (and its `accesskit-c` package lags behind the version GTK's
meson build requires), so a bundle made purely from stock MSYS2
packages is unreadable by NVDA/JAWS. Therefore:

- CI rebuilds the MSYS2 `gtk4` package with `-Daccesskit=enabled`,
  building a matching `accesskit-c` first when the MSYS2 repo version
  is too old: `scripts/windows/gtk4-accesskit.sh`. The script reuses
  MSYS2's own PKGBUILDs (same patches, same options) and only adds the
  accessibility bits; built packages are cached per gtk4 release so
  the rebuild cost is paid once per version bump.
- `scripts/windows/bundle.sh` refuses to produce a zip whose
  `libgtk-4-1.dll` lacks the AccessKit backend, and checks that the
  `libaccesskit` DLL made it into `bin/` (the ntldd closure picks it
  up like any other GTK dependency). Set `REQUIRE_A11Y=0` only for
  local throwaway builds against a stock GTK.
- If MSYS2 ever enables AccessKit in its own gtk4 package, the rebuild
  script detects that and becomes a no-op; it can then be deleted.

## macOS bundle contract

Homebrew's gtk4 bottle has the same gap (and Homebrew carries no
accesskit-c formula at all), so:

- CI rebuilds the same GTK release Homebrew installed from the
  upstream tarball with the formula's macOS meson arguments plus
  `-Daccesskit=enabled`, building accesskit-c first:
  `scripts/macos/gtk4-accesskit.sh`. Only `libgtk-4*.dylib` is
  replaced — in both `$(brew --prefix)/lib` and the gtk4 keg, because
  libadwaita and the gtk modules reference GTK through the keg's opt
  path. Headers and pkg-config files are identical for the same
  release, so the app build is untouched. The built dylibs are cached
  per gtk4 version and runner flavor.
- `scripts/macos/bundle.sh` refuses to produce an app bundle whose
  `libgtk-4.1.dylib` lacks the AccessKit backend, and checks that the
  `libaccesskit` dylib made it into `Frameworks/` (the Mach-O closure
  picks it up like any other dependency). Set `REQUIRE_A11Y=0` only
  for local throwaway builds against a stock GTK.
- If Homebrew ever ships gtk4 with AccessKit, the rebuild script
  detects that and becomes a no-op; it can then be deleted.

To smoke-test: turn on VoiceOver (Cmd+F5), start Parla, and move
focus with Tab / VO-arrows; controls should be announced with names
and roles.

## Linux packaging

Nothing special is required, but for the record: the deb uses distro
GTK; the Flatpak uses the GNOME runtime's GTK and Flatpak proxies the
accessibility bus by default (the manifest must never pass
`--no-a11y-bus`); the AppImage bundles a distro GTK whose AT-SPI
backend talks to the host a11y bus over D-Bus.

## Testing with NVDA

NVDA is free: <https://www.nvaccess.org/download/> (a portable version
exists, no install needed).

1. Start NVDA, then start Parla.
2. Tab / Shift+Tab through the window: every focused control should be
   announced with a sensible name and role ("Search, edit", "Send,
   button", ...).
3. Arrow through the chat list and messages; NVDA should read rows as
   they gain focus.
4. `GTK_A11Y=help parla.exe` from a console lists the compiled-in
   backends; "accesskit" must appear for any of the above to work.

## Build-time switch

Accessibility is a Meson option, `a11y`, enabled by default. Passing
`-Da11y=false` at `meson setup` time:

- starts GTK with `GTK_A11Y=none`, so no AT-SPI or AccessKit backend
  is loaded and nothing is registered on the accessibility bus;
- compiles out Parla's own accessibility extras, which live behind
  `#if A11Y` in the Vala sources (message-row summaries, the
  hand-applied selected state on chat rows, explicit accessible
  labels).

The Sailfish port (`-Dsailfish=true`) always sets `GTK_A11Y=none`
because Sailfish OS has no accessibility bus, independently of the
`a11y` option. CI builds the Linux tree both with and without `a11y`
so both halves of every `#if A11Y` keep compiling.

## App-side rules

A working backend only exposes what widgets declare, so:

- Anything that only exists for assistive technology (explicit
  accessible labels, `update_state` / `update_property` calls, the
  helpers that compute them) goes inside `#if A11Y` ... `#endif` so a
  `-Da11y=false` build stays free of it. Plain `tooltip_text` and
  keyboard-focus handling stay unconditional: they serve everyone.
- Icon-only buttons need an accessible name: set `tooltip_text` (GTK
  falls back to it) or call
  `update_property (Gtk.AccessibleProperty.LABEL, "...", -1)`.
- Composite rows (chat list, message rows) should carry a label
  summarizing their content, otherwise screen readers announce an
  unnamed list item. Message rows get theirs from
  `MessageRow.accessible_summary` through `ListItem.accessible_label`.
- Message rows are focusable list items: Up/Down walk the messages,
  Tab moves into a row's selectable text, Menu / Shift+F10 open the
  message menu. `ConversationView.on_focus_widget_changed` decides where
  Tab enters the list (GTK would pick the first, oldest row and scroll
  the conversation to the top).
- The chat-list rows answer the same Menu / Shift+F10 to open the chat
  context menu, anchored to the focused row, in full and compact sidebar
  modes and the archived list (`Window.focused_chat_row`).
- Purely decorative images/widgets should not be announced; give them
  `Gtk.AccessibleRole.PRESENTATION`.
- Build menus from `PopoverButton`s in a plain `Gtk.Popover`, not from a
  `GLib.Menu` model. GTK's `GtkModelButton` names itself through a
  presentational inner label, which the AccessKit backend hands to
  AccessKit unresolved, so NVDA announces every item of a
  `GtkPopoverMenu` as empty (#57). The AT-SPI backend resolves the name
  itself, which is why Orca never showed the problem. Actions and their
  accelerators stay as `win.*` actions; `PopoverButton` takes the
  shortcut hint and restates it as `KEY_SHORTCUTS`.
- Keep the chat list quiet while the user types: the open chat's row does
  not echo the draft being written into it, and `load_chats` leaves the
  rows alone when nothing displayed changed. Rebuilding rows on every
  draft save made screen readers read the row out on each pause.
- Never bind Ctrl+Tab or Ctrl+Shift+Tab application-wide. GTK4
  reserves them for moving the focus out of a widget that consumes
  plain Tab (text views walk out on their own; the chat list has a
  handler that jumps back to the contact search entry or forward to
  the message entry). Ctrl+Page Up / Ctrl+Page Down only move focus
  through chat rows; Enter opens the focused chat. This keeps unread
  chats unread while a screen-reader user browses the list. The focused
  row has an accent outline, separate from the highlight for the chat
  already open.
