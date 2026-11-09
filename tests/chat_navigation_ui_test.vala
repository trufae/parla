using Dc;

private async void check_chat_navigation (Adw.Window window, ChatSplitView split,
                                        Gtk.Widget sidebar, Gtk.Box content,
                                        Gtk.Entry draft) {
    for (int i = 0; i < 100 && !split.get_mapped (); i++) yield nap (20);
    assert (split.get_mapped ());
    assert (!split.collapsed && split.show_sidebar);
    split.desktop.min_sidebar_width = 48;
    split.desktop.max_sidebar_width = 48;
    split.desktop.sidebar_width_unit = Adw.LengthUnit.PX;
    split.show_sidebar = false;
    yield nap (50);
    assert (!split.show_sidebar);

    // Reparent the existing pages, preserving their content and focus.
    draft.text = "Unsent draft";
    draft.grab_focus ();
    split.collapsed = true;
    yield nap (50);
    var navigation = split.child as Adw.NavigationView;
    assert (navigation != null);
    assert (!navigation.pop_on_escape);
    assert (!split.show_sidebar);
    assert (navigation.visible_page.child == content);
    assert (navigation.navigation_stack.get_n_items () == 2);
    assert (window.get_focus ().is_ancestor (draft));

    // The native swipe target must span the whole page for touchscreen
    // drags AND touchpad scrolling, including away from the screen edge.
    foreach (bool drag in new bool[] { true, false }) {
        var area = navigation.get_swipe_area (Adw.NavigationDirection.BACK, drag);
        assert (area.x == 0 && area.y == 0);
        assert (area.width == navigation.get_width ());
        assert (area.height == navigation.get_height ());
        assert (area.width > 200 && area.height > 200);
    }

    int changes = 0;
    split.notify["show-sidebar"].connect (() => { changes++; });
    // A completed native back gesture pops the page, without going through
    // the app's sidebar button. Its result must still reach visibility users.
    assert (navigation.pop ());
    assert (split.show_sidebar && changes == 1);
    assert (navigation.visible_page.child == sidebar);
    assert (!navigation.pop ());
    assert (changes == 1);

    // Reopening the same chat must work after a gesture, without duplicates.
    split.show_sidebar = false;
    split.show_sidebar = false;
    assert (changes == 2 && navigation.navigation_stack.get_n_items () == 2);
    assert (draft.text == "Unsent draft");
    split.show_sidebar = true;
    assert (changes == 3 && navigation.visible_page.child == sidebar);

    // Desktop widths and hidden-sidebar controls survive a round trip.
    split.collapsed = false;
    assert (split.child == split.desktop && split.show_sidebar);
    assert (split.desktop.sidebar == sidebar && split.desktop.content == content);
    assert (split.desktop.min_sidebar_width == 48);
    assert (split.desktop.max_sidebar_width == 48);
    split.show_sidebar = false;
    assert (!split.show_sidebar && changes == 4);
    assert (draft.text == "Unsent draft");

    // Resizing while a navigation animation is in flight must not leave
    // duplicate parents, stale pages, or a lost draft.
    Gtk.Settings.get_default ().gtk_enable_animations = true;
    for (int i = 0; i < 3; i++) {
        split.collapsed = true;
        split.show_sidebar = true;
        split.show_sidebar = false;
        split.collapsed = false;
        assert (split.desktop.content == content);
        assert (draft.text == "Unsent draft");
        yield nap (50);
    }
    window.destroy ();
}

public int run_chat_navigation_ui_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var sidebar = new Gtk.Label ("Chats");
    var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
    var messages = new Gtk.ScrolledWindow ();
    messages.vexpand = true;
    messages.hscrollbar_policy = Gtk.PolicyType.NEVER;
    messages.child = new Gtk.Label ("Conversation");
    content.append (messages);
    var draft = new Gtk.Entry ();
    content.append (draft);
    var split = new ChatSplitView (sidebar, content);
    var window = new Adw.Window ();
    window.set_default_size (400, 500);
    window.content = split;
    window.present ();
    var loop = new MainLoop ();
    check_chat_navigation.begin (window, split, sidebar, content, draft,
                                () => { loop.quit (); });
    loop.run ();
    stdout.printf ("Chat navigation: full-width touch/touchpad area, back, reopen, drafts and resizing passed.\n");
    return 0;
}

/* Uses the offline account fixture from chat_lifetime_test.py --navigation. */
private async void check_chat_navigation_window (Dc.Application app, Dc.Window window) {
    for (int i = 0; i < 200 && window.chat_store.get_n_items () != 12; i++) yield nap (25);
    assert (window.chat_store.get_n_items () == 12);
    var split = (ChatSplitView) search_widget (window, typeof (ChatSplitView));
    assert (!split.collapsed && split.desktop.min_sidebar_width == 48);
    yield window.open_chat_from_notification (1, 10);
    yield nap (300);
    var view = window.current_view ();
    var composer = search_widget (view, typeof (ComposeBar));
    var draft = (Gtk.TextView) search_widget (composer, typeof (Gtk.TextView));
    draft.buffer.text = "Draft survives going back";

    window.set_default_size (390, 640);
    for (int i = 0; i < 100 && !split.collapsed; i++) yield nap (20);
    assert (split.collapsed && !split.show_sidebar);
    assert (window.settings.sidebar_mode == SidebarMode.COMPACT);
    var navigation = (Adw.NavigationView) split.child;
    assert (navigation.pop ());
    yield nap (100);
    assert (split.show_sidebar && !window.is_chat_visible (10));
    assert (!navigation.visible_page.child.has_css_class ("sidebar-compact"));
    var search = search_widget (navigation.visible_page, typeof (Gtk.SearchEntry));
    assert (search != null && search.visible);

    // Activate the current chat's actual list row after the native back action.
    var chat = (ChatRow) search_widget (navigation.visible_page, typeof (ChatRow));
    assert (chat != null && chat.chat_id == 10);
    var row = (Gtk.ListBoxRow) chat.get_parent ();
    ((Gtk.ListBox) row.get_parent ()).row_activated (row);
    yield nap (100);
    assert (!split.show_sidebar && window.current_chat_id == 10);
    assert (window.current_view () == view);
    assert (draft.buffer.text == "Draft survives going back");
    assert (view.compose_entry_has_focus ());

    window.set_default_size (920, 640);
    for (int i = 0; i < 100 && split.collapsed; i++) yield nap (20);
    assert (!split.collapsed && split.show_sidebar);
    assert (split.desktop.min_sidebar_width == 48);
    assert (split.desktop.sidebar.has_css_class ("sidebar-compact"));
    assert (window.settings.sidebar_mode == SidebarMode.COMPACT);
    assert (draft.buffer.text == "Draft survives going back");
    app.rpc.stop ();
    window.destroy ();
}

public int run_chat_navigation_window_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var settings = new SettingsManager ();
    settings.save_sidebar_mode (SidebarMode.COMPACT);
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register navigation test: %s", e.message); }
    var window = new Dc.Window (app);
    window.present ();
    var loop = new MainLoop ();
    check_chat_navigation_window.begin (app, window, () => { loop.quit (); });
    loop.run ();
    stdout.printf ("Chat window: breakpoint, back, row activation, draft/focus and compact preference passed.\n");
    return 0;
}
