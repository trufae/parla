# Parla on Sailfish OS

Experimental native package for Sailfish OS 5.1.0.11 / aarch64, built as
`harbour-parla` RPMs by the `build-sfos` CI job.

## Shared libraries

GTK4, libadwaita and their missing dependencies are maintained and built in
[sailfishos-gnome](https://github.com/trufae/sailfishos-gnome). Parla's CI
only downloads the pinned runtime/development RPMs and compiles the app.
The source recipes, library releases and GitHub Pages website all live in
that separate repository.

The `sailfish-gnome` runtime installs its libraries in standard system
paths so multiple GTK apps can share them. Sailfish's existing GLib,
Cairo, Pango, HarfBuzz, Wayland, GdkPixbuf and other available dependencies
are reused. Parla no longer contains a private copy of this GTK stack.

The Delta Chat JSON-RPC engine is still bundled in Parla's RPM under
`/usr/share/harbour-parla/bin`, alongside the app. It is the pinned
static-musl binary from [chatmail/core](https://github.com/chatmail/core),
not a runtime download. The launcher sets `PARLA_RPC_SERVER` and keeps
existing account, configuration and cache paths unchanged under
`~/.local/share/io.github.trufae/Parla` and the corresponding XDG roots.

Sailfish OS 5.1 provides the compositor xdg-shell support GTK4 needs.
The desktop entry currently disables Sailjail for the shell/app/RPC
executable chain. Webxdc mini-apps are disabled because WebKitGTK is not
part of the shared package set.

## Install

Download the matching **runtime** RPM from
[Sailfish GNOME releases](https://github.com/trufae/sailfishos-gnome/releases)
and the app RPM from [Parla releases](https://github.com/trufae/parla/releases).
Verify the runtime against that release's `SHA256SUMS`, then install both:

```sh
sha256sum --ignore-missing -c SHA256SUMS
devel-su pkcon install-local ./sailfish-gnome-0.1.0-1.sfos5.1.0.11.aarch64.rpm ./harbour-parla-*.aarch64.rpm
```

`pkcon` resolves the remaining system dependencies from the Jolla repositories.
The `-devel` RPM is only needed in the SDK target, not on the phone.
Existing account data stays in the same locations when upgrading from the
older package that bundled GTK. Downloading Parla updates no longer means
redownloading the GTK libraries unless the shared runtime also changes.

## Known caveats (help wanted)

This is a fresh port riding on compositor support that is only a couple of
releases old. Feedback from real devices is welcome:

- **On-screen keyboard**: lipstick's xdg-shell support is new and its
  text-input story for GTK apps is unverified; a hardware/bluetooth
  keyboard works regardless.
- **Scaling**: lipstick reports a scale-1 Wayland output and GTK's Wayland
  backend does not use `GDK_SCALE`. Sailfish builds therefore default to
  192 DPI, collapse to the phone layout below 720 px, and hide desktop window
  buttons. Set `PARLA_GTK_DPI` to a value from 96 to 384 before launching if
  the UI is too large or small for a particular panel.
- **Rendering**: the launcher defaults to GTK's software renderer
  (`GSK_RENDERER=cairo`) for reliability on libhybris devices. Try
  `PARLA_GSK_RENDERER=ngl` for GPU rendering.
- **Accessibility**: Sailfish OS does not provide the AT-SPI bus expected by
  GTK. The Sailfish build selects `GTK_A11Y=none` before GTK starts, avoiding
  the D-Bus warning and startup delay.
- Webxdc mini-apps are disabled (no WebKitGTK on Sailfish OS).

## Building locally

Use a Linux host with Docker, curl and Python 3:

```sh
python3 dist/sailfishos/fetch-packages.py 5.1.0.11 aarch64
dist/sailfishos/fetch-sources.sh aarch64
dist/sailfishos/build-rpm.sh 5.1.0.11 aarch64
```

`fetch-packages.py` reads `sailfish-gnome.lock`, verifies the exact bundle
SHA-256 and stages the two expected RPMs in `RPMS/`. `mb2 --search-output-dir`
installs them as build dependencies. A missing release, wrong checksum or
unsupported target fails the build; CI never falls back to compiling GTK.
The downloader caches verified bundles locally. CI also keeps a small
compiler cache for Parla, separate from the old library compilation cache.

`fetch-sources.sh` now downloads only the checksum-pinned chat engine.
`build-app.sh` compiles the `parla` target and the spec installs it without
building unused test executables. The regular CI jobs still run the full
test suite.

To upgrade dependencies, take `sailfish-gnome.lock` from a tested release in
[sailfishos-gnome](https://github.com/trufae/sailfishos-gnome/releases), review
its version and SDK target, and commit it here. Library recipes and website
changes belong in that repository. Only aarch64 is currently published.
