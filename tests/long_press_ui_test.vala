using Dc;

private void check_context_menu_lifetime (SettingsManager settings) {
    bool released = false;
    var widget = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    var context_menu = new ContextMenuGestures (widget, settings);
    context_menu.weak_ref (() => { released = true; });
    context_menu = null;
    widget = null;
    // Controllers keep the helper alive only as long as their widget.
    assert (released);
}

/* Run under X11/Xvfb with xdotool installed. Exercise real pointer events,
   including child-button activation and GTK's own selectable-label gesture. */
private async void check_long_press_ui (Gtk.Window window, Gtk.Button button,
                                        SettingsManager settings) {
    int menus = 0;
    int clicks = 0;
    int child_menus = 0;
    int clicks_before_rejected_hold = 0;
    bool accept_menu = true;
    bool expect_hold = false;
    bool cancel_hold = false;
    var context_menu = new ContextMenuGestures (window, settings);
    context_menu.requested.connect ((x, y, long_press) => {
        assert (long_press == expect_hold);
        if (!accept_menu) return false;
        menus++;
        // Opening a real popover changes focus/event routing. The helper
        // must still suppress the button's release after a successful hold.
        Gtk.Box contents;
        var popover = popover_menu (window, x, y, out contents);
        contents.append (new Gtk.Label ("Context menu"));
        popover.popup ();
        Timeout.add (400, () => {
            popover.popdown ();
            return Source.REMOVE;
        });
        return true;
    });
    // Inspect the installed hold solely to disable it mid-sequence below.
    var controllers = window.observe_controllers ();
    Gtk.GestureLongPress? hold = null;
    for (uint i = 0; i < controllers.get_n_items (); i++) {
        hold = controllers.get_item (i) as Gtk.GestureLongPress;
        if (hold != null) break;
    }
    assert (hold != null);
    hold.begin.connect ((sequence) => {
        if (cancel_hold) {
            Timeout.add (50, () => {
                settings.long_press_context_menu = false;
                return Source.REMOVE;
            });
        }
    });
    var child_menu = new Gtk.GestureClick ();
    child_menu.button = Gdk.BUTTON_SECONDARY;
    child_menu.pressed.connect (() => { child_menus++; });
    button.add_controller (child_menu);
    button.clicked.connect (() => { clicks++; });
    var gtk_settings = Gtk.Settings.get_default ();
    gtk_settings.gtk_long_press_time = 100;

    // X11 can report the window as visible before GTK has painted its
    // children. Sending the first press then can miss the button on CI.
    var frame_clock = window.get_frame_clock ();
    bool painted = false;
    ulong paint_handler = frame_clock.after_paint.connect (() => { painted = true; });
    for (int i = 0; i < 200 && !painted; i++) yield nap (25);
    SignalHandler.disconnect (frame_clock, paint_handler);
    assert (painted);

    // xdotool coordinates below are local to this fixed-size fixture.
    string prefix = "xdotool search --onlyvisible --sync --name parla-long-press-fixture ";
    string[] actions = {
        "mousemove --window %1 100 50 mousedown 1 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 50 click 3",
        "mousemove --window %1 100 50 mousedown 1 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 50 click 1",
        "mousemove --window %1 100 50 mousedown 1 mousemove --window %1 180 50 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 150 mousedown 1 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 50 mousedown 1 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 150 click 3",
        "mousemove --window %1 100 50 click 3",
        "mousemove --window %1 100 50 mousedown 1 sleep 0.3 mouseup 1"
    };
    for (int i = 0; i < actions.length; i++) {
        expect_hold = i != 1 && i != 7 && i != 8;
        if (i == 2 || i == 9) settings.long_press_context_menu = true;
        // Disable during a press, before its timeout.
        cancel_hold = i == 6;
        if (i == 8) accept_menu = false;
        if (i == 9) clicks_before_rejected_hold = clicks;
        try {
            var process = new Subprocess.newv (
                {"sh", "-c", prefix + "sleep 0.2 " + actions[i] + " sleep 0.6"},
                SubprocessFlags.NONE);
            yield process.wait_check_async (null);
        } catch (Error e) { error ("Pointer fixture: %s", e.message); }
        if (i == 0) { assert (menus == 0); assert (clicks == 1); }
        if (i == 1) { assert (menus == 1); assert (child_menus == 0); }
        if (i == 2) { assert (menus == 2); assert (clicks == 1); }
        if (i == 3) { assert (menus == 2); assert (clicks == 2); }
        if (i == 4) assert (menus == 2);
        if (i == 5) assert (menus == 3);
        if (i == 6) assert (menus == 3);
        if (i == 7) assert (menus == 4);
        if (i == 8) { assert (menus == 4); assert (child_menus == 1); }
        if (i == 9) {
            assert (menus == 4);
            assert (clicks == clicks_before_rejected_hold + 1);
        }
    }
    settings.long_press_context_menu = false;
    assert (hold.propagation_phase == Gtk.PropagationPhase.NONE);
    window.destroy ();
}

public int run_long_press_ui_test () {
    Gtk.init ();
    var settings = new SettingsManager ();
    check_context_menu_lifetime (settings);
    var window = new Gtk.Window ();
    window.decorated = false;
    window.title = "parla-long-press-fixture";
    window.set_default_size (300, 200);
    var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    var button = new Gtk.Button.with_label ("Tap or hold");
    button.set_size_request (300, 100);
    var label = new Gtk.Label ("Selectable message text");
    label.selectable = true;
    label.set_size_request (300, 100);
    box.append (button);
    box.append (label);
    window.child = box;
    window.present ();
    var loop = new MainLoop ();
    check_long_press_ui.begin (window, button, settings,
        () => { loop.quit (); });
    loop.run ();
    return 0;
}
