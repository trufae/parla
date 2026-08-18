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

They are compiled into the binary through `data/parla.gresource.xml` (app
icons) and `data/parla-fallback-icons.gresource.xml` (Adwaita copies) and
registered with `Gtk.IconTheme.add_resource_path()` (see
`register_icons()` in `src/application.vala`). GTK treats resource icons as
part of the `hicolor` fallback theme, so the user's icon theme (Breeze,
Papirus, Yaru, ...) still takes precedence whenever it provides the icon;
the bundled copy is only used when the active theme lacks it. This keeps
the UI complete on desktops that cannot select Adwaita (it is hidden in its
`index.theme`, e.g. on XFCE), see issue #61.

To add a new stock icon: use it in the source, copy the SVG from Adwaita
into the matching hicolor context directory here and list it in
`data/parla-fallback-icons.gresource.xml`. Packagers who prefer to depend on
`adwaita-icon-theme` can build with `-Dbundle_icons=false` to leave the
Adwaita copies out of the binary. Only the app icons in `scalable/apps/` are
installed to `$datadir/icons/hicolor`; the rest live solely in the
GResource, so nothing leaks into the system icon theme.
