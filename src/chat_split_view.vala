namespace Dc {

    /* OverlaySplitView intentionally supports only edge swipes on a
       touchscreen. Use NavigationView for the phone layout so going back
       works across the whole page, including with a two-finger touchpad
       scroll. Keep the overlay layout for desktop sidebar sizing/hiding. */
    public class ChatSplitView : Adw.Bin {
        public Adw.OverlaySplitView desktop { get; private set; }
        private Adw.NavigationView navigation;
        private Adw.NavigationPage sidebar_page;
        private Adw.NavigationPage content_page;
        private Gtk.Widget sidebar;
        private Gtk.Widget content;
        private bool _collapsed = false;
        private bool changing_layout = false;

        public bool collapsed {
            get { return _collapsed; }
            set {
                if (_collapsed == value) return;
                bool was_showing_sidebar = show_sidebar;
                var root = get_root ();
                Gtk.Widget? focus = root != null ? root.get_focus () : null;
                if (focus != null && !focus.is_ancestor (this)) focus = null;

                changing_layout = true;
                _collapsed = value;
                child = null;
                if (value) {
                    desktop.sidebar = null;
                    desktop.content = null;
                    sidebar_page.child = sidebar;
                    content_page.child = content;
                    navigation.replace (was_showing_sidebar
                        ? new Adw.NavigationPage[] { sidebar_page }
                        : new Adw.NavigationPage[] { sidebar_page, content_page });
                    child = navigation;
                } else {
                    navigation.replace ({ sidebar_page });
                    sidebar_page.child = null;
                    content_page.child = null;
                    desktop.sidebar = sidebar;
                    desktop.content = content;
                    desktop.show_sidebar = was_showing_sidebar;
                    child = desktop;
                }
                changing_layout = false;
                if (focus != null && focus.get_mapped ()) focus.grab_focus ();
            }
        }

        [CCode (notify = false)]
        public bool show_sidebar {
            get {
                return collapsed ? navigation.visible_page == sidebar_page
                                 : desktop.show_sidebar;
            }
            set {
                if (show_sidebar == value) return;
                if (!collapsed) desktop.show_sidebar = value;
                else if (value) navigation.pop_to_page (sidebar_page);
                else navigation.push (content_page);
            }
        }

        public ChatSplitView (Gtk.Widget sidebar, Gtk.Widget content) {
            this.sidebar = sidebar;
            this.content = content;
            sidebar_page = new Adw.NavigationPage (sidebar, _("Chats"));
            content_page = new Adw.NavigationPage (content, _("Conversation"));
            sidebar_page.child = null;
            content_page.child = null;
            navigation = new Adw.NavigationView ();
            // Escape belongs to conversation search, selection and composer.
            navigation.pop_on_escape = false;
            navigation.add (sidebar_page);
            navigation.add (content_page);
            navigation.notify["visible-page"].connect (() => {
                if (collapsed && !changing_layout) notify_property ("show-sidebar");
            });

            desktop = new Adw.OverlaySplitView ();
            desktop.sidebar = sidebar;
            desktop.content = content;
            desktop.notify["show-sidebar"].connect (() => {
                if (!collapsed && !changing_layout) notify_property ("show-sidebar");
            });
            child = desktop;
        }
    }
}
