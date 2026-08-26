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
  AccessKit backend.

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

## App-side rules

A working backend only exposes what widgets declare, so:

- Icon-only buttons need an accessible name: set `tooltip_text` (GTK
  falls back to it) or call
  `update_property (Gtk.AccessibleProperty.LABEL, "...", -1)`.
- Composite rows (chat list, message rows) should carry a label
  summarizing their content, otherwise screen readers announce an
  unnamed list item.
- Purely decorative images/widgets should not be announced; give them
  `Gtk.AccessibleRole.PRESENTATION`.
