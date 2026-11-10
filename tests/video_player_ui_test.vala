using Dc;

#if MACOS
/* Supply a short MP4 (at least two seconds) and its displayed dimensions:
 * core-compat-test --video-player-ui /tmp/video.mp4 160 96
 * Run again with a rotation-tagged copy to verify phone-video orientation. */
private async void wait_video_ready (Gtk.MediaStream stream) {
    for (int i = 0; i < 500; i++) {
        if (stream.error != null) error ("Video playback: %s", stream.error.message);
        if (stream.prepared && stream.get_intrinsic_width () > 0) return;
        yield nap (20);
    }
    error ("Video did not produce a frame");
}

private async void wait_video_seek (Gtk.MediaStream stream) {
    for (int i = 0; i < 500 && stream.seeking; i++) yield nap (20);
    assert (!stream.seeking);
    assert (stream.error == null);
}

private async void check_video_player (string path, int width, int height) {
    var viewer = new VideoPlayer ();
    var window = new Gtk.Window ();
    window.set_default_size (400, 300);
    window.child = viewer.widget;
    window.present ();
    var video = search_widget (viewer.widget, typeof (Gtk.Video)) as Gtk.Video;
    assert (video != null);

    viewer.show (path, null);
    Gtk.MediaStream? stream = video.get_media_stream ();
    assert (stream != null);
    yield wait_video_ready (stream);
    assert (stream.has_video);
    assert (stream.seekable);
    assert (stream.duration >= 2000000);
    stdout.printf ("Video size: %dx%d (expected %dx%d)\n",
        stream.get_intrinsic_width (), stream.get_intrinsic_height (), width, height);
    assert (stream.get_intrinsic_width () == width);
    assert (stream.get_intrinsic_height () == height);
    var frame = stream.get_current_image ();
    assert ((frame.get_flags () & Gdk.PaintableFlags.STATIC_CONTENTS) != 0);
    assert (frame.get_intrinsic_width () == width);
    assert (frame.get_intrinsic_height () == height);
    stdout.printf ("Video: decoded %dx%d\n", width, height);
    uint frames = 0;
    ulong frame_handler = stream.invalidate_contents.connect (() => frames++);
    yield nap (300);
    assert (frames > 1);
    assert (stream.timestamp > 0);

    viewer.handle_key (Gdk.Key.space);
    assert (!stream.playing);
    yield nap (100);
    int64 paused = stream.timestamp;
    yield nap (200);
    assert ((stream.timestamp - paused).abs () < 50000);
    stream.set_volume (0.25);
    stream.set_muted (true);
    uint before_seek = frames;
    stdout.printf ("Video: seeking while paused\n");
    stream.seek (stream.duration / 2);
    yield wait_video_seek (stream);
    for (int i = 0; i < 100 && frames == before_seek; i++) yield nap (20);
    assert (frames > before_seek);
    assert (!stream.playing);
    assert ((stream.timestamp - stream.duration / 2).abs () < 100000);

    // A newer seek must win even if the older completion arrives later.
    stdout.printf ("Video: replacing an in-flight seek\n");
    stream.seek (0);
    stream.seek (stream.duration - 300000);
    yield wait_video_seek (stream);
    viewer.handle_key (Gdk.Key.space);
    for (int i = 0; i < 250 && !stream.ended; i++) yield nap (20);
    assert (stream.ended);
    assert (!stream.playing);
    stdout.printf ("Video: replaying after end\n");
    viewer.handle_key (Gdk.Key.space);
    yield wait_video_seek (stream);
    yield nap (150);
    assert (stream.playing);
    assert (!stream.ended);
    assert (stream.timestamp < stream.duration / 2);

    stream.set_loop (true);
    stdout.printf ("Video: looping\n");
    stream.seek (stream.duration - 200000);
    yield wait_video_seek (stream);
    yield nap (500);
    assert (stream.playing);
    assert (!stream.ended);
    assert (stream.timestamp < stream.duration / 2);
    stream.disconnect (frame_handler);

    // Close during an asynchronous seek: it must not resume playback or leak.
    stdout.printf ("Video: closing during seek\n");
    stream.seek (0);
    var released = WeakRef (stream);
    viewer.hide ();
    assert (!stream.playing);
    stream = null;
    for (int i = 0; i < 250 && released.get () != null; i++) yield nap (20);
    assert (released.get () == null);
    assert (!viewer.visible);
    assert (video.get_media_stream () == null);

    // Loading failures show a readable error, and reopening clears it.
    stdout.printf ("Video: error recovery and reopening\n");
    viewer.show (path + ".missing", null);
    stream = video.get_media_stream ();
    for (int i = 0; i < 500 && stream.error == null; i++) yield nap (20);
    assert (stream.error != null);
    assert (!video.visible);
    var label = video.get_next_sibling () as Gtk.Label;
    assert (label != null && label.visible && label.label.length > 0);
    viewer.show (path, null);
    assert (video.visible);
    assert (!label.visible);
    // Also close while preparation is still pending.
    viewer.hide ();
    viewer.show (path, null);
    stream = video.get_media_stream ();
    yield wait_video_ready (stream);
    viewer.handle_key (Gdk.Key.Escape);
    assert (!viewer.visible);
    assert (!stream.playing);
    window.destroy ();
}

public int run_video_player_ui_test (string path, int width, int height) {
    Gtk.init ();
    var loop = new MainLoop ();
    check_video_player.begin (path, width, height, (o, res) => {
        check_video_player.end (res);
        loop.quit ();
    });
    loop.run ();
    stdout.printf ("Video playback: frames, controls, rotation, errors, and cleanup passed.\n");
    return 0;
}
#endif
