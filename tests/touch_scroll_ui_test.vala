using Dc;

// Driven by touch_scroll_test.py through GTK's Broadway touch-event backend.
private Graphene.Point touch_label_point (Gtk.Label label, Gtk.Window window,
                                          int byte_index, bool boundary = false) {
    var rect = label.get_layout ().index_to_pos (byte_index);
    int x, y;
    label.get_layout_offsets (out x, out y);
    var point = Graphene.Point ();
    point.init (x + (float) (rect.x + rect.width) / Pango.SCALE -
                    (boundary ? 1 : (float) rect.width / Pango.SCALE / 2),
                y + (float) (rect.y + rect.height) / Pango.SCALE -
                    (boundary ? 1 : (float) rect.height / Pango.SCALE / 2));
    Graphene.Point result;
    assert (label.compute_point (window, point, out result));
    assert (result.x > 0 && result.x < window.get_width ());
    assert (result.y > 0 && result.y < window.get_height ());
    return result;
}

private async void touch_input (string kind, Graphene.Point point) {
    stdout.printf ("INPUT %s %d %d\n", kind, (int) point.x, (int) point.y);
    stdout.flush ();
    yield nap (1000);
}

private async void check_touch_scroll (Gtk.Window window) {
    foreach (var style in new MessageStyle[] {
            MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
        MessageRow.style = style;
        var msg = new Message ();
        msg.text = "https://example.com\n";
        for (int i = 0; i < 60; i++) msg.text += "abcdef ghijkl mnopqr\n";
        var row = new MessageRow (msg);
        var label = search_widget (row, typeof (Gtk.Label),
            Markdown.format (msg.text)) as Gtk.Label;
        assert (label != null && label.selectable);
        int links = 0;
        label.activate_link.connect (() => { links++; return true; });
        var settings = new SettingsManager ();
        settings.long_press_context_menu = true;
        int menus = 0;
        var context = new ContextMenuGestures (row, settings);
        context.requested.connect ((x, y, held) => {
            assert (held);
            menus++;
            return true;
        });
        var scroll = new Gtk.ScrolledWindow ();
        scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scroll.child = row;
        // ConversationView uses ListView, without GtkViewport's automatic
        // scrolling to a label's caret when the fixture clears selection.
        ((Gtk.Viewport) scroll.child).scroll_to_focus = false;
        window.child = scroll;
        yield nap (300);
        // A character boundary crossed before the scroll drag threshold
        // used to select text, including with GTK_A11Y=none (#120).
        int body_index = label.get_text ().index_of ("abcdef") + 30 * 21;
        foreach (bool holds in new bool[] { true, false }) {
            settings.long_press_context_menu = holds;
            label.select_region (0, 0);
            scroll.kinetic_scrolling = false;
            scroll.vadjustment.value = 400;
            scroll.kinetic_scrolling = true;
            yield nap (100);
            var point = touch_label_point (label, window, body_index, true);
            double before = scroll.vadjustment.value;
            yield touch_input ("touch-drag", point);
            int start, end;
            assert (!label.get_selection_bounds (out start, out end));
            stdout.printf ("Style %d, long press %s: scroll %.1f → %.1f\n",
                (int) style, holds.to_string (), before, scroll.vadjustment.value);
            stdout.flush ();
            assert (scroll.vadjustment.value < before - 20);
            assert (menus == 0 && links == 0);
        }

        scroll.kinetic_scrolling = false;
        scroll.vadjustment.value = 400;
        scroll.kinetic_scrolling = true;
        yield nap (100);
        var point = touch_label_point (label, window, body_index);
        yield touch_input ("mouse-drag", point);
        int start, end;
        assert (label.get_selection_bounds (out start, out end));
        label.grab_focus ();
        assert (label.activate_action ("selection.select-all", null));
        assert (label.get_selection_bounds (out start, out end));
        assert (start == 0 && end == label.get_text ().char_count ());
        label.select_region (0, 0);

        scroll.vadjustment.value = 0;
        yield nap (100);
        yield touch_input ("tap", touch_label_point (label, window, 5));
        assert (links == 1 && menus == 0);

        settings.long_press_context_menu = true;
        scroll.vadjustment.value = 400;
        yield nap (100);
        yield touch_input ("hold", touch_label_point (label, window, body_index));
        assert (menus == 1 && links == 1);
        assert (!label.get_selection_bounds (out start, out end));
    }
    window.destroy ();
    stdout.printf ("Touch scrolling, mouse/keyboard selection, link taps and long presses: PASS\n");
}

public int run_touch_scroll_ui_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_long_press_time = 250;
    var window = new Gtk.Window ();
    window.decorated = false;
    window.set_default_size (300, 400);
    window.present ();
    var loop = new MainLoop ();
    check_touch_scroll.begin (window, () => loop.quit ());
    loop.run ();
    return 0;
}
