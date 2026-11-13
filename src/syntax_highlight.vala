namespace Dc {

    /**
     * Generic, language-agnostic syntax highlighter for fenced code blocks.
     * A single tokenizer colors comments, strings, numbers and a keyword set
     * shared across C-family, Python, Java, TypeScript, Swift, Rust, Go and
     * Vala, so unknown or untagged languages still look reasonable. Emits
     * Pango markup with colors from small light/dark palettes.
     *
     * GLib-only on purpose: the app owns `theme` and `dark_mode` (set from
     * SettingsManager and Adw.StyleManager), keeping this file linkable from
     * the unit tests without initializing GTK.
     */
    public class SyntaxHighlight {

        public static CodeTheme theme = CodeTheme.ADAPTIVE;
        public static bool dark_mode = false;

        private struct Palette {
            public string keyword;
            public string type;
            public string func;
            public string str;
            public string num;
            public string comment;
            public string constant;
        }

        /* Keep these lists NULL-terminated for strv_contains(). */
        private const string[] KEYWORDS = {
            "if", "else", "elif", "for", "while", "do", "switch", "case",
            "default", "break", "continue", "return", "goto", "new", "delete",
            "try", "catch", "finally", "throw", "throws", "class", "struct",
            "enum", "union", "interface", "protocol", "extension", "impl",
            "trait", "func", "function", "def", "fn", "var", "let", "const",
            "static", "public", "private", "protected", "internal", "open",
            "import", "export", "from", "package", "namespace", "using",
            "typedef", "sizeof", "typeof", "instanceof", "in", "of", "is",
            "as", "not", "and", "or", "async", "await", "yield", "lambda",
            "pass", "raise", "with", "except", "match", "guard", "defer",
            "init", "deinit", "override", "virtual", "abstract", "final",
            "extends", "implements", "module", "require", "global",
            "nonlocal", "assert", "del", "inline", "extern", "volatile",
            "register", "constexpr", "auto", "operator", "template",
            "ref", "out", "weak", "owned", "unowned", "construct",
            "mut", "pub", "unsafe", "where", "go", "chan", null
        };

        private const string[] TYPES = {
            "void", "bool", "boolean", "char", "short", "int", "long",
            "float", "double", "byte", "unsigned", "signed", "string", "str",
            "object", "size_t", "ssize_t", "wchar_t", "uint",
            "int8", "int16", "int32", "int64",
            "uint8", "uint16", "uint32", "uint64",
            "int8_t", "int16_t", "int32_t", "int64_t",
            "uint8_t", "uint16_t", "uint32_t", "uint64_t",
            "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
            "f32", "f64", "usize", "isize",
            "number", "bigint", "any", "never", "unknown", null
        };

        private const string[] CONSTANTS = {
            "true", "false", "True", "False", "null", "nullptr", "nil",
            "None", "NULL", "undefined", "NaN", "self", "this", "super",
            "Self", null
        };

        /**
         * Highlight raw (unescaped) code and return Pango markup. Every
         * emitted chunk is markup-escaped here, so callers must not escape
         * the result again.
         */
        public static string highlight (string code) {
            if (theme == CodeTheme.NONE) {
                return Markup.escape_text (code);
            }
            Palette pal = current_palette ();

            var sb = new StringBuilder ();
            int len = code.length;
            int plain_start = 0;
            int i = 0;

            while (i < len) {
                char c = code[i];
                int token_end = -1;
                string? color = null;
                bool italic = false;

                if (c == '/' && i + 1 < len && code[i + 1] == '/') {
                    token_end = line_end (code, i);
                    color = pal.comment;
                    italic = true;
                } else if (c == '/' && i + 1 < len && code[i + 1] == '*') {
                    int close = code.index_of ("*/", i + 2);
                    token_end = close < 0 ? len : close + 2;
                    color = pal.comment;
                    italic = true;
                } else if (c == '#') {
                    token_end = line_end (code, i);
                    color = pal.comment;
                    italic = true;
                } else if (c == '"' || c == '\'' || c == '`') {
                    token_end = scan_string (code, i);
                    color = pal.str;
                } else if (is_digit (c) && !is_ident_char_at (code, i - 1)) {
                    token_end = scan_number (code, i);
                    color = pal.num;
                } else if (is_ident_start (c)) {
                    int end = i + 1;
                    while (end < len && is_ident_char (code[end])) end++;
                    string word = code.substring (i, end - i);
                    color = classify (word, code, end, pal);
                    if (color != null) token_end = end;
                    else i = end - 1;
                }

                if (token_end > i) {
                    if (plain_start < i) {
                        sb.append (Markup.escape_text (
                            code.substring (plain_start, i - plain_start)));
                    }
                    append_span (sb, code.substring (i, token_end - i),
                                 color, italic);
                    i = token_end;
                    plain_start = i;
                } else {
                    i++;
                }
            }

            if (plain_start < len) {
                sb.append (Markup.escape_text (
                    code.substring (plain_start, len - plain_start)));
            }
            return sb.str;
        }

        private static Palette current_palette () {
            switch (theme) {
            case CodeTheme.SOLARIZED:
                return dark_mode
                    ? Palette () {
                        keyword = "#859900", type = "#b58900",
                        func = "#268bd2", str = "#2aa198",
                        num = "#d33682", comment = "#586e75",
                        constant = "#cb4b16" }
                    : Palette () {
                        keyword = "#859900", type = "#b58900",
                        func = "#268bd2", str = "#2aa198",
                        num = "#d33682", comment = "#93a1a1",
                        constant = "#cb4b16" };
            case CodeTheme.MONOKAI:
                return dark_mode
                    ? Palette () {
                        keyword = "#f92672", type = "#66d9ef",
                        func = "#a6e22e", str = "#e6db74",
                        num = "#ae81ff", comment = "#75715e",
                        constant = "#ae81ff" }
                    : Palette () {
                        keyword = "#d81b60", type = "#0277bd",
                        func = "#558b2e", str = "#b26500",
                        num = "#6f42c1", comment = "#8d8574",
                        constant = "#6f42c1" };
            case CodeTheme.NORD:
                return dark_mode
                    ? Palette () {
                        keyword = "#81a1c1", type = "#8fbcbb",
                        func = "#88c0d0", str = "#a3be8c",
                        num = "#b48ead", comment = "#7b88a1",
                        constant = "#d08770" }
                    : Palette () {
                        keyword = "#4f6d9c", type = "#3f7d7b",
                        func = "#3a7f96", str = "#61803f",
                        num = "#8a5f88", comment = "#8b95a7",
                        constant = "#ad5f2b" };
            default:
                return dark_mode
                    ? Palette () {
                        keyword = "#ff7b72", type = "#ffa657",
                        func = "#d2a8ff", str = "#a5d6ff",
                        num = "#79c0ff", comment = "#8b949e",
                        constant = "#79c0ff" }
                    : Palette () {
                        keyword = "#cf222e", type = "#953800",
                        func = "#8250df", str = "#0a3069",
                        num = "#0550ae", comment = "#6e7781",
                        constant = "#0550ae" };
            }
        }

        private static string? classify (string word, string code, int end,
                                         Palette pal) {
            if (strv_contains (KEYWORDS, word)) return pal.keyword;
            if (strv_contains (TYPES, word)) return pal.type;
            if (strv_contains (CONSTANTS, word)) return pal.constant;

            char first = word[0];
            if (first >= 'A' && first <= 'Z') {
                /* CamelCase reads as a type name, ALL_CAPS as a constant. */
                for (int i = 1; i < word.length; i++) {
                    char c = word[i];
                    if (c >= 'a' && c <= 'z') return pal.type;
                }
                return word.length > 1 ? pal.constant : null;
            }
            /* Call site: identifier before "(", allowing GNU-style spacing. */
            int j = end;
            while (j < code.length && (code[j] == ' ' || code[j] == '\t')) j++;
            if (j < code.length && code[j] == '(') return pal.func;
            return null;
        }

        private static void append_span (StringBuilder sb, string text,
                                         string? color, bool italic) {
            sb.append ("<span foreground=\"");
            sb.append (color);
            sb.append_c ('"');
            if (italic) sb.append (" style=\"italic\"");
            sb.append_c ('>');
            sb.append (Markup.escape_text (text));
            sb.append ("</span>");
        }

        private static int line_end (string code, int start) {
            int nl = code.index_of_char ('\n', start);
            return nl < 0 ? code.length : nl;
        }

        private static int scan_string (string code, int start) {
            char quote = code[start];
            int len = code.length;

            /* Triple-quoted strings ("""/''') span lines, as do backtick
               template literals. */
            if (quote != '`' && start + 2 < len
                && code[start + 1] == quote && code[start + 2] == quote) {
                string fence = code.substring (start, 3);
                int close = code.index_of (fence, start + 3);
                return close < 0 ? len : close + 3;
            }

            int i = start + 1;
            while (i < len) {
                char c = code[i];
                if (c == '\\') { i += 2; continue; }
                if (c == quote) return i + 1;
                /* An unterminated quote (say, an apostrophe in prose) must
                   not swallow the rest of the block. */
                if (c == '\n' && quote != '`') return i;
                i++;
            }
            return len;
        }

        private static int scan_number (string code, int start) {
            int len = code.length;
            int i = start;
            while (i < len) {
                char c = code[i];
                if (is_alnum (c) || c == '_' || c == '.') { i++; continue; }
                if ((c == '+' || c == '-') && i > start) {
                    char prev = code[i - 1];
                    if (prev == 'e' || prev == 'E'
                        || prev == 'p' || prev == 'P') { i++; continue; }
                }
                break;
            }
            return i;
        }

        private static bool is_digit (char c) {
            return c >= '0' && c <= '9';
        }

        private static bool is_alnum (char c) {
            return is_digit (c) || (c >= 'a' && c <= 'z')
                || (c >= 'A' && c <= 'Z');
        }

        private static bool is_ident_start (char c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || c == '_';
        }

        private static bool is_ident_char (char c) {
            return is_ident_start (c) || is_digit (c);
        }

        private static bool is_ident_char_at (string code, int index) {
            return index >= 0 && is_ident_char (code[index]);
        }
    }
}
