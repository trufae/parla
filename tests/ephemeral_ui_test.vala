/* Run with an isolated fake core and a display:
 * python3 tests/message_retry_ui_test.py builddir/core-compat-test --ephemeral-ui
 */
using Dc;

private Gtk.Widget? ephemeral_widget (Gtk.Widget root, Type type) {
    if (root.get_type ().is_a (type)) return root;
    for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = ephemeral_widget (child, type);
        if (found != null) return found;
    }
    return null;
}

private Gtk.Button? ephemeral_header (Gtk.Widget root) {
    var button = root as Gtk.Button;
    if (button != null && button.icon_name == "parla-timer-symbolic") return button;
    for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = ephemeral_header (child);
        if (found != null) return found;
    }
    return null;
}

private string selected_timer (Gtk.DropDown combo) {
    return ((Gtk.StringObject) combo.selected_item).string;
}

private async void timer_event (RpcClient rpc, int acct, int chat, int64 duration) throws Error {
    var args = new Json.Array ();
    args.add_int_element (acct);
    args.add_int_element (chat);
    args.add_int_element (duration);
    var node = new Json.Node (Json.NodeType.ARRAY);
    node.set_array (args);
    yield rpc.call ("test_timer", node);
    yield nap (50);
}

private async void expiry_fixture (RpcClient rpc, string json) throws Error {
    var args = new Json.Array ();
    args.add_object_element (object_from_json (json));
    var node = new Json.Node (Json.NodeType.ARRAY);
    node.set_array (args);
    yield rpc.call ("test_info", node);
}

private async void check_ephemeral_ui (Dc.Application app, Dc.Window window) {
    try {
        for (int i = 0; i < 100 && app.rpc.account_id == 0; i++) yield nap (50);
        var rpc = app.rpc;
        assert (rpc.account_id == 1);
        yield nap (100);
        yield rpc.call ("test_chats", Params.begin ().build ());
        yield window.open_chat_from_notification (1, 10);
        yield nap (100);
        var header = ephemeral_header (window);
        assert (header != null && header.visible);
        assert (header.tooltip_text == "Disappearing messages: 90 seconds");

        var details = new ChatInfoDialog (window, rpc, 10);
        details.present (window);
        yield nap (100);
        var row = retry_widget (details.child, "Disappearing messages") as Adw.ActionRow;
        assert (row != null);
        var combo = ephemeral_widget (row, typeof (Gtk.DropDown)) as Gtk.DropDown;
        assert (selected_timer (combo) == "90 seconds");
        assert ((yield retry_call_count (rpc, "set_chat_ephemeral_timer")) == 0);

        // Events cross the actual event loop; other profiles/chats cannot change this view.
        yield timer_event (rpc, 2, 10, 60);
        yield timer_event (rpc, 1, 11, 60);
        assert (selected_timer (combo) == "90 seconds");
        yield timer_event (rpc, 1, 10, 7200);
        assert (selected_timer (combo) == "2 hours");
        assert (header.tooltip_text == "Disappearing messages: 2 hours");
        yield timer_event (rpc, 1, 10, 4294967295);
        assert (selected_timer (combo) == "4294967295 seconds");
        yield timer_event (rpc, 1, 10, 0);
        assert (selected_timer (combo) == "Off" && !header.visible);
        assert ((yield retry_call_count (rpc, "set_chat_ephemeral_timer")) == 0);

        // A failed save restores the confirmed value, instead of claiming success.
        yield rpc.call ("test_fail", Params.begin ().add_string ("set_chat_ephemeral_timer").build ());
        combo.selected = 1;
        yield nap (100);
        assert (selected_timer (combo) == "Off" && row.sensitive);
        var error_dialog = window.get_visible_dialog ();
        assert (error_dialog != null && error_dialog != details);
        error_dialog.close ();
        yield nap (100);

        combo.selected = 1;
        yield nap (100);
        assert (selected_timer (combo) == "1 minute");
        assert (header.visible && header.tooltip_text == "Disappearing messages: 1 minute");
        details.close ();
        yield nap (100);

        // A live event wins over an older snapshot loaded by a newly opened dialog.
        yield rpc.call ("test_hold", Params.begin ().add_string ("get_full_chat_by_id").build ());
        details = new ChatInfoDialog (window, rpc, 10);
        details.present (window);
        yield nap (50);
        yield timer_event (rpc, 1, 10, 120);
        yield rpc.call ("test_release", Params.begin ().build ());
        yield nap (100);
        row = retry_widget (details.child, "Disappearing messages") as Adw.ActionRow;
        combo = ephemeral_widget (row, typeof (Gtk.DropDown)) as Gtk.DropDown;
        assert (selected_timer (combo) == "2 minutes");

        // Even if the selected account changes, an existing dialog writes its own account.
        rpc.account_id = 2;
        combo.selected = 2;
        yield nap (100);
        var calls = (yield rpc.call ("test_calls", Params.begin ().build ())).get_array ();
        var last = calls.get_object_element (calls.get_length () - 1);
        assert (last.get_string_member ("method") == "set_chat_ephemeral_timer");
        assert (last.get_array_member ("params").get_int_element (0) == 1);
        rpc.account_id = 1;
        details.close ();
        yield nap (100);

        var settings = new SettingsManager ();
        var store = new GLib.ListStore (typeof (Message));
        var pinned = new PinnedMessagesManager (store, settings);
        var compose = new ComposeBar ();
        var actions = new MessageActions (window, rpc, store, pinned, compose, settings);
        var msg = yield retry_fixture (rpc, 100);
        yield expiry_fixture (rpc, """{"ephemeralTimer":{"kind":"enabled","duration":90},"ephemeralTimestamp":0}""");
        var message = new MessageDetailsDialog (window, rpc, actions, msg, null);
        message.present (window);
        yield nap (100);
        var expiry = retry_widget (message.child, "Expires") as Adw.ActionRow;
        assert (expiry.visible && expiry.subtitle == "Timer not started");
        row = retry_widget (message.child, "Disappearing messages") as Adw.ActionRow;
        assert (row.subtitle == "90 seconds");

        yield expiry_fixture (rpc, """{"ephemeralTimer":{"kind":"enabled","duration":90},"ephemeralTimestamp":4102444800}""");
        window.message_info_changed (2, 10);
        yield nap (50);
        assert (expiry.subtitle == "Timer not started");
        window.message_info_changed (1, 10);
        yield nap (100);
        var date = new DateTime.from_unix_local (4102444800);
        assert (expiry.subtitle == date.format ("%Y-%m-%d %H:%M:%S %Z"));

        // A stale metadata reply is discarded when a newer refresh is pending.
        yield rpc.call ("test_hold", Params.begin ().add_string ("get_message_info_object").build ());
        window.message_info_changed (1, 10);
        yield nap (50);
        yield expiry_fixture (rpc, """{"ephemeralTimer":{"kind":"disabled"},"ephemeralTimestamp":null}""");
        window.message_info_changed (1, 10);
        yield rpc.call ("test_release", Params.begin ().build ());
        yield nap (100);
        assert (!expiry.visible && !row.visible);

        // Closing during a request must not revive the dialog or change its widgets.
        yield rpc.call ("test_hold", Params.begin ().add_string ("get_message_info_object").build ());
        window.message_info_changed (1, 10);
        yield nap (50);
        message.close ();
        yield nap (100);
        yield rpc.call ("test_release", Params.begin ().build ());
        yield nap (100);
        assert (!expiry.visible);
        window.clear_chat_view ();
        assert (!header.visible);
        rpc.stop ();
        window.destroy ();
    } catch (Error e) { error ("Ephemeral UI: %s", e.message); }
}

public int run_ephemeral_ui_test () {
    Adw.init ();
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register ephemeral test: %s", e.message); }
    var window = new Dc.Window (app);
    window.present ();
    var loop = new MainLoop ();
    check_ephemeral_ui.begin (app, window, () => { loop.quit (); });
    loop.run ();
    return 0;
}
