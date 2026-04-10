namespace Dc {

    /**
     * Compose bar at the bottom of the message view.
     * Contains a text entry, file attach button, and send button.
     */
    public class ComposeBar : Gtk.Box {

        public signal void send_message (string text, string? file_path, string? file_name, int quote_msg_id);
        public signal void edit_message (int msg_id, string new_text);

        private Gtk.TextView text_view;
        private Gtk.Label placeholder_label;
        private string placeholder_default = "Type a message…";
        private Gtk.Button send_button;
        private Gtk.Button attach_button;
        private Gtk.Button cancel_attach_button;
        private Gtk.Button cancel_edit_button;
        private Gtk.Button cancel_reply_button;
        private Gtk.Label reply_label;
        private Gtk.Box reply_bar;
        private string? pending_file = null;
        private string? pending_file_name = null;
        private int editing_msg_id = 0;
        private int replying_msg_id = 0;

        public ComposeBar () {
            Object (
                orientation: Gtk.Orientation.VERTICAL,
                spacing: 0
            );
            add_css_class ("compose-bar");
            margin_start = 8;
            margin_end = 8;
            margin_top = 6;
            margin_bottom = 6;

            /* Reply indicator bar (hidden by default) */
            reply_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            reply_bar.add_css_class ("reply-bar");
            reply_bar.visible = false;

            reply_label = new Gtk.Label ("");
            reply_label.add_css_class ("reply-label");
            reply_label.halign = Gtk.Align.START;
            reply_label.hexpand = true;
            reply_label.ellipsize = Pango.EllipsizeMode.END;
            reply_bar.append (reply_label);

            cancel_reply_button = new Gtk.Button.from_icon_name ("window-close-symbolic");
            cancel_reply_button.add_css_class ("flat");
            cancel_reply_button.add_css_class ("circular");
            cancel_reply_button.tooltip_text = "Cancel reply";
            cancel_reply_button.valign = Gtk.Align.CENTER;
            cancel_reply_button.clicked.connect (cancel_reply);
            reply_bar.append (cancel_reply_button);

            append (reply_bar);

            /* Input row */
            var input_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

            /* Attach button */
            attach_button = new Gtk.Button.from_icon_name ("mail-attachment-symbolic");
            attach_button.add_css_class ("flat");
            attach_button.tooltip_text = "Attach file";
            attach_button.valign = Gtk.Align.CENTER;
            attach_button.clicked.connect (on_attach_clicked);
            input_row.append (attach_button);

            /* Cancel attachment button (hidden by default) */
            cancel_attach_button = new Gtk.Button.from_icon_name ("edit-clear-symbolic");
            cancel_attach_button.add_css_class ("flat");
            cancel_attach_button.tooltip_text = "Remove attachment";
            cancel_attach_button.valign = Gtk.Align.CENTER;
            cancel_attach_button.visible = false;
            cancel_attach_button.clicked.connect (clear_attachment);
            input_row.append (cancel_attach_button);

            /* Cancel edit button (hidden by default) */
            cancel_edit_button = new Gtk.Button.from_icon_name ("edit-undo-symbolic");
            cancel_edit_button.add_css_class ("flat");
            cancel_edit_button.tooltip_text = "Cancel editing";
            cancel_edit_button.valign = Gtk.Align.CENTER;
            cancel_edit_button.visible = false;
            cancel_edit_button.clicked.connect (cancel_edit);
            input_row.append (cancel_edit_button);

            /* Multi-line text view with paste handler.
               Wrapped in a ScrolledWindow that grows up to a max height,
               and overlaid with a manual placeholder label since
               Gtk.TextView has no built-in placeholder support. */
            text_view = new Gtk.TextView ();
            text_view.wrap_mode = Gtk.WrapMode.WORD_CHAR;
            text_view.accepts_tab = false;
            text_view.top_margin = 7;
            text_view.bottom_margin = 3;
            text_view.left_margin = 12;
            text_view.right_margin = 12;
            text_view.pixels_above_lines = 0;
            text_view.pixels_below_lines = 0;
            text_view.pixels_inside_wrap = 0;
            text_view.hexpand = true;
            text_view.vexpand = false;
            text_view.add_css_class ("compose-entry");

            /* Placeholder is anchored to the top with the exact same
               top margin as the text view, so its baseline matches the
               first line of typed text instead of relying on valign. */
            placeholder_label = new Gtk.Label (placeholder_default);
            placeholder_label.add_css_class ("compose-placeholder");
            placeholder_label.halign = Gtk.Align.START;
            placeholder_label.valign = Gtk.Align.START;
            placeholder_label.margin_start = 12;
            placeholder_label.margin_top = 7;
            placeholder_label.can_target = false;
            placeholder_label.ellipsize = Pango.EllipsizeMode.END;

            var entry_overlay = new Gtk.Overlay ();
            entry_overlay.child = text_view;
            entry_overlay.add_overlay (placeholder_label);
            entry_overlay.hexpand = true;
            entry_overlay.valign = Gtk.Align.CENTER;

            text_view.buffer.changed.connect (update_placeholder);
            update_placeholder ();

            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.key_pressed.connect (on_entry_key_pressed);
            text_view.add_controller (key_ctrl);
            input_row.append (entry_overlay);

            /* Send button */
            send_button = new Gtk.Button.from_icon_name ("go-up-symbolic");
            send_button.add_css_class ("suggested-action");
            send_button.add_css_class ("circular");
            send_button.tooltip_text = "Send message";
            send_button.valign = Gtk.Align.CENTER;
            send_button.clicked.connect (on_send);
            input_row.append (send_button);

            append (input_row);
        }

        public void grab_entry_focus () {
            /* Gtk.TextView does not select text on grab_focus the way
               Gtk.Entry does, so a plain grab_focus is safe here.
               Defer to idle so focus lands after the current event
               (e.g. a global Ctrl+L shortcut) has finished dispatching. */
            text_view.grab_focus ();
            GLib.Idle.add (() => {
                text_view.grab_focus ();
                return GLib.Source.REMOVE;
            });
        }

        public void clear () {
            text_view.buffer.text = "";
            clear_attachment ();
        }

        private string get_text () {
            Gtk.TextIter start, end;
            text_view.buffer.get_bounds (out start, out end);
            return text_view.buffer.get_text (start, end, false);
        }

        private void set_placeholder (string s) {
            placeholder_label.label = s;
        }

        private void update_placeholder () {
            placeholder_label.visible = text_view.buffer.get_char_count () == 0;
        }

        public bool can_accept_attachment () {
            return editing_msg_id == 0;
        }

        public void set_pending_attachment (string file_path, string? file_name = null) {
            pending_file = file_path;
            pending_file_name = file_name ?? Path.get_basename (file_path);
            text_view.buffer.text = "";
            set_placeholder ("📎 %s — Type a caption…".printf (pending_file_name));
            cancel_attach_button.visible = true;
        }

        private void clear_attachment () {
            pending_file = null;
            pending_file_name = null;
            cancel_attach_button.visible = false;
            set_placeholder (placeholder_default);
        }

        private void on_send () {
            string text = get_text ().strip ();
            if (editing_msg_id > 0) {
                if (text.length == 0) return;
                edit_message (editing_msg_id, text);
                cancel_edit ();
                return;
            }
            if (text.length == 0 && pending_file == null) return;
            int qid = replying_msg_id;
            send_message (text, pending_file, pending_file_name, qid);
            cancel_reply ();
            clear ();
        }

        public void begin_reply (int msg_id, string sender_name, string preview) {
            cancel_edit ();
            replying_msg_id = msg_id;
            reply_label.label = "%s: %s".printf (sender_name, preview);
            reply_bar.visible = true;
            text_view.grab_focus ();
        }

        private void cancel_reply () {
            replying_msg_id = 0;
            reply_bar.visible = false;
            reply_label.label = "";
        }

        public void begin_edit (int msg_id, string current_text) {
            cancel_edit ();
            cancel_reply ();
            clear_attachment ();
            editing_msg_id = msg_id;
            text_view.buffer.text = current_text;
            set_placeholder ("Edit message…");
            cancel_edit_button.visible = true;
            attach_button.sensitive = false;
            text_view.grab_focus ();
            Gtk.TextIter end_iter;
            text_view.buffer.get_end_iter (out end_iter);
            text_view.buffer.place_cursor (end_iter);
        }

        private void cancel_edit () {
            if (editing_msg_id == 0) return;
            editing_msg_id = 0;
            text_view.buffer.text = "";
            set_placeholder (placeholder_default);
            cancel_edit_button.visible = false;
            attach_button.sensitive = true;
        }

        private void on_attach_clicked () {
            var dialog = new Gtk.FileDialog ();
            dialog.title = "Select file to attach";
            var window = (Gtk.Window) get_root ();
            dialog.open.begin (window, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null) {
                        var path = file.get_path ();
                        if (path != null)
                            set_pending_attachment (path, file.get_basename ());
                    }
                } catch (Error e) {
                }
            });
        }

        private bool on_entry_key_pressed (uint keyval, uint keycode,
                                           Gdk.ModifierType state) {
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (keyval == Gdk.Key.Return
                || keyval == Gdk.Key.KP_Enter
                || keyval == Gdk.Key.ISO_Enter) {
                if (shift) return false; /* let TextView insert a newline */
                on_send ();
                return true;
            }

            if (!can_accept_attachment ()) return false;
            bool ctrl_v = (state & Gdk.ModifierType.CONTROL_MASK) != 0
                        && (keyval == Gdk.Key.v || keyval == Gdk.Key.V);
            if (!ctrl_v && !(shift && keyval == Gdk.Key.Insert)) return false;

            var clipboard = get_display ().get_clipboard ();
            var formats = clipboard.get_formats ();
            if (formats.contain_gtype (typeof (Gdk.FileList))) {
                paste_file_list.begin (clipboard);
                return true;
            }
            if (formats.contain_gtype (typeof (Gdk.Texture))) {
                paste_texture.begin (clipboard);
                return true;
            }
            return false;
        }

        private async void paste_file_list (Gdk.Clipboard clipboard) {
            try {
                var value = yield clipboard.read_value_async (typeof (Gdk.FileList),
                                                              Priority.DEFAULT, null);
                if (value == null) return;
                var fl = (Gdk.FileList?) value.get_boxed ();
                if (fl == null) return;
                var files = fl.get_files ();
                if (files != null && files.data != null) {
                    var path = files.data.get_path ();
                    if (path != null)
                        set_pending_attachment (path, files.data.get_basename ());
                }
            } catch (Error e) {
            }
        }

        private async void paste_texture (Gdk.Clipboard clipboard) {
            try {
                var texture = yield clipboard.read_texture_async (null);
                if (texture == null) return;
                GLib.FileIOStream stream;
                var tmp = GLib.File.new_tmp ("deltachat-gnome-XXXXXX.png", out stream);
                stream.close ();
                string path = tmp.get_path ();
                if (texture.save_to_png (path))
                    set_pending_attachment (path, "pasted-image.png");
            } catch (Error e) {
            }
        }
    }
}
