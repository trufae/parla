namespace Dc {

    /** Offer the actual file to other chats and desktop file managers. */
    public class FileDragSource : Object {
        public static void attach (Gtk.Widget widget, Message message) {
            if (!message.has_local_file) return;

            var source = new Gtk.DragSource ();
            source.actions = Gdk.DragAction.COPY;
            source.button = Gdk.BUTTON_PRIMARY;
            source.prepare.connect ((x, y) => {
                if (message.selection_visible || !message.has_local_file)
                    return null;

                var file = File.new_for_path (message.file_path);
                var value = Value (typeof (Gdk.FileList));
                value.set_boxed (new Gdk.FileList.from_array ({ file }));
                // Keep a URI representation for external destinations as well
                // as the typed file list used for drops within GTK.
                return new Gdk.ContentProvider.union ({
                    new Gdk.ContentProvider.for_value (value),
                    new Gdk.ContentProvider.for_bytes ("text/uri-list",
                        new Bytes ((file.get_uri () + "\r\n").data))
                });
            });
            var icon = Gtk.IconTheme.get_for_display (widget.get_display ())
                .lookup_icon ("mail-attachment-symbolic", null, 48,
                    widget.get_scale_factor (), widget.get_direction (),
                    Gtk.IconLookupFlags.PRELOAD);
            source.set_icon (icon, 0, 0);
            widget.add_controller (source);
        }
    }

    public class FileDropTarget : Object {
        private const string URI_LIST_MIME_TYPE = "text/uri-list";

        private unowned Gtk.Widget widget;
        private string active_css_class;

        public signal bool accept ();
        public signal void dropped (string path, string name);
        public signal void failed (string message);

        public FileDropTarget (Gtk.Widget widget,
                               string active_css_class = "chat-drop-active") {
            this.widget = widget;
            this.active_css_class = active_css_class;
            install ();
        }

        private void install () {
            var drop = new Gtk.DropTargetAsync (content_formats (),
                                                Gdk.DragAction.COPY);
            drop.accept.connect ((gdk_drop) => {
                return can_accept (gdk_drop);
            });
            drop.drag_enter.connect ((gdk_drop, x, y) => {
                var action = action_for (gdk_drop);
                if (action != (Gdk.DragAction) 0)
                    widget.add_css_class (active_css_class);
                return action;
            });
            drop.drag_motion.connect ((gdk_drop, x, y) => {
                return action_for (gdk_drop);
            });
            drop.drag_leave.connect ((gdk_drop) => {
                widget.remove_css_class (active_css_class);
            });
            drop.drop.connect ((gdk_drop, x, y) => {
                widget.remove_css_class (active_css_class);
                if (!can_accept (gdk_drop)) return false;
                handle_drop.begin (gdk_drop);
                return true;
            });
            widget.add_controller (drop);
        }

        private Gdk.ContentFormats? content_formats () {
            if (Platform.is_macos ()) return null;

            var formats = new Gdk.ContentFormatsBuilder ();
            formats.add_gtype (typeof (GLib.File));
            formats.add_gtype (typeof (Gdk.FileList));
            formats.add_mime_type (URI_LIST_MIME_TYPE);
            return formats.to_formats ();
        }

        private bool can_accept (Gdk.Drop drop) {
            if (!accept () || preferred_action (drop) == (Gdk.DragAction) 0)
                return false;

            /* Finder can advertise useful pasteboard types before GTK can
               deserialize them, so macOS is accepted optimistically and
               validated when the payload is read. */
            if (Platform.is_macos ()) return true;

            var formats = drop.get_formats ();
            return formats.contain_gtype (typeof (GLib.File))
                || formats.contain_gtype (typeof (Gdk.FileList))
                || formats.contain_mime_type (URI_LIST_MIME_TYPE);
        }

        private Gdk.DragAction action_for (Gdk.Drop drop) {
            return can_accept (drop) ? preferred_action (drop)
                                     : (Gdk.DragAction) 0;
        }

        private Gdk.DragAction preferred_action (Gdk.Drop drop) {
            return (drop.get_actions () & Gdk.DragAction.COPY) != 0
                ? Gdk.DragAction.COPY
                : (Gdk.DragAction) 0;
        }

        private async void handle_drop (Gdk.Drop drop) {
            bool ok = false;
            try {
                var file = yield read_file (drop);
                if (file == null) {
                    failed (_("unsupported drop data"));
                } else {
                    ok = yield emit_local_file (file);
                }
            } catch (Error e) {
                failed (e.message);
            } finally {
                drop.finish (ok ? Gdk.DragAction.COPY : (Gdk.DragAction) 0);
            }
        }

        private async bool emit_local_file (GLib.File file) throws Error {
            string? path = file.get_path ();
            string name = file.get_basename () ?? "attachment";
            if (path == null) {
                GLib.FileIOStream stream;
                var tmp = GLib.File.new_tmp ("parla-XXXXXX", out stream);
                stream.close ();
                yield file.copy_async (tmp, FileCopyFlags.OVERWRITE,
                                       Priority.DEFAULT, null, null);
                path = tmp.get_path ();
            }

            if (path == null) {
                failed (_("file has no local path"));
                return false;
            }
            dropped (path, name);
            return true;
        }

        private async GLib.File? read_file (Gdk.Drop drop) throws Error {
            if (Platform.is_macos ()) {
                try {
                    var file = yield read_uri_list_file (drop);
                    if (file != null) return file;
                } catch (Error e) {
                }
            }

            var formats = drop.get_formats ();
            if (formats.contain_gtype (typeof (GLib.File))) {
                try {
                    var file = yield read_file_value (drop);
                    if (file != null) return file;
                } catch (Error e) {
                    if (!formats.contain_gtype (typeof (Gdk.FileList))
                        && !formats.contain_mime_type (URI_LIST_MIME_TYPE)) {
                        throw e;
                    }
                }
            }

            if (formats.contain_gtype (typeof (Gdk.FileList))) {
                try {
                    var file = yield read_file_list (drop);
                    if (file != null) return file;
                } catch (Error e) {
                    if (!formats.contain_mime_type (URI_LIST_MIME_TYPE)) {
                        throw e;
                    }
                }
            }

            return yield read_uri_list_file (drop);
        }

        private async GLib.File? read_file_value (Gdk.Drop drop) throws Error {
            var value = yield drop.read_value_async (typeof (GLib.File),
                                                     Priority.DEFAULT, null);
            var obj = value == null ? null : value.dup_object ();
            return obj as GLib.File;
        }

        private async GLib.File? read_file_list (Gdk.Drop drop) throws Error {
            var value = yield drop.read_value_async (typeof (Gdk.FileList),
                                                     Priority.DEFAULT, null);
            var fl = value == null ? null : (Gdk.FileList?) value.get_boxed ();
            GLib.SList<weak GLib.File>? files = null;
            if (fl != null) files = fl.get_files ();
            if (files == null || files.data == null) return null;

            unowned GLib.File borrowed = files.data;
            return (GLib.File) borrowed.ref ();
        }

        private async GLib.File? read_uri_list_file (Gdk.Drop drop) throws Error {
            var formats = drop.get_formats ();
            if (!formats.contain_mime_type (URI_LIST_MIME_TYPE)) return null;

            string[] mime_types = { URI_LIST_MIME_TYPE };
            unowned string out_mime_type;
            var stream = yield drop.read_async (mime_types, Priority.DEFAULT,
                                                null, out out_mime_type);
            if (stream == null) return null;

            var data = new DataInputStream (stream);
            string? line;
            while ((line = yield data.read_line_utf8_async (Priority.DEFAULT,
                                                            null)) != null) {
                string uri = line.strip ();
                if (uri.length == 0 || uri.has_prefix ("#")) continue;
                return GLib.File.new_for_uri (uri);
            }
            return null;
        }
    }

    public class NativeFileDropTarget : Object {
        private unowned Gtk.Widget widget;

        public signal void path_dropped (string path, double x, double y);

        public NativeFileDropTarget (Gtk.Widget widget) {
            this.widget = widget;
            widget.map.connect (install);
        }

        private void install () {
            Platform.install_macos_file_drop_handler (
                widget, on_path_dropped, this);
        }

        private static void on_path_dropped (string path, double x, double y,
                                             void* user_data) {
            unowned NativeFileDropTarget self = (NativeFileDropTarget) user_data;
            self.path_dropped (path, x, y);
        }
    }
}
