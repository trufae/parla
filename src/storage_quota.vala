namespace Dc {

    public class LocalStorageUsage : Object {
        public bool available { get; private set; }
        public int64 total_bytes { get; private set; }
        public int64 downloaded_bytes { get; private set; }
        public int64 profile_bytes { get { return total_bytes - downloaded_bytes; } }

        public LocalStorageUsage (int64 account_bytes, int64 downloaded_bytes) {
            available = account_bytes >= 0;
            this.downloaded_bytes = int64.max (0, downloaded_bytes);
            // Core's account size already includes the blob directory. The
            // scans are not atomic, so allow for files arriving between them.
            total_bytes = int64.max (account_bytes, this.downloaded_bytes);
        }

        public double downloaded_fraction () {
            return available && total_bytes > 0
                ? (double) downloaded_bytes / (double) total_bytes : 0.0;
        }

        public string summary_text () {
            if (!available) {
                return _("%s downloaded message files · local profile total unavailable").printf (
                    StorageQuota.format_mb (downloaded_bytes));
            }
            return _("%s profile and other data · %s downloaded message files · %s total").printf (
                StorageQuota.format_mb (profile_bytes),
                StorageQuota.format_mb (downloaded_bytes),
                StorageQuota.format_mb (total_bytes));
        }
    }

    public class StorageQuota : Object {
        public bool available { get; set; default = false; }
        public int64 used_bytes { get; set; default = 0; }
        public int64 limit_bytes { get; set; default = 0; }

        private const double WARNING_FRACTION = 0.75;
        private const double ERROR_FRACTION = 0.95;
        private static Regex? quota_re = null;

        public static StorageQuota parse_connectivity_report (string report) {
            var quota = new StorageQuota ();
            string text = html_to_text (report);

            try {
                ensure_regex ();
                MatchInfo match;
                if (quota_re.match (text, 0, out match)) {
                    double used = parse_number (match.fetch (1));
                    string used_unit = match.fetch (2);
                    double limit = parse_number (match.fetch (3));
                    string limit_unit = match.fetch (4);
                    quota.used_bytes = unit_to_bytes (used, used_unit);
                    quota.limit_bytes = unit_to_bytes (limit, limit_unit);
                    quota.available = quota.limit_bytes > 0;
                }
            } catch (Error e) {
                /* Keep quota unavailable when the server report changes shape. */
            }

            return quota;
        }

        public bool has_limit () {
            return available && limit_bytes > 0;
        }

        public int64 left_bytes () {
            int64 left = limit_bytes - used_bytes;
            return left > 0 ? left : 0;
        }

        public double used_fraction () {
            if (!has_limit ()) return 0.0;

            double fraction = (double) used_bytes / (double) limit_bytes;
            if (fraction < 0.0) return 0.0;
            if (fraction > 1.0) return 1.0;
            return fraction;
        }

        public bool is_warning () {
            double fraction = used_fraction ();
            return fraction >= WARNING_FRACTION && fraction < ERROR_FRACTION;
        }

        public bool is_error () {
            return used_fraction () >= ERROR_FRACTION;
        }

        public string summary_text () {
            if (!has_limit ()) return _("Server quota has not been reported yet.");
            return _("%s used · %s left of %s").printf (
                format_mb (used_bytes),
                format_mb (left_bytes ()),
                format_mb (limit_bytes));
        }

        public static string format_mb (int64 bytes) {
            double mb = (double) bytes / (1024.0 * 1024.0);
            return "%.1f MB".printf (mb);
        }

        private static void ensure_regex () throws RegexError {
            if (quota_re != null) return;
            quota_re = new Regex (
                "([0-9]+(?:[\\.,][0-9]+)?)\\s*([KMGT]?i?B)\\s+of\\s+" +
                "([0-9]+(?:[\\.,][0-9]+)?)\\s*([KMGT]?i?B)\\s+used",
                RegexCompileFlags.CASELESS);
        }

        private static string html_to_text (string html) {
            var sb = new StringBuilder ();
            bool in_tag = false;
            bool last_space = false;

            for (int i = 0; i < html.length; i++) {
                char c = html[i];
                if (in_tag) {
                    if (c == '>') {
                        in_tag = false;
                        append_space (sb, ref last_space);
                    }
                    continue;
                }

                if (c == '<') {
                    in_tag = true;
                    append_space (sb, ref last_space);
                    continue;
                }

                if (c == '&') {
                    int semi = html.index_of_char (';', i + 1);
                    if (semi > i && semi - i <= 16) {
                        string? decoded = decode_entity (
                            html.substring (i + 1, semi - i - 1));
                        if (decoded != null) {
                            append_text (sb, decoded, ref last_space);
                            i = semi;
                            continue;
                        }
                    }
                }

                if (is_space (c)) {
                    append_space (sb, ref last_space);
                } else {
                    sb.append_c (c);
                    last_space = false;
                }
            }

            return sb.str.strip ();
        }

        private static string? decode_entity (string entity) {
            string e = entity.down ();
            switch (e) {
            case "amp":
                return "&";
            case "lt":
                return "<";
            case "gt":
                return ">";
            case "quot":
                return "\"";
            case "apos":
                return "'";
            case "nbsp":
                return " ";
            default:
                if (e.has_prefix ("#")) {
                    return decode_numeric_entity (e);
                }
                return null;
            }
        }

        private static string? decode_numeric_entity (string entity) {
            int start = 1;
            int radix = 10;
            if (entity.length > 2 && entity[1] == 'x') {
                start = 2;
                radix = 16;
            }

            uint code = 0;
            for (int i = start; i < entity.length; i++) {
                int digit = digit_for_base (entity[i], radix);
                if (digit < 0) return null;
                code = code * radix + digit;
                if (code > 0x10ffff) return null;
            }
            if (code == 0) return null;

            unichar ch = (unichar) code;
            return ch.to_string ();
        }

        private static int digit_for_base (char c, int radix) {
            int digit = -1;
            if (c >= '0' && c <= '9') digit = c - '0';
            else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
            return digit >= 0 && digit < radix ? digit : -1;
        }

        private static void append_text (StringBuilder sb, string text,
                                          ref bool last_space) {
            if (text.length == 0) return;
            if (text.strip ().length == 0) {
                append_space (sb, ref last_space);
                return;
            }
            sb.append (text);
            last_space = false;
        }

        private static void append_space (StringBuilder sb, ref bool last_space) {
            if (last_space || sb.len == 0) return;
            sb.append_c (' ');
            last_space = true;
        }

        private static bool is_space (char c) {
            return c == ' ' || c == '\t' || c == '\n' ||
                   c == '\r' || c == '\f';
        }

        private static double parse_number (string s) {
            return double.parse (s.replace (",", "."));
        }

        private static int64 unit_to_bytes (double value, string unit) {
            string u = unit.up ();
            double mult = 1.0;
            if (u == "KB" || u == "KIB") mult = 1024.0;
            else if (u == "MB" || u == "MIB") mult = 1024.0 * 1024.0;
            else if (u == "GB" || u == "GIB") mult = 1024.0 * 1024.0 * 1024.0;
            else if (u == "TB" || u == "TIB") mult = 1024.0 * 1024.0 * 1024.0 * 1024.0;
            return (int64) (value * mult);
        }
    }
}
