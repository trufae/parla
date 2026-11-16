using Dc.Webxdc;

/* This executable deliberately has no dependency on parla-core, account
 * storage, settings, or RPC. Native task pointers never cross IPC. */
private class Helper : Object {
    [CCode (has_target = false)] private delegate void BlobFn (string path, void* task, void* data);
    [CCode (has_target = false)] private delegate void MessageFn (string json, void* data);
    [CCode (has_target = false)] private delegate void ClosedFn (void* data);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_open")]
    private static extern void* open_view (string title, BlobFn blob, MessageFn message,
        ClosedFn closed, bool internet, bool wasm, bool webgl, bool developer, void* data);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_load")]
    private static extern void load (void* view, string uri);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_eval_js")]
    private static extern void eval (void* view, string js);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_set_title")]
    private static extern void title (void* view, string text);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_present")]
    private static extern void present (void* view);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_minimize")]
    private static extern void minimize (void* view);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_set_visible")]
    private static extern void visible (void* view, bool show);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_finish_task")]
    private static extern void finish (void* view, void* task, uint8[] data, string mime);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_fail_task")]
    private static extern void fail (void* view, void* task);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_free")]
    private static extern void free_view (void* view);
    [CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_set_acceleration")]
    private static extern void acceleration (void* view, bool enabled);

    private Wire wire;
    private void* view;
    private int64 serial = 0;
    private HashTable<int64?, void*> tasks = new HashTable<int64?, void*> (int64_hash, int64_equal);
    private bool internet;

    public Helper (InputStream input, OutputStream output, bool internet) {
        this.internet = internet;
        wire = new Wire (input, output);
        wire.received.connect (receive);
        wire.ended.connect (() => { quit (); });
        var hello = Wire.packet ("ready");
        hello.set_int_member ("version", Wire.VERSION);
        hello.set_boolean_member ("internet", internet);
        wire.send (hello);
        wire.read.begin ();
    }

    private static void on_blob (string path, void* task, void* data) {
        unowned Helper self = (Helper) data;
        if (self.tasks.size () >= Wire.MAX_RESOURCES || !Wire.resource_path (path)) {
            fail (self.view, task);
            return;
        }
        int64 id = ++self.serial;
        self.tasks.insert (id, task);
        var obj = Wire.packet ("blob");
        obj.set_int_member ("id", id);
        obj.set_string_member ("path", path);
        self.wire.send (obj);
    }

    private static void on_message (string json, void* data) {
        unowned Helper self = (Helper) data;
        if (json.length > Wire.MAX_MESSAGE) { self.wire.stop ("Oversized app message"); return; }
        var obj = Wire.packet ("message");
        obj.set_string_member ("json", json);
        self.wire.send (obj);
    }

    private static void on_closed (void* data) {
        // EOF closes the parent's instance even if the final write is pending.
        quit ();
    }

    private void receive (Json.Object obj) {
        try {
            string op = Wire.text (obj, "op", 32);
            if (view == null) {
                if (op != "open" || Wire.flag (obj, "internet") != internet)
                    throw new IOError.INVALID_DATA ("Invalid Webxdc launch policy");
                view = open_view (Wire.text (obj, "title", 4096), on_blob, on_message,
                    on_closed, internet, Wire.flag (obj, "wasm"), Wire.flag (obj, "webgl"),
                    Wire.flag (obj, "developer"), this);
                if (view == null) throw new IOError.FAILED ("Cannot create Webxdc view");
                acceleration (view, Wire.flag (obj, "acceleration"));
                return;
            }
            switch (op) {
            case "load":
                if (Wire.text (obj, "value", 4096) != "webxdc://app/index.html")
                    throw new IOError.INVALID_DATA ("Invalid start URI");
                load (view, "webxdc://app/index.html"); break;
            case "eval": eval (view, Wire.text (obj, "value", Wire.MAX_FRAME)); break;
            case "title": title (view, Wire.text (obj, "value", 4096)); break;
            case "present": present (view); break;
            case "minimize": minimize (view); break;
            case "show": visible (view, true); break;
            case "hide": visible (view, false); break;
            case "resource":
            case "missing":
                int64 id = Wire.number (obj, "id");
                void* task = tasks.lookup (id);
                if (task == null) throw new IOError.INVALID_DATA ("Unknown resource response");
                tasks.remove (id);
                if (op == "missing") fail (view, task);
                else {
                    string encoded = Wire.text (obj, "data", Wire.MAX_FRAME);
                    string mime = Wire.text (obj, "mime", 256);
                    if (mime.contains ("\r") || mime.contains ("\n"))
                        throw new IOError.INVALID_DATA ("Invalid MIME type");
                    finish (view, task, Base64.decode (encoded), mime);
                }
                break;
            default: throw new IOError.INVALID_DATA ("Unknown host operation");
            }
        } catch (Error e) { wire.stop (e.message); }
    }

    public void shutdown () {
        wire.stop ();
        if (view != null) { free_view (view); view = null; }
    }
}

[CCode (cheader_filename = "webxdc_sandbox.h", cname = "parla_webxdc_helper_stdio")]
private extern void stdio (out InputStream input, out OutputStream output);
[CCode (cheader_filename = "webxdc_sandbox.h", cname = "parla_webxdc_helper_init")]
private extern void initialize (bool internet);
[CCode (cheader_filename = "webxdc_sandbox.h", cname = "parla_webxdc_helper_run")]
private extern void run ();
[CCode (cheader_filename = "webxdc_sandbox.h", cname = "parla_webxdc_helper_quit")]
private extern void quit ();

int main (string[] args) {
    if (args.length != 2 || (args[1] != "offline" && args[1] != "online")) return 2;
    initialize (args[1] == "online");
    InputStream input;
    OutputStream output;
    stdio (out input, out output);
    var helper = new Helper (input, output, args[1] == "online");
    run ();
    helper.shutdown ();
    return 0;
}
