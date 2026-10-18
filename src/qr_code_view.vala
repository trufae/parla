namespace Dc {

    public class QrCodeView : Gtk.Box {

        [CCode (cname = "parla_qr_svg_from_bytes", cheader_filename = "qr_svg_compat.h")]
        private static extern Gdk.Paintable load_qr_svg (Bytes bytes) throws Error;

        public string? code_text { get; private set; default = null; }

        private Gtk.Label status_label;
        private Gtk.Picture qr_picture;
        private Gtk.TextView code_text_view;
        private Gtk.ScrolledWindow code_text_scroll;
        private Gtk.Button? copy_button = null;

        public QrCodeView (string initial_status) {
            Object (
                orientation: Gtk.Orientation.VERTICAL,
                spacing: 12
            );

            status_label = new Gtk.Label (initial_status);
            status_label.wrap = true;
            status_label.xalign = 0;
            append (status_label);

            qr_picture = new Gtk.Picture ();
            qr_picture.content_fit = Gtk.ContentFit.CONTAIN;
            qr_picture.can_shrink = true;
            qr_picture.halign = Gtk.Align.CENTER;
            qr_picture.set_size_request (280, 280);
            qr_picture.visible = false;
            append (qr_picture);

            code_text_view = new Gtk.TextView ();
            code_text_view.editable = false;
            code_text_view.cursor_visible = false;
            code_text_view.monospace = true;
            code_text_view.wrap_mode = Gtk.WrapMode.CHAR;

            code_text_scroll = new Gtk.ScrolledWindow ();
            code_text_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            code_text_scroll.min_content_height = 96;
            code_text_scroll.child = code_text_view;
            code_text_scroll.visible = false;
            append (code_text_scroll);
        }

        public Gtk.Button make_copy_button (string label) {
            var btn = new Gtk.Button.with_label (label);
            btn.sensitive = code_text != null && code_text.length > 0;
            btn.clicked.connect (copy_to_clipboard);
            copy_button = btn;
            return btn;
        }

        public void show_code (string text, string svg,
                               string ready_status,
                               string render_error_status) {
            code_text = text;
            status_label.label = ready_status;
            code_text_view.buffer.text = text;
            code_text_scroll.visible = true;
            set_copy_sensitive (true);

            try {
                var bytes = new Bytes (svg.data);
                qr_picture.paintable = load_qr_svg (bytes);
                qr_picture.visible = true;
            } catch (Error e) {
                qr_picture.paintable = null;
                qr_picture.visible = false;
                status_label.label = render_error_status + e.message;
            }
        }

        public void set_status (string message) {
            status_label.label = message;
        }

        public void set_copy_sensitive (bool sensitive) {
            if (copy_button != null) copy_button.sensitive = sensitive;
        }

        public void set_qr_opacity (double opacity) {
            qr_picture.opacity = opacity;
        }

        private void copy_to_clipboard () {
            string text = code_text ?? "";
            if (text.length == 0) return;
            get_display ().get_clipboard ().set_text (text);
        }
    }
}
