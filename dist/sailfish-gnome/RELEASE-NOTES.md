Initial experimental GTK4/libadwaita packages for Sailfish OS 5.1.0.11,
aarch64. Intended for Parla and other native GTK applications.

- Runtime RPM: shared GTK4 4.14.5, libadwaita 1.5.8, Graphene, libepoxy,
  AppStream, libxmlb and the WebP GdkPixbuf loader.
- Development RPM: headers, pkg-config files and libadwaita Vala bindings.
- CI bundle and `sailfish-gnome.lock`: pin the bundle checksum in consumers.
- Corresponding sources and upstream license texts are included.

Download the runtime for devices; use both RPMs in a matching Sailfish SDK
target. Check `SHA256SUMS` before installing. These RPMs are not GPG-signed.
WebKitGTK and introspection bindings are not included. Hardware keyboard,
rendering and other device integration still require testing on real phones.
