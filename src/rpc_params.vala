namespace Dc {

    /**
     * Fluent builder for JSON-RPC params arrays.
     */
    public class Params : Object {
        private Json.Builder b;

        private Params () {
            b = new Json.Builder ();
            b.begin_array ();
        }

        public static Params begin () {
            return new Params ();
        }

        public Params add_int (int v) {
            b.add_int_value (v);
            return this;
        }

        public Params add_string (string? v) {
            if (v != null) b.add_string_value (v);
            else b.add_null_value ();
            return this;
        }

        public Params add_bool (bool v) {
            b.add_boolean_value (v);
            return this;
        }

        public Params add_null () {
            b.add_null_value ();
            return this;
        }

        public Params add_int_array (int[] values) {
            b.begin_array ();
            foreach (int v in values) b.add_int_value (v);
            b.end_array ();
            return this;
        }

        public Params add_string_array (string[] values) {
            b.begin_array ();
            foreach (string v in values) b.add_string_value (v);
            b.end_array ();
            return this;
        }

        public Params add_json_array (Json.Array arr) {
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.set_array (arr);
            b.add_value (node);
            return this;
        }

        public Params begin_object () {
            b.begin_object ();
            return this;
        }

        public Params end_object () {
            b.end_object ();
            return this;
        }

        public Params set_string_member (string name, string? value) {
            b.set_member_name (name);
            if (value != null) b.add_string_value (value);
            else b.add_null_value ();
            return this;
        }

        public Params set_int_member (string name, int value) {
            b.set_member_name (name);
            b.add_int_value (value);
            return this;
        }

        /** Adds an integer member, or null when the value is not positive. */
        public Params set_opt_int_member (string name, int value) {
            b.set_member_name (name);
            if (value > 0) b.add_int_value (value);
            else b.add_null_value ();
            return this;
        }

        public Params set_null_member (string name) {
            b.set_member_name (name);
            b.add_null_value ();
            return this;
        }

        public Json.Node build () {
            b.end_array ();
            return b.get_root ();
        }
    }
}
