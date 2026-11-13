namespace Parla.Terminal {
    /** Prefix completion with a common-prefix first step and subsequent cycling.
     * Applications provide command names, options and other candidates. */
    public class Completion : Object {
        private Editor? previous_editor;
        private string previous_text = "";
        private int previous_cursor = -1;
        private string[] matches = {};
        private int selected = -1;
        public string hint { get; private set; default = ""; }

        public void reset () { previous_editor = null; matches = {}; hint = ""; }

        public static int mention_start (string prefix) {
            int start = prefix.last_index_of ("@");
            if (start < 0 || (start > 0 && prefix[start - 1] != ' ' && prefix[start - 1] != '\n' && prefix[start - 1] != '\t')) return -1;
            return prefix.substring (start).contains ("\n") ? -1 : start;
        }

        public void complete (Editor editor, string[] candidates, bool backwards = false) {
            bool cycling = previous_editor == editor && previous_text == editor.text && previous_cursor == editor.cursor;
            if (!cycling) {
                matches = {};
                selected = -1;
                string prefix = editor.text.substring (0, editor.cursor);
                bool command = prefix.has_prefix ("/") && !prefix.has_prefix ("//") && !prefix.contains ("\n");
                if (!command && mention_start (prefix) < 0) {
                    reset ();
                    return;
                }
                foreach (var candidate in candidates)
                    if (candidate.casefold ().has_prefix (prefix.casefold ())) matches += candidate;
                if (matches.length == 0) { reset (); hint = "No matching commands or options"; return; }
                string common = matches[0];
                foreach (var match in matches) {
                    int length = int.min (common.length, match.length), i = 0;
                    while (i < length && common[i] == match[i]) i++;
                    while (i > 0 && i < common.length && (common[i] & 0xc0) == 0x80) i--;
                    common = common.substring (0, i);
                }
                if (matches.length == 1) {
                    selected = 0;
                    editor.replace_prefix (matches[0] + (editor.cursor < editor.text.length && editor.text[editor.cursor] == ' ' ? "" : " "));
                } else if (common.length > prefix.length) editor.replace_prefix (common);
            } else if (matches.length > 0) {
                selected = selected < 0 ? (backwards ? matches.length - 1 : 0) :
                    (selected + (backwards ? matches.length - 1 : 1)) % matches.length;
                editor.replace_prefix (matches[selected] + (editor.cursor < editor.text.length && editor.text[editor.cursor] == ' ' ? "" : " "));
            }
            hint = matches.length > 1 ? string.joinv ("  ", matches) : "";
            previous_editor = editor;
            previous_text = editor.text;
            previous_cursor = editor.cursor;
        }
    }
}
