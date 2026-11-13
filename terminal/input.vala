namespace Parla.Terminal {
    public enum Key {
        TEXT, ENTER, NEWLINE, LEFT, RIGHT, UP, DOWN, HOME, END, BACKSPACE,
        DELETE, PAGE_UP, PAGE_DOWN, NEXT_TAB, PREVIOUS_TAB, FOCUS, QUIT,
        REDRAW, ESCAPE, CLOSE_TAB, COMPLETE, COMPLETE_PREVIOUS,
        HISTORY_PREVIOUS, HISTORY_NEXT, CLEAR_INPUT, DELETE_WORD, SELECT_TAB
    }

    public enum MouseButton { LEFT, MIDDLE, RIGHT, WHEEL_UP, WHEEL_DOWN }

    /** Zero-based terminal coordinates. Only button/wheel reports are tracked. */
    public class MouseEvent : Object {
        public MouseButton button { get; construct; }
        public int x { get; construct; }
        public int y { get; construct; }
        public bool pressed { get; construct; }
        public bool motion { get; construct; }

        public MouseEvent (MouseButton button, int x, int y, bool pressed = true, bool motion = false) {
            Object (button: button, x: x, y: y, pressed: pressed, motion: motion);
        }
    }

    /** Incremental UTF-8 / VT input decoder. Paste is one text event, never a
     * sequence of commands, even when it contains newlines or control bytes. */
    public class Input : Object {
        public signal void key (Key code, string text);
        public signal void mouse (MouseEvent event);
        private string pending = "";
        private StringBuilder pasted = new StringBuilder ();
        private bool pasting = false;
        public bool waiting_escape { get { return !pasting && pending == "\033"; } }

        public void feed (uint8[] bytes) {
            var data = new StringBuilder (pending);
            foreach (uint8 b in bytes) if (b != 0) data.append_c ((char) b);
            pending = data.str;
            decode ();
        }

        public void flush_escape () {
            if (waiting_escape) { pending = ""; key (Key.ESCAPE, ""); }
        }

        private void mouse_sequence (string sequence) {
            char final = sequence[sequence.length - 1];
            if (final != 'M' && final != 'm') return;
            string[] parts = sequence.substring (1, sequence.length - 2).split (";");
            int button = 0, x = 0, y = 0;
            if (parts.length != 3 || !int.try_parse (parts[0], out button) ||
                !int.try_parse (parts[1], out x) || !int.try_parse (parts[2], out y)) return;
            if (button < 0 || button > 127 || x <= 0 || y <= 0) return;
            MouseButton code;
            switch (button & 67) {
            case 0: code = MouseButton.LEFT; break;
            case 1: code = MouseButton.MIDDLE; break;
            case 2: code = MouseButton.RIGHT; break;
            case 64: code = MouseButton.WHEEL_UP; break;
            case 65: code = MouseButton.WHEEL_DOWN; break;
            default: return;
            }
            mouse (new MouseEvent (code, x - 1, y - 1, final == 'M', (button & 32) != 0));
        }

        private void decode () {
            while (pending.length > 0) {
                if (pasting) {
                    int end = pending.index_of ("\033[201~");
                    int take = end < 0 ? int.max (0, pending.length - 5) : end;
                    int room = 65536 - (int) pasted.len;
                    if (room > 0) pasted.append_len (pending, int.min (take, room));
                    pending = pending.substring (take);
                    if (end < 0) return;
                    pending = pending.substring (6);
                    pasting = false;
                    key (Key.TEXT, pasted.str.make_valid ().replace ("\r\n", "\n").replace ("\r", "\n"));
                    pasted.truncate (0);
                    continue;
                }
                if (pending[0] == 27) {
                    if (pending.length == 1) return;
                    if (pending[1] == '\r' || pending[1] == '\n') {
                        pending = pending.substring (2); key (Key.NEWLINE, ""); continue;
                    }
                    if (pending[1] >= '0' && pending[1] <= '9') {
                        string number = pending.substring (1, 1);
                        pending = pending.substring (2); key (Key.SELECT_TAB, number); continue;
                    }
                    if (pending[1] == 'x') {
                        pending = pending.substring (2); key (Key.CLOSE_TAB, ""); continue;
                    }
                    if (pending[1] == '[' || pending[1] == 'O') {
                        int end = 2;
                        while (end < pending.length && !(pending[end] >= 0x40 && pending[end] <= 0x7e)) end++;
                        if (end == pending.length) {
                            if (pending.length > 64) pending = "";
                            return;
                        }
                        string sequence = pending.substring (2, end - 1);
                        pending = pending.substring (end + 1);
                        if (sequence.has_prefix ("<")) {
                            mouse_sequence (sequence);
                            continue;
                        }
                        switch (sequence) {
                        case "200~": pasting = true; break;
                        case "A": key (Key.UP, ""); break;
                        case "B": key (Key.DOWN, ""); break;
                        case "C": key (Key.RIGHT, ""); break;
                        case "D": key (Key.LEFT, ""); break;
                        case "H": case "1~": case "7~": key (Key.HOME, ""); break;
                        case "F": case "4~": case "8~": key (Key.END, ""); break;
                        case "3~": key (Key.DELETE, ""); break;
                        case "5~": key (Key.PAGE_UP, ""); break;
                        case "6~": key (Key.PAGE_DOWN, ""); break;
                        case "Z": key (Key.COMPLETE_PREVIOUS, ""); break;
                        case "1;3D": key (Key.PREVIOUS_TAB, ""); break;
                        case "1;3C": key (Key.NEXT_TAB, ""); break;
                        }
                        continue;
                    }
                    pending = pending.substring (1); key (Key.ESCAPE, ""); continue;
                }
                unichar c = pending.get_char_validated ();
                if (c == (unichar) (-2)) return;
                if (c == (unichar) (-1)) { pending = pending.substring (1); continue; }
                pending = pending.substring (c.to_string ().length);
                switch (c) {
                case 3: case 4: key (Key.QUIT, ""); break;
                case 2: key (Key.PAGE_UP, ""); break;
                case 6: key (Key.PAGE_DOWN, ""); break;
                case 7: key (Key.FOCUS, ""); break;
                case 23: key (Key.DELETE_WORD, ""); break;
                case 9: key (Key.COMPLETE, ""); break;
                case 14: key (Key.HISTORY_NEXT, ""); break;
                case 16: key (Key.HISTORY_PREVIOUS, ""); break;
                case 21: key (Key.CLEAR_INPUT, ""); break;
                case 10: key (Key.NEWLINE, ""); break;
                case 13: key (Key.ENTER, ""); break;
                case 1: key (Key.HOME, ""); break;
                case 5: key (Key.END, ""); break;
                case 12: key (Key.REDRAW, ""); break;
                case 8: case 127: key (Key.BACKSPACE, ""); break;
                default: if (!c.iscntrl ()) key (Key.TEXT, c.to_string ()); break;
                }
            }
        }
    }

    /** UTF-8 multiline draft; cursor offsets are bytes, display uses columns. */
    public class Editor : Object {
        public signal void changed ();
        public string text { get; private set; default = ""; }
        public int cursor { get; private set; default = 0; }
        internal int first_visible_row = 0;
        public const int MAX_BYTES = 65536;

        public void clear () { text = ""; cursor = 0; changed (); }

        /** Replace text before the caret, retaining any following arguments. */
        public void replace_prefix (string value) {
            text = text.substring (cursor);
            cursor = 0;
            insert (value);
        }

        public void insert (string value) {
            var data = new StringBuilder ();
            int room = MAX_BYTES - text.length;
            string valid = value.make_valid ();
            int index = 0;
            unichar c;
            while (valid.get_next_char (ref index, out c)) {
                if (c != '\n' && c != '\t' && c.iscntrl ()) continue;
                string glyph = c == '\t' ? "    " : c.to_string ();
                if (data.len + glyph.length > room) break;
                data.append (glyph);
            }
            text = text.substring (0, cursor) + data.str + text.substring (cursor);
            cursor += (int) data.len;
            changed ();
        }

        private int previous (int offset) {
            while (offset > 0) {
                do { offset--; } while (offset > 0 && (text[offset] & 0xc0) == 0x80);
                if (character_width (text.get_char (offset)) != 0) break;
            }
            return offset;
        }

        private int next (int offset) {
            int length = text.length;
            if (offset >= length) return length;
            offset += text.get_char (offset).to_string ().length;
            while (offset < length && character_width (text.get_char (offset)) == 0)
                offset += text.get_char (offset).to_string ().length;
            return offset;
        }

        private void position (int offset, int columns, out int x, out int y) {
            x = y = 0;
            int i = 0;
            unichar c = 0;
            while (i < offset && text.get_next_char (ref i, out c)) {
                if (c == '\n') { x = 0; y++; continue; }
                int w = int.min (columns, character_width (c));
                if (x + w > columns) { x = 0; y++; }
                x += w;
            }
            if (x >= columns) { x = 0; y++; }
        }

        public GenericArray<Row> layout (int columns, out int x, out int y, int max_rows = int.MAX) {
            columns = int.max (1, columns);
            max_rows = int.max (1, max_rows);
            position (cursor, columns, out x, out y);
            int first = int.max (0, y - max_rows + 1);
            first_visible_row = first;
            y -= first;
            // A trailing cell keeps the end cursor visible after a full row.
            var rows = new Text.plain (text + " ").wrap (columns, first, max_rows);
            return rows;
        }

        /** Place the caret at a column/row in the unscrolled, wrapped draft. */
        public void place_cursor (int columns, int column, int row) {
            columns = int.max (1, columns);
            column = column.clamp (0, columns - 1);
            row = int.max (0, row);
            int x = 0, y = 0, best = 0;
            int length = text.length;
            for (int i = 0; i <= length;) {
                unichar c = i < length ? text.get_char (i) : ' ';
                int width = c == '\n' ? 0 : int.min (columns, character_width (c));
                if (x >= columns || (width > 0 && x + width > columns)) {
                    // A newline immediately after a full row ends that row once.
                    if (c != '\n') { x = 0; y++; }
                }
                if (y > row || (y == row && x > column)) break;
                best = i;
                if (i == length) break;
                if (c == '\n') { x = 0; y++; }
                else x += width;
                i = next (i);
            }
            cursor = best;
            changed ();
        }

        public void handle (Key key, int columns) {
            columns = int.max (1, columns);
            switch (key) {
            case Key.LEFT: cursor = previous (cursor); break;
            case Key.RIGHT: cursor = next (cursor); break;
            case Key.BACKSPACE:
                int start = previous (cursor);
                text = text.substring (0, start) + text.substring (cursor); cursor = start; break;
            case Key.DELETE:
                text = text.substring (0, cursor) + text.substring (next (cursor)); break;
            case Key.DELETE_WORD:
                int word_start = cursor;
                while (word_start > 0 && text.get_char (previous (word_start)).isspace ()) word_start = previous (word_start);
                while (word_start > 0 && !text.get_char (previous (word_start)).isspace ()) word_start = previous (word_start);
                text = text.substring (0, word_start) + text.substring (cursor); cursor = word_start; break;
            case Key.HOME:
                while (cursor > 0 && text[cursor - 1] != '\n') cursor = previous (cursor);
                break;
            case Key.END:
                while (cursor < text.length && text[cursor] != '\n') cursor = next (cursor);
                break;
            case Key.UP: case Key.DOWN:
                int x, y;
                position (cursor, columns, out x, out y);
                int target = y + (key == Key.UP ? -1 : 1);
                if (target < 0) break;
                int best = cursor;
                // Walk once, preserving the visual column across wrapped rows.
                int px = 0, py = 0;
                int length = text.length;
                for (int i = 0; i <= length;) {
                    int vx = px >= columns ? 0 : px;
                    int vy = py + (px >= columns ? 1 : 0);
                    if (vy == target && vx <= x) best = i;
                    if (vy > target || i == length) break;
                    unichar c = text.get_char (i);
                    if (c == '\n') { px = 0; py++; }
                    else {
                        int w = int.min (columns, character_width (c));
                        if (px + w > columns) { px = 0; py++; }
                        px += w;
                    }
                    i = next (i);
                }
                cursor = best;
                break;
            default: break;
            }
            changed ();
        }
    }

    /** Shared recall list; drafts stay in their editors, across windows/accounts. */
    public class InputHistory : Object {
        private string[] entries = {};
        private int index = -1;
        private Editor? editor;
        private string draft = "";

        public void remember (string text) {
            if (entries.length == 0 || entries[entries.length - 1] != text) {
                if (entries.length == 100) entries = entries[1:];
                entries += text;
            }
            reset ();
        }

        public void reset () { editor = null; index = -1; draft = ""; }

        public void recall (Editor target, bool previous) {
            if (entries.length == 0) return;
            if (editor != target) reset ();
            if (index < 0) {
                if (!previous) return;
                editor = target;
                draft = target.text;
                index = entries.length;
            }
            index = (index + (previous ? -1 : 1)).clamp (0, entries.length);
            string value = index == entries.length ? draft : entries[index];
            if (index == entries.length) reset ();
            target.clear ();
            target.insert (value);
        }
    }
}
