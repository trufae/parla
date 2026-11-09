using Dc;

/* Run core-compat-test --compose-scroll-ui on an isolated display (Xvfb or
   Broadway): this exercises the real clipboard and keeps animations enabled. */
private void check_compose_viewport (Gtk.TextView entry) {
    Gdk.Rectangle visible, cursor;
    Gtk.TextIter iter;
    entry.get_visible_rect (out visible);
    entry.buffer.get_iter_at_mark (out iter, entry.buffer.get_insert ());
    entry.get_iter_location (iter, out cursor);
    var adjustment = entry.vadjustment;
    stdout.printf ("Composer height %d, scroll page %.0f, offset %.0f\n",
        visible.height, adjustment.page_size, adjustment.value);
    stdout.flush ();
    // A stale page size leaves most of the expanded composer blank.
    assert (adjustment.page_size == visible.height);
    assert (cursor.y >= visible.y);
    assert (cursor.y + cursor.height <= visible.y + visible.height);
    if (adjustment.upper <= visible.height)
        assert (adjustment.value == adjustment.lower);
    else
        assert (adjustment.value <= adjustment.upper - visible.height);
}

private async void check_compose_scroll_ui (Gtk.Window window, ComposeBar compose) {
    var entry = (Gtk.TextView) search_widget (compose, typeof (Gtk.TextView));
    yield nap (300);
    // Native typing scrolls the cursor before the growing entry is allocated.
    // Exercise every line count: a stale viewport used to clip the top of the
    // text and leave extra space at the bottom on alternate lines.
    entry.grab_focus ();
    for (int lines = 1; lines <= 8; lines++) {
        entry.buffer.insert_at_cursor (lines == 1 ? "Message line" : "\nMessage line", -1);
        entry.scroll_mark_onscreen (entry.buffer.get_insert ());
        yield nap (300);
        check_compose_viewport (entry);
        Gdk.Rectangle visible, last;
        entry.get_visible_rect (out visible);
        Gtk.TextIter end;
        entry.buffer.get_end_iter (out end);
        entry.get_iter_location (end, out last);
        assert (visible.y == -entry.top_margin);
        assert (visible.y + visible.height - last.y - last.height == entry.bottom_margin);
    }
    for (int lines = 7; lines >= 1; lines--) {
        Gtk.TextIter start, end;
        entry.buffer.get_iter_at_line (out start, lines);
        start.backward_char ();
        entry.buffer.get_end_iter (out end);
        entry.buffer.delete (ref start, ref end);
        entry.scroll_mark_onscreen (entry.buffer.get_insert ());
        yield nap (300);
        check_compose_viewport (entry);
    }

    entry.buffer.text = "";
    yield nap (300);
    for (int i = 0; i < 20; i++) {
        entry.buffer.insert_at_cursor (string.nfill (25, 'a'), -1);
        entry.scroll_mark_onscreen (entry.buffer.get_insert ());
        yield nap (300);
        check_compose_viewport (entry);
    }

    foreach (int lines in new int[] { 8, 40 }) {
        var message = new StringBuilder ();
        for (int i = 0; i < lines; i++) {
            if (i > 0) message.append_c ('\n');
            message.append_printf ("Message line %d", i);
        }
        entry.buffer.text = "";
        yield nap (300);
        var clipboard = entry.get_clipboard ();
        clipboard.set_text (message.str);
        entry.paste_clipboard ();
        yield nap (500);
        assert (entry.buffer.text == message.str);
        check_compose_viewport (entry);

        entry.buffer.text = "";
        yield nap (300);
        compose.begin_edit (42, message.str);
        yield nap (500);
        check_compose_viewport (entry);
        compose.cancel_active_mode ();
        yield nap (300);
        check_compose_viewport (entry);
    }

    // Pasting in the middle must reveal the insertion point, not jump to
    // the end of the message or replace the existing selection incorrectly.
    var draft = new Message ();
    draft.text = string.nfill (1000, 'a');
    compose.restore_draft (draft);
    yield nap (500);
    check_compose_viewport (entry);
    Gtk.TextIter start, end;
    entry.buffer.get_iter_at_offset (out start, 4);
    entry.buffer.get_iter_at_offset (out end, 12);
    entry.buffer.select_range (start, end);
    entry.get_clipboard ().set_text ("inserted\nmessage");
    entry.paste_clipboard ();
    yield nap (500);
    assert (entry.buffer.text == "aaaainserted\nmessage" + string.nfill (988, 'a'));
    entry.buffer.get_iter_at_mark (out end, entry.buffer.get_insert ());
    assert (end.get_offset () == 20);
    check_compose_viewport (entry);

    // A queued request survives being populated before mapping, and is
    // disconnected if the composer is closed before the next frame.
    var hidden = new ComposeBar ();
    hidden.begin_edit (43, draft.text);
    window.child = hidden;
    compose.close ();
    yield nap (500);
    check_compose_viewport ((Gtk.TextView) search_widget (hidden, typeof (Gtk.TextView)));
    hidden.begin_edit (44, "another\nmessage");
    hidden.close ();
    window.destroy ();
}

public int run_compose_scroll_ui_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = true;
    var window = new Gtk.Window ();
    window.set_default_size (575, 400);
    var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    var spacer = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    spacer.vexpand = true;
    box.append (spacer);
    var compose = new ComposeBar ();
    compose.link_previews = false;
    box.append (compose);
    window.child = box;
    window.present ();
    var loop = new MainLoop ();
    check_compose_scroll_ui.begin (window, compose, () => { loop.quit (); });
    loop.run ();
    return 0;
}

private bool press_compose_key (Gtk.TextView entry, uint key, Gdk.ModifierType mods) {
    var controllers = entry.observe_controllers ();
    for (uint i = 0; i < controllers.get_n_items (); i++) {
        var k = controllers.get_item (i) as Gtk.EventControllerKey;
        if (k != null && k.key_pressed (key, 0, mods)) return true;
    }
    return false;
}

private int compose_cursor (Gtk.TextView entry) {
    Gtk.TextIter iter;
    entry.buffer.get_iter_at_mark (out iter, entry.buffer.get_insert ());
    return iter.get_offset ();
}

/* macOS only: core-compat-test --compose-line-keys-ui. Control+A / Control+E
   move to the paragraph start / end like Cocoa instead of selecting all. */
public int run_compose_line_keys_ui_test () {
    Adw.init ();
    if (!Platform.is_macos ()) return 0;
    var compose = new ComposeBar ();
    var entry = (Gtk.TextView) search_widget (compose, typeof (Gtk.TextView));
    entry.buffer.text = "first line\nsecond line";
    Gtk.TextIter iter;
    entry.buffer.get_iter_at_offset (out iter, 15);
    entry.buffer.place_cursor (iter);
    var ctrl = Gdk.ModifierType.CONTROL_MASK;

    assert (press_compose_key (entry, Gdk.Key.e, ctrl));
    assert (compose_cursor (entry) == 22 && !entry.buffer.has_selection);
    assert (press_compose_key (entry, Gdk.Key.a, ctrl));
    assert (compose_cursor (entry) == 11 && !entry.buffer.has_selection);
    assert (press_compose_key (entry, Gdk.Key.E, ctrl | Gdk.ModifierType.SHIFT_MASK));
    assert (compose_cursor (entry) == 22 && entry.buffer.has_selection);
    stdout.printf ("Compose Control+A/E line keys passed.\n");
    return 0;
}
