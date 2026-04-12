namespace Dc {

    public class ImageViewer : Object {

        public Gtk.Box widget { get; private set; }

        private Gtk.Picture picture;
        private string? current_path = null;

        public signal void save_requested (string path, string name);
        public signal void toast_requested (string message);

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

        public void show (string path) {
            try {
                var texture = Gdk.Texture.from_filename (path);
                picture.paintable = texture;
                current_path = path;
                widget.visible = true;
                widget.grab_focus ();
            } catch (Error e) {
                toast_requested ("Cannot open image: " + e.message);
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
                save_requested (path, Path.get_basename (path));
            });
            vbox.append (save_btn);

            popover.child = vbox;
            popover.set_parent (widget);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
        }
    }
}
