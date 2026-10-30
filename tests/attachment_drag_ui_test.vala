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

private async void check_exported_file (Gtk.DragSource source, string path,
                                       int message_id)
                                       throws Error {
    assert (source.actions == Gdk.DragAction.COPY);
    var content = source.prepare (0, 0);
    assert (content != null);
    var message = MessageDrag.from_content (content);
    assert (message != null && message.account_id == 7);
    assert (message.message_id == message_id);
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
            var row = new MessageRow (msg, null, null, false, BubbleAvatarDisplay.NONE,
                false, true, null, null, 7);
            var sources = new GenericArray<Gtk.DragSource> ();
            collect_file_drags (row, sources);
            assert (sources.length == 1);
            yield check_exported_file (sources[0], file_path, 42);
            msg.selection_visible = true;
            assert (sources[0].prepare (0, 0) == null);
        }
    }
    // Grouped IRC images must each export their own attachment.
    MessageRow.style = MessageStyle.IRC;
    var first = new Message ();
    first.id = 51;
    first.file_path = image_path;
    var second = new Message ();
    second.id = 52;
    second.view_type = "Image";
    second.file_path = path;
    var trailing = new GenericArray<Message> ();
    trailing.add (second);
    var row = new MessageRow (first, null, trailing, false, BubbleAvatarDisplay.NONE,
        false, true, null, null, 7);
    var sources = new GenericArray<Gtk.DragSource> ();
    collect_file_drags (row, sources);
    assert (sources.length == 2);
    yield check_exported_file (sources[0], image_path, 51);
    yield check_exported_file (sources[1], path, 52);
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

private ChatRow? forward_chat_row (Gtk.Widget widget, int chat_id) {
    if (widget is ChatRow && ((ChatRow) widget).chat_id == chat_id)
        return (ChatRow) widget;
    for (var child = widget.get_first_child (); child != null;
            child = child.get_next_sibling ()) {
        var row = forward_chat_row (child, chat_id);
        if (row != null) return row;
    }
    return null;
}

private async void check_forward_drop (Dc.Application app, Dc.Window window) {
    try {
        for (int i = 0; i < 200 && window.chat_store.get_n_items () != 3; i++)
            yield nap (25);
        assert (window.chat_store.get_n_items () == 3);
        yield window.open_chat_from_notification (1, 10);
        yield nap (500);
        var view = window.current_view ();
        var composer = search_widget (view, typeof (ComposeBar));
        var editor = (Gtk.TextView) search_widget (composer, typeof (Gtk.TextView));
        editor.buffer.text = "Unfinished draft";
        var sources = new GenericArray<Gtk.DragSource> ();
        collect_file_drags (view, sources);
        assert (sources.length == 1);
        var content = sources[0].prepare (0, 0);
        var message = MessageDrag.from_content (content);
        assert (message != null && message.account_id == 1 && message.message_id == 42);
        var target = forward_chat_row (window, 11);
        assert (target != null && target.accept_message_drop (message));
        var request = forward_chat_row (window, 12);
        assert (request != null && !request.accept_message_drop (message));
        assert (!target.accept_message_drop (new MessageDrag (0, 42)));

        target.message_dropped (message);
        yield nap (300);
        var calls = (yield app.rpc.call ("test_calls", Params.begin ().build ())).get_array ();
        assert (calls.get_length () == 1);
        var forwarded = calls.get_object_element (0);
        assert (forwarded.get_string_member ("method") == "forward_messages");
        var args = forwarded.get_array_member ("params");
        assert (args.get_int_element (0) == 1);
        assert (args.get_array_element (1).get_length () == 1);
        assert (args.get_array_element (1).get_int_element (0) == 42);
        assert (args.get_int_element (2) == 11);
        assert (window.current_view () == view && window.current_chat_id == 10);
        assert (editor.buffer.text == "Unfinished draft");

        // A failed send must leave the source and draft intact too.
        yield app.rpc.call ("test_fail", Params.begin ().build ());
        forward_chat_row (window, 11).message_dropped (message);
        for (int i = 0; i < 100 && search_widget (window, typeof (Gtk.Label),
                "Forward failed: RPC forward_messages: offline") == null; i++)
            yield nap (50);
        assert (search_widget (window, typeof (Gtk.Label),
            "Forward failed: RPC forward_messages: offline") != null);
        assert (editor.buffer.text == "Unfinished draft");

        // An explicit source account survives a destination account change.
        forward_chat_row (window, 11).message_dropped (new MessageDrag (2, 77));
        yield nap (300);
        calls = (yield app.rpc.call ("test_calls", Params.begin ().build ())).get_array ();
        assert (calls.get_length () == 4);
        var fetch = calls.get_object_element (2);
        assert (fetch.get_string_member ("method") == "get_message");
        assert (fetch.get_array_member ("params").get_int_element (0) == 2);
        var sent = calls.get_object_element (3);
        assert (sent.get_string_member ("method") == "send_msg");
        args = sent.get_array_member ("params");
        assert (args.get_int_element (0) == 1 && args.get_int_element (1) == 11);
        var data = args.get_object_element (2);
        assert (data.get_string_member ("text") == "Picture caption");
        assert (data.get_string_member ("file") == Environment.get_variable ("PARLA_TEST_IMAGE"));
        assert (window.current_chat_id == 10 && editor.buffer.text == "Unfinished draft");
    } catch (Error e) {
        error ("Forward drop: %s", e.message);
    }
    app.rpc.stop ();
    window.destroy ();
}

public int run_forward_drop_ui_test () {
    Adw.init ();
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register forward test: %s", e.message); }
    var window = new Dc.Window (app);
    window.present ();
    var loop = new MainLoop ();
    check_forward_drop.begin (app, window, () => { loop.quit (); });
    loop.run ();
    stdout.printf ("Forward drops: destination, account, caption, rejection, failure and drafts passed.\n");
    return 0;
}
