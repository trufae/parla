namespace Dc {

    /**
     * Fullscreen image overlay shown on top of the conversation.
     * Supports navigating prev/next image in the current conversation
     * via arrow keys, hjkl, or the floating circular buttons.
     * Any other key or click closes the viewer.
     */
    public class ImageViewer : Object {

        public Gtk.Widget widget { get; private set; }

        private unowned Window? window = null;
        private Gtk.Picture picture;
        private Gtk.Button prev_btn;
        private Gtk.Button next_btn;

        private string[] paths = {};
        private int index = -1;

        public bool visible {
            get { return widget.visible; }
        }

        public ImageViewer () {
            picture = new Gtk.Picture ();
            picture.content_fit = Gtk.ContentFit.CONTAIN;
            picture.hexpand = true;
            picture.vexpand = true;

            var overlay = new Gtk.Overlay ();
            overlay.add_css_class ("image-viewer-overlay");
            overlay.hexpand = true;
            overlay.vexpand = true;
            overlay.child = picture;
            overlay.focusable = true;
            overlay.can_focus = true;
            overlay.visible = false;

            prev_btn = new Gtk.Button ();
            prev_btn.icon_name = "go-previous-symbolic";
            prev_btn.add_css_class ("circular");
            prev_btn.add_css_class ("osd");
            prev_btn.halign = Gtk.Align.START;
            prev_btn.valign = Gtk.Align.CENTER;
            prev_btn.margin_start = 12;
            prev_btn.visible = false;
            prev_btn.clicked.connect (() => { go_prev (); });
            overlay.add_overlay (prev_btn);

            next_btn = new Gtk.Button ();
            next_btn.icon_name = "go-next-symbolic";
            next_btn.add_css_class ("circular");
            next_btn.add_css_class ("osd");
            next_btn.halign = Gtk.Align.END;
            next_btn.valign = Gtk.Align.CENTER;
            next_btn.margin_end = 12;
            next_btn.visible = false;
            next_btn.clicked.connect (() => { go_next (); });
            overlay.add_overlay (next_btn);

            widget = overlay;

            /* Left click anywhere (outside the buttons) closes. */
            var click = new Gtk.GestureClick ();
            click.button = 1;
            click.pressed.connect ((n, x, y) => {
                /* Don't close if the click landed on a navigation button. */
                var picked = widget.pick (x, y, Gtk.PickFlags.DEFAULT);
                for (var w = picked; w != null; w = w.get_parent ()) {
                    if (w == prev_btn || w == next_btn) return;
                }
                hide ();
            });
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
            string[] one = { path };
            show_list (one, 0);
        }

        public void show_list (string[] image_paths, int start_index) {
            if (image_paths.length == 0) return;
            if (start_index < 0 || start_index >= image_paths.length) start_index = 0;
            this.paths = image_paths;
            this.index = start_index;
            if (!load_current ()) return;
            widget.visible = true;
            widget.grab_focus ();
        }

        public void hide () {
            widget.visible = false;
            picture.paintable = null;
            paths = {};
            index = -1;
            update_nav_buttons ();
        }

        /**
         * Called by Window's key handler while the viewer is visible.
         * Returns true if the event was handled by the viewer (either
         * navigation or closing). Any non-navigation key closes.
         */
        public bool handle_key (uint keyval) {
            switch (keyval) {
            case Gdk.Key.Left:
            case Gdk.Key.h:
            case Gdk.Key.H:
            case Gdk.Key.k:
            case Gdk.Key.K:
            case Gdk.Key.Up:
                go_prev ();
                return true;
            case Gdk.Key.Right:
            case Gdk.Key.l:
            case Gdk.Key.L:
            case Gdk.Key.j:
            case Gdk.Key.J:
            case Gdk.Key.Down:
                go_next ();
                return true;
            }
            hide ();
            return true;
        }

        private void go_prev () {
            if (index <= 0) return;
            index--;
            load_current ();
        }

        private void go_next () {
            if (index < 0 || index >= paths.length - 1) return;
            index++;
            load_current ();
        }

        private bool load_current () {
            if (index < 0 || index >= paths.length) return false;
            string path = paths[index];
            try {
                var texture = Gdk.Texture.from_filename (path);
                picture.paintable = texture;
                update_nav_buttons ();
                return true;
            } catch (Error e) {
                if (window != null) window.show_toast ("Cannot open image: " + e.message);
                return false;
            }
        }

        private void update_nav_buttons () {
            prev_btn.visible = index > 0;
            next_btn.visible = index >= 0 && index < paths.length - 1;
        }

        private void show_menu (double x, double y) {
            if (index < 0 || index >= paths.length) return;
            string path = paths[index];

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
