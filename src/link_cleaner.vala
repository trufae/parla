namespace Dc {

    /**
     * Strips well-known tracking parameters from http(s) URLs found in
     * text pasted into the compose bar. Parameters that carry content
     * (video id, timestamp, playlist, search terms) are preserved;
     * everything else is left byte-for-byte untouched.
     */
    public class LinkCleaner : Object {

        /* Ad-click and campaign IDs appended by platforms regardless of
           the destination site; always safe to drop. */
        private const string[] GLOBAL_PARAMS = {
            "fbclid", "gclid", "gclsrc", "dclid", "wbraid", "gbraid",
            "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
            "mc_cid", "mc_eid", "igshid", "srsltid", "s_cid",
            "_hsenc", "_hsmi", "_openstat", "vero_conv", "vero_id",
            "oly_anon_id", "oly_enc_id"
        };

        /* utm_* (Google Analytics), pk_/mtm_/piwik_ (Matomo),
           hsa_ (HubSpot ads). */
        private const string[] GLOBAL_PREFIXES = {
            "utm_", "pk_", "mtm_", "piwik_", "hsa_"
        };

        private const string[] YOUTUBE_PARAMS = {
            "si", "feature", "pp", "ab_channel",
            "embeds_referring_euri", "source_ve_path"
        };
        private const string[] X_PARAMS = {
            "s", "t", "ref_src", "ref_url"
        };
        private const string[] INSTAGRAM_PARAMS = {
            "igsh", "ig_rid", "ig_mid", "xmt"
        };
        private const string[] FACEBOOK_PARAMS = {
            "mibextid", "rdid", "share_url", "refid", "ref", "fref",
            "hc_ref", "sfnsn", "wtsid", "paipv", "eav",
            "comment_tracking", "notif_id", "notif_t"
        };
        /* __tn__, __cft__[0], __xts__[0] ... */
        private const string[] FACEBOOK_PREFIXES = { "__" };
        private const string[] LINKEDIN_PARAMS = {
            "trk", "trackingid", "lipi", "midtoken", "midsig",
            "trkemail", "ebp", "refid", "otptoken", "original_referer",
            "rcm"
        };
        private const string[] TIKTOK_PARAMS = {
            "_t", "_r", "is_from_webapp", "sender_device",
            "sender_web_id", "web_id", "u_code", "tt_from",
            "is_copy_url", "share_app_id", "share_link_id", "share_iid",
            "ug_btm", "checksum"
        };
        private const string[] REDDIT_PARAMS = {
            "share_id", "ref", "ref_source", "rdt", "correlation_id"
        };
        private const string[] SPOTIFY_PARAMS = {
            "si", "nd", "_branch_match_id", "_branch_referrer"
        };
        private const string[] AMAZON_PARAMS = {
            "tag", "ref", "ref_", "ascsubtag", "linkcode", "linkid",
            "camp", "creative", "creativeasin", "qid", "sr", "sprefix",
            "crid", "dib", "dib_tag", "content-id", "social_share"
        };
        private const string[] AMAZON_PREFIXES = { "pf_rd_", "pd_rd_" };
        private const string[] EBAY_PARAMS = {
            "mkcid", "mkevt", "mkrid", "ssspo", "sssrc", "ssuid",
            "campid", "toolid", "customid", "mkpid", "ul_noapp",
            "amdata"
        };
        private const string[] ALIEXPRESS_PARAMS = {
            "spm", "scm", "aff_platform", "aff_trace_key", "aff_fcid",
            "aff_fsk", "terminal_id", "pdp_npi", "gatewayadapt",
            "algo_pvid", "algo_exp_id", "utparam-url"
        };
        private const string[] TWITCH_PARAMS = {
            "tt_content", "tt_medium"
        };
        /* YouTube thumbnail CDN: rendering hints and signatures that
           the plain .jpg does not need. */
        private const string[] YTIMG_PARAMS = {
            "sqp", "rs", "usqp"
        };

        private const string[] EMPTY = {};

        /** Rewrites every http(s) URL found in the text; anything that is
            not a URL passes through unchanged. */
        public static string clean_text (string text) {
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

        /** Every http(s) URL found in the text, in order, duplicates
            included. */
        public static string[] find_urls (string text) {
            string[] urls = {};
            int pos = 0;
            while (true) {
                int start = find_url_start (text, pos);
                if (start < 0) break;
                int end = find_url_end (text, start);
                urls += text[start:end];
                pos = end;
            }
            return urls;
        }

        /** Strips tracking query parameters (and Amazon's /ref= path
            suffix) from a single URL. */
        public static string clean_url (string url) {
            string host = host_of (url);

            int frag_start = url.index_of_char ('#');
            int query_start = url.index_of_char ('?');
            if (frag_start >= 0 && query_start > frag_start) query_start = -1;

            int base_end = query_start >= 0 ? query_start
                : (frag_start >= 0 ? frag_start : url.length);
            string base_part = url[0:base_end];
            string fragment = frag_start >= 0 ? url.substring (frag_start) : "";

            if (host_is_brand (host, "amazon"))
                base_part = strip_amazon_ref_path (base_part);

            if (query_start < 0) return base_part + fragment;

            int query_end = frag_start >= 0 ? frag_start : url.length;
            string query = url[query_start + 1:query_end];

            string[] site_params, site_prefixes;
            rules_for_host (host, out site_params, out site_prefixes);

            var kept = new StringBuilder ();
            foreach (string param in query.split ("&")) {
                if (param.length == 0) continue;
                int eq = param.index_of_char ('=');
                string name = (eq >= 0 ? param[0:eq] : param).down ();
                if (is_tracking_param (name, site_params, site_prefixes))
                    continue;
                if (kept.len > 0) kept.append_c ('&');
                kept.append (param);
            }

            string cleaned = kept.len > 0
                ? base_part + "?" + kept.str
                : base_part;
            return cleaned + fragment;
        }

        private static bool is_tracking_param (string name,
                                               string[] site_params,
                                               string[] site_prefixes) {
            if (contains (GLOBAL_PARAMS, name)) return true;
            if (has_any_prefix (name, GLOBAL_PREFIXES)) return true;
            if (contains (site_params, name)) return true;
            return has_any_prefix (name, site_prefixes);
        }

        private static void rules_for_host (string host,
                                            out string[] params,
                                            out string[] prefixes) {
            params = EMPTY;
            prefixes = EMPTY;
            if (host_is (host, "youtube.com") || host_is (host, "youtu.be")) {
                params = YOUTUBE_PARAMS;
            } else if (host_is (host, "x.com") || host_is (host, "twitter.com")) {
                params = X_PARAMS;
            } else if (host_is (host, "instagram.com")
                       || host_is (host, "threads.net")
                       || host_is (host, "threads.com")) {
                params = INSTAGRAM_PARAMS;
            } else if (host_is (host, "facebook.com")
                       || host_is (host, "fb.com")
                       || host_is (host, "fb.watch")
                       || host_is (host, "fb.me")
                       || host_is (host, "messenger.com")) {
                params = FACEBOOK_PARAMS;
                prefixes = FACEBOOK_PREFIXES;
            } else if (host_is (host, "linkedin.com")
                       || host_is (host, "lnkd.in")) {
                params = LINKEDIN_PARAMS;
            } else if (host_is (host, "tiktok.com")) {
                params = TIKTOK_PARAMS;
            } else if (host_is (host, "reddit.com")
                       || host_is (host, "redd.it")) {
                params = REDDIT_PARAMS;
            } else if (host_is (host, "spotify.com")) {
                params = SPOTIFY_PARAMS;
            } else if (host_is (host, "twitch.tv")) {
                params = TWITCH_PARAMS;
            } else if (host_is (host, "ytimg.com")) {
                params = YTIMG_PARAMS;
            } else if (host_is_brand (host, "amazon")) {
                params = AMAZON_PARAMS;
                prefixes = AMAZON_PREFIXES;
            } else if (host_is_brand (host, "ebay")) {
                params = EBAY_PARAMS;
            } else if (host_is_brand (host, "aliexpress")) {
                params = ALIEXPRESS_PARAMS;
            }
        }

        /** Lowercased host without userinfo, port, or a leading www./m. */
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
            if (host.has_prefix ("www.")) host = host.substring (4);
            else if (host.has_prefix ("m.")) host = host.substring (2);
            return host;
        }

        private static bool host_is (string host, string domain) {
            return host == domain || host.has_suffix ("." + domain);
        }

        /* Matches brands with per-country TLDs: "amazon" covers
           amazon.com, amazon.co.uk, smile.amazon.de, ... */
        private static bool host_is_brand (string host, string brand) {
            int idx = host.index_of (brand + ".");
            return idx == 0 || (idx > 0 && host[idx - 1] == '.');
        }

        /* Amazon appends the click source as a trailing path segment:
           /dp/B0XXXXXXXX/ref=sr_1_3 -> /dp/B0XXXXXXXX */
        private static string strip_amazon_ref_path (string base_part) {
            int idx = base_part.index_of ("/ref=");
            return idx >= 0 ? base_part[0:idx] : base_part;
        }

        private static int find_url_start (string text, int pos) {
            int idx = text.index_of ("http", pos);
            while (idx >= 0) {
                string rest = text.substring (idx);
                if (rest.has_prefix ("http://") || rest.has_prefix ("https://"))
                    return idx;
                idx = text.index_of ("http", idx + 4);
            }
            return -1;
        }

        private static int find_url_end (string text, int start) {
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

        private static bool is_balanced (string text, int start, int end,
                                         char open, char close) {
            int depth = 0;
            for (int i = start; i < end; i++) {
                if (text[i] == open) depth++;
                else if (text[i] == close) depth--;
            }
            return depth >= 0;
        }

        private static bool contains (string[] haystack, string needle) {
            foreach (string s in haystack) {
                if (s == needle) return true;
            }
            return false;
        }

        private static bool has_any_prefix (string name, string[] prefixes) {
            foreach (string prefix in prefixes) {
                if (name.has_prefix (prefix)) return true;
            }
            return false;
        }
    }
}
