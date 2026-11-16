# Webxdc apps (experimental)

[Webxdc](https://webxdc.org/) apps are tiny offline web apps (`.xdc` zip
archives) shared as Delta Chat attachments. Parla can run them in an
embedded platform web view. The feature is **enabled by default**; it remains
experimental because a web engine is a browser-sized attack surface (and on
Linux a large extra dependency).

Three view backends share the same core:

- **GNOME/Linux**: [WebKitGTK](https://webkitgtk.org/) (`webkitgtk-6.0`).
- **macOS**: the system `WebKit.framework` (WKWebView) through a small
  ObjC shim inside a signed, sandboxed helper — no WebKitGTK dependency.
- **Windows**: the installed Evergreen WebView2 Runtime through a
  separate Win32/C++ shim. Parla bundles only Microsoft's small
  architecture-specific `WebView2Loader.dll`, not Edge itself.

## Building

```sh
make run                   # macOS: works out of the box
                           # linux: Wayland, WebKitGTK 6, bubblewrap, libseccomp
bash scripts/windows/bundle.sh  # MSYS2/UCRT64
# or directly:
meson setup builddir
```

The Windows bundle script downloads and checksum-verifies a pinned official
`Microsoft.Web.WebView2` SDK package as a build input. A direct Windows Meson
build instead passes the extracted package root with
`-Dwebview2_sdk=/path/to/package`. The SDK supplies headers and the loader;
the application always uses the system-installed Evergreen runtime.

To omit Webxdc, explicitly use `make WITH_WEBXDC=0` or configure Meson with
`-Dwebxdc=false`. Those builds link no web engine at all.

On native Linux installs, `sudo make install` also installs
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

`src/webxdc.vala` owns the core RPC connection and JS API. Its platform-neutral
`Host` (`src/webxdc_host.vala`) launches one sandbox per instance. Only the
separate `parla-webxdc` executable links the web engine; it has no core,
account storage, or settings dependency. Platform launchers implement
`webxdc_sandbox.h`, while views implement `webxdc_view.h`. When the option is off, `src/webxdc_stub.vala`
provides the same `Dc.Webxdc` entry points as no-ops, so no other file
needs conditional compilation and linking stays trivial.

The private `webxdc_wire.vala` protocol uses length-prefixed JSON over inherited
pipes/socketpairs, with a version and policy handshake. Helpers can request
archive paths and send app messages only; the main process binds those to the
instance's account and message ID. They cannot supply account IDs, RPC method
names, native pointers, filesystem paths to open, or shell commands. Frames,
messages, queued writes, and concurrent resource requests are bounded. A bad
frame, disconnected peer, or startup timeout closes the instance.

- Apps appear in the chat as an accent-colored card and in the media
  gallery under **Apps**. Clicking either opens the same dialog with
  **Start App**, **Download File**, and **Cancel**; starting or saving first
  fetches an archive that is beyond the auto-download limit. A downloaded
  card shows the app's real name and icon read from the archive. Running
  instances are still limited to one window per app.
- Besides the compile-time option there is a runtime switch: **Settings →
  Advanced → In-Chat Apps** (`webxdc_apps` in `settings.ini`). Disabled,
  the app card stays recognizable and the dialog explains why it cannot
  start the app, offering only **Download File** and **Cancel**. Builds
  compiled without Webxdc support use the same download-only flow.
- **Realtime Channels** is enabled by default in the same settings page.
  It lets instances of the same app exchange ephemeral data through Chatmail
  core. Turning it off closes running apps and hides the realtime JavaScript
  API on subsequent launches. The setting is saved across restarts and is
  separate from direct Internet access.
- The same section has opt-in switches for direct Internet access,
  WebAssembly, WebGL, developer tools, and (on WebKitGTK) hardware
  acceleration. All default to off, including when upgrading from a version
  which did not have these settings. **Restrict** resets every capability
  at once, including realtime channels. Changing any security switch closes
  running app windows so the next
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
  and `WebxdcInstanceDeleted` closes it. All app events and open windows are
  matched by profile and message, even while another profile is selected.
- Realtime channels use `send_webxdc_realtime_advertisement`,
  `send_webxdc_realtime_data`, and `leave_webxdc_realtime`. Incoming binary
  data is delivered to the matching channel; core connects advertised peers
  without another advertisement from the app. Calls are serialized so an
  in-flight send finishes before leaving. Closing/deleting an app or disabling
  apps/realtime drops queued sends, and reopening waits for the old leave.

## Security boundaries

The native helper is isolated from the account process on all three platforms:

| Platform | Native boundary | Offline network boundary |
|---|---|---|
| Native Linux | Bubblewrap user/PID/mount/IPC namespaces, private home and temporary directories, read-only system libraries, dropped capabilities, inherited seccomp filter | Private network namespace and denial of IPv4/IPv6 socket creation |
| Flatpak | Restricted `flatpak-spawn --sandbox` child, no application data or session bus forwarding, inherited seccomp filter | `--no-network` and denial of IPv4/IPv6 socket creation |
| macOS | Signed App Sandbox XPC broker launches one child per instance, inheriting its sandbox; libraries live inside the service bundle | Browser request policy; **no native network denial**, because WKWebView refuses to start without network permission |
| Windows | Unique AppContainer SID and private runtime directory, restricted handle inheritance, Job Object with kill-on-close and process/memory limits | No network capabilities in offline mode |

Native Linux forwards one connected Wayland socket, not the runtime directory,
X11 socket, or session bus. X11 sessions fail closed. GPU device access is
granted only with the hardware acceleration option. WebKitGTK retains its
inner renderer sandbox on native Linux. In a restricted Flatpak child, the
portal is unavailable; WebKit subprocesses remain inside that per-instance
outer sandbox. No sandbox-disabling environment variables are passed.

macOS uses Apple's supported App Sandbox APIs, not deprecated custom Seatbelt
profiles. Its service has a separate container and no account-directory or
user-selected-file entitlements. The caller verifies the service signature and
sandbox entitlement, and the running broker checks its own entitlement too;
unsigned development bundles fail closed. Instances use ephemeral website stores,
but share the service's OS container. Browser content rules, CSP, and API
restrictions provide offline mode; they cannot contain native-code network
access after a helper compromise. WebGL restrictions on macOS also remain
best effort. These are explicit platform limits, not equivalent guarantees.
The network entitlement requirement is enforced by
[WebKit's XPC entry point](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceEntryPoint.mm).

Windows stages only the helper's DLL import closure and WebView2 loader into
a fresh container, inheriting that directory's ACL. It never changes access
permissions on the installation or account directories. Only the IPC handles
and a null stderr handle are inherited. The helper is assigned to its Job
Object before its first instruction executes. Closing the instance kills its
process tree and removes the container profile; abnormal parent termination
can leave an unused profile directory behind.

All platforms use an allowlisted environment and keep the engine's process
isolation enabled. Sandbox creation has no unsandboxed fallback. Within that
boundary, these browser restrictions apply by default; users may explicitly
relax individual capabilities in Settings:

- **No direct browser network.** Realtime exchange is mediated by core and
  restricted to the app's chat; it does not enable browser networking.
  WebKitGTK: the `WebKit.NetworkSession` is ephemeral (no
  cookies or cache on disk) and configured with a blackhole SOCKS proxy,
  so any `http(s)` request an app attempts dies before reaching the
  network. macOS: a compiled `WKContentRuleList` blocks every load and
  then exempts only the `webxdc:` scheme, which covers subresource
  fetches too, with a non-persistent website data store. `webxdc:`
  content is served through the private IPC channel. WebKitGTK also
  disables WebRTC in offline mode, and native socket restrictions also block
  DNS traffic; macOS removes the
  WebRTC/WebTransport constructors at document start as defense in depth
  because WKWebView exposes no public WebRTC setting. Windows intercepts all
  WebView2 resource requests outside its synthetic app origin, returns a local 403, and also
  starts the runtime with a dead proxy; a document-start policy removes
  WebSocket, EventSource, WebRTC, and WebTransport constructors.
- **Shared response policy.** All three engines apply the CSP in
  `webxdc_view.h` to documents and scripts, including workers. Offline sources
  are restricted to the archive, data, and blob URLs; forms and plugins are
  disabled. This complements each engine's request interception.
- **No WebAssembly.** Every custom-scheme response carries a CSP which
  permits normal archive scripts but omits `unsafe-eval` and
  `wasm-unsafe-eval`. Enabling WebAssembly adds `wasm-unsafe-eval` while retaining
  the remaining restrictions. Linux additionally fixes JavaScriptCore's
  `JSC_useWasm` engine option before launch and verifies it in the helper,
  because some WebKitGTK releases do not enforce Wasm compilation through CSP.
  macOS removes the `WebAssembly` constructor at document start in every frame
  for the same reason: some WKWebView releases ignore `wasm-unsafe-eval`. Code
  in a dedicated worker can still reach the engine API, so the macOS Wasm
  restriction is best effort like its WebGL control.
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
- **No account filesystem access.** App resources come from the archive via
  mediated RPC; the native helper can access its private sandbox storage and
  the system/runtime files required by its platform.
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

## Testing the boundary

`meson test -C builddir` includes framing, malformed-input, policy and realtime
unit tests. The live tests exercise real helper launches, browser CSP and Wasm
policy, binary realtime exchange, profile isolation, permission revocation,
and native filesystem/network/environment probes:

```sh
# Linux: run in Wayland with user namespaces permitted; Windows: MSYS2
python3 tests/webxdc_sandbox_test.py builddir
# macOS: use a built, signed bundle; the test modifies a temporary copy only
python3 tests/webxdc_sandbox_test.py builddir --macos-bundle dist/macos/Parla.app
```

The macOS native test explicitly expects networking to remain available, while
checking denied filesystem access, sanitized environment inheritance, and
rejection after removing the service's sandbox entitlement. Linux
and Windows also expect the native localhost connection to fail. A probe is
never installed as part of the application. CI runs the live suite on all
three desktop platforms; Linux uses a headless Wayland compositor and a scoped
AppArmor test profile rather than disabling host security restrictions.

## JS API exposed to apps

Only the core of the [official webxdc spec](https://webxdc.org/docs/spec/)
as used by the official Delta Chat clients — nothing else is injected:

| member | behaviour |
|---|---|
| `webxdc.selfAddr` | account address |
| `webxdc.selfName` | display name (falls back to the address) |
| `webxdc.sendUpdate(update, descr)` | `send_webxdc_status_update` |
| `webxdc.setUpdateListener(cb, serial)` | replays updates after `serial`, then live ones |
| `webxdc.joinRealtimeChannel()` | joins the app's ephemeral channel; available when Realtime Channels is enabled |

The [realtime channel](https://webxdc.org/docs/spec/joinRealtimeChannel.html)
offers `setListener(callback)`, `send(Uint8Array)` (up to 128000 bytes), and
`leave()`. Only one handle can be active in an app at a time. Leaving invalidates
that handle; the app can call `joinRealtimeChannel()` again for a new one.
Payloads are not stored or replayed, and delivery is not guaranteed. A full
outgoing queue drops additional data instead of growing without a bound.

Optional spec extras (`sendToChat`, `importFiles`)
are intentionally absent; apps must feature-detect them, and well-behaved
ones degrade gracefully.
