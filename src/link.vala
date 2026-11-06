namespace Dc {

    /** URL extraction, tracking cleanup, and Open Graph metadata. */
    namespace Link {

        /* Ad-click and campaign IDs appended by platforms regardless of
           the destination site; always safe to drop. utm_* (Google
           Analytics), pk_/mtm_/piwik_ (Matomo), hsa_ (HubSpot ads). */
        private const string GLOBAL_PARAMS =
            "fbclid gclid gclsrc dclid wbraid gbraid msclkid yclid twclid "
            + "ttclid li_fat_id mc_cid mc_eid igshid srsltid s_cid _hsenc "
            + "_hsmi _openstat vero_conv vero_id oly_anon_id oly_enc_id";
        private const string GLOBAL_PREFIXES = "utm_ pk_ mtm_ piwik_ hsa_";

        /* Space-separated word lists; a host ending in ".*" matches the
           brand under any country TLD (amazon.co.uk, smile.amazon.de). */
        private struct SiteRule {
            unowned string hosts;
            unowned string params;
            unowned string prefixes;
        }
        private const SiteRule[] SITE_RULES = {
            { "youtube.com youtu.be",
              "si feature pp ab_channel embeds_referring_euri source_ve_path", "" },
            { "x.com twitter.com", "s t ref_src ref_url", "" },
            { "instagram.com threads.net threads.com", "igsh ig_rid ig_mid xmt", "" },
            /* __tn__, __cft__[0], __xts__[0] ... */
            { "facebook.com fb.com fb.watch fb.me messenger.com",
              "mibextid rdid share_url refid ref fref hc_ref sfnsn wtsid paipv "
              + "eav comment_tracking notif_id notif_t", "__" },
            { "linkedin.com lnkd.in",
              "trk trackingid lipi midtoken midsig trkemail ebp refid otptoken "
              + "original_referer rcm", "" },
            { "tiktok.com",
              "_t _r is_from_webapp sender_device sender_web_id web_id u_code "
              + "tt_from is_copy_url share_app_id share_link_id share_iid ug_btm "
              + "checksum", "" },
            { "reddit.com redd.it", "share_id ref ref_source rdt correlation_id", "" },
            { "spotify.com", "si nd _branch_match_id _branch_referrer", "" },
            { "twitch.tv", "tt_content tt_medium", "" },
            { "substack.com", "r", "" },
            /* YouTube thumbnail CDN: rendering hints and signatures that
               the plain .jpg does not need. */
            { "ytimg.com", "sqp rs usqp", "" },
            { "amazon.*",
              "tag ref ref_ ascsubtag linkcode linkid camp creative creativeasin "
              + "qid sr sprefix crid dib dib_tag content-id social_share",
              "pf_rd_ pd_rd_" },
            { "ebay.*",
              "mkcid mkevt mkrid ssspo sssrc ssuid campid toolid customid mkpid "
              + "ul_noapp amdata", "" },
            { "aliexpress.*",
              "spm scm aff_platform aff_trace_key aff_fcid aff_fsk terminal_id "
              + "pdp_npi gatewayadapt algo_pvid algo_exp_id utparam-url", "" },
        };

        /** Rewrites every http(s) URL found in the text; anything that is
            not a URL passes through unchanged. */
        public string clean_text (string text) {
            var result = new StringBuilder ();
            int pos = 0;
            while (true) {
                int start = find_url_start (text, pos);
                if (start < 0) break;
                int end = find_url_end (text, start);
                result.append (text[pos:start]);
                result.append (clean_url (text[start:end]));
                pos = end;
            }
            result.append (text.substring (pos));
            return result.str;
        }

        /** http(s) URLs in text, in order. Optionally de-duplicate and cap
            results for link previews; gallery callers keep every match. */
        public string[] urls_in_text (string text, int max = -1,
                                      bool unique = false) {
            string[] urls = {};
            if (max == 0) return urls;
            int pos = 0;
            while (true) {
                int start = find_url_start (text, pos);
                if (start < 0) break;
                int end = find_url_end (text, start);
                string url = text[start:end];
                if (!unique || !(url in urls)) urls += url;
                pos = end;
                if (max >= 0 && urls.length >= max) break;
            }
            return urls;
        }

        /** Strips tracking query parameters (and Amazon's /ref= path
            suffix) from a single URL. When a removeparam filter list is
            active (Settings → Links) it replaces the built-in rules. */
        public string clean_url (string url) {
            if (RemoveParamFilter.active != null)
                return RemoveParamFilter.active.clean_url (url);
            string host = host_of (url);

            int frag_start = url.index_of_char ('#');
            int query_start = url.index_of_char ('?');
            if (frag_start >= 0 && query_start > frag_start) query_start = -1;

            int base_end = query_start >= 0 ? query_start
                : (frag_start >= 0 ? frag_start : url.length);
            string base_part = url[0:base_end];
            string fragment = frag_start >= 0 ? url.substring (frag_start) : "";

            if (host_matches (host, "amazon.*"))
                base_part = strip_amazon_ref_path (base_part);

            if (query_start < 0) return base_part + fragment;

            int query_end = frag_start >= 0 ? frag_start : url.length;
            string query = url[query_start + 1:query_end];

            int site = site_rule_for (host);

            var kept = new StringBuilder ();
            foreach (string param in query.split ("&")) {
                if (param.length == 0) continue;
                int eq = param.index_of_char ('=');
                string name = (eq >= 0 ? param[0:eq] : param).down ();
                if (is_tracking_param (name, site))
                    continue;
                if (kept.len > 0) kept.append_c ('&');
                kept.append (param);
            }

            string cleaned = kept.len > 0
                ? base_part + "?" + kept.str
                : base_part;
            return cleaned + fragment;
        }

        private bool is_tracking_param (string name, int site) {
            if (has_word (GLOBAL_PARAMS, name) || has_prefix_in (GLOBAL_PREFIXES, name))
                return true;
            return site >= 0 && (has_word (SITE_RULES[site].params, name)
                || has_prefix_in (SITE_RULES[site].prefixes, name));
        }

        /* Index into SITE_RULES, or -1 when no site-specific rule applies. */
        private int site_rule_for (string host) {
            for (int i = 0; i < SITE_RULES.length; i++) {
                foreach (string pattern in SITE_RULES[i].hosts.split (" ")) {
                    if (host_matches (host, pattern)) return i;
                }
            }
            return -1;
        }

        /** Lowercased host without userinfo, port, or a leading www./m. */
        private string host_of (string url) {
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
            if (host.has_prefix ("www.")) host = host.substring (4);
            else if (host.has_prefix ("m.")) host = host.substring (2);
            return host;
        }

        /* "example.com" matches the domain and its subdomains; "brand.*"
           matches per-country TLDs: amazon.com, amazon.co.uk, smile.amazon.de */
        private bool host_matches (string host, string pattern) {
            if (pattern.has_suffix (".*")) {
                int idx = host.index_of (pattern[0:pattern.length - 1]);
                return idx == 0 || (idx > 0 && host[idx - 1] == '.');
            }
            return host == pattern || host.has_suffix ("." + pattern);
        }

        /* Amazon appends the click source as a trailing path segment:
           /dp/B0XXXXXXXX/ref=sr_1_3 -> /dp/B0XXXXXXXX */
        private string strip_amazon_ref_path (string base_part) {
            int idx = base_part.index_of ("/ref=");
            return idx >= 0 ? base_part[0:idx] : base_part;
        }

        private int find_url_start (string text, int pos) {
            int idx = text.index_of ("http", pos);
            while (idx >= 0) {
                string rest = text.substring (idx);
                if (rest.has_prefix ("http://") || rest.has_prefix ("https://"))
                    return idx;
                idx = text.index_of ("http", idx + 4);
            }
            return -1;
        }

        private int find_url_end (string text, int start) {
            int end = start;
            while (end < text.length) {
                char c = text[end];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r'
                    || c == '<' || c == '>' || c == '"' || c == '\'')
                    break;
                end++;
            }
            /* Trailing punctuation belongs to the sentence, not the URL;
               a ')' or ']' only when unbalanced within the URL itself. */
            while (end > start) {
                char c = text[end - 1];
                if (c == '.' || c == ',' || c == ';' || c == ':'
                    || c == '!' || c == '?') {
                    end--;
                } else if ((c == ')' && !is_balanced (text, start, end, '(', ')'))
                           || (c == ']' && !is_balanced (text, start, end, '[', ']'))) {
                    end--;
                } else {
                    break;
                }
            }
            return end;
        }

        private bool is_balanced (string text, int start, int end,
                                         char open, char close) {
            int depth = 0;
            for (int i = start; i < end; i++) {
                if (text[i] == open) depth++;
                else if (text[i] == close) depth--;
            }
            return depth >= 0;
        }

        private bool has_word (string words, string word) {
            return (" " + words + " ").contains (" " + word + " ");
        }

        private bool has_prefix_in (string prefixes, string name) {
            foreach (string prefix in prefixes.split (" ")) {
                if (prefix.length > 0 && name.has_prefix (prefix)) return true;
            }
            return false;
        }

        /* Never fetch more than this many links from a single paste. */
        public const int MAX_PREVIEWS = 5;
        /* Only the head of the document is scanned; OG tags live there.
           Same bound as Signal's 1000 KiB: YouTube's head alone runs
           past 690 KB. */
        public const int MAX_HTML_BYTES = 1024 * 1024;
        /* Refuse absurd images: the core would recompress on send, but
           the download itself must stay bounded. */
        public const int64 MAX_IMAGE_BYTES = 8 * 1024 * 1024;
        public const int MAX_TITLE_CHARS = 120;
        public const int MAX_DESCRIPTION_CHARS = 200;

        /** Parsed metadata; thumbnail() sets image_path, which the caller must remove. */
        public class Preview : Object {
            public string? title;
            public string? description;
            public string? image_url;
            public string? image_path;
            public string? file_name;
        }

        /** Extracts preview metadata from an HTML document. `base_url` is
            the page URL, used to resolve relative image references.
            Returns null when the page yields neither an image nor a
            title. */
        public Preview? open_graph (string html, string base_url) {
            string doc = html.length > MAX_HTML_BYTES
                ? html.substring (0, MAX_HTML_BYTES) : html;
            if (!doc.validate ()) doc = doc.make_valid ();

            string? og_title = null, og_desc = null, og_image = null;
            string? tw_title = null, tw_desc = null, tw_image = null;
            string? html_title = null, meta_desc = null, link_image = null;

            int pos = 0;
            while (true) {
                int lt = doc.index_of_char ('<', pos);
                if (lt < 0) break;
                /* Skip comments wholesale so commented-out tags are not
                   picked up. */
                if (lt + 4 <= doc.length && doc.substring (lt, 4) == "<!--") {
                    int close = doc.index_of ("-->", lt + 4);
                    if (close < 0) break;
                    pos = close + 3;
                    continue;
                }
                int gt = find_tag_end (doc, lt + 1);
                if (gt < 0) break;
                string tag = doc.substring (lt + 1, gt - lt - 1);
                pos = gt + 1;
                string lower = tag.down ();

                if (lower.has_prefix ("meta") && is_tag_boundary (lower, 4)) {
                    var attrs = parse_attributes (tag.substring (4));
                    string key = (attrs.lookup ("property")
                        ?? attrs.lookup ("name") ?? "").down ().strip ();
                    string? content = attrs.lookup ("content");
                    if (content == null) continue;
                    content = decode_entities (content).strip ();
                    if (content.length == 0) continue;
                    switch (key) {
                    case "og:title":
                        if (og_title == null) og_title = content;
                        break;
                    case "og:description":
                        if (og_desc == null) og_desc = content;
                        break;
                    case "og:image":
                    case "og:image:url":
                    case "og:image:secure_url":
                        /* The first og:image is the site's pick; a later
                           secure_url only replaces a plain http one. */
                        if (og_image == null
                            || (key == "og:image:secure_url"
                                && og_image.has_prefix ("http://")))
                            og_image = content;
                        break;
                    case "twitter:title":
                        if (tw_title == null) tw_title = content;
                        break;
                    case "twitter:description":
                        if (tw_desc == null) tw_desc = content;
                        break;
                    case "twitter:image":
                    case "twitter:image:src":
                        if (tw_image == null) tw_image = content;
                        break;
                    case "description":
                        if (meta_desc == null) meta_desc = content;
                        break;
                    default:
                        break;
                    }
                } else if (lower.has_prefix ("link") && is_tag_boundary (lower, 4)) {
                    var attrs = parse_attributes (tag.substring (4));
                    string rel = (attrs.lookup ("rel") ?? "").down ();
                    string? href = attrs.lookup ("href");
                    if (href != null && link_image == null
                        && ("image_src" in rel.split (" ")))
                        link_image = decode_entities (href).strip ();
                } else if (lower.has_prefix ("title") && is_tag_boundary (lower, 5)
                           && html_title == null) {
                    int close = doc.ascii_down ().index_of ("</title", pos);
                    if (close < 0) break;
                    html_title = decode_entities (doc.substring (pos, close - pos))
                        .strip ();
                    pos = close;
                } else if (lower.has_prefix ("/head") || lower.has_prefix ("body")) {
                    /* Nothing of interest below the head; bail out early. */
                    break;
                }
            }

            var meta = new Preview ();
            meta.title = shorten (og_title ?? tw_title ?? html_title,
                MAX_TITLE_CHARS);
            meta.description = shorten (og_desc ?? tw_desc ?? meta_desc,
                MAX_DESCRIPTION_CHARS);
            string? img = og_image ?? tw_image ?? link_image;
            if (img != null) meta.image_url = resolve_url (base_url, img);
            if (meta.image_url == null && meta.title == null) return null;
            return meta;
        }

        /** Resolves `href` against `base_url`; only http(s) results are
            accepted. */
        internal string? resolve_url (string base_url, string href) {
            string h = href.strip ();
            if (h.length == 0) return null;
            string? resolved = null;
            try {
                if (h.has_prefix ("http://") || h.has_prefix ("https://")) {
                    resolved = h;
                } else {
                    resolved = GLib.Uri.resolve_relative (base_url, h,
                        GLib.UriFlags.ENCODED | GLib.UriFlags.PARSE_RELAXED);
                }
            } catch (Error e) {
                return null;
            }
            if (resolved == null) return null;
            if (!resolved.has_prefix ("http://") && !resolved.has_prefix ("https://"))
                return null;
            return resolved;
        }

        /** Collapses whitespace and truncates to `max_chars` with an
            ellipsis. Returns null for empty input. */
        internal string? shorten (string? text, int max_chars) {
            if (text == null) return null;
            var sb = new StringBuilder ();
            bool space = false;
            int i = 0;
            unichar c;
            while (text.get_next_char (ref i, out c)) {
                if (c.isspace ()) {
                    space = true;
                    continue;
                }
                if (space && sb.len > 0) sb.append_c (' ');
                space = false;
                sb.append_unichar (c);
            }
            string s = sb.str;
            if (s.length == 0) return null;
            if (s.char_count () <= max_chars) return s;
            int cut = s.index_of_nth_char (max_chars - 1);
            return s.substring (0, cut).chomp () + "…";
        }

        /** Decodes the named and numeric character references that show
            up in meta content. */
        internal string decode_entities (string text) {
            if (text.index_of_char ('&') < 0) return text;
            var sb = new StringBuilder ();
            int pos = 0;
            while (pos < text.length) {
                int amp = text.index_of_char ('&', pos);
                if (amp < 0) {
                    sb.append (text.substring (pos));
                    break;
                }
                sb.append (text.substring (pos, amp - pos));
                int semi = text.index_of_char (';', amp);
                if (semi < 0 || semi - amp > 12) {
                    sb.append_c ('&');
                    pos = amp + 1;
                    continue;
                }
                string name = text.substring (amp + 1, semi - amp - 1);
                string? rep = null;
                if (name.has_prefix ("#x") || name.has_prefix ("#X")) {
                    int64 v;
                    if (int64.try_parse (name.substring (2), out v, null, 16)
                        && v > 0 && v <= 0x10FFFF)
                        rep = ((unichar) v).to_string ();
                } else if (name.has_prefix ("#")) {
                    int64 v;
                    if (int64.try_parse (name.substring (1), out v, null, 10)
                        && v > 0 && v <= 0x10FFFF)
                        rep = ((unichar) v).to_string ();
                } else {
                    switch (name) {
                    case "amp": rep = "&"; break;
                    case "lt": rep = "<"; break;
                    case "gt": rep = ">"; break;
                    case "quot": rep = "\""; break;
                    case "apos": rep = "'"; break;
                    case "nbsp": rep = " "; break;
                    case "ndash": rep = "–"; break;
                    case "mdash": rep = "—"; break;
                    case "hellip": rep = "…"; break;
                    case "laquo": rep = "«"; break;
                    case "raquo": rep = "»"; break;
                    case "lsquo": rep = "‘"; break;
                    case "rsquo": rep = "’"; break;
                    case "ldquo": rep = "“"; break;
                    case "rdquo": rep = "”"; break;
                    case "copy": rep = "©"; break;
                    case "reg": rep = "®"; break;
                    case "trade": rep = "™"; break;
                    case "euro": rep = "€"; break;
                    case "middot": rep = "·"; break;
                    case "bull": rep = "•"; break;
                    default: break;
                    }
                }
                if (rep == null) {
                    sb.append_c ('&');
                    pos = amp + 1;
                } else {
                    sb.append (rep);
                    pos = semi + 1;
                }
            }
            return sb.str;
        }

        /** Apply the same tracking rules to images, preserving content parameters. */
        public string image_fetch_url (string url, bool clean) {
            return clean ? clean_url (url) : url;
        }

        /* ---- helpers ---- */

        private bool is_tag_boundary (string lower, int at) {
            if (lower.length <= at) return true;
            char c = lower[at];
            return c == ' ' || c == '\t' || c == '\n' || c == '\r'
                || c == '/' || c == '>';
        }

        /* Index of the '>' closing the tag opened just before `from`,
           honouring quoted attribute values. */
        private int find_tag_end (string doc, int from) {
            char quote = 0;
            for (int i = from; i < doc.length; i++) {
                char c = doc[i];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' || c == '\'') {
                    quote = c;
                } else if (c == '>') {
                    return i;
                }
            }
            return -1;
        }

        private HashTable<string, string> parse_attributes (string s) {
            var attrs = new HashTable<string, string> (str_hash, str_equal);
            int i = 0;
            int n = s.length;
            while (i < n) {
                while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'
                                 || s[i] == '\r' || s[i] == '/')) i++;
                if (i >= n) break;
                int name_start = i;
                while (i < n && s[i] != '=' && s[i] != ' ' && s[i] != '\t'
                       && s[i] != '\n' && s[i] != '\r' && s[i] != '/'
                       && s[i] != '>') i++;
                string name = s.substring (name_start, i - name_start).down ();
                if (name.length == 0) { i++; continue; }
                while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'
                                 || s[i] == '\r')) i++;
                string value = "";
                if (i < n && s[i] == '=') {
                    i++;
                    while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'
                                     || s[i] == '\r')) i++;
                    if (i < n && (s[i] == '"' || s[i] == '\'')) {
                        char q = s[i];
                        int vs = ++i;
                        while (i < n && s[i] != q) i++;
                        value = s.substring (vs, i - vs);
                        if (i < n) i++;
                    } else {
                        int vs = i;
                        while (i < n && s[i] != ' ' && s[i] != '\t'
                               && s[i] != '\n' && s[i] != '\r' && s[i] != '>') i++;
                        value = s.substring (vs, i - vs);
                    }
                }
                if (!attrs.contains (name)) attrs.insert (name, value);
            }
            return attrs;
        }
    }
}
