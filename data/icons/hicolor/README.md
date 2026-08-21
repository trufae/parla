# Bundled icons

- `scalable/apps/`: Parla's own application, tray and welcome icons.
- `scalable/actions/{sticker,notifications-disabled,archive}-symbolic.svg`:
  Parla-specific symbolic icons.
- Every other `*-symbolic.svg` is copied verbatim from the
  [adwaita-icon-theme](https://gitlab.gnome.org/GNOME/adwaita-icon-theme),
  Copyright © GNOME Project (<https://www.gnome.org>). Upstream offers the
  symbolic icons under either the GNU LGPL v3 or CC-BY-SA 3.0; Parla
  redistributes them under the LGPL v3 option, which permits conveying them
  under Parla's GPL-3.0 licence (see `COPYING`).

The app icons and Parla-specific symbolics are compiled into the binary
through `data/parla.gresource.xml` and registered with
`Gtk.IconTheme.add_resource_path()` (see `register_icons()` in
`src/application.vala`).

The Adwaita copies are only compiled in with `-Dbundle_icons=true`
(`make BUNDLE_ICONS=1`), via `data/parla-fallback-icons.gresource.xml`, for
builds that cannot rely on an installed `adwaita-icon-theme`. GTK treats
resource icons as part of the `hicolor` fallback theme, so the user's icon
theme still wins whenever it provides the icon.

By default they are not bundled: `src/icon_fallback.vala` always adds the
installed Adwaita theme as a per-process fallback after the user's theme and
`hicolor` (issue #61). The copies kept here therefore double as the list of
stock icons Parla relies on;
`tests/check_icons.py` fails when a `*-symbolic` name used in `src/` is
neither listed here nor built into GTK4/libadwaita.

To add a new stock icon: use it in the source, copy the SVG from Adwaita
into the matching hicolor context directory here and list it in
`data/parla-fallback-icons.gresource.xml`. Only the app icons in
`scalable/apps/` are installed to `$datadir/icons/hicolor`; nothing else
leaks into the system icon theme.
