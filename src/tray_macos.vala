namespace Dc {

    /*
     * macOS drop-in for TrayIcon (tray_icon.vala): same signal surface,
     * backed by the NSStatusItem shim in tray_macos.m instead of a
     * StatusNotifierItem. This file is only compiled on macOS builds and
     * tray_icon.vala only elsewhere, so window.vala can pick one with a
     * single #if MACOS around the constructor.
     *
     * macOS has no per-desktop activation tokens, so the token argument
     * of the show/toggle signals is always null and the generic
     * this.present () fallback in window.vala does the work.
     */
    public class MacosTray : Object {

        [CCode (has_target = false)]
        private delegate void RawAction (void* user_data);
        [CCode (has_target = false)]
        private delegate void RawToggle (bool enabled, void* user_data);

        [CCode (cheader_filename = "tray_macos.h",
                cname = "parla_macos_tray_init")]
        private static extern void tray_init (RawAction window_toggle,
                                              RawAction window_show,
                                              RawAction quit,
                                              RawToggle notifications_toggle,
                                              void* user_data);
        [CCode (cheader_filename = "tray_macos.h",
                cname = "parla_macos_tray_show")]
        private static extern bool tray_show ();
        [CCode (cheader_filename = "tray_macos.h",
                cname = "parla_macos_tray_hide")]
        private static extern void tray_hide ();
        [CCode (cheader_filename = "tray_macos.h",
                cname = "parla_macos_tray_set_window_visible")]
        private static extern void tray_set_window_visible (bool visible);
        [CCode (cheader_filename = "tray_macos.h",
                cname = "parla_macos_tray_set_notifications_enabled")]
        private static extern void tray_set_notifications_enabled (bool enabled);

        public signal void show_on_current_desktop_requested (
            string? activation_token);
        public signal void window_toggle_requested (
            string? activation_token);
        public signal void quit_requested ();
        public signal void notifications_toggle_requested (bool enabled);

        /* The shim callbacks carry no closure, so they reach the single
           instance (the window creates exactly one) through this static. */
        private static unowned MacosTray? instance = null;

        public MacosTray () {
            instance = this;
            tray_init (on_raw_window_toggle, on_raw_window_show,
                       on_raw_quit, on_raw_notifications_toggle, null);
        }

        ~MacosTray () {
            if (instance == this) instance = null;
        }

        private static void on_raw_window_toggle (void* user_data) {
            if (instance != null) instance.window_toggle_requested (null);
        }

        private static void on_raw_window_show (void* user_data) {
            if (instance != null) {
                instance.show_on_current_desktop_requested (null);
            }
        }

        private static void on_raw_quit (void* user_data) {
            if (instance != null) instance.quit_requested ();
        }

        private static void on_raw_notifications_toggle (bool enabled,
                                                         void* user_data) {
            if (instance != null) {
                instance.notifications_toggle_requested (enabled);
            }
        }

        public bool show () {
            return tray_show ();
        }

        public void hide () {
            tray_hide ();
        }

        public void set_window_visible (bool window_visible) {
            tray_set_window_visible (window_visible);
        }

        public void set_notifications_enabled (bool enabled) {
            tray_set_notifications_enabled (enabled);
        }
    }
}
