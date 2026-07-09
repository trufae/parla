namespace Dc {

    [DBus (name = "org.kde.StatusNotifierWatcher")]
    private interface StatusNotifierWatcher : Object {
        public abstract void register_status_notifier_item (
            string service) throws GLib.Error;
    }

    [DBus (name = "org.kde.StatusNotifierItem")]
    private class StatusNotifierItem : Object {
        private const string ICON_NAME = "parla-tray";
        private const string ICON_RESOURCE =
            "/io/github/trufae/Parla/icons/scalable/apps/parla-tray.svg";

        private Variant _icon_pixmap;

        public StatusNotifierItem () {
            _icon_pixmap = build_pixmaps ();
        }

        private static Variant build_pixmaps () {
            var b = new VariantBuilder (new VariantType ("a(iiay)"));
            foreach (int size in new int[] { 22, 24, 32, 48 }) {
                append_pixmap (b, size);
            }
            return b.end ();
        }

        private static void append_pixmap (VariantBuilder b, int size) {
            try {
                var pix = new Gdk.Pixbuf.from_resource_at_scale (
                    ICON_RESOURCE, size, size, true);
                if (!pix.get_has_alpha ()) {
                    pix = pix.add_alpha (false, 0, 0, 0);
                }
                int w = pix.get_width ();
                int h = pix.get_height ();
                int stride = pix.get_rowstride ();
                int channels = pix.get_n_channels ();
                unowned uint8[] src = pix.get_pixels ();

                var bytes = new uint8[w * h * 4];
                int o = 0;
                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        int p = y * stride + x * channels;
                        bytes[o++] = (channels == 4) ? src[p + 3] : 255;
                        bytes[o++] = src[p];
                        bytes[o++] = src[p + 1];
                        bytes[o++] = src[p + 2];
                    }
                }
                b.add ("(ii@ay)", w, h,
                    new Variant.from_bytes (new VariantType ("ay"),
                        new Bytes (bytes), true));
            } catch (Error e) {
                info ("tray pixmap %dpx unavailable: %s", size, e.message);
            }
        }

        public string category { owned get { return "Communications"; } }
        public string id { owned get { return "parla"; } }
        public string title { owned get { return "Parla"; } }
        public string status { owned get { return "Active"; } }
        public uint32 window_id { get { return 0; } }
        public string icon_name { owned get { return _icon_pixmap.n_children () > 0 ? "" : ICON_NAME; } }
        public string icon_theme_path { owned get { return ""; } }
        [DBus (signature = "a(iiay)")]
        public Variant icon_pixmap { owned get { return _icon_pixmap; } }
        public string overlay_icon_name { owned get { return ""; } }
        public string attention_icon_name { owned get { return ""; } }
        public string attention_movie_name { owned get { return ""; } }
        public bool item_is_menu { get { return false; } }
        public ObjectPath menu { owned get { return new ObjectPath ("/MenuBar"); } }

        public signal void new_title ();
        public signal void new_icon ();
        public signal void new_attention_icon ();
        public signal void new_overlay_icon ();
        public signal void new_status (string status);

        [DBus (visible = false)]
        public signal void activate_requested ();

        public void context_menu (int x, int y) throws GLib.Error { }
        public void activate (int x, int y) throws GLib.Error {
            activate_requested ();
        }
        public void secondary_activate (int x, int y) throws GLib.Error {
            activate_requested ();
        }
        public void scroll (int delta, string orientation) throws GLib.Error { }
    }

    [DBus (name = "com.canonical.dbusmenu")]
    private class TrayMenu : Object {
        private const int32 ID_SHOW = 1;
        private const int32 ID_NOTIFY = 2;
        private const int32 ID_QUIT = 3;

        private bool notifications_on = true;
        private uint32 revision = 1;

        public uint32 version { get { return 3; } }
        public string text_direction { owned get { return "ltr"; } }
        public string status { owned get { return "normal"; } }
        public string[] icon_theme_path { owned get { return new string[0]; } }

        public signal void layout_updated (uint32 revision, int32 parent);

        [DBus (visible = false)]
        public signal void show_requested ();
        [DBus (visible = false)]
        public signal void quit_requested ();
        [DBus (visible = false)]
        public signal void notifications_toggle_requested (bool enabled);

        [DBus (visible = false)]
        public void set_notifications_enabled (bool enabled) {
            if (notifications_on == enabled) return;
            notifications_on = enabled;
            revision++;
            layout_updated (revision, 0);
        }

        private static string label_for (int32 id) {
            switch (id) {
            case ID_SHOW: return "Show Parla";
            case ID_NOTIFY: return "Notifications";
            default: return "Quit";
            }
        }

        private Variant item_props (int32 id) {
            var props = new VariantBuilder (new VariantType ("a{sv}"));
            if (id == 0) {
                props.add ("{sv}", "children-display",
                    new Variant.string ("submenu"));
            } else {
                props.add ("{sv}", "label", new Variant.string (label_for (id)));
                props.add ("{sv}", "enabled", new Variant.boolean (true));
                props.add ("{sv}", "visible", new Variant.boolean (true));
                if (id == ID_NOTIFY) {
                    props.add ("{sv}", "toggle-type",
                        new Variant.string ("checkmark"));
                    props.add ("{sv}", "toggle-state",
                        new Variant.int32 (notifications_on ? 1 : 0));
                }
            }
            return props.end ();
        }

        private Variant layout_node (int32 id) {
            var children = new VariantBuilder (new VariantType ("av"));
            if (id == 0) {
                children.add ("v", layout_node (ID_SHOW));
                children.add ("v", layout_node (ID_NOTIFY));
                children.add ("v", layout_node (ID_QUIT));
            }
            return new Variant ("(i@a{sv}@av)",
                id, item_props (id), children.end ());
        }

        public void get_layout (int32 parent_id, int32 recursion_depth,
                                string[] property_names,
                                out uint32 revision,
                                [DBus (signature = "(ia{sv}av)")]
                                out Variant layout) throws GLib.Error {
            revision = this.revision;
            layout = layout_node (parent_id == 0 ? 0 : parent_id);
        }

        public void get_group_properties (int32[] ids, string[] property_names,
                                          [DBus (signature = "a(ia{sv})")]
                                          out Variant props) throws GLib.Error {
            var b = new VariantBuilder (new VariantType ("a(ia{sv})"));
            int32[] wanted = (ids.length == 0)
                ? new int32[] { ID_SHOW, ID_NOTIFY, ID_QUIT }
                : ids;
            foreach (int32 id in wanted) {
                if (id == ID_SHOW || id == ID_NOTIFY || id == ID_QUIT) {
                    b.add ("(i@a{sv})", id, item_props (id));
                }
            }
            props = b.end ();
        }

        [DBus (name = "GetProperty")]
        public void get_dbus_property (int32 id, string name,
                                       out Variant value) throws GLib.Error {
            if (name == "label") {
                value = new Variant.variant (new Variant.string (label_for (id)));
            } else {
                value = new Variant.variant (new Variant.boolean (true));
            }
        }

        public void event (int32 id, string event_id, Variant data,
                           uint32 timestamp) throws GLib.Error {
            if (event_id != "clicked") return;
            switch (id) {
            case ID_SHOW:
                show_requested ();
                break;
            case ID_NOTIFY:
                notifications_toggle_requested (!notifications_on);
                break;
            case ID_QUIT:
                quit_requested ();
                break;
            }
        }

        public bool about_to_show (int32 id) throws GLib.Error {
            return false;
        }

        /* Batch variants XFCE/KDE panels call instead of the singular
           AboutToShow/Event that GNOME uses. The menu is static, so no item
           ever needs updating and no event can fail: both error lists stay
           empty and EventGroup just fans out to the existing event handler. */
        public void about_to_show_group (int32[] ids,
                                         out int32[] updates_needed,
                                         out int32[] id_errors) throws GLib.Error {
            updates_needed = new int32[0];
            id_errors = new int32[0];
        }

        public void event_group (
                [DBus (signature = "a(isvu)")] Variant events,
                out int32[] id_errors) throws GLib.Error {
            VariantIter iter = events.iterator ();
            int32 id;
            string event_id;
            Variant data;
            uint32 timestamp;
            while (iter.next ("(isvu)", out id, out event_id, out data, out timestamp)) {
                event (id, event_id, data, timestamp);
            }
            id_errors = new int32[0];
        }
    }

    public class TrayIcon : Object {
        private const string ITEM_PATH = "/StatusNotifierItem";
        private const string MENU_PATH = "/MenuBar";

        private DBusConnection conn;
        private StatusNotifierItem item;
        private TrayMenu menu;
        private uint item_reg = 0;
        private uint menu_reg = 0;
        private uint name_own = 0;
        private bool visible = false;

        public signal void show_requested ();
        public signal void quit_requested ();
        public signal void notifications_toggle_requested (bool enabled);

        public TrayIcon (DBusConnection connection) {
            conn = connection;
            item = new StatusNotifierItem ();
            menu = new TrayMenu ();
            item.activate_requested.connect (() => {
                emit_on_main (() => { show_requested (); });
            });
            menu.show_requested.connect (() => {
                emit_on_main (() => { show_requested (); });
            });
            menu.quit_requested.connect (() => {
                emit_on_main (() => { quit_requested (); });
            });
            menu.notifications_toggle_requested.connect ((v) => {
                emit_on_main (() => { notifications_toggle_requested (v); });
            });
        }

        private void emit_on_main (owned VoidFunc action) {
            Idle.add (() => {
                action ();
                return Source.REMOVE;
            });
        }

        public void set_notifications_enabled (bool enabled) {
            menu.set_notifications_enabled (enabled);
        }

        public bool show () {
            if (visible) return true;
            try {
                item_reg = conn.register_object (ITEM_PATH, item);
                menu_reg = conn.register_object (MENU_PATH, menu);
            } catch (Error e) {
                warning ("Failed to export tray objects: %s", e.message);
                return false;
            }
            visible = true;

            string name = "org.kde.StatusNotifierItem-%d-1".printf (
                (int) Posix.getpid ());
            name_own = Bus.own_name_on_connection (
                conn, name, BusNameOwnerFlags.NONE,
                (c, n) => { register_with_watcher.begin (n); },
                (c, n) => { });
            return true;
        }

        public void hide () {
            if (!visible) return;
            visible = false;
            if (name_own != 0) {
                Bus.unown_name (name_own);
                name_own = 0;
            }
            if (item_reg != 0) {
                conn.unregister_object (item_reg);
                item_reg = 0;
            }
            if (menu_reg != 0) {
                conn.unregister_object (menu_reg);
                menu_reg = 0;
            }
        }

        private async void register_with_watcher (string name) {
            try {
                StatusNotifierWatcher watcher = yield Bus.get_proxy (
                    BusType.SESSION,
                    "org.kde.StatusNotifierWatcher",
                    "/StatusNotifierWatcher");
                watcher.register_status_notifier_item (name);
            } catch (Error e) {
                info ("StatusNotifierWatcher unavailable: %s", e.message);
            }
        }
    }
}
