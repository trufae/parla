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

int main () {
    /* URL picking: distinct, ordered, capped, http(s) only. */
    string[] urls = LinkPreview.pick_urls (
        "see https://a.example/x and https://b.example/y, again https://a.example/x "
        + "and ftp://nope.example/z");
    check_eq (urls.length.to_string (), "2", "pick_urls dedupes");
    check_eq (urls[0], "https://a.example/x", "pick_urls keeps order");
    check_eq (urls[1], "https://b.example/y", "pick_urls second");
    var many = new StringBuilder ();
    for (int i = 0; i < 9; i++) many.append ("https://h%d.example/ ".printf (i));
    check_eq (LinkPreview.pick_urls (many.str).length.to_string (),
        LinkPreview.MAX_LINKS.to_string (), "pick_urls caps at MAX_LINKS");

    /* Full OG page. */
    var meta = LinkPreview.parse_html ("""<!doctype html><html><head>
        <meta charset="utf-8">
        <title>Fallback &amp; ignored</title>
        <meta property="og:title" content="Hello &amp; World">
        <meta content="A short   description&#39;s text" property="og:description"/>
        <meta property='og:image' content='http://img.example/pic.jpg?utm_source=x'>
        <meta property="og:image:secure_url" content="https://img.example/pic.jpg?utm_source=x">
        </head><body><meta property="og:title" content="late"></body></html>""",
        "https://site.example/page");
    check_true (meta != null, "og page parses");
    check_eq (meta.title, "Hello & World", "og:title decoded, wins over <title>");
    check_eq (meta.description, "A short description's text",
        "og:description with reversed attribute order, whitespace collapsed");
    check_eq (meta.image_url, "https://img.example/pic.jpg?utm_source=x",
        "secure_url replaces plain http og:image");

    /* Fallbacks: twitter, <title>, meta description, relative image. */
    meta = LinkPreview.parse_html ("""<html><head><TITLE> Plain
        Title </TITLE><META NAME="description" CONTENT="desc here">
        <meta name="twitter:image" content="/static/card.png"></head>""",
        "https://site.example/dir/page.html");
    check_eq (meta.title, "Plain Title", "<title> fallback, whitespace collapsed");
    check_eq (meta.description, "desc here", "meta description fallback");
    check_eq (meta.image_url, "https://site.example/static/card.png",
        "relative twitter:image resolved");

    /* Comments are skipped, image_src link honoured. */
    meta = LinkPreview.parse_html ("""<head><!-- <meta property="og:image" content="/no.png"> -->
        <link rel="image_src" href="img/yes.png"><title>T</title></head>""",
        "https://site.example/a/b/");
    check_eq (meta.image_url, "https://site.example/a/b/img/yes.png",
        "commented og:image ignored, link rel=image_src used");

    /* Nothing usable. */
    check_true (LinkPreview.parse_html ("<html><body>hi</body></html>",
        "https://x.example/") == null, "no title, no image -> null");
    /* Title only still yields metadata (image may be absent). */
    meta = LinkPreview.parse_html ("<title>Just a title</title>", "https://x.example/");
    check_true (meta != null && meta.image_url == null, "title-only metadata");

    /* Non-http image references are rejected. */
    check_eq (LinkPreview.resolve_url ("https://a.example/", "data:image/png;base64,AAAA"),
        null, "data: image rejected");
    check_eq (LinkPreview.resolve_url ("https://a.example/p/", "//cdn.example/i.png"),
        "https://cdn.example/i.png", "protocol-relative resolved");

    /* Truncation. */
    string long_title = string.nfill (200, 'a');
    string? t = LinkPreview.shorten (long_title, LinkPreview.MAX_TITLE_CHARS);
    /* char_count () is glong in C; go through an int so the generated
       printf format matches under -Werror=format. */
    int title_len = t.char_count ();
    check_eq (title_len.to_string (), LinkPreview.MAX_TITLE_CHARS.to_string (),
        "title truncated with ellipsis");
    check_true (t.has_suffix ("…"), "ellipsis appended");

    /* Entities. */
    check_eq (LinkPreview.decode_entities ("a &lt;b&gt; &#x41;&#66; &unknown; &amp"),
        "a <b> AB &unknown; &amp", "entity decoding");

    /* Image URL cleaning follows the tracking setting. */
    string yt = "https://i.ytimg.com/vi/uQtjBiO-3W8/oardefault.jpg?sqp=-oaymwEk&rs=AOn4CLB&usqp=CCk";
    check_eq (LinkPreview.image_fetch_url (yt, false), yt,
        "image url untouched when cleaning is off");
    check_eq (LinkPreview.image_fetch_url (yt, true),
        "https://i.ytimg.com/vi/uQtjBiO-3W8/oardefault.jpg",
        "ytimg params dropped when cleaning is on");
    check_eq (LinkCleaner.clean_url (yt),
        "https://i.ytimg.com/vi/uQtjBiO-3W8/oardefault.jpg",
        "LinkCleaner knows ytimg params");
    check_eq (LinkPreview.image_fetch_url ("https://cdn.example/img?id=42&utm_source=x", true),
        "https://cdn.example/img?id=42",
        "non-file image url keeps content params, drops tracking");

    /* Extension mapping. */
    check_eq (LinkPreview.image_extension ("image/jpeg; charset=binary", "https://x/y"),
        "jpg", "mimetype with params");
    check_eq (LinkPreview.image_extension (null, "https://x/y.PNG?z=1"), "png",
        "extension from url");
    check_eq (LinkPreview.image_extension ("text/html", "https://x/y"), null,
        "html is not an image");
    check_eq (LinkPreview.image_extension ("image/svg+xml", "https://x/y.svg"), "img",
        "unknown image type deferred to the loader");

    if (failures == 0) stdout.printf ("link_preview: all tests passed\n");
    return failures == 0 ? 0 : 1;
}
