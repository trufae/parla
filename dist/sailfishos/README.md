# Parla on Sailfish OS

Experimental native package of Parla for Sailfish OS 5.1 and newer,
built as `harbour-parla` RPMs by the `build-sfos` CI job.

## Why 5.1, and how this works

Sailfish OS has no GTK stack, and before 5.1 its compositor (lipstick)
did not speak the Wayland `xdg-shell` protocol GTK4 windows require.
Sailfish OS 5.1 "Pispala" added xdg-shell support, which makes a native
GTK4 app possible for the first time. Since none of the GTK libraries are
packaged by Jolla, this package builds and bundles a private stack under
`/usr/share/harbour-parla`:

- vendored: graphene, libepoxy, GTK4, libadwaita, plus libxmlb and
  appstream (libadwaita hard-requires appstream) and a build-time-only
  static sassc/libsass for libadwaita's stylesheet
- from Sailfish OS: glib2, cairo, pango, harfbuzz, gdk-pixbuf, fribidi,
  json-glib, wayland, libxkbcommon, freetype, fontconfig, librsvg,
  libyaml, libcurl, libxml2, vala

The Delta Chat JSON-RPC engine (`deltachat-rpc-server`, a static-musl
binary from [chatmail/core](https://github.com/chatmail/core) releases) is
shipped inside the same RPM and pinned at build time via the
`rpc_server_path` meson option, which also disables the in-app engine
downloader. The `/usr/bin/harbour-parla` launcher forces the whole runtime
environment: the private library path, the bundled engine path
(`PARLA_RPC_SERVER`), and Sailfish-compatible
`XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` under
`~/.local/share/io.github.trufae/Parla` so both Parla and the engine write
to one private location. The desktop entry disables Sailjail: the jail cannot
launch the shell -> private GTK binary -> private RPC engine executable chain,
which is why an affected build works from the terminal but not from its icon.

## Install

Grab the `harbour-parla-*.rpm` for your architecture from the
[releases page](https://github.com/trufae/parla/releases) and install it:

```sh
devel-su pkcon install-local harbour-parla-*.aarch64.rpm
```

(`pkcon install-local` resolves the few system dependencies, such as
librsvg and libwebp, from the Jolla repositories; plain `rpm -U` does not.)

All currently sold/flashable Sailfish OS devices (Xperia 10 II-V, Jolla
C2) are aarch64. The spec also knows armv7hl (Xperia XA2) and i486 asset
names, but CI builds aarch64 only for now.

For an aarch64 RPM, `Source5` resolves to
`deltachat-rpc-server-aarch64-linux`. It is a statically linked 64-bit ARM
ELF (not the Android arm64 asset), so it has no target glibc dependency.

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

You need the Sailfish Platform SDK, or Docker:

```sh
dist/sailfishos/fetch-sources.sh aarch64
docker run --rm --privileged -v "$PWD:/workspace" \
    coderus/sailfishos-platform-sdk:5.1.0.11 bash -lc \
    'cp -r /workspace ~/build && cd ~/build && \
     mb2 -t SailfishOS-5.1.0.11-aarch64 build && \
     cp -r RPMS /workspace/'
```

`fetch-sources.sh` downloads the pinned, checksum-verified vendored
sources into `rpm/` where mb2 expects them. The stack build itself lives
in `dist/sailfishos/build-stack.sh`, driven by `rpm/harbour-parla.spec`.

A future goal is submitting this to [SailfishOS:Chum](
https://github.com/sailfishos-chum/main); the spec already carries Chum
metadata behind `%if 0%{?_chum}`. Note that Chum's OBS builds without
network access, so the vendored sources would need to be committed or
mirrored as proper OBS sources first.
