namespace Dc {

    /**
     * Network half of link previews: fetches a pasted page and its
     * Open Graph image through core's get_http_response (so the account's
     * proxy applies and core's HTTP cache is reused) and writes the image
     * to a temp file for the composer to attach.
     */
    public class LinkPreviewFetcher : Object {

        public class Result {
            public string url;
            public string image_path;
            public string file_name;
            public string? title;
            public string? description;
        }

        private unowned RpcClient rpc;

        public LinkPreviewFetcher (RpcClient rpc) {
            this.rpc = rpc;
        }

        /** Returns null when the page has no usable image; the caller
            owns the returned temp file. */
        public async Result? fetch (string url, bool clean_image_urls) {
            if (!url.has_prefix ("https://") && !url.has_prefix ("http://"))
                return null;
            string? mimetype;
            uint8[] body;
            try {
                body = yield rpc.get_http_response (url, out mimetype);
            } catch (Error e) {
                debug ("link preview: %s: %s", url, e.message);
                return null;
            }
            LinkPreview.Metadata? meta = null;
            string mt = (mimetype ?? "").down ();
            if (mt.has_prefix ("image/")) {
                /* The link itself is a picture: attach it directly. */
                meta = new LinkPreview.Metadata ();
                meta.image_url = url;
            } else if (mt.length == 0 || mt.has_prefix ("text/html")
                       || mt.has_prefix ("application/xhtml")) {
                int len = int.min (body.length, LinkPreview.MAX_HTML_BYTES);
                var sb = new StringBuilder.sized (len + 1);
                sb.append_len ((string) body, len);
                meta = LinkPreview.parse_html (sb.str, url);
            }
            if (meta == null || meta.image_url == null) return null;

            string image_url = meta.image_url;
            uint8[] image = {};
            string? image_mime = null;
            string fetched_from = image_url;
            bool ok = false;
            string first = LinkPreview.image_fetch_url (image_url, clean_image_urls);
            string[] candidates = first == image_url
                ? new string[] { image_url } : new string[] { first, image_url };
            foreach (string candidate in candidates) {
                if (mt.has_prefix ("image/") && candidate == url) {
                    image = body;
                    image_mime = mimetype;
                    ok = true;
                    break;
                }
                try {
                    image = yield rpc.get_http_response (candidate, out image_mime);
                    if (image.length > 0
                        && image.length <= LinkPreview.MAX_IMAGE_BYTES) {
                        ok = true;
                        fetched_from = candidate;
                        break;
                    }
                } catch (Error e) {
                    debug ("link preview image: %s: %s", candidate, e.message);
                }
            }
            if (!ok) return null;

            string? ext = LinkPreview.image_extension (image_mime, fetched_from);
            if (ext == null) return null;

            string? path = null;
            try {
                GLib.FileIOStream stream;
                var tmp = GLib.File.new_tmp ("parla-preview-XXXXXX." + ext,
                    out stream);
                path = tmp.get_path ();
                size_t written;
                yield stream.output_stream.write_all_async (image,
                    Priority.DEFAULT, null, out written);
                yield stream.close_async (Priority.DEFAULT, null);
                /* Only attach what GTK can actually decode. */
                var pixbuf = new Gdk.Pixbuf.from_file (path);
                if (pixbuf.width < 2 || pixbuf.height < 2)
                    throw new IOError.INVALID_DATA ("empty image");
            } catch (Error e) {
                debug ("link preview image unusable: %s", e.message);
                if (path != null) GLib.FileUtils.unlink (path);
                return null;
            }

            var r = new Result ();
            r.url = url;
            r.image_path = path;
            r.file_name = "%s.%s".printf (file_stem (url), ext == "img" ? "jpg" : ext);
            r.title = meta.title;
            r.description = meta.description;
            return r;
        }

        /* "example.com" from "https://www.example.com/a/b" — used as the
           attachment's file name so the recipient sees where it is from. */
        private static string file_stem (string url) {
            try {
                var uri = GLib.Uri.parse (url, GLib.UriFlags.PARSE_RELAXED);
                string? host = uri.get_host ();
                if (host != null && host.length > 0) {
                    if (host.has_prefix ("www.")) host = host.substring (4);
                    return host;
                }
            } catch (Error e) {
            }
            return "link-preview";
        }
    }
}
