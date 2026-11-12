using Dc;

private Gtk.ListBoxRow sidebar_row (Gtk.ListBox list, int id) {
    for (var c = list.get_first_child (); c != null; c = c.get_next_sibling ()) {
        var row = c as Gtk.ListBoxRow;
        if (row != null && row.child is ChatRow && ((ChatRow) row.child).chat_id == id)
            return row;
    }
    assert_not_reached ();
}

private double sidebar_top (Gtk.Widget row, Gtk.Widget scroll) {
    Graphene.Point point;
    assert (row.compute_point (scroll, Graphene.Point (), out point));
    return point.y;
}

private async void sidebar_key (uint key, uint modifiers = 0) {
    stdout.printf ("KEY %u %u\n", key, modifiers);
    stdout.flush ();
    yield nap (250);
}

private async Gtk.Popover sidebar_menu (Gtk.ListBox list, Gtk.ScrolledWindow scroll,
                                        Dc.Window window, int id) {
    var row = sidebar_row (list, id);
    yield conversation_input (scroll, window, "right-click", 25,
        (float) sidebar_top (row, scroll) + row.get_height () / 2);
    var menu = search_widget (list, typeof (Gtk.Popover)) as Gtk.Popover;
    assert (menu != null && menu.visible);
    return menu;
}

private void sidebar_position (Gtk.Widget row, Gtk.ScrolledWindow scroll,
                               double top, string action) {
    double after = sidebar_top (row, scroll);
    stdout.printf ("%s: %.1f -> %.1f (scroll %.1f)\n", action, top, after, scroll.vadjustment.value);
    stdout.flush ();
    assert (Math.fabs (after - top) <= 2);
}

private async void check_sidebar_scroll (Dc.Application app, Dc.Window window) {
    try {
        for (int i = 0; i < 200 && window.chat_store.get_n_items () < 80; i++) yield nap (25);
        assert (window.chat_store.get_n_items () == 80);
        yield nap (400);
        var chat = (ChatRow) search_widget (window, typeof (ChatRow));
        var list = (Gtk.ListBox) chat.get_parent ().get_parent ();
        var scroll = (Gtk.ScrolledWindow) list.get_ancestor (typeof (Gtk.ScrolledWindow));
        var search = (Gtk.SearchEntry) search_widget (window, typeof (Gtk.SearchEntry), "Search chats or messages…");
        // An offscreen keyboard cursor is common after wheel scrolling.
        sidebar_row (list, 10).grab_focus ();
        scroll.vadjustment.value = 1800;
        yield nap (200);
        assert (scroll.vadjustment.value > 1000);
        var anchor = list.get_row_at_y ((int) scroll.vadjustment.value + 1);
        int anchor_id = ((ChatRow) anchor.child).chat_id;
        int target_id = anchor_id + 2;
        double top = sidebar_top (anchor, scroll);
        double drift = 0;
        ulong paint = scroll.get_frame_clock ().after_paint.connect (() => {
            drift = double.max (drift, Math.fabs (sidebar_top (anchor, scroll) - top));
        });
        yield sidebar_menu (list, scroll, window, target_id);
        yield sidebar_key (Gdk.Key.Escape);
        scroll.get_frame_clock ().disconnect (paint);
        sidebar_position (anchor, scroll, top, "Right click / Escape");
        assert (drift <= 2);
        assert (sidebar_row (list, 10).has_focus);

        yield sidebar_menu (list, scroll, window, target_id);
        yield conversation_input (window, window, "click", 900, 650);
        sidebar_position (anchor, scroll, top, "Dismiss menu by clicking outside");
        assert (search_widget (list, typeof (Gtk.Popover)) == null);

        var menu = yield sidebar_menu (list, scroll, window, target_id);
        ((Gtk.Button) search_widget (menu, typeof (Gtk.Button), "Delete Chat…")).clicked ();
        yield nap (300);
        var dialog = window.visible_dialog as Adw.AlertDialog;
        assert (dialog != null);
        dialog.close ();
        yield nap (300);
        sidebar_position (anchor, scroll, top, "Cancel dialog with offscreen cursor");

        // The same menu from a visible keyboard row must restore that row.
        var target = sidebar_row (list, target_id);
        target.grab_focus ();
        yield nap (200);
        top = sidebar_top (anchor, scroll);
        yield sidebar_key (Gdk.Key.F10, (uint) Gdk.ModifierType.SHIFT_MASK);
        assert (search_widget (list, typeof (Gtk.Popover)) != null);
        yield sidebar_key (Gdk.Key.Escape);
        sidebar_position (anchor, scroll, top, "Keyboard menu / Escape");
        assert (target.has_focus);

        menu = yield sidebar_menu (list, scroll, window, target_id);
        ((Gtk.Button) search_widget (menu, typeof (Gtk.Button), "Delete Chat…")).clicked ();
        yield nap (300);
        dialog = window.visible_dialog as Adw.AlertDialog;
        assert (dialog != null);
        dialog.response ("cancel");
        dialog.close ();
        yield nap (300);
        sidebar_position (anchor, scroll, top, "Cancel deletion");

        menu = yield sidebar_menu (list, scroll, window, target_id);
        ((Gtk.Button) search_widget (menu, typeof (Gtk.Button), "Delete Chat…")).clicked ();
        yield nap (300);
        dialog = window.visible_dialog as Adw.AlertDialog;
        assert (dialog != null);
        dialog.response ("delete");
        dialog.close ();
        yield nap (500);
        sidebar_position (anchor, scroll, top, "Delete focused row");
        assert (window.chat_store.get_n_items () == 79);

        // Pinning the top visible row must leave its neighbours in place.
        anchor = sidebar_row (list, anchor_id + 1);
        top = sidebar_top (anchor, scroll);
        menu = yield sidebar_menu (list, scroll, window, anchor_id);
        ((Gtk.Button) search_widget (menu, typeof (Gtk.Button), "Pin")).clicked ();
        yield nap (500);
        sidebar_position (anchor, scroll, top, "Pin top visible row");

        menu = yield sidebar_menu (list, scroll, window, anchor_id + 3);
        ((Gtk.Button) search_widget (menu, typeof (Gtk.Button), "Archive")).clicked ();
        yield nap (500);
        sidebar_position (anchor, scroll, top, "Archive row");

        search.grab_focus ();
        yield app.rpc.call ("test_prepend", Params.begin ().build ());
        yield window.load_chats ();
        yield nap (300);
        sidebar_position (anchor, scroll, top, "Incoming chat above viewport");
        yield app.rpc.delete_chat (10);
        yield window.load_chats ();
        yield nap (300);
        sidebar_position (anchor, scroll, top, "Delete above viewport");

        // A row refresh with no membership change preserves position too.
        yield app.rpc.call ("test_refresh", Params.begin ().build ());
        yield window.load_chats ();
        yield nap (300);
        sidebar_position (anchor, scroll, top, "Preview and unread refresh");
        yield window.load_chats ();
        yield nap (100);
        sidebar_position (anchor, scroll, top, "No-op refresh");

        // Capture after RPC completion, then honour input before allocation.
        yield app.rpc.call ("test_move", Params.begin ().add_int (88).build ());
        yield window.load_chats ();
        scroll.vadjustment.value -= 100;
        yield nap (300);
        top += 100;
        sidebar_position (anchor, scroll, top, "Reorder and immediate scroll");

        yield window.open_chat_from_notification (1, anchor_id + 4);
        yield nap (400);
        assert (window.current_view () != null);
        sidebar_position (anchor, scroll, top, "Open chat");
        menu = yield sidebar_menu (list, scroll, window, anchor_id + 4);
        ((Gtk.Button) search_widget (menu, typeof (Gtk.Button), "Mark as Unread")).clicked ();
        yield nap (500);
        sidebar_position (anchor, scroll, top, "Mark active chat unread");
        assert (window.current_view () == null);

        yield window.open_chat_from_notification (1, anchor_id + 5);
        yield nap (400);
        menu = yield sidebar_menu (list, scroll, window, anchor_id + 5);
        ((Gtk.Button) search_widget (menu, typeof (Gtk.Button), "Delete Chat…")).clicked ();
        yield nap (200);
        dialog = window.visible_dialog as Adw.AlertDialog;
        assert (dialog != null);
        dialog.response ("delete");
        dialog.close ();
        yield nap (500);
        sidebar_position (anchor, scroll, top, "Delete active chat");
        assert (window.current_view () == null);

        // Normal keyboard navigation must still reveal offscreen rows.
        sidebar_row (list, 89).grab_focus ();
        yield nap (300);
        double bottom = sidebar_top (sidebar_row (list, 89), scroll);
        assert (bottom >= 0 && bottom < scroll.get_height ());
        yield sidebar_key (Gdk.Key.Home, (uint) Gdk.ModifierType.CONTROL_MASK);
        assert (scroll.vadjustment.value < 10);
        yield sidebar_key (Gdk.Key.End);
        assert (sidebar_row (list, 89).has_focus);
        assert (scroll.vadjustment.value > 1000);
        yield app.rpc.delete_chat (89);
        yield window.load_chats ();
        yield nap (300);
        assert (scroll.vadjustment.value > 1000);
        assert (scroll.vadjustment.value <= scroll.vadjustment.upper - scroll.vadjustment.page_size);
        app.rpc.stop ();
        window.destroy ();
    } catch (Error e) {
        error ("Sidebar scroll: %s", e.message);
    }
}

public int run_sidebar_scroll_ui_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var settings = new SettingsManager ();
    settings.save_sidebar_mode (Environment.get_variable ("PARLA_TEST_SIDEBAR_MODE") == "compact"
        ? SidebarMode.COMPACT : SidebarMode.FULL);
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register sidebar test: %s", e.message); }
    var window = new Dc.Window (app);
    window.set_default_size (1000, 700);
    window.present ();
    var loop = new MainLoop ();
    check_sidebar_scroll.begin (app, window, () => { loop.quit (); });
    loop.run ();
    stdout.printf ("Sidebar scrolling passed.\n");
    return 0;
}
