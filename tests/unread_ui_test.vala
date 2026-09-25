using Dc;

/* Optional display test, driven by unread_ui_test.py. Uses the real Window,
   ConversationView, virtualized rows and JSON-RPC transport. */
private async void unread_ui_pause (uint milliseconds = 1000) {
    Timeout.add (milliseconds, unread_ui_pause.callback);
    yield;
}

private int unread_separator_count (Gtk.Widget widget) {
    int count = widget.has_css_class ("unread-separator") ? 1 : 0;
    for (var child = widget.get_first_child (); child != null;
            child = child.get_next_sibling ()) count += unread_separator_count (child);
    return count;
}

private async bool fixture_seen (RpcClient rpc, int id) throws Error {
    var result = yield rpc.call ("test_seen", Params.begin ().add_int (id).build ());
    return result.get_boolean ();
}

private async void check_unread_ui (Dc.Application app, Dc.Window window) {
    try {
        for (int i = 0; i < 100 && app.rpc.account_id == 0; i++)
            yield unread_ui_pause (50);
        assert (app.rpc.account_id == 1);
        yield window.open_chat_from_notification (1, 10);
        var view = window.current_view ();
        assert (view != null);
        // A core refresh while activation is loading must retain the boundary.
        view.reload_messages.begin ();
        yield unread_ui_pause (1500);
        assert (window.is_chat_visible (10));
        assert (view.first_unread_message_id == 20);
        assert (unread_separator_count (view) == 1);
        assert (yield fixture_seen (app.rpc, 20));
        // Both messages are loaded but only the first is on screen.
        assert (!(yield fixture_seen (app.rpc, 80)));
        assert (!(yield fixture_seen (app.rpc, 109)));

        // Scrolling to the bottom reads the messages that enter the viewport.
        view.on_reselected (false);
        yield unread_ui_pause ();
        assert (yield fixture_seen (app.rpc, 109));
        assert (view.first_unread_message_id == 20);

        // Marking the open chat unread closes it and defeats pending timers.
        yield window.mark_chat_unread (10);
        yield unread_ui_pause ();
        assert (window.current_chat_id == 0);
        assert ((yield app.rpc.get_first_unread_message_of_chat (10)) == 109);
        yield window.open_chat_from_notification (1, 10);
        yield unread_ui_pause (1500);
        view = window.current_view ();
        assert (view.first_unread_message_id == 109);
        assert (unread_separator_count (view) == 1);
        assert (yield fixture_seen (app.rpc, 109));

        // Receiving at the bottom while hidden must defer receipts to focus.
        window.visible = false;
        yield app.rpc.call ("test_incoming", Params.begin ().add_int (110).build ());
        yield view.handle_incoming_msg (110);
        yield unread_ui_pause ();
        assert (!(yield fixture_seen (app.rpc, 110)));
        window.present ();
        yield unread_ui_pause (1500);
        assert (yield fixture_seen (app.rpc, 110));

        // New messages below the viewport remain unread while reading history.
        view.scroll_to_message (20);
        yield unread_ui_pause (1500);
        yield app.rpc.call ("test_incoming", Params.begin ().add_int (111).build ());
        yield view.handle_incoming_msg (111);
        yield unread_ui_pause ();
        assert (!(yield fixture_seen (app.rpc, 111)));
        view.close ();
        app.rpc.stop ();
        window.destroy ();
        stdout.printf ("Unread navigation, separator, visible receipts, reopen and focus: PASS\n");
    } catch (Error e) {
        error ("Unread UI: %s", e.message);
    }
}

public int run_unread_ui_test () {
    Adw.init ();
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register test app: %s", e.message); }
    var window = new Dc.Window (app);
    window.present ();
    var loop = new MainLoop ();
    check_unread_ui.begin (app, window, () => { loop.quit (); });
    loop.run ();
    return 0;
}
