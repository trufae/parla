# Webxdc apps (experimental)

[Webxdc](https://webxdc.org/) apps are tiny offline web apps (`.xdc` zip
archives) shared as Delta Chat attachments. Parla can run them in an
embedded platform web view, but the feature is **off by default**: a web engine
is a browser-sized attack surface (and on Linux a large extra dependency),
so it will only be enabled once it has seen enough testing.

Three view backends share the same core:

- **GNOME/Linux**: [WebKitGTK](https://webkitgtk.org/) (`webkitgtk-6.0`).
- **macOS**: the system `WebKit.framework` (WKWebView) through a small
  ObjC shim — no WebKitGTK, no extra dependency, nothing to bundle.
- **Windows**: the installed Evergreen WebView2 Runtime through a
  separate Win32/C++ shim. Parla bundles only Microsoft's small
  architecture-specific `WebView2Loader.dll`, not Edge itself.

## Building

```sh
make run WITH_WEBXDC=1     # macOS: works out of the box
                           # linux: needs webkitgtk-6.0 pkg-config
WITH_WEBXDC=1 bash scripts/windows/bundle.sh  # MSYS2/UCRT64
# or directly:
meson setup builddir -Dwebxdc=true
```

The Windows bundle script downloads and checksum-verifies a pinned official
`Microsoft.Web.WebView2` SDK package as a build input. A direct Windows Meson
build instead passes the extracted package root with
`-Dwebview2_sdk=/path/to/package`. The SDK supplies headers and the loader;
the application always uses the system-installed Evergreen runtime.

A plain `make` (or `-Dwebxdc=false`) reverts to the default build, which
links no web engine at all.

On native Linux installs, `sudo make install WITH_WEBXDC=1` also installs
and loads an AppArmor profile when AppArmor is active. This is needed on
Ubuntu 24.04 and newer, where the default user-namespace restriction can
otherwise prevent WebKitGTK's bubblewrap sandbox from starting. Systems
without AppArmor need no profile, staged package installs include it without
loading it on the build host, and Flatpak uses its own sandbox. See the
[README](../README.md#webxdc-apps-experimental) for platform support and
source-build caveats.

CI builds it in for macOS (system framework), Windows (system WebView2 runtime),
the plain Linux build, the .deb (depends on `libwebkitgtk-6.0-4`) and the
Flatpak (WebKitGTK comes with the GNOME runtime). The AppImage still ships the stub: bundling
WebKitGTK's helper processes into an AppImage is its own project. Users
can always turn apps off at runtime in Settings → Advanced.

## How it works

The feature is isolated at file level: `src/webxdc.vala` holds the shared
jsonrpc plumbing and JS bridge. Linux keeps its Adw.Window/WebKitGTK view;
macOS selects `src/webxdc_macos.m`, and Windows selects the fully separate
`src/webxdc_windows.cpp` Win32/WebView2 implementation. When the option is off, `src/webxdc_stub.vala`
provides the same `Dc.Webxdc` entry points as no-ops, so no other file
needs conditional compilation and linking stays trivial.

- Apps appear in the chat as an accent-colored card and in the media
  gallery under **Apps**. Clicking either opens the same dialog with
  **Start App**, **Download File**, and **Cancel**; starting or saving first
  fetches an archive that is beyond the auto-download limit. A downloaded
  card shows the app's real name and icon read from the archive. Running
  instances are still limited to one window per app.
- Besides the compile-time option there is a runtime switch: **Settings →
  Advanced → Webxdc apps** (`webxdc_apps` in `settings.ini`). Disabled,
  the app card stays recognizable and the dialog explains why it cannot
  start the app, offering only **Download File** and **Cancel**. Builds
  compiled without Webxdc support use the same download-only flow.
- The same section has opt-in switches for direct Internet access,
  WebAssembly, WebGL, developer tools, and (on WebKitGTK) hardware
  acceleration. All default to off, including when upgrading from a version
  which did not have these settings. **Use safest** resets every capability
  at once. Changing any security switch closes running app windows so the next
  launch cannot retain an older, broader policy.
- Sending an `.xdc` file from Parla announces it with the `Webxdc`
  viewtype, so other clients show it as an app too.
- Every window gets its own isolated web context. WebKit uses a custom
  `webxdc:` URI scheme; WebView2 uses an intercepted, nonexistent secure
  `https://webxdc.invalid` origin. Files are extracted from the `.xdc` archive by deltachat
  core (`get_webxdc_blob` over jsonrpc) — Parla never unzips anything
  itself and serves nothing from disk.
- `webxdc.js` is the one synthetic file: it installs `window.webxdc` and
  bridges to Vala through the native view's script-message API.
- Status updates flow through the core jsonrpc calls
  `send_webxdc_status_update` / `get_webxdc_status_updates`; incoming
  `WebxdcStatusUpdate` events are routed to the matching open window,
  and `WebxdcInstanceDeleted` closes it.

## Security boundaries

Webxdc's contract is that apps run **offline and sandboxed**. Parla starts
with the following safest policy inside all three engines; users may explicitly
relax individual capabilities in Settings:

- **No network.** WebKitGTK: the `WebKit.NetworkSession` is ephemeral (no
  cookies or cache on disk) and configured with a blackhole SOCKS proxy,
  so any `http(s)` request an app attempts dies before reaching the
  network. macOS: a compiled `WKContentRuleList` blocks every load and
  then exempts only the `webxdc:` scheme, which covers subresource
  fetches too, with a non-persistent website data store. `webxdc:`
  content is served in-process and is unaffected either way. WebKitGTK also
  disables WebRTC and DNS prefetching in offline mode; macOS removes the
  WebRTC/WebTransport constructors at document start as defense in depth
  because WKWebView exposes no public WebRTC setting. Windows intercepts all
  WebView2 resource requests outside its synthetic app origin, returns a local 403, and also
  starts the runtime with a dead proxy; a document-start policy removes
  WebSocket, EventSource, WebRTC, and WebTransport constructors.
- **No WebAssembly.** Every custom-scheme response carries a CSP which
  permits normal archive scripts but omits `unsafe-eval` and
  `wasm-unsafe-eval`. Enabling WebAssembly removes that host CSP.
- **No WebGL.** WebKitGTK uses its public per-view `enable-webgl` setting.
  WKWebView has no public equivalent, so macOS installs a document-start
  script in every frame which blocks canvas WebGL contexts. This is a
  best-effort compatibility control, not a macOS security boundary: code in
  a worker can still reach APIs Apple does not expose for configuration.
  Windows combines Edge's `--disable-webgl`/`--disable-gpu` policy with the
  same document-start canvas restriction. Enabling WebGL on Windows is also
  the GPU opt-in because WebView2 has no stable per-controller acceleration
  setting.
- **No developer tools.** Browser inspection and the JavaScript console are
  disabled by default. The opt-in setting opens the engine's inspector in a
  separate window when an app starts: WebKitGTK's public inspector on Linux,
  WebView2 DevTools on Windows, and WebKit's private in-process inspector on
  macOS. The macOS SPI is resolved at runtime and may stop working after an
  OS update; the view remains inspectable through Safari as a fallback. While
  developer tools are off, the bridge displays the first uncaught JavaScript
  exception, unhandled promise rejection, or script-load failure inside the
  app window, and a failed `index.html` fetch gets a startup error page,
  instead of leaving an unexplained blank or broken view.
- **No hardware acceleration on WebKitGTK.** Its public per-view policy is
  set to `NEVER` by default. WKWebView exposes no equivalent public setting,
  so Parla does not show a misleading hardware-acceleration switch on macOS.
- **No navigation escape.** The navigation policy delegate refuses any
  navigation or `window.open` outside the app origin on every backend
  (macOS fails closed: if the rule list cannot compile, the web view is
  never created). Windows also cancels every WebView2 download.
- **No filesystem.** All content comes from the archive via jsonrpc.
- **No persistence.** Ephemeral session: `localStorage` survives only as
  long as the window (a deliberate, safer deviation from the official
  client). Windows creates a unique InPrivate WebView2 profile for each app
  window.
- Developer extras and modal dialogs are disabled.

Enabling **Internet access** removes the dead proxy/content rule for
subresources, but it does not remove the navigation delegate: top-level
navigation and `window.open` outside the app origin remain blocked. This mode is
deliberately marked unsafe because it breaks Webxdc's privacy guarantee.
Sessions remain ephemeral even when direct networking is enabled.

## JS API exposed to apps

Only the core of the [official webxdc spec](https://webxdc.org/docs/spec/)
as used by the official Delta Chat clients — nothing else is injected:

| member | behaviour |
|---|---|
| `webxdc.selfAddr` | account address |
| `webxdc.selfName` | display name (falls back to the address) |
| `webxdc.sendUpdate(update, descr)` | `send_webxdc_status_update` |
| `webxdc.setUpdateListener(cb, serial)` | replays updates after `serial`, then live ones |

Optional spec extras (`sendToChat`, `importFiles`, `joinRealtimeChannel`)
are intentionally absent; apps must feature-detect them, and well-behaved
ones degrade gracefully.
