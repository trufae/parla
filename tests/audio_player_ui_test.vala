using Dc;

private void audio_assert_inside (Gtk.Widget widget, Gtk.Widget parent) {
    Graphene.Rect bounds;
    assert (widget.get_mapped ());
    assert (widget.compute_bounds (parent, out bounds));
    assert (bounds.origin.x >= 0);
    assert (bounds.origin.x + bounds.size.width <= parent.get_width ());
    assert (bounds.origin.y + bounds.size.height <= parent.get_height ());
}

private void audio_screenshot (Gtk.Window window, string name) {
    var directory = Environment.get_variable ("PARLA_TEST_SCREENSHOTS");
    if (directory == null) return;
    var paintable = new Gtk.WidgetPaintable (window);
    var snapshot = new Gtk.Snapshot ();
    paintable.snapshot (snapshot, window.get_width (), window.get_height ());
    var node = snapshot.free_to_node ();
    assert (node != null);
    var texture = window.get_renderer ().render_texture (node, null);
    assert (texture.save_to_png (Path.build_filename (directory, name)));
}

private async void check_audio_player_ui (Dc.Application app, Dc.Window window) {
    for (int i = 0; i < 100 && app.rpc.account_id == 0; i++) yield nap (50);
    yield window.open_chat_from_notification (1, 10);
    yield nap (500);
    var view = window.current_view ();
    var bar = (ConversationMediaBar) search_widget (view, typeof (ConversationMediaBar));
    var inline_player = search_widget (view, typeof (AudioPlayer));
    assert (inline_player != null);
    var playback = AudioPlayback.shared ();
    ((Gtk.Button) search_widget (inline_player, typeof (Gtk.Button), "Play")).clicked ();
    yield nap (1500);
    assert (bar.message_id == 1001);
    assert (playback.playing);
    assert (playback.duration_us > 0);
    var close = (Gtk.Button) search_widget (bar, typeof (Gtk.Button), "Close player");
    var options = (Gtk.MenuButton) search_widget (bar, typeof (Gtk.MenuButton));
    var progress = (Gtk.Scale) search_widget (bar, typeof (Gtk.Scale));
    var compose = search_widget (view, typeof (ComposeBar));
    foreach (int width in new int[] { 360, 390, 920 }) {
        window.set_default_size (width, 720);
        yield nap (400);
        stdout.printf ("Requested width: %dpx; allocated width: %dpx\n", width, window.get_width ());
        stdout.flush ();
        audio_screenshot (window, "audio-player-%d.png".printf (width));
        // GTK documents get_default_size as the size to compare/restore;
        // widget allocations and native surfaces include different margins.
        int actual_width;
        window.get_default_size (out actual_width, null);
        assert (actual_width == width);
        assert (window.get_width () <= width);
        audio_assert_inside (bar, window);
        audio_assert_inside (close, window);
        audio_assert_inside (options, window);
        audio_assert_inside (progress, window);
        audio_assert_inside (compose, window);
    }
    // The bar itself also fits the 270px viewport from #101, even though
    // the full application enforces a 360px minimum for preference dialogs.
    int minimum, natural;
    bar.measure (Gtk.Orientation.HORIZONTAL, -1, out minimum, out natural, null, null);
    stdout.printf ("Active player minimum width: %dpx\n", minimum);
    assert (minimum <= 270);
    window.set_default_size (360, 720);
    yield nap (300);
    options.popup ();
    yield nap (200);
    assert (options.popover.get_mapped ());
    var previous = (Gtk.Button) search_widget (bar, typeof (Gtk.Button), "Previous voice message");
    var next = (Gtk.Button) search_widget (bar, typeof (Gtk.Button), "Next voice message");
    assert (!previous.sensitive && next.sensitive);
    next.clicked ();
    yield nap (500);
    assert (bar.message_id == 1002);
    assert (previous.sensitive && !next.sensitive);
    previous.clicked ();
    yield nap (500);
    assert (bar.message_id == 1001);
    var speed = (Gtk.DropDown) search_widget (bar, typeof (Gtk.DropDown));
    assert (speed.sensitive);
    speed.selected = AudioPlayback.index_for_rate (1.5);
    assert (playback.playback_rate == 1.5);
    options.popdown ();
    yield nap (300);
    var pause = (Gtk.Button) search_widget (bar, typeof (Gtk.Button), "Pause");
    pause.clicked ();
    yield nap (200);
    assert (!playback.playing);
    assert (pause.tooltip_text == "Play");
    assert (progress.sensitive);
    progress.change_value (Gtk.ScrollType.JUMP, 0.5);
    yield nap (200);
    assert (playback.position_us >= playback.duration_us * 0.45);
    audio_screenshot (window, "audio-player-paused.png");
    pause.clicked ();
    yield nap (200);
    assert (playback.playing);
    close.clicked ();
    yield nap (200);
    assert (playback.current_item == null && bar.message_id == 0);
    bar.measure (Gtk.Orientation.HORIZONTAL, -1, out minimum, out natural, null, null);
    assert (minimum == 0);
    audio_assert_inside (compose, window);
    audio_screenshot (window, "audio-player-closed.png");
    app.rpc.stop ();
    window.destroy ();
}

public int run_audio_player_ui_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register test app: %s", e.message); }
    var window = new Dc.Window (app);
    window.set_default_size (360, 720);
    window.present ();
    var loop = new MainLoop ();
    check_audio_player_ui.begin (app, window, () => { loop.quit (); });
    loop.run ();
    return 0;
}
