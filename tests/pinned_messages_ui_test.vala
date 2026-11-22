using Dc;

// Display test: core-compat-test --pinned-ui
private async void check_pinned_messages (string binary) {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ binary, "--fake-retry" });
        rpc.account_id = 1;
        yield rpc.call ("test_pins", Params.begin ().add_int_array ({ 100, 101 }).build ());
        // A channel subscriber cannot change the shared pin state.
        yield rpc.call ("test_fail", Params.begin ().add_string ("set_pinned_message_state").build ());
        var store = new GLib.ListStore (typeof (Message));
        foreach (int id in new int[] { 100, 101 }) {
            var msg = new Message ();
            msg.id = id;
            msg.text = "**bold** & <literal>\n`code`\r\nhttps://example.com";
            msg.sender_name = "<Sender>\nname";
            store.append (msg);
        }
        var settings = new SettingsManager ();
        var pinned = new PinnedMessagesManager (store, settings);
        pinned.set_rpc (rpc);
        yield pinned.load_for_chat (10);
        yield pinned.update_bar ();
        var content = pinned.revealer.child;
        var row = content.get_first_child ();
        var jump = (Gtk.Button) row.get_first_child ();
        var text_box = jump.child.get_last_child ();
        var label = (Gtk.Label) text_box.get_last_child ();
        assert (label.use_markup && label.label.contains ("<b>bold</b>"));
        assert (label.label.contains ("<tt>code</tt>"));
        assert (label.get_text ().contains ("& <literal>"));
        label.allocate (180, 40, -1, null);
        assert (label.get_layout ().get_line_count () == 1);
        assert (label.get_layout ().is_ellipsized ());
        var sender = (Gtk.Label) text_box.get_first_child ();
        sender.allocate (80, 40, -1, null);
        assert (sender.get_layout ().get_line_count () == 1);
        int scrolled = 0;
        pinned.scroll_requested.connect ((id) => { scrolled = id; });
        jump.clicked ();
        assert (scrolled == 100);
        ((Gtk.Button) row.get_last_child ()).clicked ();
        assert (pinned.is_pinned (100) && find_message (store, 100).is_pinned);
        assert ((yield retry_call_count (rpc, "set_pinned_message_state")) == 0);
        // Reloads keep the dismissed preview hidden; the other pin still shows.
        yield pinned.load_for_chat (10);
        yield pinned.update_bar ();
        row = pinned.revealer.child.get_first_child ();
        assert (row != null && row.get_next_sibling () == null);
        ((Gtk.Button) row.get_first_child ()).clicked ();
        assert (scrolled == 101);
        ((Gtk.Button) row.get_last_child ()).clicked ();
        assert (!pinned.revealer.reveal_child);
        // Once unpinned remotely, pinning the same message can show it again.
        yield rpc.call ("test_pins", Params.begin ().add_int_array ({}).build ());
        yield pinned.load_for_chat (10);
        yield rpc.call ("test_pins", Params.begin ().add_int_array ({ 100 }).build ());
        yield pinned.load_for_chat (10);
        yield pinned.update_bar ();
        assert (pinned.revealer.reveal_child);
    } catch (Error e) {
        error ("Pinned messages: %s", e.message);
    }
    rpc.stop ();
}

public int run_pinned_messages_ui_test (string binary) {
    Gtk.init ();
    var loop = new MainLoop ();
    check_pinned_messages.begin (binary, () => { loop.quit (); });
    loop.run ();
    stdout.printf ("Pinned message Markdown, single-line layout and local dismissal passed.\n");
    return 0;
}
