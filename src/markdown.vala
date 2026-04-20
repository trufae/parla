namespace Dc {

    /**
     * Converts markdown-formatted text to Pango markup for GTK labels.
     * Supports: bold, italic, strikethrough, inline code, code blocks,
     * headings, and URL linkification.
     */
    public class Markdown {

        public static bool enabled = false;

        /* Compiled regexes — built once on first use */
        private static Regex? cb_re = null;
        private static Regex? ic_re = null;
        private static Regex? bold_re = null;
        private static Regex? italic_re = null;
        private static Regex? italic2_re = null;
        private static Regex? strike_re = null;
        private static Regex? heading_re = null;
        private static Regex? link_re = null;

        private static void ensure_regexes () throws RegexError {
            if (cb_re != null) return;
            cb_re = new Regex ("```(?:[a-zA-Z]*)\\n?([\\s\\S]*?)```");
            ic_re = new Regex ("`([^`\\n]+)`");
            bold_re = new Regex ("(\\*\\*|__)(.+?)\\1");
            italic_re = new Regex ("\\*([^\\*\\n]+)\\*");
            italic2_re = new Regex ("(?<!\\w)_([^_\\n]+)_(?!\\w)");
            strike_re = new Regex ("~~(.+?)~~");
            heading_re = new Regex ("^(#{1,3}) +(.+)$", RegexCompileFlags.MULTILINE);
            link_re = new Regex ("(https?://[^\\s<>\"]+)");
        }

        /**
         * Format message text. Always linkifies URLs.
         * When enabled, also converts markdown syntax to Pango markup.
         */
        public static string format (string input) {
            var escaped = Markup.escape_text (input);
            if (!enabled) {
                return linkify (escaped);
            }
            try {
                return format_markdown (escaped);
            } catch (RegexError e) {
                return linkify (escaped);
            }
        }

        private static string format_markdown (string escaped) throws RegexError {
            ensure_regexes ();
            var segments = new GenericArray<string> ();
            string work = escaped;

            /* Code blocks: ```lang\ncontent``` — extract first to protect contents */
            work = extract_code (cb_re, work, segments);

            /* Inline code: `content` */
            work = extract_code (ic_re, work, segments);

            /* Bold: **text** and __text__ (backreference ensures matching delimiters) */
            work = bold_re.replace (work, -1, 0, "<b>\\2</b>");

            /* Italic: *text* and _text_ (underscore variant requires word boundaries) */
            work = italic_re.replace (work, -1, 0, "<i>\\1</i>");
            work = italic2_re.replace (work, -1, 0, "<i>\\1</i>");

            /* Strikethrough: ~~text~~ */
            work = strike_re.replace (work, -1, 0, "<s>\\1</s>");

            /* Headings: #, ##, ### */
            work = heading_re.replace_eval (work, -1, 0, 0, (mi, sb) => {
                var text = mi.fetch (2);
                switch (mi.fetch (1).length) {
                    case 1:
                        sb.append ("<span size=\"x-large\"><b>" + text + "</b></span>");
                        break;
                    case 2:
                        sb.append ("<span size=\"large\"><b>" + text + "</b></span>");
                        break;
                    default:
                        sb.append ("<b>" + text + "</b>");
                        break;
                }
                return false;
            });

            /* Linkify URLs */
            work = linkify (work);

            /* Restore protected code segments */
            for (int i = 0; i < segments.length; i++) {
                work = work.replace ("\x01%d\x01".printf (i), segments[i]);
            }

            return work;
        }

        /**
         * Replace regex matches with numbered placeholders, storing the
         * matched content wrapped in <tt> tags for later restoration.
         */
        private static string extract_code (Regex re, string input,
                                             GenericArray<string> segments) throws RegexError {
            return re.replace_eval (input, -1, 0, 0, (mi, sb) => {
                int idx = (int) segments.length;
                segments.add ("<tt>" + mi.fetch (1) + "</tt>");
                sb.append ("\x01%d\x01".printf (idx));
                return false;
            });
        }

        private static string linkify (string escaped) {
            try {
                ensure_regexes ();
                return link_re.replace_eval (escaped, -1, 0, 0, (mi, sb) => {
                    var url = mi.fetch (0);
                    sb.append ("<a href=\"");
                    sb.append (url);
                    sb.append ("\"><span foreground=\"#1c71d8\" underline=\"single\">");
                    sb.append (url);
                    sb.append ("</span></a>");
                    return false;
                });
            } catch (RegexError e) {
                return escaped;
            }
        }
    }
}
