namespace Parla.Terminal {
    [Flags]
    public enum Style {
        NORMAL = 0, BOLD = 1, ITALIC = 2, UNDERLINE = 4, CODE = 8,
        DIM = 16, ACCENT = 32, SELECTED = 64, ERROR = 128,
        GREEN = 256, BLUE = 512, MAGENTA = 1024,
        STATUS = 2048, TAB = 4096, ACTIVE_TAB = 8192, UNREAD_TAB = 16384,
        CONTACT = 32768, ACTIVE_CONTACT = 65536, OPEN_CONTACT = 131072,
        INPUT = 262144, SEPARATOR = 524288, INFO = 1048576, OWN_NICK = 2097152,
        TIME = 4194304, MESSAGE = 8388608, COMPLETION = 16777216,
        NICK1 = 33554432, NICK2 = 67108864, NICK3 = 134217728, NICK4 = 268435456,
        QR = 536870912, PREVIEW = 1073741824
    }

    public struct Cell {
        public string text;
        public Style style;
        public int width;
        public string? link;
    }

    /** Terminal column widths, independent of the process locale. */
    public int character_width (unichar c) {
        if (c.iszerowidth ()) return 0;
        return c.iswide () ? 2 : 1;
    }

    /** A row of terminal cells. A Frame owns rows once they are installed. */
    public class Row : Object {
        public string message_id { get; internal set; default = ""; }
        internal Cell[] cells;
        public int width { get { return cells.length; } }

        public Row (int width, Style style = Style.NORMAL) {
            cells = new Cell[int.max (1, width)];
            for (int i = 0; i < cells.length; i++)
                cells[i] = Cell () { text = " ", style = style, width = 1 };
        }

        internal void put (int x, Cell cell) {
            if (x < 0 || x + cell.width > width || cell.width <= 0) return;
            // Overwriting either half of an old wide glyph must erase it all.
            if (cells[x].width == 0 && x > 0)
                cells[x - 1] = Cell () { text = " ", style = cells[x - 1].style, width = 1 };
            int last = x + cell.width - 1;
            if (cells[last].width == 2 && last + 1 < width)
                cells[last + 1] = Cell () { text = " ", style = cells[last + 1].style, width = 1 };
            cells[x] = cell;
            if (cell.width == 2)
                cells[x + 1] = Cell () { text = "", style = cell.style, width = 0 };
        }

        public void text (int x, string value, Style style = Style.NORMAL, int limit = -1) {
            var clean = new Text.plain (value, style);
            int end = limit < 0 ? width : int.min (width, x + limit);
            foreach (var cell in clean.glyphs) {
                if (cell.text == "\n" || x + cell.width > end) break;
                put (x, cell);
                x += cell.width;
            }
        }

        public string plain_text () {
            var result = new StringBuilder ();
            foreach (var cell in cells) result.append (cell.text);
            return result.str;
        }
    }

    /** Sanitized, styled text. Neither remote text nor Markdown emits escapes. */
    public class Text : Object {
        internal Cell[] glyphs = {};
        private int body_start = int.MAX;
        private int continuation_indent = 0;
        private int minimum_columns = 0;

        /** Preserve diagrams such as QR codes instead of wrapping their rows. */
        public Text.block (string value, int minimum_columns, Style style = Style.NORMAL) {
            this.minimum_columns = minimum_columns;
            append (value, style);
        }

        private Text narrow_notice () {
            return new Text.plain ("[Widen the chat area to %d columns to display this block]".printf (minimum_columns));
        }

        public Text.plain (string value, Style style = Style.NORMAL) {
            append (value, style);
        }

        public Text.link (string label, string uri, Style style = Style.UNDERLINE) {
            append (label, style, safe_link (uri));
        }

        private static string? safe_link (string uri) {
            if (uri.length > 8192 || !(uri.has_prefix ("file://") || uri.has_prefix ("https://") || uri.has_prefix ("http://"))) return null;
            int index = 0; unichar c;
            while (uri.get_next_char (ref index, out c)) if (c.iscntrl ()) return null;
            return uri;
        }

        public Text.message (string time, string nick, string markdown,
                             string state = "", string color_key = "", bool outgoing = false,
                             bool render_markdown = true, bool nick_colors = true, bool compact = true,
                             string attachment_label = "", string attachment_uri = "") {
            // Green is reserved for the local user; remote hashes cannot use it.
            Style[] colors = { Style.NICK1, Style.NICK2, Style.NICK3, Style.NICK4 };
            Style color = outgoing ? Style.OWN_NICK : nick_colors ?
                colors[str_hash (color_key == "" ? nick : color_key) % colors.length] : Style.NICK1;
            append ((time == "" ? "" : time.replace ("\n", " ") + " ") + "<", Style.DIM | Style.TIME);
            append (nick.replace ("\n", " "), color | Style.BOLD);
            append (compact ? "> " : ">\n", Style.DIM | Style.TIME);
            body_start = glyphs.length;
            if (compact) foreach (var cell in glyphs) continuation_indent += cell.width;
            var body = render_markdown ? new Text.markdown (markdown) : new Text.plain (markdown);
            foreach (var original in body.glyphs) {
                var cell = original;
                cell.style |= Style.MESSAGE;
                glyphs += cell;
            }
            if (attachment_label != "") {
                if (markdown != "") append ("\n");
                append (attachment_label, Style.MESSAGE | Style.UNDERLINE | Style.ACCENT, safe_link (attachment_uri));
            }
            if (state != "") append (" " + state, Style.DIM);
        }

        public Text.markdown (string value) {
            bool fenced = false;
            string[] lines = value.make_valid ().split ("\n");
            for (int i = 0; i < lines.length; i++) {
                string line = lines[i];
                if (line.strip ().has_prefix ("```")) {
                    fenced = !fenced;
                    append (fenced ? "┌ code" : "└", Style.DIM);
                } else if (fenced) {
                    append (line, Style.CODE);
                } else {
                    Style style = Style.NORMAL;
                    int heading = 0;
                    while (heading < line.length && line[heading] == '#') heading++;
                    if (heading > 0 && heading <= 6 && heading < line.length && line[heading] == ' ') {
                        line = line.substring (heading + 1);
                        style = Style.BOLD | Style.ACCENT;
                    } else if (line.has_prefix ("> ")) {
                        append ("│ ", Style.DIM);
                        line = line.substring (2);
                        style = Style.DIM;
                    } else if (line.has_prefix ("- ") || line.has_prefix ("* ")) {
                        append ("• ");
                        line = line.substring (2);
                    }
                    inline_text (line, style);
                }
                if (i + 1 < lines.length) append ("\n");
            }
        }

        private void inline_text (string value, Style base_style) {
            int start = 0;
            int i = 0;
            int length = value.length;
            while (i < length) {
                string? marker = null;
                Style extra = Style.NORMAL;
                if (value[i] == '`') { marker = "`"; extra = Style.CODE; }
                else if (value[i] == '*' && i + 1 < length && value[i + 1] == '*') { marker = "**"; extra = Style.BOLD; }
                else if (value[i] == '*') { marker = "*"; extra = Style.ITALIC; }
                if (marker != null) {
                    int end = value.index_of (marker, i + marker.length);
                    if (end > i + marker.length) {
                        append (value.substring (start, i - start), base_style);
                        string inner = value.substring (i + marker.length, end - i - marker.length);
                        if (extra == Style.BOLD) inline_text (inner, base_style | extra);
                        else append (inner, base_style | extra);
                        i = end + marker.length;
                        start = i;
                        continue;
                    }
                } else if (value[i] == '[') {
                    int mid = value.index_of ("](", i + 1);
                    int end = mid < 0 ? -1 : value.index_of (")", mid + 2);
                    if (end >= 0) {
                        append (value.substring (start, i - start), base_style);
                        append (value.substring (i + 1, mid - i - 1), base_style | Style.UNDERLINE);
                        append (" (" + value.substring (mid + 2, end - mid - 2) + ")", Style.DIM);
                        i = end + 1;
                        start = i;
                        continue;
                    }
                }
                i++;
            }
            append (value.substring (start), base_style);
        }

        private void append (string value, Style style = Style.NORMAL, string? link = null) {
            string valid = value.make_valid ();
            int index = 0;
            unichar c;
            while (valid.get_next_char (ref index, out c)) {
                if (c == '\t') {
                    for (int j = 0; j < 4; j++)
                        glyphs += Cell () { text = " ", style = style, width = 1 };
                    continue;
                }
                if (c != '\n' && (c.iscntrl () || c == 0x7f)) continue;
                int width = c == '\n' ? 0 : character_width (c);
                // Keep combining marks with their base, never on a continuation cell.
                if (width == 0 && c != '\n') {
                    if (glyphs.length > 0 && glyphs[glyphs.length - 1].text != "\n")
                        glyphs[glyphs.length - 1].text += c.to_string ();
                    continue;
                }
                glyphs += Cell () { text = c.to_string (), style = style, width = width, link = link };
            }
        }

        public int line_count (int columns) {
            if (columns < minimum_columns) return narrow_notice ().line_count (columns);
            columns = int.max (1, columns);
            int lines = 1, x = 0;
            for (int i = 0; i < glyphs.length; i++) {
                var cell = glyphs[i];
                int indent = i >= body_start ? int.min (continuation_indent, int.max (0, columns - 2)) : 0;
                if (cell.text == "\n") { lines++; x = indent; continue; }
                int width = int.min (cell.width, columns);
                if (x + width > columns) { lines++; x = indent; }
                x += width;
            }
            return lines;
        }

        /** Wrap at terminal columns, allocating only the requested row window.
         * Combining marks stay attached to their base. */
        public GenericArray<Row> wrap (int columns, int first_row = 0, int max_rows = int.MAX) {
            if (columns < minimum_columns) return narrow_notice ().wrap (columns, first_row, max_rows);
            columns = int.max (1, columns);
            first_row = int.max (0, first_row);
            max_rows = int.max (1, max_rows);
            var rows = new GenericArray<Row> ();
            Row? row = first_row == 0 ? new Row (columns) : null;
            int x = 0, y = 0;
            for (int i = 0; i < glyphs.length; i++) {
                var cell = glyphs[i];
                if (cell.width > columns) { cell.text = "?"; cell.width = 1; }
                if (cell.text == "\n" || x + cell.width > columns) {
                    if (row != null) rows.add (row);
                    if (rows.length >= max_rows) return rows;
                    y++;
                    row = y >= first_row ? new Row (columns) : null;
                    x = i >= body_start ? int.min (continuation_indent, int.max (0, columns - 2)) : 0;
                    if (cell.text == "\n") continue;
                }
                if (row != null) row.put (x, cell);
                x += cell.width;
            }
            if (row != null) rows.add (row);
            return rows;
        }
    }
}
