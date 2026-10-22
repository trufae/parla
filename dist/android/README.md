# Android arm64 (experimental)

Parla uses GTK's native Android backend through
[Pixiewood](https://github.com/sp1ritCS/gtk-android-builder), the same packager
used by GTK's Android CI. The existing Vala/libadwaita interface and JSON-RPC
transport are shared with desktop builds. There is no separate Kotlin UI,
WebView wrapper, X server, or Termux dependency.

- **Android 12 / API 31 or newer, arm64-v8a only.** Target/compile SDK: 36.
- GTK and Chatmail Core are packaged together; first launch needs no engine
  download. Android 10+ forbids executing downloads from writable app data.
  The core is installed as `libchatmail-rpc.so` in Android's `nativeLibraryDir`
  and executed over the existing stdio RPC transport. The `.so` suffix is an
  Android packaging convention; it is a PIE executable, not a JNI library.
- All native code must pass 16 KiB LOAD and RELRO checks, and the APK must pass
  `zipalign -c -P 16 4`. The pinned upstream 2.63.0 Android server has only
  4 KiB LOAD alignment, so `build-core.sh` downloads the pinned upstream source
  and builds it using the NDK. Keep this until an upstream 16 KiB release can
  be pinned and downloaded with a verified SHA-256.
- Account databases, encryption keys, settings and caches use **private internal
  storage**, overriding GTK's external-storage defaults. Android backups are
  disabled; use Chatmail's device transfer/export to move accounts.

## Build

Use an x86-64 Linux host with JDK 17+, Android SDK command-line tools, Rustup,
Meson 1.12.1, and the host packages listed in the `build-android` CI job. The
host GTK/libadwaita/json-glib packages supply Vala bindings only: the native
libraries are cross-built from source and host pkg-config paths are excluded.

```sh
export ANDROID_HOME=/path/to/android-sdk
source scripts/android/versions.env
sdkmanager "platforms;android-36" "build-tools;$ANDROID_BUILD_TOOLS" "ndk;$ANDROID_NDK_VERSION"
scripts/android/build.sh          # installable debug APK, separate .debug app ID
scripts/android/build.sh release  # aligned, unsigned release APK
```

The output is `dist/android/Parla-<version>-android-arm64-debug.apk` or
`Parla-<version>-android-arm64-unsigned.apk`. Versions come from the existing
Meson/AppStream release metadata. Pixiewood's `sem121010` version-code mapping
keeps semantic version upgrades monotonic. Keep both metadata files in sync.
Debug builds use Gradle's development key; a fresh CI runner may have a different
key, so uninstall an earlier CI debug build before installing another. Production
updates must always use the same backed-up release key.

Toolchain/source pins live in `scripts/android/versions.env`, `parla.xml`, and
these wrap files. The small AppStream patch skips desktop test executables when
cross-compiling for Android. Update the pins intentionally and test a fresh build. To clear
all Android-generated sources and outputs, remove `.cache/android`,
`.pixiewood`, and `subprojects` (do not do this during another build).

## CI and releases

PRs and main build an installable debug APK as the `parla-android-arm64-build`
Actions artifact. Tags build an unsigned release APK, then a separate job in
the existing `release` environment signs it. The normal release job requires
one signed Android APK and attaches it alongside the desktop assets.

Before the first tagged Android release, configure these **release environment
secrets** with a permanent keystore owned and backed up by the maintainer:

- `ANDROID_KEYSTORE_BASE64`: base64-encoded keystore containing the private key.
- `ANDROID_KEYSTORE_PASSWORD`: keystore password.
- `ANDROID_KEY_ALIAS`: signing key alias.
- `ANDROID_KEY_PASSWORD`: signing key password.

`sign.sh` accepts the same variables for local signing. A tagged release fails
if signing is unconfigured; it never publishes a debug-signed production APK.
Signing secrets are only exposed to the signing job, after compilation, and are
not used on PRs. The keystore is removed when that step exits.

## Device validation and current limits

```sh
adb install -r dist/android/Parla-*-android-arm64-debug.apk
adb shell monkey -p io.github.trufae.parla.debug 1
adb logcat -s Gtk Parla AndroidRuntime
adb shell getconf PAGE_SIZE
```

Test on both 4096- and 16384-byte page-size devices: launch, create/link a test
profile, send/receive text and image attachments, reopen the app, and upgrade
without losing account data. ELF/package checks alone do not prove device
runtime compatibility. Arm64 emulation is not assumed to work on the x86-64
GitHub runner.

This first port is a **foreground client**. Android may suspend or kill it in
background; reliable background reception, a foreground service/push bridge,
and Android notifications still need platform integration. Desktop tray and
notification controls are hidden. Webxdc and GStreamer media playback/recording
are disabled by the Android toolchain; those need Android-specific integration.
Changing language closes the app; reopen it to apply the selection. GTK's
Android file chooser handles document access, but attachment workflows still
need device testing.

Text fields use Parla's labeled touch menu on Android: long-press an entry or
the message composer for Cut, Copy, Paste, and Select All. Paste attempts a
clipboard read when tapped, even if GTK advertises no compatible text format.
Password fields disable Cut/Copy; read-only fields disable Cut/Paste. This is
an app-side fallback for missing GTK touch paste controls, not a replacement
Android clipboard backend.

When validating a build, copy an invite URL in another Android app, return to
Parla, open **Use Invite Link**, long-press the empty field, and tap **Paste**.
Verify **Add** becomes enabled and joining still requires confirmation. Repeat
with text selected in an existing entry and with the message composer; test
an empty clipboard, password fields, and returning after copying new text.
