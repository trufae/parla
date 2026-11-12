using Dc;

private async void conversation_input (Gtk.Widget widget, Gtk.Window window,
                                       string kind, float x, float y) {
    Graphene.Point point;
    assert (widget.compute_point (window, Graphene.Point () { x = x, y = y }, out point));
    double surface_x, surface_y;
    window.get_surface_transform (out surface_x, out surface_y);
    stdout.printf ("INPUT %s %d %d\n", kind, (int) (point.x + surface_x), (int) (point.y + surface_y));
    stdout.flush ();
    yield nap (350);
}

private Gtk.Label? conversation_text (Gtk.Widget widget) {
    var label = widget as Gtk.Label;
    if (label != null && label.selectable) return label;
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = conversation_text (child);
        if (found != null) return found;
    }
    return null;
}

private MessageRow conversation_row_at (Gtk.Widget scroll, float y) {
    for (int offset = 0; offset < 100; offset += 5) {
        var widget = scroll.pick (180, y + offset, Gtk.PickFlags.DEFAULT);
        while (widget != null && widget != scroll) {
            if (widget is MessageRow) return (MessageRow) widget;
            if (widget.get_parent () is Gtk.ListView) {
                var row = search_widget (widget, typeof (MessageRow)) as MessageRow;
                if (row != null) return row;
            }
            widget = widget.get_parent ();
        }
    }
    assert_not_reached ();
}

private async void check_conversation_scroll (Dc.Application app, Dc.Window window) {
    try {
        for (int i = 0; i < 100 && app.rpc.account_id == 0; i++) yield nap (50);
        // Account selection precedes the initial sidebar fetch.
        for (int i = 0; i < 100 && window.current_view () == null; i++) {
            yield window.open_chat_from_notification (1, 10);
            yield nap (50);
        }
        yield nap (800);
        var view = window.current_view ();
        assert (view != null);
        var list = (Gtk.ListView) search_widget (view, typeof (Gtk.ListView), "conversation-messages");
        var scroll = (Gtk.ScrolledWindow) search_widget (view, typeof (Gtk.ScrolledWindow), "conversation-scroll");
        var adj = scroll.vadjustment;
        // The offline core supplies mixed heights, including rows taller
        // than the viewport, for every batch fetched during the test.
        var store = (GLib.ListStore) ((Gtk.NoSelection) list.model).model;
        view.scroll_to_message (1973);
        yield nap (1200);
        adj.value += 120;
        yield nap (300);
        // Clicking text in a tall, clipped row must not align another edge.
        for (int i = 0; i < 8; i++) {
            view.focus_entry ();
            var row = conversation_row_at (scroll, 60);
            var label = conversation_text (row);
            assert (label != null);
            Graphene.Point origin;
            assert (label.compute_point (scroll, Graphene.Point (), out origin));
            double top = search_message_top (view, row.message_id, scroll);
            double drift = 0;
            var clock = scroll.get_frame_clock ();
            ulong paint = clock.after_paint.connect (() => {
                drift = double.max (drift, Math.fabs (
                    search_message_top (view, row.message_id, scroll) - top));
            });
            double before = adj.value;
            yield conversation_input (scroll, window, "click", origin.x + 10,
                float.max (10, origin.y + 10));
            clock.disconnect (paint);
            stdout.printf ("Click: %.1f -> %.1f, maximum visible drift %.1f\n", before, adj.value, drift);
            stdout.flush ();
            assert (drift <= 2);
            yield conversation_input (scroll, window, "wheel-up", 180, 60);
            stdout.printf ("Wheel up: %.1f -> %.1f\n", before, adj.value);
            stdout.flush ();
            assert (search_message_top (view, row.message_id, scroll) > top + 10);
        }
        for (int i = 0; i < 12; i++) {
            var row = conversation_row_at (scroll, 200);
            double top = search_message_top (view, row.message_id, scroll);
            yield conversation_input (scroll, window, "wheel-down", 180, 60);
            assert (search_message_top (view, row.message_id, scroll) < top - 10);
        }
        view.focus_entry ();
        var rapid_row = conversation_row_at (scroll, 60);
        var rapid_label = conversation_text (rapid_row);
        Graphene.Point rapid_origin;
        assert (rapid_label.compute_point (scroll, Graphene.Point (), out rapid_origin));
        double rapid_top = search_message_top (view, rapid_row.message_id, scroll);
        yield conversation_input (scroll, window, "click-wheel-up", rapid_origin.x + 10,
            float.max (10, rapid_origin.y + 10));
        assert (search_message_top (view, rapid_row.message_id, scroll) > rapid_top + 10);
        // Updating a message must not undo input arriving before layout.
        var replacement = find_message (store, 1973).dup ();
        view.replace_message (1973, replacement);
        adj.value -= 100;
        double edited_position = adj.value;
        yield nap (400);
        stdout.printf ("Edit and scroll: %.1f -> %.1f\n", edited_position, adj.value);
        stdout.flush ();
        assert (Math.fabs (adj.value - edited_position) <= 2);

        // Loading older history must preserve the message currently being
        // read, including wheel input while the RPC request is pending.
        yield app.rpc.call ("test_hold", Params.begin ().build ());
        adj.value = 40;
        yield nap (300);
        uint count = store.get_n_items ();
        yield conversation_input (scroll, window, "wheel-down", 180, 60);
        var anchor = conversation_row_at (scroll, 200);
        int anchor_id = anchor.message_id;
        double anchor_top = search_message_top (view, anchor_id, scroll);
        yield app.rpc.call ("test_release", Params.begin ().build ());
        yield nap (500);
        assert (store.get_n_items () > count);
        stdout.printf ("History prepend: message %d, %.1f -> %.1f\n", anchor_id,
            anchor_top, search_message_top (view, anchor_id, scroll));
        stdout.flush ();
        assert (Math.fabs (search_message_top (view, anchor_id, scroll) - anchor_top) <= 2);

        // A full refresh must capture the reading position after the fetch,
        // not the position from before the user's intervening wheel input.
        yield app.rpc.call ("test_hold", Params.begin ().build ());
        bool refreshed = false;
        view.reload_messages.begin (() => { refreshed = true; });
        yield nap (300);
        yield conversation_input (scroll, window, "wheel-down", 180, 60);
        anchor = conversation_row_at (scroll, 200);
        anchor_id = anchor.message_id;
        anchor_top = search_message_top (view, anchor_id, scroll);
        yield app.rpc.call ("test_release", Params.begin ().build ());
        yield nap (500);
        assert (refreshed);
        assert (Math.fabs (search_message_top (view, anchor_id, scroll) - anchor_top) <= 2);

        // A cancelled distant jump must not replace the viewport when its
        // delayed response arrives.
        yield app.rpc.call ("test_hold", Params.begin ().build ());
        view.scroll_to_message (1000);
        yield nap (300);
        yield conversation_input (scroll, window, "wheel-down", 180, 60);
        anchor = conversation_row_at (scroll, 200);
        anchor_id = anchor.message_id;
        anchor_top = search_message_top (view, anchor_id, scroll);
        count = store.get_n_items ();
        yield app.rpc.call ("test_release", Params.begin ().build ());
        yield nap (500);
        assert (store.get_n_items () == count);
        assert (Math.fabs (search_message_top (view, anchor_id, scroll) - anchor_top) <= 2);

        view.scroll_to_bottom ();
        yield nap (700);
        assert (adj.upper - adj.page_size - adj.value <= 1);
        // One wheel notch from the bottom must release bottom following,
        // even when it leaves less than the old 80px snap threshold.
        yield conversation_input (scroll, window, "wheel-up", 180, 60);
        double gap = adj.upper - adj.page_size - adj.value;
        assert (gap > 10);
        view.replace_message (2009, find_message (store, 2009).dup ());
        yield nap (400);
        stdout.printf ("Bottom gap after edit: %.1f -> %.1f\n", gap, adj.upper - adj.page_size - adj.value);
        stdout.flush ();
        assert (Math.fabs (adj.upper - adj.page_size - adj.value - gap) <= 2);
        app.rpc.stop ();
        window.destroy ();
        stdout.printf ("Conversation scrolling: clicks, wheel, edits, history and cancelled jumps: PASS\n");
    } catch (Error e) { error ("Conversation scroll: %s", e.message); }
}

public int run_conversation_scroll_ui_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = true;
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register test app: %s", e.message); }
    var window = new Dc.Window (app);
    var style = Environment.get_variable ("PARLA_SCROLL_STYLE");
    if (style == "irc") window.settings.save_message_style (MessageStyle.IRC);
    else if (style == "workspace") window.settings.save_message_style (MessageStyle.WORKSPACE);
    window.set_default_size (1000, 720);
    window.present ();
    var loop = new MainLoop ();
    check_conversation_scroll.begin (app, window, () => loop.quit ());
    loop.run ();
    return 0;
}
