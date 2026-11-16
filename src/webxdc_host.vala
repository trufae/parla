namespace Dc.Webxdc {
    /* The application's only interface to the web engine. All platform
     * code here is confined to the sandbox launcher, never to the caller. */
    internal class Host : Object {
        [CCode (cheader_filename = "webxdc_sandbox.h", cname = "parla_webxdc_sandbox_launch")]
        private static extern void* launch (string helper, bool internet, bool acceleration, bool wasm,
            out InputStream input, out OutputStream output) throws Error;
        [CCode (cheader_filename = "webxdc_sandbox.h", cname = "parla_webxdc_sandbox_stop")]
        private static extern void terminate (void* process);

        private void* process;
        private Wire wire;
        private Json.Object policy;
        private Queue<Json.Object> pending = new Queue<Json.Object> ();
        private HashTable<int64?, bool> resources = new HashTable<int64?, bool> (int64_hash, int64_equal);
        private bool ready = false;
        private size_t pending_bytes = 0;
        private uint startup_timeout;
        private ulong received_handler;
        private ulong ended_handler;
        public signal void blob (string path, int64 id);
        public signal void message (string json);
        public signal void closed (string? reason);

        public Host (string title, bool internet, bool wasm, bool webgl,
                     bool acceleration, bool developer) throws Error {
            string? executable = Platform.get_executable_path ();
            if (executable == null) throw new IOError.NOT_FOUND ("Cannot locate Webxdc helper");
            string helper = Path.build_filename (Path.get_dirname (executable), "parla-webxdc");
#if WINDOWS
            helper += ".exe";
#endif
            InputStream input;
            OutputStream output;
            process = launch (helper, internet, acceleration, wasm, out input, out output);
            wire = new Wire (input, output, 2 * Wire.MAX_MESSAGE + 1024);
            policy = Wire.packet ("open");
            policy.set_string_member ("title", title);
            policy.set_boolean_member ("internet", internet);
            policy.set_boolean_member ("wasm", wasm);
            policy.set_boolean_member ("webgl", webgl);
            policy.set_boolean_member ("acceleration", acceleration);
            policy.set_boolean_member ("developer", developer);
            received_handler = wire.received.connect (receive);
            ended_handler = wire.ended.connect ((reason) => {
                if (startup_timeout != 0) { Source.remove (startup_timeout); startup_timeout = 0; }
                if (process != null) { terminate (process); process = null; }
                resources.remove_all ();
                pending = new Queue<Json.Object> ();
                pending_bytes = 0;
                wire.disconnect (received_handler);
                wire.disconnect (ended_handler);
                closed (!ready && reason == null ? "Webxdc sandbox exited before startup" : reason);
            });
            startup_timeout = Timeout.add_seconds (20, () => {
                startup_timeout = 0;
                wire.stop ("Webxdc sandbox did not start");
                return Source.REMOVE;
            });
            wire.read.begin ();
        }

        private void receive (Json.Object obj) {
            try {
                string op = Wire.text (obj, "op", 32);
                if (!ready) {
                    if (op != "ready" || Wire.number (obj, "version") != Wire.VERSION
                        || Wire.flag (obj, "internet") != Wire.flag (policy, "internet"))
                        throw new IOError.INVALID_DATA ("Invalid Webxdc handshake");
                    ready = true;
                    Source.remove (startup_timeout);
                    startup_timeout = 0;
                    wire.send (policy);
                    while (!pending.is_empty ()) wire.send (pending.pop_head ());
                    pending_bytes = 0;
                    return;
                }
                switch (op) {
                case "blob":
                    int64 id = Wire.number (obj, "id");
                    string path = Wire.text (obj, "path", 4096);
                    if (id <= 0 || resources.contains (id) || resources.size () >= Wire.MAX_RESOURCES
                        || !Wire.resource_path (path))
                        throw new IOError.INVALID_DATA ("Invalid Webxdc resource request");
                    resources.insert (id, true);
                    blob (path, id);
                    break;
                case "message": message (Wire.text (obj, "json")); break;
                case "closed": wire.stop (); break;
                case "error": wire.stop (Wire.text (obj, "message", 4096)); break;
                default: throw new IOError.INVALID_DATA ("Unknown Webxdc operation");
                }
            } catch (Error e) { wire.stop (e.message); }
        }

        private void send (Json.Object obj) {
            if (wire.stopped) return;
            if (ready) wire.send (obj);
            else {
                var node = new Json.Node (Json.NodeType.OBJECT);
                node.set_object (obj);
                pending_bytes += Json.to_string (node, false).length;
                if (pending.get_length () < 64 && pending_bytes <= 2 * Wire.MAX_FRAME)
                    pending.push_tail (obj);
                else wire.stop ("Too many commands before Webxdc startup");
            }
        }

        public void command (string op, string? value = null) {
            var obj = Wire.packet (op);
            if (value != null) obj.set_string_member ("value", value);
            send (obj);
        }

        public void deliver (int64 id, uint8[]? data, string? mime = null) {
            if (!resources.remove (id) || wire.stopped) return;
            var obj = Wire.packet (data != null ? "resource" : "missing");
            obj.set_int_member ("id", id);
            if (data != null) {
                if (data.length > 16 * 1024 * 1024) { deliver_missing (id); return; }
                obj.set_string_member ("data", Base64.encode (data));
                obj.set_string_member ("mime", mime ?? "application/octet-stream");
            }
            send (obj);
        }

        private void deliver_missing (int64 id) {
            var obj = Wire.packet ("missing");
            obj.set_int_member ("id", id);
            send (obj);
        }

        public void close (string? reason = null) { wire.stop (reason); }
    }
}
