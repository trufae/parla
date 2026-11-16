/* Private, versioned IPC. Neither endpoint exposes a general RPC service.
 * Lengths are checked before allocation; writes and outstanding resources
 * are bounded so an unresponsive or compromised helper cannot grow queues. */
namespace Dc.Webxdc {
    internal class Wire : Object {
        public const int VERSION = 1;
        public const int MAX_FRAME = 24 * 1024 * 1024;
        // A maximum-size realtime packet expands to about 512 KB as a JSON byte
        // array. Keep that supported while bounding arbitrary bridge input.
        public const int MAX_MESSAGE = 1024 * 1024;
        public const int MAX_RESOURCES = 32;
        private InputStream input;
        private OutputStream output;
        private Cancellable cancel = new Cancellable ();
        private Queue<Bytes> queue = new Queue<Bytes> ();
        private size_t queued = 0;
        private bool writing = false;
        private int receive_limit;
        public bool stopped { get; private set; default = false; }
        public signal void received (Json.Object message);
        public signal void ended (string? reason);

        public Wire (InputStream input, OutputStream output, int receive_limit = MAX_FRAME) {
            this.input = input;
            this.output = output;
            this.receive_limit = receive_limit;
        }

        public static Json.Object packet (string op) {
            var obj = new Json.Object ();
            obj.set_string_member ("op", op);
            return obj;
        }

        public static string text (Json.Object obj, string key, int limit = MAX_MESSAGE) throws Error {
            var node = obj.get_member (key);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE
                || node.get_value_type () != typeof (string))
                throw new IOError.INVALID_DATA ("Missing string: %s", key);
            string value = node.get_string ();
            if (value.length > limit)
                throw new IOError.INVALID_DATA ("Oversized string: %s", key);
            return value;
        }

        public static int64 number (Json.Object obj, string key) throws Error {
            var node = obj.get_member (key);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE
                || node.get_value_type () != typeof (int64))
                throw new IOError.INVALID_DATA ("Missing integer: %s", key);
            return node.get_int ();
        }

        public static bool flag (Json.Object obj, string key) throws Error {
            var node = obj.get_member (key);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE
                || node.get_value_type () != typeof (bool))
                throw new IOError.INVALID_DATA ("Missing boolean: %s", key);
            return node.get_boolean ();
        }

        public static bool resource_path (string path) {
            if (path.length == 0 || path.length > 4096 || path.contains ("\\")
                || path.contains (":") || !path.validate ()) return false;
            string relative = path.has_prefix ("/") ? path.substring (1) : path;
            foreach (string part in relative.split ("/")) {
                if (part == "." || part == "..") return false;
            }
            return !relative.has_prefix ("/");
        }

        public void send (Json.Object obj) {
            if (stopped) return;
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (obj);
            string json = Json.to_string (node, false);
            uint length = json.length;
            if (length > MAX_FRAME || queued + length + 4 > 2 * MAX_FRAME) {
                stop ("Webxdc IPC queue limit exceeded");
                return;
            }
            uint8[] frame = new uint8[length + 4];
            for (int i = 0; i < 4; i++) frame[i] = (uint8) (length >> (24 - i * 8));
            Memory.copy ((uint8*) frame + 4, json.data, length);
            queue.push_tail (new Bytes.take ((owned) frame));
            queued += length + 4;
            if (!writing) write.begin ();
        }

        private async void write () {
            writing = true;
            try {
                while (!stopped && !queue.is_empty ()) {
                    var frame = queue.pop_head ();
                    size_t count;
                    yield output.write_all_async (frame.get_data (), Priority.DEFAULT, cancel, out count);
                    if (!stopped) queued -= frame.get_size ();
                }
            } catch (Error e) { stop (e.message); }
            writing = false;
        }

        public async void read () {
            try {
                while (!stopped) {
                    uint8[] header = new uint8[4];
                    size_t count;
                    yield input.read_all_async (header, Priority.DEFAULT, cancel, out count);
                    if (count == 0) { stop (null); return; }
                    uint length = 0;
                    foreach (uint8 byte in header) length = (length << 8) | byte;
                    if (count != 4 || length == 0 || length > receive_limit)
                        throw new IOError.INVALID_DATA ("Invalid Webxdc IPC frame");
                    uint8[] body = new uint8[length + 1];
                    yield input.read_all_async (body[0:length], Priority.DEFAULT, cancel, out count);
                    if (count != length || !((string) body).validate ((ssize_t) length)
                        || ((string) body).length != length)
                        throw new IOError.INVALID_DATA ("Invalid Webxdc IPC body");
                    var parser = new Json.Parser ();
                    parser.load_from_data ((string) body, length);
                    if (parser.get_root ().get_node_type () != Json.NodeType.OBJECT)
                        throw new IOError.INVALID_DATA ("Expected Webxdc IPC object");
                    received (parser.get_root ().get_object ());
                }
            } catch (Error e) { stop (e.message); }
        }

        public void stop (string? reason = null) {
            if (stopped) return;
            stopped = true;
            cancel.cancel ();
            // Queue.clear() drops links without releasing owned elements.
            queue = new Queue<Bytes> ();
            queued = 0;
            input.close_async.begin ();
            output.close_async.begin ();
            ended (reason);
        }
    }
}
