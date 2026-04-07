namespace Dc {

    /**
     * Compose bar at the bottom of the message view.
     * Contains a text entry, file attach button, and send button.
     */
    public class ComposeBar : Gtk.Box {

        public signal void send_message (string text, string? file_path);
        public signal void attach_file ();

        private Gtk.Entry text_entry;
        private Gtk.Button send_button;
        private Gtk.Button attach_button;
        private string? pending_file = null;

        public ComposeBar () {
            Object (
                orientation: Gtk.Orientation.HORIZONTAL,
                spacing: 6
            );
            add_css_class ("compose-bar");
            margin_start = 8;
            margin_end = 8;
            margin_top = 6;
            margin_bottom = 6;

            /* Attach button */
            attach_button = new Gtk.Button.from_icon_name ("mail-attachment-symbolic");
            attach_button.add_css_class ("flat");
            attach_button.tooltip_text = "Attach file";
            attach_button.valign = Gtk.Align.CENTER;
            attach_button.clicked.connect (on_attach_clicked);
            append (attach_button);

            /* Text entry */
            text_entry = new Gtk.Entry ();
            text_entry.hexpand = true;
            text_entry.placeholder_text = "Type a message…";
            text_entry.add_css_class ("compose-entry");
            text_entry.activate.connect (on_send);
            append (text_entry);

            /* Send button */
            send_button = new Gtk.Button.from_icon_name ("go-up-symbolic");
            send_button.add_css_class ("suggested-action");
            send_button.add_css_class ("circular");
            send_button.tooltip_text = "Send message";
            send_button.valign = Gtk.Align.CENTER;
            send_button.clicked.connect (on_send);
            append (send_button);
        }

        public void grab_entry_focus () {
            text_entry.grab_focus ();
        }

        public void clear () {
            text_entry.text = "";
            pending_file = null;
        }

        private void on_send () {
            string text = text_entry.text.strip ();
            if (text.length == 0 && pending_file == null) return;

            send_message (text, pending_file);
            clear ();
        }

        private void on_attach_clicked () {
            var dialog = new Gtk.FileDialog ();
            dialog.title = "Select file to attach";

            var window = (Gtk.Window) get_root ();
            dialog.open.begin (window, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null) {
                        pending_file = file.get_path ();
                        /* Show file name in entry as preview */
                        string basename = Path.get_basename (pending_file);
                        if (text_entry.text.strip ().length == 0) {
                            text_entry.text = "";
                        }
                        text_entry.placeholder_text = "📎 %s — Type a caption…".printf (basename);
                    }
                } catch (Error e) {
                    /* User cancelled */
                }
            });
        }
    }
}
