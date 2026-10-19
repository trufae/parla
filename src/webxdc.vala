/* Experimental Webxdc runner: hosts a Delta Chat mini-app (.xdc archive)
 * in a web view. Compiled only with -Dwebxdc=true; otherwise
 * webxdc_stub.vala provides the same entry points as no-ops so no other
 * file needs conditional compilation. The jsonrpc plumbing and the JS
 * bridge below are platform-independent; only the view layer splits:
 * WebKitGTK on GNOME, and isolated native shims on macOS and Windows. See
 * docs/webxdc.md for the security boundaries and the JS API. */
namespace Dc.Webxdc {
    public void close_all () {
        if (windows == null) return;
        foreach (var app in windows.get_values ()) { app.stop_realtime (); app.close_view (); }
    }

    public const bool AVAILABLE = true;

    private HashTable<string, Instance>? windows = null;

    private string instance_key (int account_id, int msg_id) {
        return "%d:%d".printf (account_id, msg_id);
    }

    private Instance? current_instance (int msg_id) {
        return windows == null || client == null ? null
            : windows.lookup (instance_key (client.account_id, msg_id));
    }

    /** Signal hub for run-state and preference changes, so UI like the
        per-chat apps bar can stay in sync without polling. */
    public class Monitor : Object {
        public signal void changed (int msg_id);
        private static Monitor? instance = null;
        public static Monitor get_default () {
            if (instance == null) instance = new Monitor ();
            return instance;
        }
    }

    /* The chat the main window is currently showing, fed from window.vala.
       FOLLOW_CHAT app windows show only while their own chat is on screen.
       Focus is deliberately not part of this: focusing the app window
       unfocuses the chat, and hiding on that would fight the user. */
    private int active_account = 0;
    private int active_chat = 0;
    private bool chat_window_visible = true;

    public void set_active_chat (int account_id, int chat_id,
                                 bool window_visible) {
        active_account = account_id;
        active_chat = chat_id;
        chat_window_visible = window_visible;
        if (windows == null) return;
        foreach (unowned Instance app in windows.get_values ()) {
            app.apply_follow_visibility ();
        }
    }

    public bool is_running (int msg_id) {
        var app = current_instance (msg_id);
        return app != null && !app.closed;
    }

    /** Msg ids of the running app windows started from the given chat. */
    public int[] running_apps (int account_id, int chat_id) {
        int[] ids = {};
        if (windows == null) return ids;
        foreach (unowned Instance app in windows.get_values ()) {
            if (!app.closed && app.belongs_to (account_id, chat_id)) ids += app.msg_id;
        }
        return ids;
    }

    public void stop_app (int msg_id) {
        var app = current_instance (msg_id);
        if (app != null) app.close_view ();
    }

    /** Raise the app window (and restore it if minimized). */
    public void present_app (int msg_id) {
        var app = current_instance (msg_id);
        if (app != null) app.present ();
    }

    /** Minimize the app window, or restore it if already minimized. */
    public void minimize_app (int msg_id) {
        var app = current_instance (msg_id);
        if (app != null) app.toggle_minimize_view ();
    }


    /* Client used for chat-card lookups (window title/icon before an app
       is started); set from window.vala whenever the RpcClient changes.
       Strong ref so a lookup racing an account switch stays valid. */
    private RpcClient? client = null;
    private unowned SettingsManager? config = null;

    private bool follow_setting_connected = false;
    private bool security_settings_connected = false;
    private bool security_close_pending = false;

    public void setup (RpcClient rpc, SettingsManager settings) {
        if (client != null && client != rpc && windows != null) {
            foreach (var app in windows.get_values ()) app.close_view ();
        }
        client = rpc;
        config = settings;
        cards = null;   /* msg ids are per-account */
        if (!follow_setting_connected) {
            follow_setting_connected = true;
            /* Window behavior is a global setting: reapply to every open
               app window the moment it is changed in Settings. */
            settings.notify["webxdc-follow-chat"].connect (() => {
                if (windows == null) return;
                foreach (unowned Instance app in windows.get_values ()) {
                    app.apply_follow_visibility ();
                }
            });
        }
        if (!security_settings_connected) {
            security_settings_connected = true;
            settings.notify["webxdc-apps"].connect (() => {
                schedule_security_close ();
            });
            settings.notify["webxdc-realtime"].connect (() => {
                schedule_security_close ();
            });
            settings.notify["webxdc-allow-internet"].connect (() => {
                schedule_security_close ();
            });
            settings.notify["webxdc-allow-wasm"].connect (() => {
                schedule_security_close ();
            });
            settings.notify["webxdc-allow-webgl"].connect (() => {
                schedule_security_close ();
            });
            settings.notify["webxdc-allow-hardware-acceleration"].connect (
                () => { schedule_security_close (); });
            settings.notify["webxdc-developer-tools"].connect (() => {
                schedule_security_close ();
            });
        }
    }

    /* Security policy is fixed when a web view is created. Close existing
       instances so changing a switch takes effect immediately and no app
       silently keeps broader permissions than Settings shows. Coalesce the
       safest-default button's four property notifications into one pass. */
    private void schedule_security_close () {
        if (security_close_pending) return;
        security_close_pending = true;
        // Stop accepting traffic synchronously, before native window teardown.
        if (windows != null) {
            foreach (var app in windows.get_values ()) app.stop_realtime ();
        }
        Idle.add (() => {
            security_close_pending = false;
            if (windows != null) {
                foreach (unowned Instance app in windows.get_values ()) {
                    app.close_view ();
                }
            }
            return Source.REMOVE;
        });
    }

    /** Compile-time support plus the runtime settings toggle. */
    public bool enabled () {
        return config == null || config.webxdc_apps;
    }

    public class CardInfo {
        public string? name;
        public Gdk.Texture? icon;
    }

    private HashTable<int, CardInfo>? cards = null;

    /** App name and icon for the chat/gallery card, cached per message. */
    public async CardInfo card_info (int msg_id) {
        if (cards == null) {
            cards = new HashTable<int, CardInfo> (direct_hash, direct_equal);
        }
        var hit = cards.lookup (msg_id);
        if (hit != null) return hit;
        return yield fetch_card_info (msg_id);
    }

    private async CardInfo fetch_card_info (int msg_id) {
        var info = new CardInfo ();
        var rpc = client;
        if (rpc == null) return info;
        int acct = rpc.account_id;
        try {
            var res = yield rpc.call ("get_webxdc_info", Params.begin ()
                .add_int (acct).add_int (msg_id).build ());
            var obj = res.get_object ();
            var name = obj.get_string_member_with_default ("name", "");
            if (name.length > 0) info.name = name;
            var icon = obj.get_string_member_with_default ("icon", "");
            if (icon.length > 0) {
                var blob = yield rpc.call ("get_webxdc_blob", Params.begin ()
                    .add_int (acct).add_int (msg_id)
                    .add_string (icon).build ());
                info.icon = Gdk.Texture.from_bytes (
                    new Bytes (decode_rpc_blob (blob.get_string ())));
            }
        } catch (Error e) {
            debug ("webxdc card info: %s", e.message);
        }
        cards.replace (msg_id, info);
        return info;
    }

    public void open (Gtk.Window? parent, RpcClient rpc, Message msg) {
        if (!enabled () || security_close_pending) return;
#if !MACOS && !WINDOWS
        string sandbox_error;
        if (!linux_sandbox_available (out sandbox_error)) {
            if (parent != null) show_error (parent, sandbox_error);
            else warning ("%s", sandbox_error);
            return;
        }
#endif
        if (windows == null) {
            windows = new HashTable<string, Instance> (str_hash, str_equal);
        }
        var key = instance_key (rpc.account_id, msg.id);
        var existing = windows.lookup (key);
        if (existing != null) {
            // Native close callbacks may still own this window's user_data.
            if (!existing.closed) existing.present ();
            return;
        }
        windows.insert (key, new Instance (rpc, msg));
        Monitor.get_default ().changed (msg.id);
    }

#if !MACOS && !WINDOWS
    /* Ubuntu's AppArmor userns restriction moves an unprofiled process into
       the unprivileged_userns profile when WebKit starts bubblewrap. That
       profile cannot write bubblewrap's uid_map, and WebKit treats the helper
       failure as fatal. Detect this exact host state before creating a web
       process so an unpackaged build fails closed with an actionable error. */
    private bool linux_sandbox_available (out string message) {
        message = "";
        string restricted;
        string label;
        try {
            FileUtils.get_contents (
                "/proc/sys/kernel/apparmor_restrict_unprivileged_userns",
                out restricted);
            FileUtils.get_contents ("/proc/self/attr/current", out label);
        } catch (FileError e) {
            /* Kernels without Ubuntu's AppArmor knob need no Parla policy. */
            return true;
        }
        if (restricted.strip () != "1" || label.strip () != "unconfined") {
            return true;
        }
        message = _("Ubuntu AppArmor is blocking the user namespace required "
            + "by WebKitGTK's sandbox. Install this Webxdc build with "
            + "‘sudo make install’, then restart Parla. "
            + "Webxdc will not run without its web-engine sandbox.");
        return false;
    }
#endif

    public bool handle_event (RpcClient rpc, int account_id, string kind,
                              Json.Object event) {
        if (kind != "WebxdcStatusUpdate" && kind != "WebxdcInstanceDeleted")
            return false;
        var key = instance_key (account_id, (int) json_int (event, "msgId"));
        var app = windows == null ? null : windows.lookup (key);
        if (app != null && app.uses_client (rpc)) {
            if (kind == "WebxdcInstanceDeleted") app.close_view ();
            else if (!app.closed) app.pull_updates.begin ();
        }
        return true;
    }

    private class Instance : Object {
        /* Keep the originating client and profile even when another profile
           becomes active or the application's shared client is replaced. */
        private RpcClient rpc;
        private RealtimeSession? realtime;
        private ulong realtime_data_handler;
        private ulong realtime_error_handler;
        public bool closed { get; private set; default = false; }
        private int account_id;
        public int msg_id;
        private int chat_id;
        private int64 last_serial = 0;
        private string self_addr = "unknown";
        private string self_name = "me";
        private string app_name;
        private string document_name = "";
        private string? chat_name = null;
        private bool allow_internet = false;
        private bool allow_wasm = false;
        private bool allow_webgl = false;
        private bool allow_hardware_acceleration = false;
        private bool developer_tools = false;
        /* Whether follow-chat mode currently keeps the window hidden;
           tracked so mode/chat changes only touch window state on an
           actual transition (a plain show would un-minimize, say). */
        private bool hidden_by_follow = false;

        public Instance (RpcClient rpc, Message msg) {
            this.rpc = rpc;
            this.account_id = rpc.account_id;
            this.msg_id = msg.id;
            this.chat_id = msg.chat_id;
            this.app_name = msg.display_file_name ("Webxdc");
            if (config == null || config.webxdc_realtime) {
                realtime = new RealtimeSession (rpc, account_id, msg_id);
                realtime_data_handler = realtime.data_received.connect ((id, data) => {
                    var node = new Json.Node (Json.NodeType.ARRAY);
                    node.set_array (data);
                    eval_js ("window.__webxdc_realtime_receive(%s,%s)".printf (
                        js_str (id), Json.to_string (node, false)));
                });
                realtime_error_handler = realtime.channel_failed.connect ((id, message) => {
                    eval_js ("window.__webxdc_realtime_closed(%s,%s)".printf (
                        js_str (id), js_str (message)));
                });
            }
            if (config != null) {
                allow_internet = config.webxdc_allow_internet;
                allow_wasm = config.webxdc_allow_wasm;
                allow_webgl = config.webxdc_allow_webgl;
                allow_hardware_acceleration =
                    config.webxdc_allow_hardware_acceleration;
                developer_tools = config.webxdc_developer_tools;
            }
            create_view (app_name);
            present ();
            start.begin ();
        }

        /** Mirror the official Delta Chat clients: cut at max_len
            characters and append an ellipsis only when truncating. */
        private static string truncate_text (string text, int max_len) {
            if (max_len <= 0) return text;
            int end = text.index_of_nth_char (max_len);
            if (end < 0 || end >= text.length) return text;
            return "%s…".printf (text.slice (0, end));
        }

        /** "app – chat" (or "document - app – chat" for editing apps),
            exactly how the official clients build webxdc window titles.
            The chat is where the app's binding to a chat is visible. */
        private string compose_title () {
            var document = document_name != null && document_name.length > 0
                ? "%s - ".printf (truncate_text (document_name, 32))
                : "";
            var name = truncate_text (app_name, 42);
            return chat_name != null && chat_name.length > 0
                ? "%s%s – %s".printf (document, name, chat_name)
                : "%s%s".printf (document, name);
        }

        private async void start () {
            try {
                var info = yield rpc.call ("get_webxdc_info", Params.begin ()
                    .add_int (account_id).add_int (msg_id).build ());
                var obj = info.get_object ();
                var name = obj.get_string_member_with_default ("name", "");
                if (name.length > 0) app_name = name;
                document_name =
                    obj.get_string_member_with_default ("document", "");
                // Core supplies a stable identity for this Webxdc instance,
                // independent of which relay address the profile uses today.
                self_addr = obj.get_string_member_with_default ("selfAddr", "unknown");
            } catch (Error e) {
                warning ("webxdc info: %s", e.message);
            }
            if (closed) return;
            try {
                var chat = yield rpc.get_full_chat_by_id_for (account_id,
                                                              chat_id);
                if (chat != null) {
                    var name = chat.get_string_member_with_default ("name",
                                                                    "");
                    if (name.length > 0) chat_name = name;
                }
            } catch (Error e) {
                warning ("webxdc chat info: %s", e.message);
            }
            if (closed) return;
            set_view_title (compose_title ());
            try {
                var dn = yield rpc.get_config ("displayname", account_id);
                if (dn != null && dn.length > 0) self_name = dn;
                else self_name = (yield rpc.get_account_address (account_id)) ?? _("You");
            } catch (Error e) {
                warning ("webxdc config: %s", e.message);
            }
            if (!closed) load_view ("webxdc://app/index.html");
        }

        /* Everything the page loads is pulled out of the .xdc archive by
           deltachat core (get_webxdc_blob); nothing is read from disk or
           the network. webxdc.js itself is the one synthetic file. */
#if MACOS || WINDOWS
        private async void serve (string path, void* token) {
#else
        private async void serve (string path, WebKit.URISchemeRequest token) {
#endif
            string p = path.has_prefix ("/") ? path.substring (1) : path;
            if (p.length == 0) p = "index.html";
            if (Path.get_basename (p) == "webxdc.js") {
                deliver (token, bridge_js ().data, "text/javascript");
                return;
            }
            try {
                var res = yield rpc.call ("get_webxdc_blob", Params.begin ()
                    .add_int (account_id).add_int (msg_id)
                    .add_string (p).build ());
                var data = decode_rpc_blob (res.get_string ());
                bool uncertain;
                string ctype = ContentType.guess (p, data, out uncertain);
                string mime = ContentType.get_mime_type (ctype)
                    ?? "application/octet-stream";
                deliver (token, data, mime);
            } catch (Error e) {
                warning ("webxdc blob '%s': %s", path, e.message);
                if (!developer_tools && p == "index.html") {
                    var message = Markup.escape_text (e.message);
                    var html = """<!doctype html><meta charset="utf-8">
<title>%s</title>
<style>
html,body{height:100%%;margin:0}body{box-sizing:border-box;display:flex;
align-items:center;justify-content:center;padding:24px;background:#292929;
color:#222;font:14px system-ui,sans-serif}.dialog{box-sizing:border-box;
width:min(520px,100%%);max-height:80vh;overflow:auto;border-radius:12px;
padding:20px;background:#fff;box-shadow:0 12px 40px #0008}h1{font-size:18px;
margin:0 0 10px}pre{white-space:pre-wrap;overflow-wrap:anywhere;
font:12px ui-monospace,monospace}.hint{color:#555}
</style><main class="dialog" role="alert"><h1>%s</h1>
<pre>%s</pre><div class="hint">%s</div></main>""".printf (
                        Markup.escape_text (_("Webxdc app error")),
                        Markup.escape_text (_("This Webxdc app could not start")),
                        message, Markup.escape_text (error_diagnostics_hint ()));
                    deliver (token, html.data, "text/html");
                    return;
                }
                fail (token);
            }
        }

        private static string js_str (string s) {
            var node = new Json.Node (Json.NodeType.VALUE);
            node.set_string (s);
            return Json.to_string (node, false);
        }

        private static string error_diagnostics_hint () {
            return _("Enable Web developer tools in Settings → Advanced for full diagnostics.");
        }

        /* Without an inspector, a broken app would otherwise leave only a
           blank window and a warning in Parla's terminal log. Install this
           before the app's own code (webxdc.js is conventionally its first
           script) and show the first uncaught runtime or script-load error
           inside the app window. This is host UI, not window.alert(), so
           apps still cannot create arbitrary modal-dialog spam. */
        private string runtime_error_reporter_js () {
            if (developer_tools) return "";
            string labels = "{\"heading\":%s,\"unknown\":%s,\"hint\":%s," +
                "\"dismiss\":%s,\"loadFailed\":%s,\"rejected\":%s}";
            labels = labels.printf (
                js_str (_("This Webxdc app encountered an error")),
                js_str (_("Unknown JavaScript error")),
                js_str (error_diagnostics_hint ()), js_str (_("Dismiss")),
                js_str (_("Failed to load: ")),
                js_str (_("Unhandled promise rejection: ")));
            return "(function () {\n    'use strict';\n    var labels = " + labels + ";\n" + """
    var reported = false;
    function text(value) {
        if (value instanceof Error) return value.stack || value.message;
        if (typeof value === 'string') return value;
        try { return JSON.stringify(value); } catch (e) { return String(value); }
    }
    function show(message) {
        if (reported) return;
        reported = true;
        function render() {
            var shade = document.createElement('div');
            shade.setAttribute('role', 'alertdialog');
            shade.setAttribute('aria-modal', 'true');
            shade.style.cssText = 'position:fixed;inset:0;z-index:2147483647;'
                + 'display:flex;align-items:center;justify-content:center;'
                + 'padding:24px;background:rgba(0,0,0,.58);color:#222;'
                + 'font:14px system-ui,sans-serif';
            var box = document.createElement('div');
            box.style.cssText = 'box-sizing:border-box;width:min(520px,100%);'
                + 'max-height:80vh;overflow:auto;border-radius:12px;'
                + 'padding:20px;background:#fff;box-shadow:0 12px 40px #0008';
            var heading = document.createElement('div');
            heading.textContent = labels.heading;
            heading.style.cssText = 'font-size:18px;font-weight:700;margin-bottom:10px';
            var details = document.createElement('pre');
            details.textContent = message || labels.unknown;
            details.style.cssText = 'white-space:pre-wrap;overflow-wrap:anywhere;'
                + 'margin:0 0 12px;font:12px ui-monospace,monospace';
            var hint = document.createElement('div');
            hint.textContent = labels.hint;
            hint.style.cssText = 'margin-bottom:16px;color:#555';
            var close = document.createElement('button');
            close.textContent = labels.dismiss;
            close.style.cssText = 'float:right;padding:7px 14px';
            close.addEventListener('click', function () { shade.remove(); });
            box.append(heading, details, hint, close);
            shade.appendChild(box);
            (document.body || document.documentElement).appendChild(shade);
            close.focus();
        }
        if (document.readyState === 'loading')
            document.addEventListener('DOMContentLoaded', render, { once: true });
        else
            render();
    }
    window.addEventListener('error', function (event) {
        if (event.target && event.target !== window) {
            var tag = event.target.tagName || 'resource';
            var url = event.target.src || event.target.href || '';
            if (tag === 'SCRIPT')
                show(labels.loadFailed + tag.toLowerCase() + (url ? ': ' + url : ''));
            return;
        }
        var where = event.filename
            ? '\n' + event.filename + ':' + event.lineno + ':' + event.colno : '';
        show(text(event.error || event.message) + where);
    }, true);
    window.addEventListener('unhandledrejection', function (event) {
        show(labels.rejected + text(event.reason));
    });
})();
""";
        }

        /* The window.webxdc object and its optional realtime channel.
           De-duplicate serials so a pull racing an event push never delivers
           an update twice. */
        private string bridge_js () {
            string js = runtime_error_reporter_js () + """window.webxdc = (function () {
    'use strict';
    var handler = window.webkit.messageHandlers.webxdc;
    var listener = null;
    var last = 0;
    window.__webxdc_deliver = function (updates) {
        updates.forEach(function (u) {
            if (u.serial > last) {
                last = u.serial;
                if (listener) listener(u);
            }
        });
    };
    return {
        selfAddr: %s,
        selfName: %s,
        sendUpdate: function (update, description) {
            handler.postMessage(JSON.stringify({ type: 'send', update: update }));
        },
        setUpdateListener: function (cb, serial) {
            listener = cb;
            last = serial || 0;
            handler.postMessage(JSON.stringify({ type: 'pull', serial: last }));
            return Promise.resolve();
        }
    };
})();
""".printf (js_str (self_addr), js_str (self_name));
            if (realtime != null) {
                try {
                    var bytes = resources_lookup_data (
                        "/io/github/trufae/Parla/webxdc/webxdc-realtime.js",
                        ResourceLookupFlags.NONE);
                    js += (string) bytes.get_data ();
                } catch (Error e) {
                    warning ("webxdc realtime bridge: %s", e.message);
                }
            }
            return js;
        }

        private void on_message (string json) {
            if (closed || security_close_pending || !enabled ()) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json);
                if (parser.get_root ().get_node_type () != Json.NodeType.OBJECT) return;
                var obj = parser.get_root ().get_object ();
                var type = obj.get_member ("type");
                if (type == null || type.get_node_type () != Json.NodeType.VALUE
                        || type.get_value_type () != typeof (string)) return;
                var channel_node = obj.get_member ("channel");
                string? channel = channel_node != null
                    && channel_node.get_node_type () == Json.NodeType.VALUE
                    && channel_node.get_value_type () == typeof (string)
                    ? channel_node.get_string () : null;
                switch (type.get_string ()) {
                case "realtime-join":
                    if (realtime != null && channel != null) realtime.join (channel);
                    break;
                case "realtime-send":
                    if (realtime != null && channel != null)
                        realtime.send (channel, obj.get_member ("data"));
                    break;
                case "realtime-leave":
                    if (realtime != null && channel != null) realtime.leave (channel);
                    break;
                case "send":
                    var member = obj.get_member ("update");
                    if (member == null) break;
                    var update = Json.to_string (member, false);
                    rpc.call.begin ("send_webxdc_status_update",
                        Params.begin ().add_int (account_id).add_int (msg_id)
                            .add_string (update).add_string ("").build ());
                    break;
                case "pull":
                    last_serial = obj.get_int_member_with_default ("serial", 0);
                    pull_updates.begin ();
                    break;
                }
            } catch (Error e) {
                warning ("webxdc message: %s", e.message);
            }
        }

        /** Fetch status updates newer than last_serial and hand them to the
            page. Called on setUpdateListener and on core events. */
        public async void pull_updates () {
            if (closed) return;
            string updates;
            try {
                var res = yield rpc.call ("get_webxdc_status_updates",
                    Params.begin ().add_int (account_id).add_int (msg_id)
                        .add_int ((int) last_serial).build ());
                if (closed) return;
                updates = res.get_string ();
                var parser = new Json.Parser ();
                parser.load_from_data (updates);
                var arr = parser.get_root ().get_array ();
                if (arr.get_length () == 0) return;
                for (uint i = 0; i < arr.get_length (); i++) {
                    var item = arr.get_object_element (i);
                    int64 serial = item
                        .get_int_member_with_default ("serial", 0);
                    if (serial > last_serial) last_serial = serial;
                    var doc = item.get_member ("document");
                    if (doc != null
                        && doc.get_node_type () == Json.NodeType.VALUE) {
                        string d = doc.get_string ();
                        if (d != null && d.length > 0 && d != document_name) {
                            document_name = d;
                            set_view_title (compose_title ());
                        }
                    }
                }
            } catch (Error e) {
                warning ("webxdc updates: %s", e.message);
                return;
            }
            eval_js ("window.__webxdc_deliver(%s)".printf (updates));
        }

        private void on_view_closed () {
            closed = true;
            stop_realtime ();
            var key = instance_key (account_id, msg_id);
            if (windows != null && windows.lookup (key) == this) windows.remove (key);
            Monitor.get_default ().changed (msg_id);
        }

        public void stop_realtime () {
            if (realtime == null) return;
            realtime.disconnect (realtime_data_handler);
            realtime.disconnect (realtime_error_handler);
            realtime.close ();
            realtime = null;
        }

        public bool uses_client (RpcClient client) { return rpc == client; }

        public bool belongs_to (int account_id, int chat_id) {
            return this.account_id == account_id && this.chat_id == chat_id;
        }

        /** Re-evaluate follow-chat visibility against the chat the main
            window currently shows. Called when the global window-behavior
            setting changes and whenever window.vala reports a chat or
            visibility change. */
        public void apply_follow_visibility () {
            bool want_hidden = false;
            if (config != null && config.webxdc_follow_chat) {
                want_hidden = !(chat_window_visible
                    && account_id == active_account
                    && chat_id == active_chat);
            }
            if (want_hidden == hidden_by_follow) return;
            hidden_by_follow = want_hidden;
            set_view_visible (!want_hidden);
        }

#if MACOS || WINDOWS
        /* ============================================================
         *  Native-window view layer: each platform shim owns its window
         *  and browser state behind an opaque handle.
         * ============================================================ */

        [CCode (has_target = false)]
        private delegate void RawBlobFn (string path, void* task,
                                         void* user_data);
        [CCode (has_target = false)]
        private delegate void RawMsgFn (string json, void* user_data);
        [CCode (has_target = false)]
        private delegate void RawClosedFn (void* user_data);

        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_open")]
        private static extern void* shim_open (string title, RawBlobFn blob,
                                               RawMsgFn message,
                                               RawClosedFn closed,
                                               bool allow_internet,
                                               bool allow_wasm,
                                               bool allow_webgl,
                                               bool developer_tools,
                                               void* user_data);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_load")]
        private static extern void shim_load (void* handle, string uri);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_finish_task")]
        private static extern void shim_finish_task (void* handle, void* task,
                                                     uint8[] data,
                                                     string mime);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_fail_task")]
        private static extern void shim_fail_task (void* handle, void* task);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_eval_js")]
        private static extern void shim_eval_js (void* handle, string js);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_set_title")]
        private static extern void shim_set_title (void* handle, string title);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_present")]
        private static extern void shim_present (void* handle);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_minimize")]
        private static extern void shim_minimize (void* handle);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_set_visible")]
        private static extern void shim_set_visible (void* handle,
                                                     bool visible);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_close")]
        private static extern void shim_close (void* handle);
        [CCode (cheader_filename = "webxdc_platform.h",
                cname = "parla_webxdc_free")]
        private static extern void shim_free (void* handle);

        private void* handle = null;

        /* The shim callbacks carry no closure; user_data is this instance,
           kept alive by the windows table until on_view_closed. */
        private static void on_raw_blob (string path, void* task,
                                         void* user_data) {
            unowned Instance self = (Instance) user_data;
            self.serve.begin (path, task);
        }

        private static void on_raw_message (string json, void* user_data) {
            unowned Instance self = (Instance) user_data;
            self.on_message (json);
        }

        private static void on_raw_closed (void* user_data) {
            var self = (Instance) user_data;
            var h = self.handle;
            self.handle = null;
            if (h != null) shim_free (h);
            self.on_view_closed ();
        }

        private void create_view (string title) {
            handle = shim_open (title, on_raw_blob, on_raw_message,
                                on_raw_closed, allow_internet, allow_wasm,
                                allow_webgl, developer_tools, this);
        }

        public void present () {
            if (handle != null) shim_present (handle);
        }

        /* Native shims can query their own window's minimized state. */
        public void toggle_minimize_view () {
            if (handle != null) shim_minimize (handle);
        }

        private void set_view_visible (bool visible) {
            if (handle != null) shim_set_visible (handle, visible);
        }

        private void load_view (string uri) {
            if (handle != null) shim_load (handle, uri);
        }

        private void set_view_title (string title) {
            if (handle != null) shim_set_title (handle, title);
        }

        private void eval_js (string js) {
            if (!closed && handle != null) shim_eval_js (handle, js);
        }

        /* A blob fetch may complete after the window is gone; the null
           handle drops it (the shim released the task on teardown). */
        private void deliver (void* token, uint8[] data, string mime) {
            if (handle != null) shim_finish_task (handle, token, data, mime);
        }

        private void fail (void* token) {
            if (handle != null) shim_fail_task (handle, token);
        }

        public void close_view () {
            closed = true;
            stop_realtime ();
            if (handle != null) shim_close (handle);
        }
#else
        /* ============================================================
         *  View layer, GNOME: Adw.Window + WebKitGTK.
         * ============================================================ */

        private Adw.Window? win = null;
        private WebKit.WebView view;

        private void create_view (string title) {
            win = new Adw.Window ();
            win.title = title;
            win.default_width = 420;
            win.default_height = 640;

            var ucm = new WebKit.UserContentManager ();
            ucm.register_script_message_handler ("webxdc", (string) null);
            ucm.script_message_received["webxdc"].connect ((value) => {
                on_message (value.to_string ());
            });

            var ctx = new WebKit.WebContext ();
            ctx.register_uri_scheme ("webxdc", (req) => {
                serve.begin (req.get_path () ?? "", req);
            });
            /* Secure, but NOT register_uri_scheme_as_local: "local" gives
               documents file:-like treatment with an opaque origin, which
               fails every CORS-mode fetch — e.g. <script type="module"
               crossorigin> as emitted by Vite builds — leaving such apps
               on a blank page. Plain webxdc: documents keep a proper
               origin, and this context serves no other scheme anyway. */
            var sec = ctx.get_security_manager ();
            sec.register_uri_scheme_as_secure ("webxdc");

            /* No cookies/cache on disk. The safe default adds a blackhole
               proxy so http(s) dies before reaching the network; the unsafe
               opt-in leaves the ephemeral session directly connected.
               webxdc: URIs are served in-process and unaffected. */
            var session = new WebKit.NetworkSession.ephemeral ();
            if (!allow_internet) {
                session.set_proxy_settings (WebKit.NetworkProxyMode.CUSTOM,
                    new WebKit.NetworkProxySettings ("socks5://127.0.0.1:1",
                                                     null));
            }

            view = (WebKit.WebView) GLib.Object.new (typeof (WebKit.WebView),
                "web-context", ctx,
                "network-session", session,
                "user-content-manager", ucm);
            var s = view.get_settings ();
            s.enable_developer_extras = developer_tools;
            s.allow_modal_dialogs = false;
            s.javascript_can_open_windows_automatically = false;
            /* The proxy covers URL loads; WebRTC can create direct UDP
               transports outside it. */
            s.enable_webrtc = allow_internet;
            s.enable_webgl = allow_webgl;
            s.hardware_acceleration_policy = allow_hardware_acceleration
                ? WebKit.HardwareAccelerationPolicy.ALWAYS
                : WebKit.HardwareAccelerationPolicy.NEVER;
            view.decide_policy.connect (on_decide_policy);
            if (developer_tools) {
                bool inspector_opened = false;
                view.load_changed.connect ((event) => {
                    if (event == WebKit.LoadEvent.FINISHED
                        && !inspector_opened) {
                        inspector_opened = true;
                        view.get_inspector ().show ();
                    }
                });
            }
            view.vexpand = true;

            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (new Adw.HeaderBar ());
            toolbar.content = view;
            win.content = toolbar;
            win.close_request.connect (() => {
                win = null;
                on_view_closed ();
                return false;
            });
        }

        /* The app may only navigate inside its own scheme; anything else
           (http links, window.open) is refused. */
        private bool on_decide_policy (WebKit.PolicyDecision decision,
                                       WebKit.PolicyDecisionType type) {
            if (type == WebKit.PolicyDecisionType.NAVIGATION_ACTION
                || type == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION) {
                var nav = (WebKit.NavigationPolicyDecision) decision;
                var uri = nav.navigation_action.get_request ().get_uri ();
                if (!uri.has_prefix ("webxdc:")) {
                    decision.ignore ();
                    return true;
                }
            }
            return false;
        }

        /* Wayland never reports the minimized state back, so remember
           what the bar did; the surface state covers the backends that
           do report it (and users unminimizing through the WM there). */
        private bool minimized_by_bar = false;

        public void present () {
            minimized_by_bar = false;
            if (win != null) win.present ();
        }

        public void toggle_minimize_view () {
            if (win == null) return;
            bool minimized = minimized_by_bar;
            var toplevel = win.get_surface () as Gdk.Toplevel;
            if (toplevel != null
                && (toplevel.state & Gdk.ToplevelState.MINIMIZED) != 0) {
                minimized = true;
            }
            if (minimized) {
                minimized_by_bar = false;
                win.present ();
            } else {
                minimized_by_bar = true;
                win.minimize ();
            }
        }

        private void set_view_visible (bool visible) {
            if (win != null) win.set_visible (visible);
        }

        private void load_view (string uri) {
            view.load_uri (uri);
        }

        private void set_view_title (string title) {
            if (win != null) win.title = title;
        }

        private void eval_js (string js) {
            if (!closed) view.evaluate_javascript.begin (js, -1, null, null, null);
        }

        private void deliver (WebKit.URISchemeRequest token, uint8[] data,
                              string mime) {
            var stream = new MemoryInputStream.from_bytes (new Bytes (data));
            var csp = WebxdcSecurity.wasm_csp (allow_wasm);
            if (csp == null) {
                token.finish (stream, data.length, mime);
                return;
            }
            var response = new WebKit.URISchemeResponse (stream, data.length);
            response.set_content_type (mime);
            var headers = new Soup.MessageHeaders (
                Soup.MessageHeadersType.RESPONSE);
            headers.append ("Content-Security-Policy", csp);
            response.set_http_headers ((owned) headers);
            token.finish_with_response (response);
        }

        private void fail (WebKit.URISchemeRequest token) {
            token.finish_error (new IOError.NOT_FOUND ("webxdc blob"));
        }

        public void close_view () {
            closed = true;
            stop_realtime ();
            if (win != null) win.close ();
        }
#endif
    }
}
