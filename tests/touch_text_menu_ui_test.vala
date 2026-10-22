using Dc;

// Run core-compat-test --touch-text-menu-ui on a GTK display. No system
// clipboard contents are changed: intercept the native paste signals.
private async void check_touch_text_menu (Gtk.Window window, Gtk.Box box) {
    var entry = new Gtk.Entry ();
    var search = new Gtk.SearchEntry ();
    var password = new Gtk.PasswordEntry ();
    var row = new Adw.EntryRow ();
    var view = new Gtk.TextView ();
    foreach (var widget in new Gtk.Widget[] { entry, search, password, view })
        box.append (widget);
    var rows = new Gtk.ListBox ();
    rows.append (row);
    box.append (rows);
    TouchTextMenu.install (window);
    window.present ();
    yield nap (150);

    foreach (var widget in new Gtk.Widget[] { entry, search, password, row, view }) {
        Gtk.Widget editor;
        if (widget is Gtk.TextView) {
            editor = widget;
            view.buffer.text = "aé日z";
            Gtk.TextIter start, end;
            view.buffer.get_iter_at_offset (out start, 1);
            view.buffer.get_iter_at_offset (out end, 3);
            view.buffer.select_range (start, end);
        } else {
            var editable = (Gtk.Editable) widget;
            editable.text = "aé日z";
            editable.select_region (1, 3);
            var inner = editable.get_delegate ();
            while (inner != null && !(inner is Gtk.Text))
                inner = inner.get_delegate ();
            editor = (Gtk.Widget) inner;
        }
        assert (editor != null);
        assert (TouchTextMenu.find_target (editor) == editor);
        int pastes = 0;
        // Count the signal without reading or modifying the user's clipboard.
        ulong handler;
        if (editor is Gtk.Text)
            handler = ((Gtk.Text) editor).paste_clipboard.connect (() => {
                pastes++;
                Signal.stop_emission_by_name (editor, "paste-clipboard");
            });
        else
            handler = ((Gtk.TextView) editor).paste_clipboard.connect (() => {
                pastes++;
                Signal.stop_emission_by_name (editor, "paste-clipboard");
            });

        editor.grab_focus ();
        editor.action_set_enabled ("clipboard.paste", false);
        var menu = TouchTextMenu.show (editor);
        var contents = (Gtk.Box) menu.child;
        var cut = (Gtk.Button) contents.get_first_child ();
        var copy = (Gtk.Button) cut.get_next_sibling ();
        var paste = (Gtk.Button) copy.get_next_sibling ();
        bool secret = widget == password;
        assert (cut.sensitive == !secret);
        assert (copy.sensitive == !secret);
        assert (paste.sensitive);
        assert (TouchTextMenu.find_target (paste) == null);
        paste.clicked ();
        assert (pastes == 1);
        yield nap (250);
        assert (menu.parent == null);
        SignalHandler.disconnect (editor, handler);
    }

    // A long press on non-text content must remain available to other menus.
    assert (TouchTextMenu.find_target (box) == null);
    var text = (Gtk.Text) entry.get_delegate ();
    text.editable = false;
    var menu = TouchTextMenu.show (text);
    var paste = menu.child.get_first_child ().get_next_sibling ().get_next_sibling ();
    assert (!paste.sensitive);
    menu.popdown ();
    yield nap (250);
    window.destroy ();
}

public int run_touch_text_menu_ui_test () {
    Adw.init ();
    Gtk.Settings.get_default ().gtk_enable_animations = false;
    var window = new Gtk.Window ();
    window.title = "Parla touch text menu test";
    var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
    window.child = box;
    var loop = new MainLoop ();
    check_touch_text_menu.begin (window, box, () => loop.quit ());
    loop.run ();
    stdout.printf ("Touch text menus passed for entry, search, password, entry row and composer.\n");
    return 0;
}
