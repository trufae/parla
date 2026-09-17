# Sailfish GNOME

Reusable GTK4 and libadwaita packages for **Sailfish OS 5.1.0.11 / aarch64**.
Build the missing libraries once, then share them between apps and CI jobs.
[Parla](https://github.com/trufae/parla) is the first consumer.

This directory is staged in Parla while the standalone
`trufae/sailfish-gnome` repository is being set up. Its contents belong at
that repository's root. No release is available there yet.

## What is included

| Component | Version |
| --- | --- |
| GTK | 4.14.5 |
| libadwaita | 1.5.8 |
| Graphene | 1.10.8 |
| libepoxy | 1.5.10 |
| AppStream | 1.0.3 |
| libxmlb | 0.3.22 |
| WebP GdkPixbuf loader | 0.2.7 |

`sailfish-gnome` installs shared libraries, data, translations and tools in
standard `/usr` paths. `sailfish-gnome-devel` adds headers, linker symlinks,
pkg-config files and libadwaita's Vala bindings. GLib, Cairo, Pango,
Harfbuzz, Wayland, GdkPixbuf and the other available dependencies come
from Sailfish OS. Sass is used only while building and is not packaged.

This is an experimental Wayland toolkit port, not the whole GNOME desktop.
WebKitGTK, GObject introspection typelibs and Python bindings are not
included. Other Sailfish releases and CPU architectures are not validated.
Use `GDK_BACKEND=wayland GSK_RENDERER=cairo` for an initial device test;
GPU rendering and on-screen keyboard integration need device testing.

## Build

On a Linux host with Docker, curl, Python 3 and sha256sum:

```sh
scripts/fetch-sources.sh
scripts/build-rpm.sh 5.1.0.11 aarch64
python3 scripts/make-release.py
```

The helper uses the aarch64 Sailfish Platform SDK container and keeps a
compiler cache under `.cache/ccache`. `out/` contains two RPMs, an RPM
bundle, corresponding sources, build information, checksums and a lock
file for consuming CI jobs. Build logs contain compiler cache statistics.

All upstream source downloads are pinned in `sources.lock` and verified
before use. The corresponding-source archive includes the original source
tarballs, RPM recipe, build scripts, Vala bindings and source checksums.
Each RPM carries the upstream license texts. Packaging scripts are covered
by the root `COPYING`; library sources retain their upstream licenses.

## Install a release

Download the runtime RPM and `SHA256SUMS` from the same version on
[Releases](https://github.com/trufae/sailfish-gnome/releases), then:

```sh
sha256sum --ignore-missing -c SHA256SUMS
devel-su pkcon install-local ./sailfish-gnome-0.1.0-1.sfos5.1.0.11.aarch64.rpm
```

`pkcon` resolves the remaining dependencies from the system repositories.
The development RPM is for SDK targets; an end-user device only needs the
runtime plus the app RPM. The package manager refreshes the GTK schema and
GdkPixbuf loader caches during installation and removal.

## Use in another app

Add `BuildRequires: sailfish-gnome-devel >= 0.1.0` and
`Requires: sailfish-gnome >= 0.1.0` to the app's RPM spec. Put both library
RPMs in the SDK project's `RPMS/` directory, then build with:

```sh
mb2 -t SailfishOS-5.1.0.11-aarch64 --search-output-dir build
```

For CI, commit the release's `sailfish-gnome.lock` to the app repository.
It pins the SDK release, architecture, bundle URL, SHA-256 and exact RPM
names. Parla's `dist/sailfishos/fetch-packages.py` consumes this format.
Do not resolve `latest` on every build: dependency changes should be
reviewed as lock-file updates.

## Website and releases

`site/` is a static GitHub Pages site. Binaries live in GitHub Releases;
the Git repository tracks build recipes, sources' hashes and the website.
Do not commit RPM blobs to Git or put them in the Pages deployment.

1. Create the public `trufae/sailfish-gnome` repository and copy this
   directory's tracked contents into its root, including `.github/`.
2. In **Settings → Pages → Build and deployment**, choose **GitHub Actions**.
3. Push `main`. The Packages workflow builds RPMs, and Website deploys Pages.
4. Verify the package artifact and a consumer build. Set the spec's
   `Version`, update `RELEASE-NOTES.md`, then push a matching `v0.1.0` tag.
5. The tag workflow publishes the versioned release. Commit its generated
   `sailfish-gnome.lock` in Parla and remove Parla's bootstrap library job.

Keep releases immutable; publish a new version for any changed binary.
Website-only changes do not run the package build. Library recipe changes
and version tags do. Keep matching source downloads available with binaries.
