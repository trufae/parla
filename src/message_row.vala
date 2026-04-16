namespace Dc {

    /**
     * A single message bubble in the conversation view.
     * Incoming messages are left-aligned, outgoing messages right-aligned.
     */
    public class MessageRow : Gtk.Box {

        public int message_id { get; private set; }
        public int64 timestamp { get; private set; }
        public bool is_outgoing { get; private set; }
        public string? file_path { get; private set; }
        public string? file_name { get; private set; }
        public string? message_text { get; private set; }
        public int quote_msg_id { get; private set; }
        public bool is_image { get; private set; }

        public signal void quote_clicked (int quoted_msg_id);

        public void highlight () {
            this.add_css_class ("message-new");
            Timeout.add (2000, () => {
                this.remove_css_class ("message-new");
                return Source.REMOVE;
            });
        }

        public MessageRow (Message msg) {
            Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 0);
            this.message_id = msg.id;
            this.timestamp = msg.timestamp;
            this.is_outgoing = msg.is_outgoing;
            this.file_path = msg.file_path;
            this.file_name = msg.file_name;
            this.message_text = msg.text;
            this.quote_msg_id = msg.quote_msg_id;

            /* Info messages (system notifications) get centered styling */
            if (msg.is_info) {
                build_info_row (msg);
                return;
            }

            bool outgoing = msg.is_outgoing;

            /* Margins (applied to this box directly) */
            this.margin_start = 8;
            this.margin_end = 8;
            this.margin_top = 2;
            this.margin_bottom = 2;

            /* Bubble */
            var bubble = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            bubble.add_css_class ("message-bubble");
            bubble.add_css_class (outgoing ? "outgoing" : "incoming");

            /* Sender name (incoming only) */
            if (!outgoing && msg.sender_name != null && msg.sender_name.length > 0) {
                var sender = new Gtk.Label (msg.sender_name);
                sender.add_css_class ("message-sender");
                sender.halign = Gtk.Align.START;
                sender.xalign = 0;
                bubble.append (sender);
            }

            /* Quoted / reply block */
            if (msg.quote_text != null && msg.quote_text.length > 0) {
                var quote_btn = new Gtk.Button ();
                quote_btn.add_css_class ("flat");
                quote_btn.add_css_class ("quote-block");

                var quote_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
                if (msg.quote_sender_name != null && msg.quote_sender_name.length > 0) {
                    var q_sender = new Gtk.Label (msg.quote_sender_name);
                    q_sender.add_css_class ("quote-sender");
                    q_sender.halign = Gtk.Align.START;
                    q_sender.xalign = 0;
                    quote_box.append (q_sender);
                }
                var q_text = new Gtk.Label (msg.quote_text);
                q_text.add_css_class ("quote-text");
                q_text.halign = Gtk.Align.START;
                q_text.xalign = 0;
                q_text.ellipsize = Pango.EllipsizeMode.END;
                q_text.max_width_chars = 40;
                q_text.lines = 2;
                quote_box.append (q_text);

                quote_btn.child = quote_box;
                if (msg.quote_msg_id > 0) {
                    int qid = msg.quote_msg_id;
                    quote_btn.clicked.connect (() => {
                        quote_clicked (qid);
                    });
                }
                bubble.append (quote_btn);
            }

            /* File attachment */
            bool has_file = (msg.file_name != null && msg.file_name.length > 0)
                         || (msg.file_path != null && msg.file_path.length > 0);
            if (has_file) {
                bool image_shown = false;

                /* Try to show inline image preview */
                if (msg.file_path != null &&
                    FileUtils.test (msg.file_path, FileTest.EXISTS) &&
                    is_image_file (msg)) {
                    this.is_image = true;
                    try {
                        var pixbuf = new Gdk.Pixbuf.from_file_at_scale (
                            msg.file_path, 400, 400, true);
                        int dw = pixbuf.width;
                        int dh = pixbuf.height;
                        if (dw > 260) {
                            dh = (int) ((double) dh * 260.0 / (double) dw);
                            dw = 260;
                        }
                        var texture = Gdk.Texture.for_pixbuf (pixbuf);
                        var picture = new Gtk.Picture.for_paintable (texture);
                        picture.content_fit = Gtk.ContentFit.CONTAIN;
                        picture.can_shrink = false;
                        picture.set_size_request (dw, dh);
                        picture.add_css_class ("message-image");
                        bubble.append (picture);
                        image_shown = true;
                    } catch (Error e) {
                        stderr.printf ("  -> Image load failed: %s\n", e.message);
                    }
                }

                /* Show attachment indicator if image wasn't shown */
                if (!image_shown) {
                    bubble.append (build_file_indicator (msg));
                }
            }

            /* Message text */
            if (msg.text != null && msg.text.length > 0) {
                var text = new Gtk.Label (msg.text);
                try {
                    string markup = Markdown.format (msg.text);
                    Pango.AttrList attrs;
                    string parsed;
                    unichar accel;
                    Pango.parse_markup (markup, -1, 0, out attrs, out parsed, out accel);
                    text.set_markup (markup);
                } catch {
                    /* invalid markup — plain text fallback already set */
                }
                text.wrap = true;
                text.wrap_mode = Pango.WrapMode.WORD_CHAR;
                text.halign = Gtk.Align.START;
                text.xalign = 0;
                text.selectable = true;
                text.max_width_chars = 50;
                bubble.append (text);
            }

            /* Timestamp + pin indicator */
            var footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            footer.halign = Gtk.Align.END;
            if (msg.is_pinned) {
                var pin_icon = new Gtk.Label ("📌");
                pin_icon.add_css_class ("message-time");
                footer.append (pin_icon);
            }
            var time_str = format_timestamp (msg.timestamp);
            var time_lbl = new Gtk.Label (time_str);
            time_lbl.add_css_class ("message-time");
            footer.append (time_lbl);
            bubble.append (footer);

            /* Reactions */
            if (msg.reactions != null && msg.reactions.length > 0) {
                var reactions_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
                reactions_box.add_css_class ("reaction-bar");
                reactions_box.halign = Gtk.Align.START;

                var parts = msg.reactions.split (",");
                foreach (string part in parts) {
                    var kv = part.split (":", 2);
                    if (kv.length >= 2) {
                        string emoji_str = kv[0];
                        string count_str = kv[1];
                        string label_text = count_str == "1"
                            ? emoji_str
                            : "%s %s".printf (emoji_str, count_str);
                        var badge = new Gtk.Label (label_text);
                        badge.add_css_class ("reaction-badge");
                        reactions_box.append (badge);
                    }
                }

                bubble.append (reactions_box);
            }

            /* Alignment: outgoing right, incoming left */
            if (outgoing) {
                var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                spacer.hexpand = true;
                this.append (spacer);
            }
            this.append (bubble);
            if (!outgoing) {
                var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                spacer.hexpand = true;
                this.append (spacer);
            }
        }

        private void build_info_row (Message msg) {
            var label = new Gtk.Label (msg.text ?? "");
            label.add_css_class ("dim-label");
            label.add_css_class ("caption");
            label.halign = Gtk.Align.CENTER;
            label.margin_top = 4;
            label.margin_bottom = 4;
            label.wrap = true;
            this.append (label);
        }

        public static bool is_image_file (Message msg) {
            if (msg.file_mime != null && msg.file_mime.has_prefix ("image/"))
                return true;
            if (msg.view_type != null) {
                var vt = msg.view_type.down ();
                if (vt == "image" || vt == "gif" || vt == "sticker")
                    return true;
            }
            if (msg.file_path != null) {
                var lower = msg.file_path.down ();
                if (lower.has_suffix (".jpg") || lower.has_suffix (".jpeg") ||
                    lower.has_suffix (".png") || lower.has_suffix (".webp") ||
                    lower.has_suffix (".gif") || lower.has_suffix (".bmp") ||
                    lower.has_suffix (".svg"))
                    return true;
            }
            return false;
        }

        private static Gtk.Box build_file_indicator (Message msg) {
            var file_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            file_box.add_css_class ("message-attachment");

            var icon = new Gtk.Image.from_icon_name ("mail-attachment-symbolic");
            icon.pixel_size = 16;
            file_box.append (icon);

            var fname = new Gtk.Label (msg.file_name ?? "file");
            fname.add_css_class ("dim-label");
            fname.ellipsize = Pango.EllipsizeMode.MIDDLE;
            fname.max_width_chars = 28;
            file_box.append (fname);

            return file_box;
        }

        private static string format_timestamp (int64 ts) {
            if (ts <= 0) return "";
            var dt = new DateTime.from_unix_local (ts);
            return dt.format ("%H:%M");
        }

    }

    public class ImageViewer : Object {

        public Gtk.Box widget { get; private set; }

        private unowned Window? window = null;
        private Gtk.Picture picture;
        private string? current_path = null;

        public bool visible {
            get { return widget.visible; }
        }

        public ImageViewer () {
            picture = new Gtk.Picture ();
            picture.content_fit = Gtk.ContentFit.CONTAIN;
            picture.hexpand = true;
            picture.vexpand = true;

            widget = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            widget.add_css_class ("image-viewer-overlay");
            widget.hexpand = true;
            widget.vexpand = true;
            widget.append (picture);
            widget.visible = false;

            var click = new Gtk.GestureClick ();
            click.button = 1;
            click.pressed.connect (() => { hide (); });
            widget.add_controller (click);

            var right_click = new Gtk.GestureClick ();
            right_click.button = 3;
            right_click.pressed.connect ((n, x, y) => {
                show_menu (x, y);
            });
            widget.add_controller (right_click);
        }

        public void set_window (Window w) { this.window = w; }

        public void show (string path) {
            try {
                var texture = Gdk.Texture.from_filename (path);
                picture.paintable = texture;
                current_path = path;
                widget.visible = true;
                widget.grab_focus ();
            } catch (Error e) {
                if (window != null) window.show_toast ("Cannot open image: " + e.message);
            }
        }

        public void hide () {
            widget.visible = false;
            picture.paintable = null;
            current_path = null;
        }

        private void show_menu (double x, double y) {
            if (current_path == null) return;
            string path = current_path;

            var popover = new Gtk.Popover ();
            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            vbox.margin_start = 4;
            vbox.margin_end = 4;
            vbox.margin_top = 4;
            vbox.margin_bottom = 4;

            var save_btn = new Gtk.Button.with_label ("Save image");
            save_btn.add_css_class ("flat");
            save_btn.clicked.connect (() => {
                popover.popdown ();
                if (window != null) window.save_attachment.begin (path, Path.get_basename (path));
            });
            vbox.append (save_btn);

            popover.child = vbox;
            popover.set_parent (widget);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
        }
    }
}
