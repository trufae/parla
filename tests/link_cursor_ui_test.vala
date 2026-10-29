using Dc;

private void hover_label_byte (Gtk.Label label, Gtk.EventControllerMotion motion,
                                int index, bool enter) {
    int x, y;
    label.get_layout_offsets (out x, out y);
    var rect = label.get_layout ().index_to_pos (index);
    double px = x + (rect.x + rect.width / 2.0) / Pango.SCALE;
    double py = y + (rect.y + rect.height / 2.0) / Pango.SCALE;
    if (enter) motion.enter (px, py);
    else motion.motion (px, py);
}

public int run_link_cursor_ui_test () {
    Adw.init ();
    foreach (var style in new MessageStyle[] {
            MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
        MessageRow.style = style;
        var msg = new Message ();
        msg.text = "Préface https://example.com/path tail";
        var row = new MessageRow (msg);
        var label = search_widget (row, typeof (Gtk.Label),
            Markdown.format (msg.text)) as Gtk.Label;
        assert (label != null && label.selectable);
        label.allocate (400, 100, -1, null);
        Gtk.EventControllerMotion? motion = null;
        var controllers = label.observe_controllers ();
        for (uint i = 0; i < controllers.get_n_items (); i++) {
            motion = controllers.get_item (i) as Gtk.EventControllerMotion;
            if (motion != null) break;
        }
        assert (motion != null);
        int link_index = msg.text.index_of ("https://") + 2;
        // Entering a link must work even without a separate motion event.
        hover_label_byte (label, motion, link_index, true);
        assert (label.cursor.get_name () == "pointer");
        var cursor = label.cursor;
        hover_label_byte (label, motion, link_index + 1, false);
        assert (label.cursor.get_name () == "pointer");
        assert (label.cursor != cursor); // Refresh the platform cursor too.
        hover_label_byte (label, motion, 0, false);
        assert (label.cursor.get_name () == "text");
        hover_label_byte (label, motion, link_index, false);
        motion.leave ();
        assert (label.cursor.get_name () == "text");
        // Text selection keeps GTK's selection cursor and link behavior.
        label.select_region (0, -1);
        hover_label_byte (label, motion, link_index, true);
        assert (label.cursor.get_name () == "text");
    }
    stdout.printf ("Chat link cursors passed for entry, motion, exit, and selection.\n");
    return 0;
}
