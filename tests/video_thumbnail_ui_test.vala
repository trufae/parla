using Dc;

#if MACOS
private async void check_video_preview_layout (string video) {
    foreach (var style in new MessageStyle[] {
            MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
        MessageRow.style = style;
        foreach (string state in new string[] { "Available", "InProgress", "Failure", "Done" }) {
            foreach (bool portrait in new bool[] { false, true }) {
                var msg = new Message ();
                msg.id = 42;
                msg.view_type = "Video";
                msg.state = MessageState.OUT_DELIVERED;
                msg.file_name = "video_2026-10-29_12-25-52.mp4";
                msg.download_state = state;
                if (state == "Done") msg.file_path = video;
                if (portrait) {
                    msg.dimensions_width = 1080;
                    msg.dimensions_height = 1920;
                }
                // The caption/download controls can be wider than the preview.
                msg.text = "A video attachment with a caption that fills the message bubble";
                foreach (int width in new int[] { 800, 400 }) {
                    var row = new MessageRow (msg);
                    var picture = search_widget (row, typeof (Gtk.Picture)) as Gtk.Picture;
                    assert (picture != null);
                    var overlay = picture.get_parent () as Gtk.Overlay;
                    var frame = overlay.get_parent () as ScaledPreviewFrame;
                    assert (frame != null);
                    var window = new Gtk.Window ();
                    window.set_default_size (width, 400);
                    window.child = row;
                    window.present ();
                    yield nap (50);
                    stdout.printf ("Video layout: %s %s portrait=%s window=%d frame=%dx%d content=%dx%d\n",
                        style.to_string (), state, portrait.to_string (), window.get_width (),
                        frame.get_width (), frame.get_height (), picture.get_width (), picture.get_height ());
                    assert (frame.get_width () <= window.get_width ());
                    assert (frame.get_width () <= (portrait ? 112 : 260));
                    assert (frame.get_height () <= (portrait ? 200 : 150));
                    assert (picture.get_width () == frame.get_width ());
                    assert (picture.get_height () == frame.get_height ());
                    var badge = picture.get_next_sibling ();
                    Graphene.Rect bounds;
                    assert (badge.compute_bounds (frame, out bounds));
                    assert ((bounds.origin.x + bounds.size.width / 2
                        - frame.get_width () / 2.0).abs () <= 1);
                    assert ((bounds.origin.y + bounds.size.height / 2
                        - frame.get_height () / 2.0).abs () <= 1);
                    window.destroy ();
                }
            }
        }
    }
}

/* Run core-compat-test --video-thumbnail-ui /path/to/short-video.mp4 on macOS.
   Uses the real AVFoundation worker and GTK pictures, including task cleanup. */
private async void check_video_thumbnails (string video, string folder) {
    var picture = new Gtk.Picture ();
    // Failed generation used to double-clear the weak ref on the early return.
    yield VideoThumbnail.load (Path.build_filename (folder, "missing.mp4"), picture);
    assert (picture.paintable == null);
    string broken = Path.build_filename (folder, "broken.mp4");
    try { FileUtils.set_contents (broken, "not a video"); }
    catch (Error e) { error ("Video fixture: %s", e.message); }
    yield VideoThumbnail.load (broken, picture);
    assert (picture.paintable == null);
    FileUtils.unlink (broken);

    // Remove a preview before its uncached worker completes. Loading must
    // neither retain the widget nor try to update it after it is finalized.
    var removed = new Gtk.Picture ();
    var removed_ref = WeakRef (removed);
    bool completed = false;
    VideoThumbnail.load.begin (video, removed, (o, res) => {
        VideoThumbnail.load.end (res);
        completed = true;
    });
    removed = null;
    assert (removed_ref.get () == null);
    for (int i = 0; i < 1000 && !completed; i++) yield nap (10);
    assert (completed);

    // A separate path forces a successful uncached decode with a live target.
    string copy = Path.build_filename (folder, "copy.mp4");
    try { File.new_for_path (video).copy (File.new_for_path (copy), FileCopyFlags.NONE); }
    catch (Error e) { error ("Video fixture: %s", e.message); }
    yield VideoThumbnail.load (copy, picture);
    var texture = picture.paintable as Gdk.Texture;
    assert (texture != null && texture.width > 0 && texture.height > 0);
    assert (texture.width <= 520 && texture.height <= 520);
    FileUtils.unlink (copy);

    // Repeated cache hits return without yielding; their cleanup also crashed.
    for (int i = 0; i < 64; i++) {
        var cached = new Gtk.Picture ();
        yield VideoThumbnail.load (copy, cached);
        assert (cached.paintable == texture);
    }

    yield check_video_preview_layout (video);

    // Reopen the video attachment in every chat style through the real caller.
    foreach (var style in new MessageStyle[] {
            MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
        MessageRow.style = style;
        var msg = new Message ();
        msg.id = 42;
        msg.view_type = "Video";
        msg.file_path = video;
        msg.file_name = Path.get_basename (video);
        var row = new MessageRow (msg);
        var preview = search_widget (row, typeof (Gtk.Picture)) as Gtk.Picture;
        assert (preview != null && preview.paintable is Gdk.Texture);
    }
    yield nap (10); // Let all completed tasks finalize before reporting success.
}

public int run_video_thumbnail_ui_test (string video) {
    Adw.init ();
    assert (FileUtils.test (video, FileTest.IS_REGULAR));
    string folder;
    try { folder = DirUtils.make_tmp ("parla-video-thumbnail-XXXXXX"); }
    catch (Error e) { error ("Video fixture: %s", e.message); }
    var loop = new MainLoop ();
    check_video_thumbnails.begin (video, folder, (o, res) => {
        check_video_thumbnails.end (res);
        loop.quit ();
    });
    loop.run ();
    DirUtils.remove (folder);
    stdout.printf ("Video thumbnails: loading, layout, and all chat styles passed.\n");
    return 0;
}
#endif
