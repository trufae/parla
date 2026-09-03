using Dc;

private void test_media_formats_are_not_semantic_types () {
    assert (AttachmentTypes.infer_outgoing_view_type ("/tmp/a.gif") == null);
    assert (AttachmentTypes.infer_outgoing_view_type ("/tmp/a.WEBP") == null);
    assert (AttachmentTypes.infer_outgoing_view_type ("/tmp/a.webm") == null);
    assert (AttachmentTypes.infer_outgoing_view_type ("/tmp/a.png") == null);
}

private void test_webxdc_apps () {
    assert (AttachmentTypes.infer_outgoing_view_type ("/tmp/poll.xdc") == "Webxdc");
    assert (AttachmentTypes.infer_outgoing_view_type (
        "/tmp/blob-without-extension", "chess.XDC") == "Webxdc");
}

private void test_regular_attachments () {
    assert (AttachmentTypes.infer_outgoing_view_type ("/tmp/photo.png") == null);
    assert (AttachmentTypes.infer_outgoing_view_type ("/tmp/audio.ogg") == null);
    assert (AttachmentTypes.infer_outgoing_view_type (null) == null);
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/attachment-types/media-formats",
        test_media_formats_are_not_semantic_types);
    Test.add_func ("/attachment-types/webxdc", test_webxdc_apps);
    Test.add_func ("/attachment-types/regular", test_regular_attachments);
    return Test.run ();
}
