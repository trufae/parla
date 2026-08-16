namespace Dc {

    public enum MarkdownMode {
        ENABLED = 0,
        STRIPPED = 1,
        DISABLED = 2;
    }

    /**
     * Converts markdown-formatted text to Pango markup for GTK labels.
     * Supports: bold, italic, strikethrough, inline code, code blocks,
     * headings, task-list checkboxes, tables, and URL linkification.
     * Also strips markdown down to plain text for compact previews.
     */
    public class Markdown {

        public static MarkdownMode mode = MarkdownMode.ENABLED;
        private const int ALIGN_LEFT = 0;
        private const int ALIGN_RIGHT = 1;
        private const int ALIGN_CENTER = 2;

        private delegate string MatchReplacement (MatchInfo match);

        private class TableRow {
            public string[] cells;
            public bool separator;

            public TableRow (string[] cells, bool separator = false) {
                this.cells = cells;
                this.separator = separator;
            }
        }

        /* Compiled regexes — built once on first use */
        private static Regex? cb_re = null;
        private static Regex? ic_re = null;
        private static Regex? bold_re = null;
        private static Regex? italic_re = null;
        private static Regex? italic2_re = null;
        private static Regex? strike_re = null;
        private static Regex? heading_re = null;
        private static Regex? link_re = null;
        private static Regex? strip_heading_re = null;
        private static Regex? strip_link_re = null;
        private static Regex? strip_ref_link_re = null;
        private static Regex? strip_auto_link_re = null;
        private static Regex? strip_quote_re = null;
        private static Regex? strip_hr_re = null;
        private static Regex? strip_list_re = null;
        private static Regex? strip_escape_re = null;

        private static void ensure_regexes () throws RegexError {
            if (cb_re != null) return;
            cb_re = new Regex ("(```|~~~)(?:[a-zA-Z]*)\\n?([\\s\\S]*?)\\1");
            ic_re = new Regex ("`([^`\\n]+)`");
            bold_re = new Regex ("(\\*\\*|__)(.+?)\\1");
            italic_re = new Regex ("\\*([^\\*\\n]+)\\*");
            italic2_re = new Regex ("(?<!\\w)_([^_\\n]+)_(?!\\w)");
            strike_re = new Regex ("~~(.+?)~~");
            heading_re = new Regex ("^(#{1,3}) +(.+)$", RegexCompileFlags.MULTILINE);
            link_re = new Regex ("(https?://[^\\s<>\"]+)");
            strip_heading_re = new Regex ("^(#{1,6})[ \\t]+(.+)$",
                                           RegexCompileFlags.MULTILINE);
            strip_link_re = new Regex ("!?\\[([^\\]\\n]*)\\]\\([^\\)\\n]*\\)");
            strip_ref_link_re = new Regex ("\\[([^\\]\\n]*)\\]\\[[^\\]\\n]*\\]");
            strip_auto_link_re = new Regex ("<((?:https?|mailto):[^>\\s]+)>");
            strip_quote_re = new Regex ("^\\s*>\\s?", RegexCompileFlags.MULTILINE);
            strip_hr_re = new Regex ("^\\s{0,3}(?:[-*_]\\s*){3,}$",
                                      RegexCompileFlags.MULTILINE);
            strip_list_re = new Regex ("^\\s{0,3}(?:[-+*]|\\d+[.)])\\s+",
                                        RegexCompileFlags.MULTILINE);
            strip_escape_re = new Regex ("\\\\([\\\\`*_{}\\[\\]()#+\\-.!>])");
        }

        private static string replace_matches (Regex regex, string input,
                                               MatchReplacement replacement)
                                               throws RegexError {
            var result = new StringBuilder ();
            int offset = 0;
            MatchInfo match;
            while (regex.match_full (input, -1, offset, 0, out match)) {
                int start, end;
                if (!match.fetch_pos (0, out start, out end) || end <= offset) {
                    throw new RegexError.MATCH ("Invalid replacement match");
                }
                result.append (input.substring (offset, start - offset));
                result.append (replacement (match));
                offset = end;
            }
            result.append (input.substring (offset));
            return result.str;
        }

        /**
         * Format message text according to the selected markdown mode.
         * URLs are always linkified.
         */
        public static string format (string input) {
            return format_with_mode (input, mode);
        }

        /**
         * Format text using an explicit mode without changing the application
         * setting. This is useful for previews whose rendering can be toggled
         * locally, such as the full-message reader.
         */
        public static string format_with_mode (string input,
                                               MarkdownMode render_mode) {
            string text = render_mode == MarkdownMode.STRIPPED
                ? strip (input) : input;
            var escaped = Markup.escape_text (text);
            if (render_mode != MarkdownMode.ENABLED) {
                return linkify (escaped);
            }
            try {
                return format_markdown (escaped);
            } catch (RegexError e) {
                return linkify (escaped);
            }
        }

        /**
         * Convert markdown to plain text for short previews.
         */
        public static string strip (string input) {
            try {
                return strip_markdown (input);
            } catch (RegexError e) {
                return input.strip ();
            }
        }

        /**
         * Convert markdown to preview text, stripping markdown before line
         * clamping so line-oriented syntax such as task checkboxes survives.
         */
        public static string preview (string input, int max_lines,
                                      int max_chars) {
            string result = strip (input);

            if (max_lines > 0) {
                string[] lines = result.split ("\n");
                int n = (lines.length < max_lines) ? lines.length : max_lines;
                var sb = new StringBuilder ();
                for (int i = 0; i < n; i++) {
                    if (i > 0) sb.append_c ('\n');
                    sb.append (lines[i]);
                }
                if (lines.length > max_lines) sb.append ("…");
                result = sb.str;
            }

            return clamp_chars (result, max_chars);
        }

        /**
         * Convert markdown to a single-line preview, stripping markdown before
         * collapsing newlines so task checkboxes still start at line scope.
         */
        public static string single_line_preview (string input, int max_chars) {
            return clamp_chars (collapse_lines (strip (input)), max_chars);
        }

        private static string format_markdown (string escaped) throws RegexError {
            ensure_regexes ();
            var segments = new GenericArray<string> ();
            string work = escaped;

            /* Code blocks: ```lang\ncontent``` or ~~~lang\ncontent~~~ —
               extract first to protect contents */
            work = extract_code_block (cb_re, work, segments);

            /* Inline code: `content` */
            work = extract_code (ic_re, work, segments);

            /* Task-list checkboxes: * [ ] item / * [x] item */
            work = format_task_checkboxes (work);

            /* Bold: **text** and __text__ (backreference ensures matching delimiters) */
            work = bold_re.replace (work, -1, 0, "<b>\\2</b>");

            /* Italic: *text* and _text_ (underscore variant requires word boundaries) */
            work = italic_re.replace (work, -1, 0, "<i>\\1</i>");
            work = italic2_re.replace (work, -1, 0, "<i>\\1</i>");

            /* Strikethrough: ~~text~~ */
            work = strike_re.replace (work, -1, 0, "<s>\\1</s>");

            /* Headings: #, ##, ### */
            work = replace_matches (heading_re, work, (mi) => {
                var text = mi.fetch (2);
                switch (mi.fetch (1).length) {
                    case 1:
                        return "<span size=\"x-large\"><b>" + text
                            + "</b></span>";
                    case 2:
                        return "<span size=\"large\"><b>" + text
                            + "</b></span>";
                    default:
                        return "<b>" + text + "</b>";
                }
            });

            /* Tables: render pipe tables as aligned monospace text. */
            work = format_tables (work, segments);

            /* Linkify URLs */
            work = linkify (work);

            /* Restore protected code segments */
            for (int i = 0; i < segments.length; i++) {
                work = work.replace ("\x01%d\x01".printf (i), segments[i]);
            }

            return work;
        }

        private static string strip_markdown (string input) throws RegexError {
            ensure_regexes ();
            var segments = new GenericArray<string> ();
            string work = input;

            work = extract_plain_code (cb_re, work, segments, 2);
            work = extract_plain_code (ic_re, work, segments);

            work = strip_task_checkboxes (work);
            work = strip_heading_re.replace (work, -1, 0, "\\2");
            work = strip_quote_re.replace (work, -1, 0, "");
            work = strip_hr_re.replace (work, -1, 0, "");

            work = strip_link_re.replace (work, -1, 0, "\\1");
            work = strip_ref_link_re.replace (work, -1, 0, "\\1");
            work = strip_auto_link_re.replace (work, -1, 0, "\\1");

            work = bold_re.replace (work, -1, 0, "\\2");
            work = italic_re.replace (work, -1, 0, "\\1");
            work = italic2_re.replace (work, -1, 0, "\\1");
            work = strike_re.replace (work, -1, 0, "\\1");

            work = strip_list_re.replace (work, -1, 0, "");
            work = strip_escape_re.replace (work, -1, 0, "\\1");

            for (int i = 0; i < segments.length; i++) {
                work = work.replace ("\x01%d\x01".printf (i), segments[i]);
            }

            return work.strip ();
        }

        private static string collapse_lines (string input) {
            string normalized = input.replace ("\r\n", "\n").replace ("\r", "\n");
            string[] lines = normalized.split ("\n");
            var sb = new StringBuilder ();

            for (int i = 0; i < lines.length; i++) {
                string line = lines[i].strip ();
                if (line.length == 0) continue;
                if (sb.len > 0) sb.append_c (' ');
                sb.append (line);
            }
            return sb.str;
        }

        private static string clamp_chars (string input, int max_chars) {
            if (max_chars > 0 && input.char_count () > max_chars) {
                int byte_pos = input.index_of_nth_char (max_chars);
                return input.substring (0, byte_pos) + "…";
            }
            return input;
        }

        private static string format_task_checkboxes (string input) {
            var lines = input.split ("\n");
            var sb = new StringBuilder ();

            for (int i = 0; i < lines.length; i++) {
                if (i > 0) sb.append_c ('\n');

                int marker_start;
                int content_start;
                bool checked;
                if (parse_task_checkbox (lines[i], out checked,
                                         out marker_start, out content_start)) {
                    int prefix_end = 0;
                    while (prefix_end < lines[i].length &&
                           is_ascii_space (lines[i][prefix_end])) {
                        prefix_end++;
                    }
                    sb.append (lines[i].substring (0, prefix_end));
                    sb.append (checked ? "✅" : "⬜");
                    if (content_start < lines[i].length) {
                        sb.append_c (' ');
                        sb.append (lines[i].substring (content_start));
                    }
                } else {
                    sb.append (lines[i]);
                }
            }

            return sb.str;
        }

        private static string strip_task_checkboxes (string input) {
            var lines = input.split ("\n");
            var sb = new StringBuilder ();

            for (int i = 0; i < lines.length; i++) {
                if (i > 0) sb.append_c ('\n');

                int marker_start;
                int content_start;
                bool checked;
                if (parse_task_checkbox (lines[i], out checked,
                                         out marker_start, out content_start)) {
                    int prefix_end = 0;
                    while (prefix_end < lines[i].length &&
                           is_ascii_space (lines[i][prefix_end])) {
                        prefix_end++;
                    }
                    sb.append (lines[i].substring (0, prefix_end));
                    sb.append (checked ? "✓" : "☐");
                    if (content_start < lines[i].length) {
                        sb.append_c (' ');
                        sb.append (lines[i].substring (content_start));
                    }
                } else {
                    sb.append (lines[i]);
                }
            }

            return sb.str;
        }

        public static bool parse_task_checkbox (string line,
                                                out bool checked,
                                                out int marker_start,
                                                out int content_start) {
            checked = false;
            marker_start = 0;
            content_start = 0;

            int i = 0;
            while (i < line.length && is_ascii_space (line[i])) i++;
            if (i >= line.length) return false;

            char bullet = line[i];
            if (bullet != '*') return false;
            i++;
            if (i >= line.length || !is_ascii_space (line[i])) return false;
            while (i < line.length && is_ascii_space (line[i])) i++;

            marker_start = i;
            if (i + 2 >= line.length) return false;
            if (line[i] != '[' || line[i + 2] != ']') return false;

            char state = line[i + 1];
            if (state == ' ') checked = false;
            else if (state == 'x') checked = true;
            else return false;

            i += 3;
            while (i < line.length && is_ascii_space (line[i])) i++;
            content_start = i;
            return true;
        }

        private static bool is_ascii_space (char c) {
            return c == ' ' || c == '\t';
        }

        /**
         * Replace regex matches with numbered placeholders, storing the
         * matched content wrapped in <tt> tags for later restoration.
         */
        private static string extract_code (Regex re, string input,
                                             GenericArray<string> segments) throws RegexError {
            return replace_matches (re, input, (mi) => {
                int idx = (int) segments.length;
                segments.add ("<tt>" + mi.fetch (1) + "</tt>");
                return "\x01%d\x01".printf (idx);
            });
        }

        /**
         * Like extract_code, but runs fenced blocks through the generic
         * syntax highlighter. Group 1 is the fence delimiter, group 2 the
         * content. The captured content was markup-escaped with
         * the whole message, so unescape before tokenizing; the highlighter
         * re-escapes every chunk it emits.
         */
        private static string extract_code_block (Regex re, string input,
                                                  GenericArray<string> segments) throws RegexError {
            return replace_matches (re, input, (mi) => {
                int idx = (int) segments.length;
                string raw = unescape_markup (mi.fetch (2));
                segments.add ("<tt>" + SyntaxHighlight.highlight (raw) + "</tt>");
                return "\x01%d\x01".printf (idx);
            });
        }

        private static string unescape_markup (string escaped) {
            return escaped
                .replace ("&lt;", "<")
                .replace ("&gt;", ">")
                .replace ("&quot;", "\"")
                .replace ("&apos;", "'")
                .replace ("&amp;", "&");
        }

        private static string extract_plain_code (Regex re, string input,
                                                  GenericArray<string> segments,
                                                  int group = 1) throws RegexError {
            return replace_matches (re, input, (mi) => {
                int idx = (int) segments.length;
                segments.add (mi.fetch (group));
                return "\x01%d\x01".printf (idx);
            });
        }

        private static string format_tables (string input,
                                             GenericArray<string> segments) {
            var lines = input.split ("\n");
            var sb = new StringBuilder ();
            bool first = true;

            for (int i = 0; i < lines.length;) {
                int end;
                string? table = try_format_table_at (lines, i, out end, segments);
                if (!first) sb.append_c ('\n');
                first = false;

                if (table != null) {
                    sb.append (table);
                    i = end;
                } else {
                    sb.append (lines[i]);
                    i++;
                }
            }

            return sb.str;
        }

        private static string? try_format_table_at (string[] lines, int start,
                                                    out int end,
                                                    GenericArray<string> segments) {
            end = start;
            if (start + 1 >= lines.length) return null;

            string[]? header = parse_table_row (lines[start]);
            string[]? separator = parse_table_row (lines[start + 1]);
            if (header == null || separator == null) return null;
            if (header.length < 2 || header.length != separator.length) return null;
            if (!is_separator_row (separator)) return null;

            int cols = header.length;
            int[] widths = new int[cols];
            int[] aligns = new int[cols];
            for (int c = 0; c < cols; c++) {
                widths[c] = 3;
                aligns[c] = separator_align (separator[c]);
            }

            var rows = new GenericArray<TableRow> ();
            rows.add (new TableRow (header));
            rows.add (new TableRow (separator, true));
            update_widths (widths, header, segments);

            end = start + 2;
            while (end < lines.length) {
                string line = lines[end];
                if (line.strip ().length == 0) break;

                string[]? cells = parse_table_row (line);
                if (cells == null || cells.length != cols) break;

                rows.add (new TableRow (cells));
                update_widths (widths, cells, segments);
                end++;
            }

            return render_table (rows, widths, aligns, segments);
        }

        private static string[]? parse_table_row (string line) {
            string trimmed = line.strip ();
            if (!trimmed.contains ("|")) return null;

            string inner = trimmed;
            if (inner.has_prefix ("|")) {
                inner = inner.substring (1);
            }
            if (inner.has_suffix ("|") && inner.length > 0) {
                inner = inner.substring (0, inner.length - 1);
            }

            var raw = inner.split ("|");
            if (raw.length < 2) return null;

            string[] cells = new string[raw.length];
            for (int i = 0; i < raw.length; i++) {
                cells[i] = raw[i].strip ();
            }
            return cells;
        }

        private static bool is_separator_row (string[] cells) {
            foreach (string cell in cells) {
                string s = cell.strip ();
                int start = s.has_prefix (":") ? 1 : 0;
                int end = s.has_suffix (":") ? s.length - 1 : s.length;
                if (end - start < 3) return false;
                for (int i = start; i < end; i++) {
                    if (s[i] != '-') return false;
                }
            }
            return true;
        }

        private static int separator_align (string cell) {
            string s = cell.strip ();
            bool left = s.has_prefix (":");
            bool right = s.has_suffix (":");
            if (left && right) return ALIGN_CENTER;
            if (right) return ALIGN_RIGHT;
            return ALIGN_LEFT;
        }

        private static void update_widths (int[] widths, string[] cells,
                                           GenericArray<string> segments) {
            for (int i = 0; i < widths.length; i++) {
                int width = visible_width (cells[i], segments);
                if (width > widths[i]) widths[i] = width;
            }
        }

        private static string render_table (GenericArray<TableRow> rows,
                                            int[] widths, int[] aligns,
                                            GenericArray<string> segments) {
            var sb = new StringBuilder ();
            sb.append ("<tt>");

            for (int r = 0; r < rows.length; r++) {
                if (r > 0) sb.append_c ('\n');
                TableRow row = rows[r];
                if (row.separator) {
                    append_separator (sb, widths);
                    continue;
                }

                for (int c = 0; c < widths.length; c++) {
                    if (c > 0) sb.append (" | ");
                    append_aligned_cell (sb, row.cells[c], widths[c],
                                         aligns[c], segments);
                }
            }

            sb.append ("</tt>");
            return sb.str;
        }

        private static void append_separator (StringBuilder sb, int[] widths) {
            for (int c = 0; c < widths.length; c++) {
                if (c > 0) sb.append ("-+-");
                append_repeated (sb, '-', widths[c]);
            }
        }

        private static void append_aligned_cell (StringBuilder sb, string cell,
                                                 int width, int align,
                                                 GenericArray<string> segments) {
            int pad = width - visible_width (cell, segments);
            if (pad < 0) pad = 0;

            if (align == ALIGN_RIGHT) {
                append_repeated (sb, ' ', pad);
                sb.append (cell);
            } else if (align == ALIGN_CENTER) {
                int left = pad / 2;
                append_repeated (sb, ' ', left);
                sb.append (cell);
                append_repeated (sb, ' ', pad - left);
            } else {
                sb.append (cell);
                append_repeated (sb, ' ', pad);
            }
        }

        private static void append_repeated (StringBuilder sb, char c, int count) {
            for (int i = 0; i < count; i++) {
                sb.append_c (c);
            }
        }

        private static int visible_width (string markup,
                                          GenericArray<string>? segments = null) {
            int width = 0;
            bool in_tag = false;

            for (int i = 0; i < markup.length;) {
                unichar c;
                if (!markup.get_next_char (ref i, out c)) break;

                if (in_tag) {
                    if (c == '>') in_tag = false;
                    continue;
                }

                if (c == '<') {
                    in_tag = true;
                    continue;
                }

                if (c == '&') {
                    int semi = markup.index_of_char (';', i);
                    if (semi >= i && semi - i <= 16) {
                        width++;
                        i = semi + 1;
                        continue;
                    }
                }

                if (c == 0x01 && segments != null) {
                    int? idx = read_segment_index (markup, ref i);
                    if (idx != null && idx >= 0 && idx < segments.length) {
                        width += visible_width (segments[idx]);
                        continue;
                    }
                }

                width++;
            }

            return width;
        }

        private static int? read_segment_index (string text, ref int index) {
            int idx = 0;
            bool have_digit = false;

            while (index < text.length) {
                char c = text[index];
                if (c == '\x01') {
                    index++;
                    if (have_digit) return idx;
                    return null;
                }
                if (c < '0' || c > '9') return null;
                idx = idx * 10 + (c - '0');
                have_digit = true;
                index++;
            }

            return null;
        }

        private static string linkify (string escaped) {
            try {
                ensure_regexes ();
                return replace_matches (link_re, escaped, (mi) => {
                    var url = mi.fetch (0);
                    /* No foreground here: the colour comes from the
                       "label link" CSS so it can adapt to the bubble tint
                       (see Application.apply_link_colors). */
                    return "<a href=\"" + url + "\"><span underline=\"single\">"
                        + url + "</span></a>";
                });
            } catch (RegexError e) {
                return escaped;
            }
        }
    }
}
