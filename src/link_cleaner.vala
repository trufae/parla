namespace Dc {

    /**
     * Strips well-known tracking parameters from http(s) URLs found in
     * text pasted into the compose bar. Parameters that carry content
     * (video id, timestamp, playlist, search terms) are preserved;
     * everything else is left byte-for-byte untouched.
     */
    public class LinkCleaner : Object {

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
            suffix) from a single URL. When a removeparam filter list is
            active (Settings → Links) it replaces the built-in rules. */
        public static string clean_url (string url) {
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

        private static bool is_tracking_param (string name, int site) {
            if (has_word (GLOBAL_PARAMS, name) || has_prefix_in (GLOBAL_PREFIXES, name))
                return true;
            return site >= 0 && (has_word (SITE_RULES[site].params, name)
                || has_prefix_in (SITE_RULES[site].prefixes, name));
        }

        /* Index into SITE_RULES, or -1 when no site-specific rule applies. */
        private static int site_rule_for (string host) {
            for (int i = 0; i < SITE_RULES.length; i++) {
                foreach (string pattern in SITE_RULES[i].hosts.split (" ")) {
                    if (host_matches (host, pattern)) return i;
                }
            }
            return -1;
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

        /* "example.com" matches the domain and its subdomains; "brand.*"
           matches per-country TLDs: amazon.com, amazon.co.uk, smile.amazon.de */
        private static bool host_matches (string host, string pattern) {
            if (pattern.has_suffix (".*")) {
                int idx = host.index_of (pattern[0:pattern.length - 1]);
                return idx == 0 || (idx > 0 && host[idx - 1] == '.');
            }
            return host == pattern || host.has_suffix ("." + pattern);
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

        private static bool has_word (string words, string word) {
            return (" " + words + " ").contains (" " + word + " ");
        }

        private static bool has_prefix_in (string prefixes, string name) {
            foreach (string prefix in prefixes.split (" ")) {
                if (prefix.length > 0 && name.has_prefix (prefix)) return true;
            }
            return false;
        }
    }
}
