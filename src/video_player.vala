namespace Dc {

    /**
     * Fullscreen video overlay shown on top of the conversation, mirroring
     * ImageViewer. Plays the file with Gtk.Video's built-in controls; Escape
     * or the close button dismisses it, and right-click offers "Save video".
     */
    public class VideoPlayer : Object {

        public Gtk.Widget widget { get; private set; }

        private unowned Window? window = null;
        private Gtk.Video video;
        private Gtk.Label error_label;
        private ulong error_handler = 0;
        private string? current_path = null;
        private string? current_name = null;

        public bool visible {
            get { return widget.visible; }
        }

        public VideoPlayer () {
            video = new Gtk.Video ();
            video.autoplay = true;
            video.hexpand = true;
            video.vexpand = true;
            video.halign = Gtk.Align.FILL;
            video.valign = Gtk.Align.FILL;
            video.margin_top = 24;
            video.margin_bottom = 24;
            video.margin_start = 24;
            video.margin_end = 24;

            var overlay = new Gtk.Overlay ();
            overlay.add_css_class ("image-viewer-overlay");
            overlay.hexpand = true;
            overlay.vexpand = true;
            overlay.child = video;
            overlay.focusable = true;
            overlay.can_focus = true;
            overlay.visible = false;

            error_label = new Gtk.Label (null);
            error_label.add_css_class ("osd");
            error_label.wrap = true;
            error_label.max_width_chars = 60;
            error_label.halign = Gtk.Align.CENTER;
            error_label.valign = Gtk.Align.CENTER;
            error_label.margin_start = 24;
            error_label.margin_end = 24;
            error_label.visible = false;
            overlay.add_overlay (error_label);

            var close_btn = new Gtk.Button ();
            close_btn.icon_name = "window-close-symbolic";
            close_btn.add_css_class ("circular");
            close_btn.add_css_class ("osd");
            close_btn.halign = Gtk.Align.END;
            close_btn.valign = Gtk.Align.START;
            close_btn.margin_top = 12;
            close_btn.margin_end = 12;
            close_btn.clicked.connect (() => { hide (); });
            overlay.add_overlay (close_btn);

            widget = overlay;
        }

        public void set_window (Window w) {
            this.window = w;
            var context_menu = new ContextMenuGestures (widget, w.settings);
            context_menu.requested.connect ((x, y, long_press) => show_menu (x, y));
        }

        public void show (string path, string? name) {
            hide ();
            current_path = path;
            current_name = name;
#if MACOS
            video.set_media_stream (native_video_stream (path));
#else
            video.set_filename (path);
#endif
            video.visible = true;
            widget.visible = true;
            widget.grab_focus ();
            var ms = video.get_media_stream ();
            if (ms != null) {
                error_handler = ms.notify["error"].connect (show_error);
                show_error ();
                ms.set_playing (true);
            }
        }

#if MACOS
        [CCode (cheader_filename = "platform.h", cname = "parla_video_stream_new")]
        private static extern Gtk.MediaStream native_video_stream (string path);
#endif

        private void show_error () {
            var ms = video.get_media_stream ();
            if (ms == null || ms.error == null) return;
            error_label.label = _("Could not play video") + "\n" + ms.error.message;
            error_label.visible = true;
            video.visible = false;
        }

        public void hide () {
            var ms = video.get_media_stream ();
            if (ms != null) {
                if (error_handler != 0) ms.disconnect (error_handler);
                ms.pause ();
            }
            error_handler = 0;
            video.set_media_stream (null);
            error_label.visible = false;
            widget.visible = false;
            current_path = null;
            current_name = null;
        }

        /**
         * Called by Window's key handler while the player is visible. Escape
         * (or q) closes; space toggles play/pause. Any other key is swallowed
         * so conversation shortcuts don't fire behind the overlay.
         */
        public bool handle_key (uint keyval) {
            switch (keyval) {
            case Gdk.Key.Escape:
            case Gdk.Key.q:
            case Gdk.Key.Q:
                hide ();
                return true;
            case Gdk.Key.space:
                var ms = video.get_media_stream ();
                if (ms != null) {
                    ms.set_playing (!ms.playing);
                }
                return true;
            }
            return true;
        }

        private bool show_menu (double x, double y) {
            if (current_path == null) return false;
            string path = current_path;
            string? name = current_name;

            var popover = new Gtk.Popover ();
            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            vbox.margin_start = 4;
            vbox.margin_end = 4;
            vbox.margin_top = 4;
            vbox.margin_bottom = 4;
            var save_btn = new PopoverButton (popover, _("Save video"));
            save_btn.selected.connect (() => {
                if (window != null)
                    window.save_attachment.begin (path,
                        name ?? Path.get_basename (path));
            });
            vbox.append (save_btn);

            popover.child = vbox;
            popover.set_parent (widget);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            unparent_on_close (popover);
            popover.popup ();
            return true;
        }
    }
}
