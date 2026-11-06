using Dc;

int failures = 0;

void check_eq (string? got, string? expected, string what) {
    if (got != expected) {
        stderr.printf ("FAIL: %s\n  expected: %s\n  got:      %s\n",
                       what, expected ?? "(null)", got ?? "(null)");
        failures++;
    }
}

void check_true (bool cond, string what) {
    if (!cond) {
        stderr.printf ("FAIL: %s\n", what);
        failures++;
    }
}

namespace Dc {
    public class RpcClient : Object {
        public uint8[] image;
        public uint8[] cleaned = "<html>Access denied</html>".data;
        public int requests = 0;

        public async uint8[] get_http_response (string url, out string? mimetype) throws Error {
            requests++;
            mimetype = "image/jpeg";
            if (url.has_suffix ("/page")) {
                mimetype = "text/html";
                return "<meta property='og:image' content='/image.jpg?token=ok'>".data;
            }
            return url.has_suffix ("?token=ok") ? image : cleaned;
        }
    }
}

async int main () {
    /* URL picking: distinct, ordered, capped, http(s) only. */
    string[] urls = Link.urls_in_text (
        "see https://a.example/x and https://b.example/y, again https://a.example/x "
        + "and ftp://nope.example/z", Link.MAX_PREVIEWS, true);
    check_eq (urls.length.to_string (), "2", "urls_in_text dedupes");
    check_eq (urls[0], "https://a.example/x", "urls_in_text keeps order");
    check_eq (urls[1], "https://b.example/y", "urls_in_text second");
    check_eq (Link.urls_in_text ("https://a.example https://a.example").length.to_string (),
        "2", "urls_in_text keeps duplicates by default");
    check_eq (Link.urls_in_text ("https://a.example", 0).length.to_string (),
        "0", "urls_in_text zero cap");
    var many = new StringBuilder ();
    for (int i = 0; i < 9; i++) many.append ("https://h%d.example/ ".printf (i));
    check_eq (Link.urls_in_text (many.str, Link.MAX_PREVIEWS, true).length.to_string (),
        Link.MAX_PREVIEWS.to_string (), "urls_in_text caps at MAX_PREVIEWS");

    /* Full OG page. */
    var meta = Link.open_graph ("""<!doctype html><html><head>
        <meta charset="utf-8">
        <title>Fallback &amp; ignored</title>
        <meta property="og:title" content="Hello &amp; World">
        <meta content="A short   description&#39;s text" property="og:description"/>
        <meta property='og:image' content='http://img.example/pic.jpg?utm_source=x'>
        <meta property="og:image:secure_url" content="https://img.example/pic.jpg?utm_source=x">
        </head><body><meta property="og:title" content="late"></body></html>""",
        "https://site.example/page");
    check_true (meta != null, "og page parses");
    check_true (meta.image_path == null, "parsed metadata has no downloaded image");
    check_eq (meta.title, "Hello & World", "og:title decoded, wins over <title>");
    check_eq (meta.description, "A short description's text",
        "og:description with reversed attribute order, whitespace collapsed");
    check_eq (meta.image_url, "https://img.example/pic.jpg?utm_source=x",
        "secure_url replaces plain http og:image");

    /* Fallbacks: twitter, <title>, meta description, relative image. */
    meta = Link.open_graph ("""<html><head><TITLE> Plain
        Title </TITLE><META NAME="description" CONTENT="desc here">
        <meta name="twitter:image" content="/static/card.png"></head>""",
        "https://site.example/dir/page.html");
    check_eq (meta.title, "Plain Title", "<title> fallback, whitespace collapsed");
    check_eq (meta.description, "desc here", "meta description fallback");
    check_eq (meta.image_url, "https://site.example/static/card.png",
        "relative twitter:image resolved");

    /* Comments are skipped, image_src link honoured. */
    meta = Link.open_graph ("""<head><!-- <meta property="og:image" content="/no.png"> -->
        <link rel="image_src" href="img/yes.png"><title>T</title></head>""",
        "https://site.example/a/b/");
    check_eq (meta.image_url, "https://site.example/a/b/img/yes.png",
        "commented og:image ignored, link rel=image_src used");

    /* Nothing usable. */
    check_true (Link.open_graph ("<html><body>hi</body></html>",
        "https://x.example/") == null, "no title, no image -> null");
    /* Title only still yields metadata (image may be absent). */
    meta = Link.open_graph ("<title>Just a title</title>", "https://x.example/");
    check_true (meta != null && meta.image_url == null, "title-only metadata");
    foreach (string title in new string[] { "İ hello", "K hello" }) {
        meta = Link.open_graph ("<title>" + title + "</title><", "https://x.example/");
        check_eq (meta.title, title, "Unicode title and truncated trailing tag");
    }

    /* Non-http image references are rejected. */
    check_eq (Link.resolve_url ("https://a.example/", "data:image/png;base64,AAAA"),
        null, "data: image rejected");
    check_eq (Link.resolve_url ("https://a.example/p/", "//cdn.example/i.png"),
        "https://cdn.example/i.png", "protocol-relative resolved");

    /* Truncation. */
    string long_title = string.nfill (200, 'a');
    string? t = Link.shorten (long_title, Link.MAX_TITLE_CHARS);
    /* char_count () is glong in C; go through an int so the generated
       printf format matches under -Werror=format. */
    int title_len = t.char_count ();
    check_eq (title_len.to_string (), Link.MAX_TITLE_CHARS.to_string (),
        "title truncated with ellipsis");
    check_true (t.has_suffix ("…"), "ellipsis appended");

    /* Entities. */
    check_eq (Link.decode_entities ("a &lt;b&gt; &#x41;&#66; &unknown; &amp"),
        "a <b> AB &unknown; &amp", "entity decoding");

    /* Image URL cleaning follows the tracking setting. */
    string yt = "https://i.ytimg.com/vi/uQtjBiO-3W8/oardefault.jpg?sqp=-oaymwEk&rs=AOn4CLB&usqp=CCk";
    check_eq (Link.image_fetch_url (yt, false), yt,
        "image url untouched when cleaning is off");
    check_eq (Link.image_fetch_url (yt, true),
        "https://i.ytimg.com/vi/uQtjBiO-3W8/oardefault.jpg",
        "ytimg params dropped when cleaning is on");
    check_eq (Link.clean_url (yt),
        "https://i.ytimg.com/vi/uQtjBiO-3W8/oardefault.jpg",
        "Link knows ytimg params");
    check_eq (Link.image_fetch_url ("https://cdn.example/img?id=42&utm_source=x", true),
        "https://cdn.example/img?id=42",
        "non-file image url keeps content params, drops tracking");
    check_eq (Link.image_fetch_url ("https://cdn.example/img.jpg?width=80&token=ok&utm_source=x", true),
        "https://cdn.example/img.jpg?width=80&token=ok", "image keeps functional query parameters");

    try {
        var rpc = new RpcClient ();
        var image = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 2, 2);
        image.fill (0xff0000ffU);
        image.save_to_buffer (out rpc.image, "png");
        RemoveParamFilter.active = RemoveParamFilter.from_text ("$removeparam=token");
        meta = yield Link.thumbnail (rpc, "https://site.example/page", true);
        RemoveParamFilter.active = null;
        check_true (meta != null, "invalid cleaned response falls back to signed image");
        check_true (rpc.requests == 3, "page, cleaned image, original image fetched");
        if (meta != null) {
            check_eq (meta.file_name, "site.example.png", "filename uses decoded format");
            uint8[] saved;
            GLib.FileUtils.get_data (meta.image_path, out saved);
            check_true (new Bytes (saved).compare (new Bytes (rpc.image)) == 0, "original image bytes preserved");
            GLib.FileUtils.unlink (meta.image_path);
        }
        rpc.requests = 0;
        meta = yield Link.thumbnail (rpc, "https://site.example/image.jpg?token=ok", false);
        check_true (meta != null && rpc.requests == 1, "direct image fetched once");
        if (meta != null) GLib.FileUtils.unlink (meta.image_path);
        rpc.image = new uint8[(int) Link.MAX_IMAGE_BYTES + 1];
        check_true ((yield Link.thumbnail (rpc, "https://site.example/image.jpg?token=ok", false)) == null,
            "oversized direct image rejected");
    } catch (Error e) {
        check_true (false, e.message);
    }

    if (failures == 0) stdout.printf ("link_preview: all tests passed\n");
    return failures == 0 ? 0 : 1;
}
