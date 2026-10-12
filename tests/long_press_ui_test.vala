using Dc;

/* Run under X11/Xvfb with xdotool installed. Exercise real pointer events,
   including child-button activation and GTK's own selectable-label gesture. */
private async void check_long_press_ui (Gtk.Window window, Gtk.Button button,
                                        SettingsManager settings) {
    int menus = 0;
    int clicks = 0;
    bool cancel_hold = false;
    var hold = context_menu_long_press (window, settings);
    hold.pressed.connect ((x, y) => {
        hold.set_state (Gtk.EventSequenceState.CLAIMED);
        menus++;
    });
    hold.begin.connect ((sequence) => {
        if (cancel_hold) {
            Timeout.add (50, () => {
                settings.long_press_context_menu = false;
                return Source.REMOVE;
            });
        }
    });
    button.clicked.connect (() => { clicks++; });
    var gtk_settings = Gtk.Settings.get_default ();
    gtk_settings.gtk_long_press_time = 100;

    // xdotool coordinates below are local to this fixed-size fixture.
    string prefix = "xdotool search --onlyvisible --sync --name parla-long-press-fixture ";
    string[] actions = {
        "mousemove --window %1 100 50 mousedown 1 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 50 mousedown 1 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 50 click 1",
        "mousemove --window %1 100 50 mousedown 1 mousemove --window %1 180 50 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 150 mousedown 1 sleep 0.3 mouseup 1",
        "mousemove --window %1 100 50 mousedown 1 sleep 0.3 mouseup 1"
    };
    for (int i = 0; i < actions.length; i++) {
        if (i == 1) settings.long_press_context_menu = true;
        // Disable during the final press, before its timeout.
        cancel_hold = i == 5;
        try {
            var process = new Subprocess.newv (
                {"sh", "-c", prefix + "sleep 0.2 " + actions[i] + " sleep 0.1"},
                SubprocessFlags.NONE);
            yield process.wait_check_async (null);
        } catch (Error e) { error ("Pointer fixture: %s", e.message); }
        if (i == 0) { assert (menus == 0); assert (clicks == 1); }
        if (i == 1) { assert (menus == 1); assert (clicks == 1); }
        if (i == 2) { assert (menus == 1); assert (clicks == 2); }
        if (i == 3) assert (menus == 1);
        if (i == 4) assert (menus == 2);
        if (i == 5) assert (menus == 2);
    }
    settings.long_press_context_menu = false;
    assert (hold.propagation_phase == Gtk.PropagationPhase.NONE);
    window.destroy ();
}

public int run_long_press_ui_test () {
    Gtk.init ();
    var settings = new SettingsManager ();
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
