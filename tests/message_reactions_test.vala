/* Run with an isolated fake core and a display:
 * python3 tests/message_retry_ui_test.py builddir/core-compat-test --reactions-ui
 */
using Dc;

private async void reaction_click (Gtk.Button button) {
    if (Environment.get_variable ("PARLA_REACTIONS_POINTER") == null) {
        button.clicked ();
        return;
    }
    var native = button.get_native ();
    var surface = native.get_surface ();
    Graphene.Point point;
    assert (button.compute_point ((Gtk.Widget) native,
        Graphene.Point () { x = button.get_width () / 2, y = button.get_height () / 2 }, out point));
    double x, y;
    native.get_surface_transform (out x, out y);
    stdout.printf ("CLICK %d %d %d %d\n", surface.get_width (), surface.get_height (),
        (int) (point.x + x), (int) (point.y + y));
    stdout.flush ();
    yield nap (350);
}

private async void check_reactions_ui (Dc.Application app, Dc.Window window) {
    try {
        for (int i = 0; i < 100 && app.rpc.account_id == 0; i++) yield nap (50);
        var rpc = app.rpc;
        assert (rpc.account_id == 1);
        yield nap (100);
        yield rpc.call ("test_chats", Params.begin ().build ());
        yield window.open_chat_from_notification (1, 10);
        yield nap (100);
        var view = window.current_view ();
        assert (view != null);
        var list = (Gtk.ListView) search_widget (view, typeof (Gtk.ListView), "conversation-messages");
        var store = (GLib.ListStore) ((Gtk.NoSelection) list.model).model;
        var settings = new SettingsManager ();
        var pinned = new PinnedMessagesManager (store, settings);
        var compose = new ComposeBar ();
        var actions = new MessageActions (window, rpc, store, pinned, compose, settings);
        // Reactions must refresh even when full-message metadata cannot load.
        yield rpc.call ("test_fail", Params.begin ().add_string ("get_message").build ());

        foreach (var style in new MessageStyle[] { MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
            MessageRow.style = style;
            var msg = yield retry_fixture (rpc, 100, 26);
            store.remove_all ();
            store.append (msg);
            yield nap (100);
            actions.show_context_menu (100, true, 50, 50, list);
            yield nap (100);
            var popover = search_widget (list, typeof (Gtk.Popover));
            assert (popover != null);
            var button = retry_widget (popover, "👍") as Gtk.Button;
            assert (button != null);
            yield reaction_click (button);
            for (int i = 0; i < 100 && find_message (store, 100).my_reactions == null; i++) yield nap (10);
            assert (find_message (store, 100).my_reactions == "👍");
            yield nap (100);
            var row = search_widget (list, typeof (MessageRow));
            var badge = retry_widget (row, "👍") as Gtk.Button;
            assert (badge != null && badge.has_css_class ("reaction-badge") && badge.get_mapped ());

            actions.show_context_menu (100, true, 50, 50, list);
            yield nap (100);
            popover = search_widget (list, typeof (Gtk.Popover));
            button = retry_widget (popover, "👍") as Gtk.Button;
            assert (button.has_css_class ("suggested-action"));
            assert (button.tooltip_text == "Remove reaction");
            assert (retry_widget (popover, "Remove reaction") != null);
            yield reaction_click (button);
            for (int i = 0; i < 100 && find_message (store, 100).my_reactions != null; i++) yield nap (10);
            assert (find_message (store, 100).reactions == null);
            yield nap (100);
            row = search_widget (list, typeof (MessageRow));
            assert (retry_widget (row, "👍") == null);
        }
        assert ((yield retry_call_count (rpc, "get_message")) == 0);

        // An emoji from the full picker is removable without finding it again.
        yield actions.send_reaction (100, "🦊");
        assert (find_message (store, 100).my_reactions == "🦊");
        actions.show_reaction_menu (100, list, 50, 50);
        yield nap (100);
        var popover = search_widget (list, typeof (Gtk.Popover));
        var remove = retry_widget (popover, "Remove reaction") as Gtk.Button;
        assert (remove != null);
        yield reaction_click (remove);
        for (int i = 0; i < 100 && find_message (store, 100).my_reactions != null; i++) yield nap (10);
        assert (find_message (store, 100).reactions == null);
        actions.show_reaction_menu (100, list, 50, 50);
        yield nap (100);
        popover = search_widget (list, typeof (Gtk.Popover));
        assert (retry_widget (popover, "Remove reaction") == null);
        ((Gtk.Popover) popover).popdown ();
        yield nap (100);

        // Switching chats while the request is pending still updates its source.
        yield rpc.call ("test_hold", Params.begin ().add_string ("send_reaction").build ());
        bool finished = false;
        uint before = yield retry_call_count (rpc, "send_reaction");
        actions.send_reaction.begin (100, "❤️", (o, res) => {
            actions.send_reaction.end (res);
            finished = true;
        });
        for (int i = 0; i < 100 && (yield retry_call_count (rpc, "send_reaction")) == before; i++) yield nap (10);
        assert (!finished);
        yield window.open_chat_from_notification (1, 11);
        assert (window.current_view ().chat_id == 11);
        yield rpc.call ("test_release", Params.begin ().build ());
        for (int i = 0; i < 100 && !finished; i++) yield nap (10);
        assert (finished && find_message (store, 100).my_reactions == "❤️");

        // A failed send leaves the confirmed reaction in place.
        yield rpc.call ("test_fail", Params.begin ().add_string ("send_reaction").build ());
        yield actions.send_reaction (100, "");
        assert (find_message (store, 100).my_reactions == "❤️");
        // The subsequent fetch stays on the original profile after a switch.
        yield rpc.call ("test_hold", Params.begin ().add_string ("send_reaction").build ());
        finished = false;
        before = yield retry_call_count (rpc, "send_reaction");
        actions.send_reaction.begin (100, "", (o, res) => {
            actions.send_reaction.end (res);
            finished = true;
        });
        for (int i = 0; i < 100 && (yield retry_call_count (rpc, "send_reaction")) == before; i++) yield nap (10);
        rpc.account_id = 2;
        yield rpc.call ("test_release", Params.begin ().build ());
        for (int i = 0; i < 100 && !finished; i++) yield nap (10);
        assert (finished && find_message (store, 100).my_reactions == "❤️");
        var calls = (yield rpc.call ("test_calls", Params.begin ().build ())).get_array ();
        for (uint i = 0; i < calls.get_length (); i++) {
            var call = calls.get_object_element (i);
            if (call.get_string_member ("method") == "send_reaction"
                    || call.get_string_member ("method") == "get_message_reactions")
                assert (call.get_array_member ("params").get_int_element (0) == 1);
        }
        rpc.stop ();
        window.destroy ();
        stdout.printf ("Reaction add/toggle/remove, badges in all styles, metadata failure and chat/profile switches: PASS\n");
    } catch (Error e) { error ("Reactions UI: %s", e.message); }
}

public int run_reactions_ui_test () {
    Adw.init ();
    var app = new Dc.Application ();
    app.flags |= ApplicationFlags.NON_UNIQUE;
    try { app.register (null); }
    catch (Error e) { error ("Register reactions test: %s", e.message); }
    var window = new Dc.Window (app);
    window.present ();
    var loop = new MainLoop ();
    check_reactions_ui.begin (app, window, () => { loop.quit (); });
    loop.run ();
    return 0;
}
