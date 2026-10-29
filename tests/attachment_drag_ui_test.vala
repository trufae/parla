using Dc;

private void collect_file_drags (Gtk.Widget widget,
                                 GenericArray<Gtk.DragSource> sources) {
    var controllers = widget.observe_controllers ();
    for (uint i = 0; i < controllers.get_n_items (); i++) {
        var source = controllers.get_item (i) as Gtk.DragSource;
        if (source != null) sources.add (source);
    }
    for (var child = widget.get_first_child (); child != null;
            child = child.get_next_sibling ())
        collect_file_drags (child, sources);
}

private async void check_exported_file (Gtk.DragSource source, string path)
                                       throws Error {
    assert (source.actions == Gdk.DragAction.COPY);
    var content = source.prepare (0, 0);
    assert (content != null);
    var value = Value (typeof (Gdk.FileList));
    content.get_value (ref value);
    var files = ((Gdk.FileList) value.get_boxed ()).get_files ();
    assert (files.length () == 1);
    assert (files.data.get_path () == path);
    // File managers need escaped file URIs, rather than the rendered preview.
    var stream = new MemoryOutputStream.resizable ();
    yield content.write_mime_type_async ("text/uri-list", stream,
                                        Priority.DEFAULT, null);
    stream.close ();
    string expected = File.new_for_path (path).get_uri () + "\r\n";
    assert (stream.steal_as_bytes ().compare (new Bytes (expected.data)) == 0);
}

private async void check_attachment_drags (string folder) throws Error {
    string path = Path.build_filename (folder, "résumé with spaces.txt");
    FileUtils.set_contents (path, "attachment contents");
    string image_path = Path.build_filename (folder, "image.png");
    var pixels = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 16, 16);
    pixels.fill (0xff0000ffU);
    pixels.save (image_path, "png");
    foreach (var style in new MessageStyle[] {
            MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
        MessageRow.style = style;
        foreach (var file_path in new string[] { path, image_path }) {
            var msg = new Message ();
            msg.id = 42;
            msg.file_path = file_path;
            msg.file_name = Path.get_basename (file_path);
            var row = new MessageRow (msg);
            var sources = new GenericArray<Gtk.DragSource> ();
            collect_file_drags (row, sources);
            assert (sources.length == 1);
            yield check_exported_file (sources[0], file_path);
            msg.selection_visible = true;
            assert (sources[0].prepare (0, 0) == null);
        }
    }
    // Grouped IRC images must each export their own attachment.
    MessageRow.style = MessageStyle.IRC;
    var first = new Message ();
    first.file_path = image_path;
    var second = new Message ();
    second.view_type = "Image";
    second.file_path = path;
    var trailing = new GenericArray<Message> ();
    trailing.add (second);
    var row = new MessageRow (first, null, trailing);
    var sources = new GenericArray<Gtk.DragSource> ();
    collect_file_drags (row, sources);
    assert (sources.length == 2);
    yield check_exported_file (sources[0], image_path);
    yield check_exported_file (sources[1], path);
    FileUtils.unlink (path);
    assert (sources[1].prepare (0, 0) == null);
    var missing = new Message ();
    missing.file_name = "not-downloaded.txt";
    var missing_row = new MessageRow (missing);
    sources = new GenericArray<Gtk.DragSource> ();
    collect_file_drags (missing_row, sources);
    assert (sources.length == 0);
    FileUtils.unlink (image_path);
}

public int run_attachment_drag_ui_test () {
    Adw.init ();
    var loop = new MainLoop ();
    string folder;
    try { folder = DirUtils.make_tmp ("parla-attachment-drag-XXXXXX"); }
    catch (Error e) { error ("Drag fixture: %s", e.message); }
    check_attachment_drags.begin (folder, (o, res) => {
        try { check_attachment_drags.end (res); }
        catch (Error e) { error ("Attachment drag: %s", e.message); }
        loop.quit ();
    });
    loop.run ();
    DirUtils.remove (folder);
    stdout.printf ("Attachment drag payloads, grouped images, and availability passed.\n");
    return 0;
}
