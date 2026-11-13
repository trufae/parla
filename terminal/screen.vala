namespace Parla.Terminal {
    /** Retained screen: replace only rows belonging to invalidated panels. */
    public class Frame : Object {
        internal Row[] rows;
        public int width { get; private set; }
        public int height { get; private set; }
        public int cursor_x { get; set; default = 0; }
        public int cursor_y { get; set; default = 0; }
        public bool cursor_visible { get; set; default = true; }

        public Frame (int width, int height) {
            this.width = int.max (1, width);
            this.height = int.max (1, height);
            rows = new Row[this.height];
            for (int y = 0; y < this.height; y++) rows[y] = new Row (this.width);
        }

        public void set_row (int y, Row row) {
            if (y >= 0 && y < height && row.width == width) rows[y] = row;
        }

        public unowned Row get_row (int y) { return rows[y]; }
    }

    /** Encodes changed cell spans into one output batch. Identical frames cost
     * no terminal IO; unchanged row objects require no cell comparisons. */
    public class Renderer : Object {
        private Theme theme = new Theme ();
        public void use_theme (Theme value) { theme = value; invalidate (); }
        private Row[] previous = {};
        private int width = 0;
        private int cursor_x = -1;
        private int cursor_y = -1;
        private bool cursor_visible = true;

        public void invalidate () { previous = {}; cursor_x = cursor_y = -1; }

        private bool equal (Cell a, Cell b) {
            return a.text == b.text && a.style == b.style && a.width == b.width && a.link == b.link;
        }

        private void move (StringBuilder output, int x, int y) {
            output.append_printf ("\033[%d;%dH", y + 1, x + 1);
        }

        private void style (StringBuilder output, Style value) {
            output.append ("\033[0");
            if (Style.BOLD in value) output.append (";1");
            if (Style.DIM in value) output.append (";2");
            if (Style.ITALIC in value) output.append (";3");
            if (Style.UNDERLINE in value) output.append (";4");
            output.append (theme.codes (value));
            output.append_c ('m');
        }

        public string render (Frame frame) {
            var output = new StringBuilder ();
            bool full = previous.length != frame.height || width != frame.width;
            if (full) {
                output.append ("\033[0m\033[2J");
                previous = new Row[frame.height];
                width = frame.width;
            }
            for (int y = 0; y < frame.height; y++) {
                Row row = frame.rows[y];
                if (!full && previous[y] == row) continue;
                int start = 0, end = width;
                if (!full) {
                    while (start < end && equal (row.cells[start], previous[y].cells[start])) start++;
                    while (end > start && equal (row.cells[end - 1], previous[y].cells[end - 1])) end--;
                    // Repaint complete wide glyphs, including the old trailing cell.
                    while (start > 0 && start < end &&
                        (row.cells[start].width == 0 || previous[y].cells[start].width == 0)) start--;
                    if (end < width && (row.cells[end].width == 0 || previous[y].cells[end].width == 0)) end++;
                }
                if (start < end) {
                    move (output, start, y);
                    Style current = (Style) (-1);
                    string? link = null;
                    for (int x = start; x < end; x++) {
                        var cell = row.cells[x];
                        if (cell.width == 0) continue;
                        if (link != cell.link) {
                            if (link != null) output.append ("\033]8;;\033\\");
                            link = cell.link;
                            if (link != null) output.append ("\033]8;;" + link + "\033\\");
                        }
                        if (current != cell.style) { style (output, cell.style); current = cell.style; }
                        output.append (cell.text);
                    }
                    if (link != null) output.append ("\033]8;;\033\\");
                }
                previous[y] = row;
            }
            int cx = frame.cursor_x.clamp (0, frame.width - 1);
            int cy = frame.cursor_y.clamp (0, frame.height - 1);
            if (frame.cursor_visible != cursor_visible) {
                output.append (frame.cursor_visible ? "\033[?25h" : "\033[?25l");
                cursor_visible = frame.cursor_visible;
            }
            if (output.len > 0 || cx != cursor_x || cy != cursor_y) {
                if (output.len > 0) output.append ("\033[0m");
                move (output, cx, cy);
                cursor_x = cx; cursor_y = cy;
            }
            return output.str;
        }
    }
}
