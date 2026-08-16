namespace Dc {

    /**
     * Interpreter for the `$removeparam` subset of uBlock Origin / AdGuard
     * filter lists (for example the AdGuard URL Tracking filter,
     * https://filters.adtidy.org/extension/ublock/filters/17.txt).
     *
     * A parsed list replaces LinkCleaner's built-in rules for pasted
     * links: every rule whose URL pattern matches the link decides which
     * query parameters are dropped. Supported syntax:
     *
     *   pattern$removeparam=name          drop parameter `name`
     *   pattern$removeparam=/regex/       drop `name=value` pairs matching
     *   pattern$removeparam=~name         drop everything except `name`
     *   pattern$removeparam               drop the whole query
     *   @@pattern$removeparam[=x]         exception (keep x / keep all)
     *   options: domain=, denyallow=, request types, ~3p, match-case
     *
     * Patterns follow ABP conventions: `||host^`, `|` anchors, `*` and
     * `^` wildcards, `/regex/`. Since a pasted link is a top-level
     * navigation, rules restricted to other request types (xhr, script,
     * image, ...) are ignored and `domain=` is checked against the link's
     * own host.
     */
    public class RemoveParamFilter : Object {

        /** The list applied by LinkCleaner; null keeps the built-in rules. */
        public static RemoveParamFilter? active = null;

        public string title { get; private set; default = ""; }
        public string version { get; private set; default = ""; }
        /** From the `! Expires:` header; DEFAULT_EXPIRES when absent. */
        public int64 expires_seconds { get; private set; default = DEFAULT_EXPIRES; }
        public int rule_count { get { return rules.length; } }

        public const int64 DEFAULT_EXPIRES = 5 * 24 * 3600;
        public const string DEFAULT_URL =
            "https://filters.adtidy.org/extension/ublock/filters/17.txt";

        private class Rule {
            public bool exception = false;
            public bool remove_all = false;
            public bool inverse = false;
            public string? param_name = null;
            public Regex? param_regex = null;
            /* URL pattern: null regex means "matches everything". */
            public Regex? pattern = null;
            /* Fast reject for `||host` patterns: the URL host must equal
               or end with ".host". */
            public string? host_hint = null;
            public string[] domains = {};
            public string[] not_domains = {};
            public string[] denyallow = {};
        }

        private Rule[] rules = {};

        public static string cache_path () {
            return Path.build_filename (Environment.get_user_config_dir (),
                                        "parla", "tracking_filter.txt");
        }

        /** Parses a filter list; returns null when it holds no usable rule. */
        public static RemoveParamFilter? from_text (string text) {
            var f = new RemoveParamFilter ();
            f.parse (text);
            return f.rules.length > 0 ? f : null;
        }

        public static RemoveParamFilter? load_cached () {
            string text;
            try {
                FileUtils.get_contents (cache_path (), out text);
            } catch (Error e) {
                return null;
            }
            return from_text (text);
        }

        public static bool save_cached (string text) {
            try {
                DirUtils.create_with_parents (
                    Path.get_dirname (cache_path ()), 0755);
                FileUtils.set_contents (cache_path (), text);
                return true;
            } catch (Error e) {
                warning ("tracking filter: cannot save list: %s", e.message);
                return false;
            }
        }

        /** Modification time of the cached list, null when absent. */
        public static DateTime? cache_time () {
            try {
                var info = File.new_for_path (cache_path ()).query_info (
                    FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                return info.get_modification_date_time ();
            } catch (Error e) {
                return null;
            }
        }

        /** True when the cache is missing or older than the list's own
            expiry (or `min_age` seconds, whichever is larger). */
        public bool cache_is_stale (int64 min_age = 3600) {
            var t = cache_time ();
            if (t == null) return true;
            int64 age = new DateTime.now_utc ().to_unix () - t.to_unix ();
            return age > int64.max (expires_seconds, min_age);
        }

        /* ------------------------------------------------------------ */
        /*  Parsing                                                     */
        /* ------------------------------------------------------------ */

        private void parse (string text) {
            foreach (string raw in text.split ("\n")) {
                string line = raw.strip ();
                if (line.length == 0) continue;
                if (line[0] == '!' || line[0] == '[') {
                    parse_header (line);
                    continue;
                }
                if (line[0] == '#' && (line.length == 1 || line[1] == ' '))
                    continue;
                /* Cosmetic / HTML filtering rules never carry removeparam. */
                if (line.contains ("##") || line.contains ("#@#")
                    || line.contains ("#?#") || line.contains ("#$#")
                    || line.contains ("$$"))
                    continue;
                Rule? r = parse_rule (line);
                if (r != null) rules += r;
            }
        }

        private void parse_header (string line) {
            if (line.has_prefix ("! Title:")) {
                title = line.substring (8).strip ();
            } else if (line.has_prefix ("! Version:")) {
                version = line.substring (10).strip ();
            } else if (line.has_prefix ("! Expires:")) {
                string v = line.substring (10).strip ().down ();
                int n = int.parse (v);
                if (n > 0) {
                    if (v.contains ("hour")) expires_seconds = n * 3600;
                    else expires_seconds = n * 24 * 3600;
                }
            }
        }

        private static Rule? parse_rule (string input) {
            string line = input;
            var r = new Rule ();
            if (line.has_prefix ("@@")) {
                r.exception = true;
                line = line.substring (2);
            }

            int sep = find_options_separator (line);
            if (sep < 0) return null;
            string pattern = line[0:sep];
            string options = line.substring (sep + 1);

            bool has_removeparam = false;
            bool match_case = false;
            bool type_restricted = false;
            bool allows_document = false;
            foreach (string opt in split_unescaped (options, ',')) {
                string o = opt.strip ();
                if (o.length == 0) continue;
                int eq = o.index_of_char ('=');
                string key = eq >= 0 ? o[0:eq] : o;
                string val = eq >= 0 ? o.substring (eq + 1) : "";
                switch (key) {
                case "removeparam":
                case "queryprune":
                    has_removeparam = true;
                    if (!parse_removeparam_value (r, unescape (val)))
                        return null;
                    break;
                case "domain":
                case "from":
                    foreach (string d in val.split ("|")) {
                        if (d.length == 0) continue;
                        if (d[0] == '~') r.not_domains += d.substring (1).down ();
                        else r.domains += d.down ();
                    }
                    break;
                case "denyallow":
                    foreach (string d in val.split ("|")) {
                        if (d.length > 0) r.denyallow += d.down ();
                    }
                    break;
                case "match-case":
                    match_case = true;
                    break;
                case "document":
                case "doc":
                case "all":
                    type_restricted = true;
                    allows_document = true;
                    break;
                case "~document":
                case "~doc":
                    return null;
                case "xhr": case "xmlhttprequest": case "script":
                case "image": case "font": case "media": case "stylesheet":
                case "css": case "subdocument": case "frame": case "object":
                case "ping": case "beacon": case "websocket": case "other":
                case "webrtc": case "popup":
                    type_restricted = true;
                    break;
                case "3p": case "~3p": case "third-party": case "~third-party":
                case "1p": case "~1p": case "first-party": case "~first-party":
                case "important": case "app": case "~xhr": case "~script":
                case "~image": case "~font": case "~media": case "~stylesheet":
                case "~subdocument": case "~object": case "~ping":
                case "~websocket": case "~other":
                    break;
                case "badfilter":
                    return null;
                default:
                    /* Unknown modifier: better to ignore the rule than to
                       misapply it. */
                    return null;
                }
            }
            if (!has_removeparam) return null;
            if (type_restricted && !allows_document) return null;

            if (!compile_pattern (r, pattern, match_case)) return null;
            return r;
        }

        private static bool parse_removeparam_value (Rule r, string value) {
            string v = value;
            if (v.length == 0) {
                r.remove_all = true;
                return true;
            }
            if (v[0] == '~') {
                r.inverse = true;
                v = v.substring (1);
                if (v.length == 0) return false;
            }
            if (v.length >= 2 && v[0] == '/' && v[v.length - 1] == '/') {
                try {
                    r.param_regex = new Regex (v[1:v.length - 1],
                                               RegexCompileFlags.OPTIMIZE);
                } catch (Error e) {
                    debug ("tracking filter: bad param regex %s: %s", v, e.message);
                    return false;
                }
            } else {
                r.param_name = v;
            }
            return true;
        }

        /* Locates the `$` that starts the modifier list: the first `$`
           followed by something that looks like an option name. */
        private static int find_options_separator (string line) {
            int idx = line.index_of_char ('$');
            while (idx >= 0) {
                if (idx > 0 && line[idx - 1] == '\\') {
                    idx = line.index_of_char ('$', idx + 1);
                    continue;
                }
                int i = idx + 1;
                if (i < line.length && line[i] == '~') i++;
                int name_start = i;
                while (i < line.length
                       && (line[i].isalnum () || line[i] == '-' || line[i] == '_'))
                    i++;
                if (i > name_start
                    && (i == line.length || line[i] == '=' || line[i] == ','))
                    return idx;
                idx = line.index_of_char ('$', idx + 1);
            }
            return -1;
        }

        private static string[] split_unescaped (string s, char sep) {
            string[] parts = {};
            var cur = new StringBuilder ();
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if (c == '\\' && i + 1 < s.length && s[i + 1] == sep) {
                    cur.append_c ('\\');
                    cur.append_c (sep);
                    i++;
                } else if (c == sep) {
                    parts += cur.str;
                    cur.truncate ();
                } else {
                    cur.append_c (c);
                }
            }
            parts += cur.str;
            return parts;
        }

        /* `\,` hides the option separator; lists write a literal `$`
           (the modifier separator) as `\\$`, which as a regex must stay
           an escaped dollar rather than an anchor. */
        private static string unescape (string s) {
            return s.replace ("\\,", ",").replace ("\\\\$", "\\$");
        }

        private static bool compile_pattern (Rule r, string pattern,
                                             bool match_case) {
            string p = pattern;
            if (p.length == 0 || p == "*") return true;

            var flags = match_case ? RegexCompileFlags.OPTIMIZE
                : RegexCompileFlags.OPTIMIZE | RegexCompileFlags.CASELESS;

            if (p.length > 2 && p[0] == '/' && p[p.length - 1] == '/') {
                try {
                    r.pattern = new Regex (p[1:p.length - 1], flags);
                    return true;
                } catch (Error e) {
                    debug ("tracking filter: bad pattern %s: %s", p, e.message);
                    return false;
                }
            }

            var re = new StringBuilder ();
            int i = 0;
            if (p.has_prefix ("||")) {
                re.append ("^[a-z][a-z0-9+.-]*://(?:[^/?#]*@)?(?:[^/?#]*\\.)?");
                i = 2;
                /* Literal host prefix, usable as a fast reject. */
                int j = i;
                while (j < p.length
                       && (p[j].isalnum () || p[j] == '.' || p[j] == '-' || p[j] == '_'))
                    j++;
                bool boundary = j == p.length || p[j] == '^' || p[j] == '/'
                    || p[j] == '?' || p[j] == '|';
                if (j > i && boundary && p[j - 1] != '.')
                    r.host_hint = p[i:j].down ();
            } else if (p.has_prefix ("|")) {
                re.append_c ('^');
                i = 1;
            }
            int end = p.length;
            bool anchor_end = false;
            if (end > i && p[end - 1] == '|') {
                anchor_end = true;
                end--;
            }
            for (; i < end; i++) {
                char c = p[i];
                if (c == '*') {
                    re.append (".*");
                } else if (c == '^') {
                    re.append ("(?:[^0-9a-zA-Z_.%-]|$)");
                } else if (c.isalnum ()) {
                    re.append_c (c);
                } else {
                    re.append_c ('\\');
                    re.append_c (c);
                }
            }
            if (anchor_end) re.append_c ('$');
            try {
                r.pattern = new Regex (re.str, flags);
            } catch (Error e) {
                debug ("tracking filter: bad pattern %s: %s", p, e.message);
                return false;
            }
            return true;
        }

        /* ------------------------------------------------------------ */
        /*  Matching                                                    */
        /* ------------------------------------------------------------ */

        /** Applies the list to one http(s) URL. */
        public string clean_url (string url) {
            if (!url.has_prefix ("http://") && !url.has_prefix ("https://"))
                return url;
            int frag_start = url.index_of_char ('#');
            int query_start = url.index_of_char ('?');
            if (frag_start >= 0 && query_start > frag_start) query_start = -1;
            if (query_start < 0) return url;

            string host = host_of (url);
            int query_end = frag_start >= 0 ? frag_start : url.length;
            string query = url[query_start + 1:query_end];
            if (query.length == 0) return url;
            string[] pairs = query.split ("&");
            bool[] removed = new bool[pairs.length];
            bool[] shielded = new bool[pairs.length];

            /* Exceptions first: a bare one shields the whole URL. */
            foreach (Rule r in rules) {
                if (!r.exception || !rule_matches (r, url, host)) continue;
                if (r.remove_all) return url;
                for (int i = 0; i < pairs.length; i++) {
                    if (param_selected (r, pairs[i])) shielded[i] = true;
                }
            }

            bool any = false;
            foreach (Rule r in rules) {
                if (r.exception || !rule_matches (r, url, host)) continue;
                for (int i = 0; i < pairs.length; i++) {
                    if (removed[i] || shielded[i]) continue;
                    if (r.remove_all || param_selected (r, pairs[i])) {
                        removed[i] = true;
                        any = true;
                    }
                }
            }
            if (!any) return url;

            var kept = new StringBuilder ();
            for (int i = 0; i < pairs.length; i++) {
                if (removed[i]) continue;
                if (kept.len > 0) kept.append_c ('&');
                kept.append (pairs[i]);
            }
            string result = url[0:query_start];
            if (kept.len > 0) result += "?" + kept.str;
            if (frag_start >= 0) result += url.substring (frag_start);
            return result;
        }

        private static bool param_selected (Rule r, string pair) {
            bool hit;
            if (r.param_name != null) {
                int eq = pair.index_of_char ('=');
                string name = eq >= 0 ? pair[0:eq] : pair;
                hit = name == r.param_name;
            } else if (r.param_regex != null) {
                hit = r.param_regex.match (pair);
                if (!hit) {
                    string decoded = Uri.unescape_string (pair) ?? pair;
                    if (decoded != pair) hit = r.param_regex.match (decoded);
                }
            } else {
                return false;
            }
            return r.inverse ? !hit : hit;
        }

        private static bool rule_matches (Rule r, string url, string host) {
            if (r.host_hint != null && !host_matches (host, r.host_hint))
                return false;
            if (r.pattern != null && !r.pattern.match (url)) return false;
            if (r.domains.length > 0 && !in_domain_list (host, r.domains))
                return false;
            if (r.not_domains.length > 0 && in_domain_list (host, r.not_domains))
                return false;
            if (r.denyallow.length > 0 && in_domain_list (host, r.denyallow))
                return false;
            return true;
        }

        private static bool in_domain_list (string host, string[] list) {
            foreach (string d in list) {
                if (host_matches (host, d)) return true;
            }
            return false;
        }

        /* `amazon.*` matches amazon.com, www.amazon.co.uk, ... */
        private static bool host_matches (string host, string domain) {
            if (domain.has_suffix (".*")) {
                string prefix = domain[0:domain.length - 1];
                if (host.has_prefix (prefix)) return true;
                int idx = host.index_of ("." + prefix);
                return idx > 0 && idx + prefix.length + 1 < host.length;
            }
            return host == domain || host.has_suffix ("." + domain);
        }

        /** Lowercased host without userinfo or port. */
        private static string host_of (string url) {
            int scheme_end = url.index_of ("://");
            if (scheme_end < 0) return "";
            int start = scheme_end + 3;
            int end = start;
            while (end < url.length) {
                char c = url[end];
                if (c == '/' || c == '?' || c == '#') break;
                end++;
            }
            string host = url[start:end].down ();
            int at = host.last_index_of_char ('@');
            if (at >= 0) host = host.substring (at + 1);
            int colon = host.index_of_char (':');
            if (colon >= 0) host = host[0:colon];
            return host;
        }
    }
}
