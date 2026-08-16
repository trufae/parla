namespace Dc {

    /**
     * Sender-side link previews, in the spirit of Signal: when the user
     * pastes a link into the composer the page is fetched, its Open Graph
     * metadata (og:title / og:description / og:image, with twitter:* and
     * plain <title>/<meta name=description> fallbacks) is extracted and the
     * picked image is attached to the outgoing message. Delta Chat has no
     * structured preview payload, so the preview travels as an ordinary
     * image attachment every client can render.
     *
     * This file only holds the pure, testable parts (URL picking, HTML
     * scanning, entity decoding, image URL resolution); the network side
     * lives in ConversationView, which fetches through core's
     * get_http_response so proxy settings apply and nothing bypasses the
     * account's transport configuration.
     */
    namespace LinkPreview {

        /* Never fetch more than this many links from a single paste. */
        public const int MAX_LINKS = 5;
        /* Only the head of the document is scanned; OG tags live there.
           Same bound as Signal's 1000 KiB: YouTube's head alone runs
           past 690 KB. */
        public const int MAX_HTML_BYTES = 1024 * 1024;
        /* Refuse absurd images: the core would recompress on send, but
           the download itself must stay bounded. */
        public const int64 MAX_IMAGE_BYTES = 8 * 1024 * 1024;
        public const int MAX_TITLE_CHARS = 120;
        public const int MAX_DESCRIPTION_CHARS = 200;

        public class Metadata {
            public string? title = null;
            public string? description = null;
            public string? image_url = null;

            /** Short caption for the attached image: title, plus the
                description when there is room. */
            public string caption () {
                string t = title ?? "";
                string d = description ?? "";
                if (t.length == 0) return d;
                if (d.length == 0) return t;
                return "%s\n%s".printf (t, d);
            }
        }

        /** Distinct http(s) URLs in paste order, capped at MAX_LINKS. */
        public string[] pick_urls (string text) {
            string[] out = {};
            foreach (string url in LinkCleaner.find_urls (text)) {
                if (!url.has_prefix ("http://") && !url.has_prefix ("https://"))
                    continue;
                bool dup = false;
                foreach (string seen in out) {
                    if (seen == url) { dup = true; break; }
                }
                if (dup) continue;
                out += url;
                if (out.length >= MAX_LINKS) break;
            }
            return out;
        }

        /** Extracts preview metadata from an HTML document. `base_url` is
            the final page URL, used to resolve relative image references.
            Returns null when the page yields neither an image nor a
            title. */
        public Metadata? parse_html (string html, string base_url) {
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
                if (doc.substring (lt, 4) == "<!--") {
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
                    int close = index_of_ci (doc, "</title", pos);
                    if (close < 0) break;
                    html_title = decode_entities (doc.substring (pos, close - pos))
                        .strip ();
                    pos = close;
                } else if (lower.has_prefix ("/head") || lower.has_prefix ("body")) {
                    /* Nothing of interest below the head; bail out early. */
                    break;
                }
            }

            var meta = new Metadata ();
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
        public string? resolve_url (string base_url, string href) {
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
        public string? shorten (string? text, int max_chars) {
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
        public string decode_entities (string text) {
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

        /** The URL to fetch an image from. With `clean` unset the URL is
            returned untouched; otherwise tracking parameters are stripped
            (the same rules as pasted links) and, for URLs whose path is a
            plain image file, the whole query is dropped: CDNs such as
            i.ytimg.com append rendering hints and signatures the bare
            .jpg serves fine without. Callers fall back to the original
            URL when the cleaned one fails, so a signed URL still works. */
        public string image_fetch_url (string url, bool clean) {
            if (!clean) return url;
            string cleaned = LinkCleaner.clean_url (url);
            int q = cleaned.index_of_char ('?');
            if (q < 0) return cleaned;
            string path = cleaned.substring (0, q);
            int hash = path.index_of_char ('#');
            if (hash >= 0) path = path.substring (0, hash);
            string lower = path.down ();
            foreach (string ext in new string[] { ".jpg", ".jpeg", ".png",
                                                  ".gif", ".webp", ".avif" }) {
                if (lower.has_suffix (ext)) return path;
            }
            return cleaned;
        }

        /** Maps the mimetype (or, failing that, the URL suffix) of a
            fetched image to a file extension; null for anything that is
            not a raster image we can attach. */
        public string? image_extension (string? mimetype, string url) {
            string mt = (mimetype ?? "").down ();
            int semi = mt.index_of_char (';');
            if (semi >= 0) mt = mt.substring (0, semi).strip ();
            switch (mt) {
            case "image/jpeg": case "image/jpg": return "jpg";
            case "image/png": return "png";
            case "image/gif": return "gif";
            case "image/webp": return "webp";
            case "image/avif": return "avif";
            default: break;
            }
            string path = url.down ();
            int q = path.index_of_char ('?');
            if (q >= 0) path = path.substring (0, q);
            int hash = path.index_of_char ('#');
            if (hash >= 0) path = path.substring (0, hash);
            foreach (string ext in new string[] { "jpg", "jpeg", "png", "gif",
                                                  "webp", "avif" }) {
                if (path.has_suffix ("." + ext)) return ext == "jpeg" ? "jpg" : ext;
            }
            /* Unknown declared type but not obviously wrong: let the
               pixbuf loader decide. */
            if (mt.length == 0 || mt.has_prefix ("image/")
                || mt == "application/octet-stream")
                return "img";
            return null;
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

        private int index_of_ci (string doc, string needle, int from) {
            /* Documents are ASCII in the tag names we look for; a
               lower-cased scan is enough. */
            return doc.down ().index_of (needle, from);
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
