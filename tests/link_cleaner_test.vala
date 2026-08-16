using Dc;

int failures = 0;

void check_eq (string got, string expected, string what) {
    if (got != expected) {
        stderr.printf ("FAIL: %s\n  expected: %s\n  got:      %s\n",
                       what, expected, got);
        failures++;
    }
}

int main () {
    check_eq (
        LinkCleaner.clean_url ("https://www.youtube.com/watch?v=abc123&si=XyZ_track&feature=share"),
        "https://www.youtube.com/watch?v=abc123",
        "youtube keeps video id, drops si/feature");

    check_eq (
        LinkCleaner.clean_url ("https://youtu.be/abc123?si=XyZ&t=42"),
        "https://youtu.be/abc123?t=42",
        "youtu.be keeps timestamp");

    check_eq (
        LinkCleaner.clean_url ("https://x.com/user/status/123?s=20&t=AbCdEf"),
        "https://x.com/user/status/123",
        "x.com share params dropped");

    check_eq (
        LinkCleaner.clean_url ("https://twitter.com/user/status/123?ref_src=twsrc%5Etfw"),
        "https://twitter.com/user/status/123",
        "twitter ref_src dropped");

    check_eq (
        LinkCleaner.clean_url ("https://www.instagram.com/p/Cxyz/?igsh=MTQ4&img_index=2"),
        "https://www.instagram.com/p/Cxyz/?img_index=2",
        "instagram keeps carousel index, drops igsh");

    check_eq (
        LinkCleaner.clean_url ("https://www.facebook.com/story.php?story_fbid=1&id=2&mibextid=Nif5oz"),
        "https://www.facebook.com/story.php?story_fbid=1&id=2",
        "facebook keeps content ids, drops mibextid");

    check_eq (
        LinkCleaner.clean_url ("https://www.facebook.com/photo?fbid=1&__cft__[0]=AZW&__tn__=%2CO"),
        "https://www.facebook.com/photo?fbid=1",
        "facebook double-underscore params dropped");

    check_eq (
        LinkCleaner.clean_url ("https://www.linkedin.com/posts/foo_bar-activity-123?trk=public_profile&trackingId=abc%3D%3D"),
        "https://www.linkedin.com/posts/foo_bar-activity-123",
        "linkedin trk/trackingId dropped");

    check_eq (
        LinkCleaner.clean_url ("https://www.tiktok.com/@user/video/123?_t=8abc&_r=1&is_from_webapp=1"),
        "https://www.tiktok.com/@user/video/123",
        "tiktok share params dropped");

    check_eq (
        LinkCleaner.clean_url ("https://www.reddit.com/r/gnome/comments/abc/foo/?share_id=xyz&context=3"),
        "https://www.reddit.com/r/gnome/comments/abc/foo/?context=3",
        "reddit keeps comment context, drops share_id");

    check_eq (
        LinkCleaner.clean_url ("https://open.spotify.com/track/abc?si=xyz"),
        "https://open.spotify.com/track/abc",
        "spotify si dropped");

    check_eq (
        LinkCleaner.clean_url ("https://www.amazon.com/dp/B08N5WRWNW/ref=sr_1_3?tag=aff-20&qid=1700000000&sr=8-3&th=1"),
        "https://www.amazon.com/dp/B08N5WRWNW?th=1",
        "amazon ref path and affiliate params dropped, keeps variant");

    check_eq (
        LinkCleaner.clean_url ("https://example.com/page?utm_source=nl&utm_medium=email&id=7"),
        "https://example.com/page?id=7",
        "utm_* dropped on any site");

    check_eq (
        LinkCleaner.clean_url ("https://example.com/?fbclid=IwAR123&gclid=abc"),
        "https://example.com/",
        "global click ids dropped on any site");

    check_eq (
        LinkCleaner.clean_url ("https://example.com/watch?si=notyoutube&v=1"),
        "https://example.com/watch?si=notyoutube&v=1",
        "site-specific params untouched on other hosts");

    check_eq (
        LinkCleaner.clean_url ("https://example.com/a?x=1#frag"),
        "https://example.com/a?x=1#frag",
        "fragment preserved");

    check_eq (
        LinkCleaner.clean_url ("https://example.com/a?utm_source=x#frag"),
        "https://example.com/a#frag",
        "empty query removed, fragment preserved");

    check_eq (
        LinkCleaner.clean_text ("look https://youtu.be/abc?si=x and https://x.com/a/status/1?s=20 wow"),
        "look https://youtu.be/abc and https://x.com/a/status/1 wow",
        "multiple urls inside text");

    check_eq (
        LinkCleaner.clean_text ("(see https://youtu.be/abc?si=x)"),
        "(see https://youtu.be/abc)",
        "trailing parenthesis not part of url");

    check_eq (
        LinkCleaner.clean_text ("https://en.wikipedia.org/wiki/Foo_(bar)?utm_source=x"),
        "https://en.wikipedia.org/wiki/Foo_(bar)",
        "balanced parentheses stay in url");

    check_eq (
        LinkCleaner.clean_text ("no links here"),
        "no links here",
        "plain text untouched");

    check_eq (
        LinkCleaner.clean_text ("Check https://youtu.be/abc?si=x."),
        "Check https://youtu.be/abc.",
        "trailing period not part of url");

    /* ---- uBlock/AdGuard $removeparam filter lists ---- */

    const string LIST = """! Title: Test list
! Expires: 2 days
$removeparam=utm_source
$removeparam=/^utm_/
$removeparam=/^__s=[A-Za-z0-9]{6\,}/
||example.com^$removeparam=ref
||shop.example.org/*/products/$removeparam=TrackId
||amazon.*/dp/$removeparam=tag
$removeparam=fbclid,domain=facebook.com|fb.com
$removeparam=lang,domain=~keep.example.net
$denyallow=safe.example.com,removeparam=cid
||api.example.com^$xhr,removeparam=token
||doc.example.com^$document,removeparam=token
||all.example.com/redirect?$removeparam
||only.example.com^$removeparam=~id
||ad.example.net/clk/$removeparam=/^\\$ja=/
@@||example.com/keep$removeparam=ref
@@||example.com/raw$removeparam
example.com##.cosmetic
""";
    var filter = RemoveParamFilter.from_text (LIST);
    if (filter == null) {
        stderr.printf ("FAIL: filter list did not parse\n");
        failures++;
    } else {
        check_eq (filter.expires_seconds.to_string (), "172800", "expires header");
        check_eq (filter.title, "Test list", "title header");
        RemoveParamFilter.active = filter;

        check_eq (LinkCleaner.clean_url ("https://foo.org/p?utm_source=a&utm_medium=b&id=1"),
                  "https://foo.org/p?id=1", "generic name and regex rules");
        check_eq (LinkCleaner.clean_url ("https://foo.org/p?__s=abcdef1&x=1"),
                  "https://foo.org/p?x=1", "escaped comma inside regex quantifier");
        check_eq (LinkCleaner.clean_url ("https://foo.org/p?__s=abc&x=1"),
                  "https://foo.org/p?__s=abc&x=1", "regex quantifier respected");
        check_eq (LinkCleaner.clean_url ("https://www.example.com/a?ref=x&q=1"),
                  "https://www.example.com/a?q=1", "||host^ subdomain match");
        check_eq (LinkCleaner.clean_url ("https://notexample.com/a?ref=x"),
                  "https://notexample.com/a?ref=x", "||host^ needs a label boundary");
        check_eq (LinkCleaner.clean_url ("https://foo.org/a?ref=x"),
                  "https://foo.org/a?ref=x", "site rule does not leak");
        check_eq (LinkCleaner.clean_url ("https://shop.example.org/xx/products/1?TrackId=9&a=b"),
                  "https://shop.example.org/xx/products/1?a=b", "path wildcard, case-sensitive name");
        check_eq (LinkCleaner.clean_url ("https://shop.example.org/xx/products/1?trackid=9"),
                  "https://shop.example.org/xx/products/1?trackid=9", "param names are case-sensitive");
        check_eq (LinkCleaner.clean_url ("https://www.amazon.co.uk/dp/B01?tag=aff&th=1"),
                  "https://www.amazon.co.uk/dp/B01?th=1", "amazon.* tld wildcard");
        check_eq (LinkCleaner.clean_url ("https://m.facebook.com/x?fbclid=1&id=2"),
                  "https://m.facebook.com/x?id=2", "domain= restricts to listed hosts");
        check_eq (LinkCleaner.clean_url ("https://foo.org/x?fbclid=1"),
                  "https://foo.org/x?fbclid=1", "domain= excludes other hosts");
        check_eq (LinkCleaner.clean_url ("https://foo.org/x?lang=en"),
                  "https://foo.org/x", "negated domain applies elsewhere");
        check_eq (LinkCleaner.clean_url ("https://keep.example.net/x?lang=en"),
                  "https://keep.example.net/x?lang=en", "negated domain excluded");
        check_eq (LinkCleaner.clean_url ("https://foo.org/x?cid=1"),
                  "https://foo.org/x", "denyallow applies elsewhere");
        check_eq (LinkCleaner.clean_url ("https://safe.example.com/x?cid=1"),
                  "https://safe.example.com/x?cid=1", "denyallow host excluded");
        check_eq (LinkCleaner.clean_url ("https://api.example.com/x?token=1"),
                  "https://api.example.com/x?token=1", "xhr-only rule ignored for links");
        check_eq (LinkCleaner.clean_url ("https://doc.example.com/x?token=1"),
                  "https://doc.example.com/x", "document rule applies");
        check_eq (LinkCleaner.clean_url ("https://all.example.com/redirect?a=1&b=2#frag"),
                  "https://all.example.com/redirect#frag", "bare removeparam drops whole query");
        check_eq (LinkCleaner.clean_url ("https://only.example.com/x?a=1&id=7&b=2"),
                  "https://only.example.com/x?id=7", "inverse keeps only named param");
        check_eq (LinkCleaner.clean_url ("https://ad.example.net/clk/x?$ja=1&u=2"),
                  "https://ad.example.net/clk/x?u=2", "escaped $ inside regex value");
        check_eq (LinkCleaner.clean_url ("https://example.com/keep?ref=x&utm_source=y"),
                  "https://example.com/keep?ref=x", "exception protects one param");
        check_eq (LinkCleaner.clean_url ("https://example.com/raw?ref=x&utm_source=y"),
                  "https://example.com/raw?ref=x&utm_source=y", "bare exception protects url");
        check_eq (LinkCleaner.clean_url ("https://youtu.be/abc?si=x"),
                  "https://youtu.be/abc?si=x", "built-in rules replaced by the list");
        check_eq (LinkCleaner.clean_text ("see https://foo.org/p?utm_source=a."),
                  "see https://foo.org/p.", "clean_text routes through the list");

        RemoveParamFilter.active = null;
        check_eq (LinkCleaner.clean_url ("https://youtu.be/abc?si=x"),
                  "https://youtu.be/abc", "built-in rules back once list is cleared");
    }
    if (RemoveParamFilter.from_text ("! nothing\nexample.com##.ad\n") != null) {
        stderr.printf ("FAIL: list without removeparam rules should be null\n");
        failures++;
    }

    if (failures == 0) stdout.printf ("all link-cleaner tests passed\n");
    return failures == 0 ? 0 : 1;
}
