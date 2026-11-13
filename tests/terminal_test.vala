using Parla.Terminal;

private void renderer_test () {
    var renderer = new Renderer ();
    var frame = new Frame (80, 24);
    var row = new Row (80);
    row.text (0, "Hello 日本語", Style.BOLD);
    frame.set_row (4, row);
    string first = renderer.render (frame);
    assert (first.contains ("\033[2J"));
    assert (renderer.render (frame) == "");
    row = new Row (80);
    row.text (0, "Hello 日本語", Style.BOLD);
    frame.set_row (4, row);
    assert (renderer.render (frame) == "");
    row = new Row (80);
    row.text (0, "Hallo 日本語", Style.BOLD);
    frame.set_row (4, row);
    string change = renderer.render (frame);
    assert (!change.contains ("\033[2J"));
    assert (change.contains ("\033[5;2H"));
    assert (change.length < 40);
    frame.cursor_x = 3;
    assert (renderer.render (frame) == "\033[1;4H");
    renderer.invalidate ();
    assert (renderer.render (frame).contains ("\033[2J"));

    frame = new Frame (4, 1);
    row = new Row (4); row.text (0, "界x"); frame.set_row (0, row);
    renderer.render (frame);
    row = new Row (4); row.text (0, "axb"); frame.set_row (0, row);
    assert (renderer.render (frame).contains ("axb"));
    row = new Row (4); row.text (0, "界界"); row.text (1, "x");
    assert (row.plain_text () == " x界");
    row.text (1, "界");
    assert (row.plain_text () == " 界 ");
}

private void text_test () {
    var rows = new Text.markdown ("# Heading\n**bold** and *italic* `code`\n- item\n> quote\n[x](https://example.org)\n```\n**literal**\n```").wrap (60);
    assert (rows.get (0).plain_text ().strip () == "Heading");
    assert (rows.get (1).plain_text ().strip () == "bold and italic code");
    assert (rows.get (2).plain_text ().strip () == "• item");
    assert (rows.get (6).plain_text ().strip () == "**literal**");
    rows = new Text.plain ("A界e\u0301Z").wrap (3);
    assert (rows.length == 2);
    assert (rows.get (0).plain_text () == "A界");
    assert (rows.get (1).plain_text () == "e\u0301Z ");
    rows = new Text.plain ("a\033[2J\007\r" + ((unichar) 0x9b).to_string () + "b").wrap (20);
    assert (rows.get (0).plain_text ().strip () == "a[2Jb");
    rows = new Text.plain ("界").wrap (1);
    assert (rows.get (0).plain_text () == "?");
    var many = new Text.plain (string.nfill (16000, '\n') + "last");
    assert (many.line_count (1000) == 16001);
    rows = many.wrap (1000, 16000, 5);
    assert (rows.length == 1 && rows.get (0).plain_text ().strip () == "last");
}

private void input_test () {
    var input = new Input ();
    Key[] keys = {};
    string[] values = {};
    input.key.connect ((code, text) => { keys += code; values += text; });
    uint8[] utf8 = {0xc3}; input.feed (utf8);
    assert (keys.length == 0);
    utf8 = {0xa9}; input.feed (utf8);
    assert (values[0] == "é");
    input.feed ("\033".data);
    assert (input.waiting_escape);
    input.feed ("[5".data);
    input.feed ("~\033[1;3C\033\r".data);
    assert (keys[1] == Key.PAGE_UP && keys[2] == Key.NEXT_TAB && keys[3] == Key.NEWLINE);
    input.feed ("\033[200~one\r\ntwo\003\033[2".data);
    assert (keys.length == 4);
    input.feed ("01~\r".data);
    assert (keys.length == 6);
    assert (keys[4] == Key.TEXT && values[4] == "one\ntwo\003");
    assert (keys[5] == Key.ENTER);
    input.feed ("\033".data); input.flush_escape ();
    assert (keys[6] == Key.ESCAPE);
    input.feed ("\033[999~a".data);
    assert (values[7] == "a");
    var mouse = new GenericArray<MouseEvent> ();
    input.mouse.connect ((event) => mouse.add (event));
    input.feed ("\033[<0;12;".data);
    assert (mouse.length == 0);
    input.feed ("3M\033[<0;12;3m\033[<64;50;8M\033[<65;50;8M".data);
    assert (mouse.length == 4 && keys.length == 8);
    assert (mouse[0].button == MouseButton.LEFT && mouse[0].x == 11 && mouse[0].y == 2 && mouse[0].pressed);
    assert (!mouse[1].pressed);
    assert (mouse[2].button == MouseButton.WHEEL_UP && mouse[3].button == MouseButton.WHEEL_DOWN);
    input.feed ("\033[<0;0;1M\033[<999;2;3M\033[<0;no;3M".data);
    assert (mouse.length == 4);
    input.feed ("\033[<0;20;5M\033[<32;30;5M\033[<0;30;5m".data);
    assert (mouse.length == 7 && mouse[5].motion && mouse[5].x == 29 && !mouse[6].pressed);
    int count = keys.length;
    input.feed ("\017\022\027".data);
    assert (keys.length == count + 1 && keys[count] == Key.DELETE_WORD);
    count = keys.length;
    input.feed ("\0332\033x\002\006\007\011\020\016\033[12~\033[13~\033OQ".data);
    assert (keys.length == count + 8); // No function-key bindings.
    assert (keys[count] == Key.SELECT_TAB && values[count] == "2");
    assert (keys[count + 1] == Key.CLOSE_TAB && keys[count + 2] == Key.PAGE_UP && keys[count + 3] == Key.PAGE_DOWN);
    assert (keys[count + 4] == Key.FOCUS && keys[count + 5] == Key.COMPLETE);
    assert (keys[count + 6] == Key.HISTORY_PREVIOUS && keys[count + 7] == Key.HISTORY_NEXT);
}

private void editor_test () {
    var editor = new Editor ();
    editor.insert ("e");
    editor.insert ("\u0301");
    assert (editor.text == "e\u0301");
    editor.handle (Key.BACKSPACE, 20);
    assert (editor.text == "");
    editor.insert ("a界e\u0301");
    editor.handle (Key.LEFT, 20);
    editor.handle (Key.BACKSPACE, 20);
    assert (editor.text == "ae\u0301" && editor.cursor == 1);
    editor.handle (Key.DELETE, 20);
    assert (editor.text == "a");
    editor.insert ("b\ncd");
    editor.handle (Key.UP, 20);
    assert (editor.cursor == 2);
    editor.handle (Key.DOWN, 20);
    assert (editor.cursor == 5);
    editor.handle (Key.HOME, 20);
    assert (editor.cursor == 3);
    editor.handle (Key.END, 20);
    assert (editor.cursor == 5);
    editor.clear ();
    editor.insert ("abcd");
    int x, y;
    var rows = editor.layout (4, out x, out y);
    assert (rows.length == 2 && x == 0 && y == 1);
    editor.clear ();
    editor.insert ("hello\033[2J\003\nworld");
    assert (editor.text == "hello[2J\nworld");
    var large = new StringBuilder ();
    for (int i = 0; i < 40000; i++) large.append ("界");
    editor.insert (large.str);
    assert (editor.text.length <= Editor.MAX_BYTES && editor.text.validate ());
    rows = editor.layout (1, out x, out y, 5);
    assert (rows.length <= 5 && y < 5);
    editor.clear ();
    editor.insert ("a界e\u0301\nsecond");
    editor.place_cursor (10, 2, 0);  // Either half of a wide glyph selects its base.
    assert (editor.cursor == 1);
    editor.place_cursor (10, 2, 1);
    assert (editor.text.substring (editor.cursor) == "cond");
    editor.clear (); editor.insert ("one 日本語 e\u0301  suffix");
    for (int i = 0; i < 6; i++) editor.handle (Key.LEFT, 80);
    editor.handle (Key.DELETE_WORD, 80);
    assert (editor.text == "one 日本語 suffix");
    editor.handle (Key.DELETE_WORD, 80);
    assert (editor.text == "one suffix");
    editor.handle (Key.DELETE_WORD, 80);
    assert (editor.text == "suffix" && editor.cursor == 0);
    editor.handle (Key.DELETE_WORD, 80);
    assert (editor.text == "suffix");
}

private void completion_test () {
    var completion = new Parla.Terminal.Completion ();
    var editor = new Editor ();
    string[] commands = { "/close", "/query", "/set", "/version" };
    editor.insert ("/"); completion.complete (editor, commands);
    assert (editor.text == "/" && completion.hint.contains ("/version"));
    completion.complete (editor, commands); assert (editor.text == "/close ");
    completion.complete (editor, commands, true); assert (editor.text == "/version ");
    editor.clear (); editor.insert ("/ver more");
    for (int i = 0; i < 5; i++) editor.handle (Key.LEFT, 80);
    completion.complete (editor, commands);
    assert (editor.text == "/version more");
    editor.clear (); editor.insert ("hello @Al");
    completion.complete (editor, { "hello @Alice", "hello @Alfred" });
    assert (editor.text == "hello @Al");
    completion.complete (editor, {}, true); assert (editor.text == "hello @Alfred ");
    editor.clear (); editor.insert ("user@example.org");
    completion.complete (editor, { "user@example.orgmore" });
    assert (editor.text == "user@example.org" && completion.hint == "");
    var view = new View ();
    view.add_tab ("home", "Parla"); view.add_tab ("chat", "Alice");
    view.handle_key (Key.COMPLETE);
    assert (view.active_buffer.id == "home");
}

private void shared_history_test () {
    var history = new InputHistory ();
    var first = new View (); first.input_history = history;
    var home = first.add_tab ("home", "Parla"); home.closable = false;
    first.add_tab ("a", "Alice");
    first.handle_key (Key.TEXT, "first command"); first.handle_key (Key.ENTER);
    first.handle_key (Key.SELECT_TAB, "2");
    first.handle_key (Key.TEXT, "second message"); first.handle_key (Key.ENTER);
    first.select_tab ("home"); first.handle_key (Key.TEXT, "draft");
    first.handle_key (Key.HISTORY_PREVIOUS); assert (home.editor.text == "second message");
    first.handle_key (Key.UP); assert (home.editor.text == "first command");
    first.handle_key (Key.DOWN); assert (home.editor.text == "second message");
    first.handle_key (Key.HISTORY_NEXT); assert (home.editor.text == "draft");
    var second = new View (); second.input_history = history;
    var other_account = second.add_tab ("home", "Parla");
    second.handle_key (Key.UP); assert (other_account.editor.text == "second message");
    first.handle_key (Key.ESCAPE); first.handle_key (Key.TEXT, "2");
    assert (first.active_buffer.id == "a");
    first.handle_key (Key.ESCAPE); first.handle_key (Key.TEXT, "x");
    assert (first.active_buffer == home && !first.close_tab ("home"));
}

private void contacts_tab_test () {
    var view = new View ();
    view.add_tab ("home", "Parla");
    view.set_contacts ({ new Contact ("a", "Alice"), new Contact ("b", "Bob", "", 2) });
    string selected = "";
    view.contact_activated.connect ((contact) => { selected = contact.id; view.add_tab (contact.id, contact.name); view.select_tab (contact.id); });
    view.handle_key (Key.SELECT_TAB, "2");
    var frame = view.draw (80, 24);
    assert (frame.get_row (0).plain_text ().contains ("2:Contacts"));
    assert (frame.get_row (3).plain_text ().has_prefix ("*    Bob"));
    assert (!frame.get_row (3).plain_text ().contains ("│"));
    view.handle_key (Key.TEXT, "j"); view.handle_key (Key.ENTER);
    assert (selected == "b" && view.active_buffer.id == "b");
    view.handle_key (Key.SELECT_TAB, "2"); view.draw (80, 24);
    view.handle_mouse (new MouseEvent (MouseButton.LEFT, 40, 2));
    assert (selected == "a");
    assert (!view.close_tab (View.CONTACTS_TAB));
    view.set_info_visible (true);
    view.set_info ("Chat information", "Members\nAlice\nBob\nDisappearing messages: 1 hour");
    frame = view.draw (100, 24);
    assert (frame.get_row (1).plain_text ().contains ("Chat information"));
    assert (frame.get_row (2).plain_text ().contains ("Members"));
    for (int width = 1; width < 120; width += 7) view.draw (width, 10);
}

private void message_format_test () {
    var message = new Text.message ("12:34", "Alice", "one\ntwo and a longer message", "", "Alice");
    var rows = message.wrap (25);
    assert (rows.get (0).plain_text ().strip () == "12:34 <Alice> one");
    assert (rows.get (1).plain_text ().has_prefix ("              two"));
    assert (rows.get (2).plain_text ().has_prefix ("              "));
    for (int width = 1; width < 60; width++) assert (message.wrap (width).length == message.line_count (width));
    var block = new Text.block ("▄▄\n▀▀", 2, Style.QR);
    assert (block.wrap (1).get (0).plain_text () == "[");
    assert (block.wrap (3).get (0).plain_text ().has_prefix ("▄▄"));
    foreach (var preset in new string[] { "default", "light", "ocean" }) {
        var theme = new Theme (preset);
        foreach (Style remote in new Style[] { Style.NICK1, Style.NICK2, Style.NICK3, Style.NICK4 })
            assert (theme.codes (Style.OWN_NICK) != theme.codes (remote));
        theme.set_color ("nick1", theme.get_color ("own_nick"));
        assert (theme.codes (Style.OWN_NICK) != theme.codes (Style.NICK1));
    }
    assert (Theme.valid_color ("#123ABC:blue"));
    assert (!Theme.valid_color ("#123:blue") && !Theme.valid_color ("red:blue:green"));
    var ocean = new Theme ("ocean");
    assert (ocean.codes (Style.INPUT) == ";39;48;2;15;23;42");
    ocean.set_color ("text", "white:#abcdef");
    assert (ocean.codes (Style.INPUT) == ";39;48;2;171;205;239");
    assert (ocean.codes (Style.OWN_NICK) == ";38;2;74;222;128;48;2;171;205;239");
}

private void navigation_test () {
    var view = new View ();
    var alice = view.add_tab ("a", "Alice");
    view.add_tab ("b", "Bob");
    view.set_contacts ({ new Contact ("a", "Alice"), new Contact ("b", "Bob"), new Contact ("c", "Carol") });
    string activated = "";
    view.contact_activated.connect ((contact) => { activated = contact.id; view.select_tab (contact.id); });
    view.handle_key (Key.FOCUS);
    view.handle_key (Key.TEXT, "j");
    view.handle_key (Key.ENTER);
    assert (activated == "b");
    view.handle_key (Key.FOCUS);
    view.handle_key (Key.TEXT, "k");
    view.handle_key (Key.ENTER);
    assert (activated == "a");
    view.handle_key (Key.TEXT, "jk");
    assert (alice.editor.text == "jk");
    view.handle_key (Key.FOCUS);
    view.draw (80, 24);
    view.handle_mouse (new MouseEvent (MouseButton.LEFT, 2, 3));
    assert (activated == "b" && view.active_buffer.id == "b");
    view.draw (80, 24);
    view.handle_mouse (new MouseEvent (MouseButton.LEFT, 2, 0));
    assert (view.active_buffer.id == "a");
    view.draw (80, 24);
    view.handle_mouse (new MouseEvent (MouseButton.LEFT, 3, 23));
    view.handle_key (Key.TEXT, "X");
    assert (alice.editor.text == "jXk");
    for (int i = 0; i < 80; i++) alice.append_text ("line");
    view.draw (80, 24);
    view.handle_mouse (new MouseEvent (MouseButton.WHEEL_UP, 40, 8));
    assert (alice.scroll_offset == 1);
    view.handle_mouse (new MouseEvent (MouseButton.WHEEL_DOWN, 40, 8));
    assert (alice.scroll_offset == 0);
    view.handle_key (Key.FOCUS);
    view.draw (80, 24);
    view.handle_mouse (new MouseEvent (MouseButton.WHEEL_DOWN, 2, 8));
    view.handle_key (Key.ENTER);
    assert (activated == "c");
    view.handle_mouse (new MouseEvent (MouseButton.LEFT, 0, 0, false));
    view.handle_mouse (new MouseEvent (MouseButton.LEFT, 800, 240));
    assert (activated == "c");
}

private void view_test () {
    var view = new View ();
    var tab = view.add_tab ("a", "Alice");
    var other = view.add_tab ("b", "Bob");
    view.set_contacts ({ new Contact ("a", "Alice", "online") });
    for (int i = 0; i < 100; i++) tab.append_text ("message %03d".printf (i));
    var renderer = new Renderer ();
    var frame = view.draw (80, 24);
    renderer.render (frame);
    assert (renderer.render (view.draw (80, 24)) == "");
    Row history = frame.get_row (5);
    view.handle_key (Key.TEXT, "hello");
    frame = view.draw (80, 24);
    assert (frame.get_row (5) == history);
    string edit = renderer.render (frame);
    assert (edit.length < 60 && edit.contains ("hello"));
    other.append_text ("background");
    assert (renderer.render (view.draw (80, 24)) == "");
    view.set_contacts ({ new Contact ("a", "Alice", "online", 0, ContactKind.DIRECT, false, 1, "12:00", "new preview") });
    assert (view.draw (80, 24).get_row (5) == history);
    assert (renderer.render (view.draw (80, 24)) == "");
    view.scroll (20);
    string anchored = view.draw (80, 24).get_row (1).plain_text ();
    tab.append_text ("new arrival");
    assert (view.draw (80, 24).get_row (1).plain_text () == anchored);
    view.select_tab ("b");
    view.handle_key (Key.TEXT, "draft two");
    view.select_tab ("a");
    assert (view.active_buffer.editor.text == "hello");
    view.scroll (-int.MAX);
    assert (view.draw (80, 24).get_row (21).plain_text ().contains ("new arrival"));
    // The history bound must not leave expired rows visible.
    for (int i = 0; i < 400; i++) tab.append_text ("extra %03d".printf (i));
    view.scroll (int.MAX);
    assert (view.draw (80, 24).get_row (1).plain_text ().contains ("extra 100"));
    for (int width = 1; width <= 100; width += 3) {
        for (int height = 1; height < 30; height += 3) {
            frame = view.draw (width, height);
            assert (frame.cursor_x >= 0 && frame.cursor_x < width);
            assert (frame.cursor_y >= 0 && frame.cursor_y < height);
            renderer.render (frame);
        }
    }
    view.set_contacts ({});
    view.handle_key (Key.FOCUS);
    view.handle_key (Key.DOWN);
    view.set_contacts ({ new Contact ("a", "Alice") });
    view.handle_key (Key.ENTER);
}

private void irc_layout_test () {
    var view = new View ();
    var alice = view.add_tab ("a", "Alice");
    var bob = view.add_tab ("b", "Bob");
    alice.append_message ("14:05", "Alice", "Hello **world**");
    view.set_contacts ({ new Contact ("a", "Alice", "", 2), new Contact ("b", "Bob") });
    var renderer = new Renderer ();
    var frame = view.draw (80, 24);
    assert (frame.get_row (1).plain_text ().has_prefix ("14:05 <Alice> Hello world"));
    string ansi = renderer.render (frame);
    assert (Regex.match_simple ("\\x1b\\[0;1;(94|35|36|33);49mAlice", ansi));
    assert (ansi.contains ("\033[0;1;33;49m 1:Alice (2) "));
    Row history = frame.get_row (1);
    bob.set_unread (3);
    frame = view.draw (80, 24);
    assert (frame.get_row (1) == history);
    assert (renderer.render (frame).contains ("\033[0;1;33;49m 2:Bob (3) "));
    bob.set_unread (0);
    alice.editor.insert ("saved draft");
    view.handle_key (Key.FOCUS);
    frame = view.draw (80, 24);
    assert (!frame.cursor_visible && !frame.get_row (1).plain_text ().contains ("[focus]"));
    assert (frame.get_row (2).plain_text ().has_prefix ("*    Alice"));
    view.select_tab ("a");
    assert (view.close_tab ("a"));
    assert (view.add_tab ("a", "Alice") == alice);
    view.select_tab ("a");
    assert (view.active_buffer.editor.text == "saved draft");
    assert (!view.close_tab (View.CONTACTS_TAB));
}

private void contacts_order_test () {
    var view = new View ();
    view.add_tab ("home", "Parla");
    Contact[] people = {
        new Contact ("g", "#Zebra", "", 3, ContactKind.GROUP, false, 30, "12:30", "Grey preview"),
        new Contact ("a", "@alice", "", 2, ContactKind.DIRECT, false, 20, "12:20", "hello\nworld"),
        new Contact ("b", "@Bob", "", 4, ContactKind.DIRECT, true, 10)
    };
    view.set_contacts (people);
    var frame = view.draw (100, 24);
    assert (frame.get_row (0).plain_text ().contains ("Contacts (9)"));
    view.add_tab ("g", "#Zebra");
    assert (view.draw (100, 24).get_row (0).plain_text ().contains ("Contacts (6)"));
    view.close_tab ("g");
    assert (view.draw (100, 24).get_row (0).plain_text ().contains ("Contacts (9)"));
    view.select_tab (View.CONTACTS_TAB);
    frame = view.draw (100, 24);
    assert (frame.get_row (2).plain_text ().contains ("📌 @Bob"));
    assert (column_of (frame.get_row (2).plain_text (), "@Bob") == 5);
    assert (column_of (frame.get_row (3).plain_text (), "#Zebra") == 5);
    assert (column_of (frame.get_row (4).plain_text (), "@alice") == 5);
    assert (frame.get_row (3).plain_text ().contains ("#Zebra"));
    assert (frame.get_row (4).plain_text ().contains ("12:20") && frame.get_row (4).plain_text ().contains ("hello world"));
    string pinned_id = "";
    view.contact_pin_requested.connect ((contact, pinned) => { pinned_id = contact.id; assert (!pinned); });
    view.handle_key (Key.TEXT, "a");
    frame = view.draw (100, 24);
    assert (frame.get_row (3).plain_text ().contains ("@alice"));
    view.handle_key (Key.TEXT, "g");
    frame = view.draw (100, 24);
    assert (frame.get_row (2).plain_text ().strip () == "Pinned");
    assert (frame.get_row (4).plain_text ().strip () == "Private chats");
    assert (frame.get_row (6).plain_text ().strip () == "Group chats");
    view.handle_key (Key.TEXT, "p"); assert (pinned_id == "b");
    string activated = "";
    view.contact_activated.connect ((contact) => activated = contact.id);
    view.handle_mouse (new MouseEvent (MouseButton.LEFT, 2, 4)); // Header has no contact hit.
    assert (activated == "");
    view.handle_key (Key.DOWN); view.handle_key (Key.ENTER);
    assert (activated == "a");
    var renderer = new Renderer ();
    assert (renderer.render (view.draw (100, 24)).contains ("38;2;153;153;153"));
    assert (renderer.render (view.draw (100, 24)) == "");
    view.set_contacts_grouped (false);
    view.set_contacts ({
        new Contact ("a", "@Pinned unread", "", 1, ContactKind.DIRECT, true),
        new Contact ("b", "@Pinned read", "", 0, ContactKind.DIRECT, true),
        new Contact ("c", "@Unpinned unread", "", 2, ContactKind.DIRECT),
        new Contact ("d", "@Unpinned read")
    });
    frame = view.draw (100, 24);
    for (int y = 2; y <= 5; y++) assert (column_of (frame.get_row (y).plain_text (), "@") == 5);
}

private int column_of (string line, string text) {
    int end = line.index_of (text), offset = 0, columns = 0;
    assert (end >= 0);
    unichar c = 0;
    while (offset < end && line.get_next_char (ref offset, out c)) columns += character_width (c);
    return columns;
}

private void message_selection_test () {
    var view = new View ();
    var chat = view.add_tab ("chat", "Chat");
    for (int i = 1; i <= 25; i++) chat.append_message ("12:00", "Alice", "first\nsecond", "", "", false, true, true, true, i.to_string ());
    view.draw (50, 12);
    assert (view.begin_message_selection ("/reply"));
    assert (chat.selected_message_id == "25");
    for (int i = 0; i < 6; i++) view.handle_key (Key.TEXT, "k");
    assert (chat.selected_message_id == "19" && chat.scroll_offset > 0);
    string confirmed = "";
    view.message_selection_confirmed.connect ((buffer, action) => confirmed = action + buffer.selected_message_id);
    view.handle_key (Key.ENTER); assert (confirmed == "/reply19" && !view.selecting_messages);
    view.scroll (-int.MAX);
    view.draw (50, 12);
    view.handle_mouse (new MouseEvent (MouseButton.LEFT, 20, 9));
    assert (chat.selected_message_id == "25");
    view.handle_key (Key.ESCAPE); assert (chat.selected_message_id == "");
    view.begin_message_selection ("/reply"); view.handle_key (Key.UP); view.handle_key (Key.ESCAPE);
    assert (!view.selecting_messages && chat.selected_message_id == "");
}

private void hyperlink_test () {
    var text = new Text.link ("image.png", "file:///tmp/image%20one.png");
    var frame = new Frame (30, 2);
    frame.set_row (0, text.wrap (30).get (0));
    var renderer = new Renderer ();
    string output = renderer.render (frame);
    assert (output.contains ("\033]8;;file:///tmp/image%20one.png\033\\"));
    assert (output.contains ("image.png\033]8;;\033\\"));
    assert (renderer.render (frame) == "");
    frame.set_row (0, new Text.link ("image.png", "file:///tmp/changed.png").wrap (30).get (0));
    assert (renderer.render (frame).contains ("file:///tmp/changed.png"));
    frame.set_row (0, new Text.link ("bad", "file:///tmp/evil\033]title").wrap (30).get (0));
    assert (!renderer.render (frame).contains ("\033]8;;file"));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/terminal/renderer", renderer_test);
    Test.add_func ("/terminal/text", text_test);
    Test.add_func ("/terminal/input", input_test);
    Test.add_func ("/terminal/editor", editor_test);
    Test.add_func ("/terminal/view", view_test);
    Test.add_func ("/terminal/navigation", navigation_test);
    Test.add_func ("/terminal/irc-layout", irc_layout_test);
    Test.add_func ("/terminal/completion", completion_test);
    Test.add_func ("/terminal/shared-history", shared_history_test);
    Test.add_func ("/terminal/contacts-tab", contacts_tab_test);
    Test.add_func ("/terminal/message-format", message_format_test);
    Test.add_func ("/terminal/contact-order", contacts_order_test);
    Test.add_func ("/terminal/message-selection", message_selection_test);
    Test.add_func ("/terminal/hyperlinks", hyperlink_test);
    return Test.run ();
}
