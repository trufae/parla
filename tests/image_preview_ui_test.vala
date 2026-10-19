using Dc;

/* Run core-compat-test --image-preview-ui [image] on an isolated GTK display.
   The optional path also checks a real attachment without modifying it. */
private void write_preview_gif (string path) throws Error {
    var data = new ByteArray ();
    // Two 320x240 frames, red then blue. Clear the LZW dictionary between
    // pixels to keep the fixture larger than the loader's read buffer.
    // Small GIFs do not reproduce from_file_at_scale's partial-load error.
    data.append ({ 'G', 'I', 'F', '8', '9', 'a',
        0x40, 0x01, 0xf0, 0x00, 0x80, 0, 0, 255, 0, 0, 0, 0, 255 });
    data.append ({ 0x21, 0xff, 11, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E',
        '2', '.', '0', 3, 1, 0, 0, 0 }); // Loop indefinitely.
    for (int frame = 0; frame < 2; frame++) {
        data.append ({ 0x21, 0xf9, 4, 0, 10, 0, 0, 0,
            0x2c, 0, 0, 0, 0, 0x40, 0x01, 0xf0, 0, 0, 2 });
        uint8[] pattern = frame == 0
            ? new uint8[] { 0x04, 0x41, 0x10 }
            : new uint8[] { 0x0c, 0xc3, 0x30 };
        for (int offset = 0; offset < 57600; offset += 255) {
            int length = int.min (255, 57600 - offset);
            data.append ({ (uint8) length });
            var block = new uint8[length];
            for (int i = 0; i < length; i++) block[i] = pattern[i % 3];
            data.append (block);
        }
        data.append ({ 1, 5, 0 }); // End code and data terminator.
    }
    data.append ({ 0x3b });
    FileUtils.set_data (path, data.data);
}

private void check_image_preview (string path) {
    var msg = new Message ();
    msg.id = 42;
    msg.file_path = path;
    msg.file_name = Path.get_basename (path);
    msg.text = "An image with a caption";
    foreach (var style in new MessageStyle[] {
            MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
        MessageRow.style = style;
        var row = new MessageRow (msg);
        var picture = search_widget (row, typeof (Gtk.Picture)) as Gtk.Picture;
        assert (picture != null && picture.paintable != null);
        assert (picture.get_parent () is ScaledPreviewFrame);
        assert (picture.paintable.get_intrinsic_width () > 0);
        assert (picture.paintable.get_intrinsic_height () > 0);
        assert (picture.paintable.get_intrinsic_width () <= 400);
        assert (picture.paintable.get_intrinsic_height () <= 400);
        assert (search_widget (row, typeof (Gtk.Label), msg.text) != null);
    }

    var viewer = new ImageViewer ();
    viewer.show_list ({ path }, 0);
    assert (viewer.visible);
    assert (viewer.current_path == path);
    var picture = search_widget (viewer.widget, typeof (Gtk.Picture)) as Gtk.Picture;
    assert (picture != null && picture.paintable != null);
    viewer.hide ();
    assert (picture.paintable == null);
}

private Bytes preview_pixels (Gdk.Paintable paintable) {
    var texture = paintable.get_current_image () as Gdk.Texture;
    assert (texture != null);
    var pixels = new uint8[texture.width * texture.height * 4];
    texture.download (pixels, texture.width * 4);
    return new Bytes (pixels);
}

private async void check_image_motion (string path, bool animated,
                                       bool sticker = false) {
    foreach (var style in new MessageStyle[] {
            MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
        MessageRow.style = style;
        var msg = new Message ();
        msg.id = 42;
        msg.file_path = path;
        msg.file_name = Path.get_basename (path);
        if (sticker) msg.view_type = "Sticker";
        var row = new MessageRow (msg);
        var picture = search_widget (row, typeof (Gtk.Picture)) as Gtk.Picture;
        assert (picture != null && picture.paintable != null);
        var paintable = picture.paintable;
        var first_frame = preview_pixels (paintable);
        int updates = 0;
        int resizes = 0;
        ulong contents_handler = paintable.invalidate_contents.connect (() => { updates++; });
        ulong size_handler = paintable.invalidate_size.connect (() => { resizes++; });
        var window = new Gtk.Window ();
        window.child = row;
        window.present ();
        for (int i = 0; i < 100 && !picture.get_mapped (); i++) yield nap (20);
        assert (picture.get_mapped ());

        if (!animated || sticker) {
            yield nap (250);
            assert (updates == 0);
            assert (first_frame.compare (preview_pixels (paintable)) == 0);
            // The sticker autoplay setting and click-to-play still work.
            if (sticker) picture.get_data<ImageAnimation> (
                "parla-image-animation").toggle_playing ();
        }
        if (animated) {
            for (int i = 0; i < 100
                    && first_frame.compare (preview_pixels (paintable)) == 0; i++)
                yield nap (20);
            assert (first_frame.compare (preview_pixels (paintable)) != 0);
            assert (updates > 0);
            // A stable paintable avoids a relayout on every GIF frame.
            assert (picture.paintable == paintable);
            assert (resizes == 0);
            window.visible = false;
            assert (!picture.get_mapped ());
            int before_hide = updates;
            yield nap (250);
            assert (updates == before_hide);
            window.present ();
            for (int i = 0; i < 100 && updates == before_hide; i++) yield nap (20);
            assert (updates > before_hide);
        }

        var animation_ref = WeakRef (picture.get_data<ImageAnimation> (
            "parla-image-animation"));
        SignalHandler.disconnect (paintable, contents_handler);
        SignalHandler.disconnect (paintable, size_handler);
        window.destroy ();
        window.child = null;
        picture = null;
        row = null;
        assert (animation_ref.get () == null);
    }
}

private async void check_image_animations (string gif, string png,
                                           string? attachment) {
    // Ordinary GIFs autoplay even when sticker autoplay is disabled.
    yield check_image_motion (gif, true);
    yield check_image_motion (png, false);
    yield check_image_motion (gif, true, true);
    if (attachment != null) yield check_image_motion (attachment, true);
}

public int run_image_preview_ui_test (string? attachment = null) {
    Adw.init ();
    MessageRow.animate_stickers = false;
    string? folder = null;
    try {
        folder = DirUtils.make_tmp ("parla-image-preview-XXXXXX");
        string gif = Path.build_filename (folder, "animated.gif");
        string png = Path.build_filename (folder, "still.png");
        write_preview_gif (gif);
        var animation = PixbufAnimationCompat.load (gif);
        assert (!PixbufAnimationCompat.is_static_image (animation));
        var frame = scaled_frame_from_file (gif, 100);
        assert (frame.width == 100 && frame.height == 75);
        unowned uint8[] pixels = frame.get_pixels ();
        assert (pixels[0] == 255 && pixels[1] == 0 && pixels[2] == 0);
        frame.save (png, "png");
        check_image_preview (gif);
        check_image_preview (png);
        if (attachment != null) check_image_preview (attachment);
        var loop = new MainLoop ();
        check_image_animations.begin (gif, png, attachment, () => { loop.quit (); });
        loop.run ();
        FileUtils.unlink (gif);
        FileUtils.unlink (png);
        DirUtils.remove (folder);
    } catch (Error e) {
        error ("Image preview fixture: %s", e.message);
    }
    stdout.printf ("Image previews and chat GIF playback passed in all message styles.\n");
    return 0;
}
