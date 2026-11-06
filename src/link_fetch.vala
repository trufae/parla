namespace Dc.Link {
    /** Fetches through core for account proxy/cache. Returns null without a
        usable image; the caller owns the returned image's temp file. */
    public async Preview? thumbnail (RpcClient rpc, string url,
                                     bool clean_image_urls) {
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
        Preview? meta = null;
        string mt = (mimetype ?? "").down ();
        if (mt.has_prefix ("image/")) {
            /* The link itself is a picture: attach it directly. */
            meta = new Preview ();
            meta.image_url = url;
        } else if (mt.length == 0 || mt.has_prefix ("text/html")
                   || mt.has_prefix ("application/xhtml")) {
            int len = int.min (body.length, MAX_HTML_BYTES);
            var sb = new StringBuilder.sized (len + 1);
            sb.append_len ((string) body, len);
            meta = open_graph (sb.str, url);
        }
        if (meta == null || meta.image_url == null) return null;

        string image_url = meta.image_url;
        string first = image_fetch_url (image_url, clean_image_urls);
        string[] candidates = first == image_url
            ? new string[] { image_url } : new string[] { first, image_url };
        foreach (string candidate in candidates) {
            string? path = null;
            try {
                uint8[] image = body;
                if (candidate != url || !mt.has_prefix ("image/"))
                    image = yield rpc.get_http_response (candidate, out mimetype);
                if (image.length == 0 || image.length > MAX_IMAGE_BYTES) continue;
                var loader = new Gdk.PixbufLoader ();
                try {
                    loader.write (image);
                } catch (Error e) {
                    try { loader.close (); } catch (Error ignored) {}
                    throw e;
                }
                loader.close ();
                var pixbuf = loader.get_pixbuf ();
                var format = loader.get_format ();
                if (pixbuf == null || format == null || pixbuf.width < 2 || pixbuf.height < 2)
                    continue;
                string ext = format.get_extensions ()[0];
                GLib.FileIOStream stream;
                var tmp = GLib.File.new_tmp ("parla-preview-XXXXXX." + ext, out stream);
                path = tmp.get_path ();
                size_t written;
                yield stream.output_stream.write_all_async (image,
                    Priority.DEFAULT, null, out written);
                yield stream.close_async (Priority.DEFAULT, null);
                meta.image_path = path;
                meta.file_name = "%s.%s".printf (file_stem (url), ext);
                return meta;
            } catch (Error e) {
                debug ("link preview image: %s: %s", candidate, e.message);
                if (path != null) GLib.FileUtils.unlink (path);
            }
        }
        return null;
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
