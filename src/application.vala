namespace Dc {

    [CCode (cname = "gtk_style_context_add_provider_for_display")]
    private extern void add_provider_for_display (
        Gdk.Display display,
        Gtk.StyleProvider provider,
        uint priority
    );

    public class Application : Adw.Application {

        public RpcClient rpc { get; private set; }

        public Application () {
            Object (
                application_id: "io.github.trufae.Parla",
                flags: ApplicationFlags.FLAGS_NONE
            );
        }

        construct {
            rpc = new RpcClient ();
        }

        protected override void activate () {
            var window = active_window;
            if (window == null) {
                window = new Dc.Window (this);
            }
            window.present ();
        }

        protected override void startup () {
            base.startup ();
            load_css ();
            register_icons ();
            Gtk.Window.set_default_icon_name ("io.github.trufae.Parla");

            set_accels_for_action ("win.new-chat", {"<Control>n"});
            set_accels_for_action ("win.refresh", {"<Control>r"});
            set_accels_for_action ("win.settings", {"<Control>comma"});
        }

        private void register_icons () {
            var theme = Gtk.IconTheme.get_for_display (Gdk.Display.get_default ());
            /* Support running uninstalled: add the project data/icons dir */
            try {
                var exe_path = FileUtils.read_link ("/proc/self/exe");
                var exe_dir = File.new_for_path (exe_path).get_parent ();
                /* exe in builddir/ → icons in ../data/icons */
                var project_icons = exe_dir.get_parent ().get_child ("data").get_child ("icons");
                if (project_icons.query_exists ()) {
                    theme.add_search_path (project_icons.get_path ());
                }
            } catch (FileError e) {
                /* not on Linux or unreadable — fall through to installed path */
            }
        }

        private void load_css () {
            var provider = new Gtk.CssProvider ();
            provider.load_from_string (CSS);
            add_provider_for_display (
                Gdk.Display.get_default (),
                provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
        }

        private const string CSS = """
            .message-bubble {
                padding: 8px 12px;
                border-radius: 16px;
                min-width: 60px;
            }
            .message-bubble.incoming {
                background-color: alpha(@view_fg_color, 0.08);
                border-top-left-radius: 4px;
            }
            .message-bubble.outgoing {
                background-color: alpha(@accent_bg_color, 0.5);
                border-bottom-right-radius: 4px;
            }
            .message-sender {
                font-weight: bold;
                font-size: small;
                color: @accent_color;
            }
            .message-time {
                font-size: x-small;
                opacity: 0.55;
                margin-top: 2px;
            }
            .message-attachment { padding: 4px 0; }
            .message-image { border-radius: 12px; margin-top: 4px; }
            .compose-bar { border-top: none; }
            .compose-entry { min-height: 36px; border-radius: 18px; }
            .chat-drop-active {
                background-color: alpha(@accent_bg_color, 0.08);
                box-shadow: inset 0 0 0 2px alpha(@accent_bg_color, 0.45);
            }
            .chat-row { border-radius: 8px; padding: 4px; }
            .current-account-row {
                background-color: alpha(@accent_bg_color, 0.10);
                border-radius: 8px;
            }
            .unread-dot {
                color: @accent_bg_color;
                font-size: 12px;
            }
            .unread-dot-muted {
                color: alpha(@view_fg_color, 0.4);
                font-size: 12px;
            }
            .unread-name {
                font-weight: 800;
            }
            .unread-badge {
                background-color: @accent_bg_color;
                color: @accent_fg_color;
                border-radius: 10px;
                padding: 0 6px;
                min-width: 20px; min-height: 20px;
                font-size: small; font-weight: bold;
            }
            .unread-badge-muted {
                background-color: alpha(@view_fg_color, 0.35);
                color: @view_bg_color;
                border-radius: 10px;
                padding: 0 6px;
                min-width: 20px; min-height: 20px;
                font-size: small; font-weight: bold;
            }
            .contact-request-badge {
                background-color: @warning_bg_color;
                color: @warning_fg_color;
                border-radius: 10px;
                padding: 0 6px;
                min-width: 20px; min-height: 20px;
                font-size: small; font-weight: bold;
            }
            .message-new {
                background-color: alpha(@accent_bg_color, 0.15);
                transition: background-color 2s ease-out;
            }
            .quote-block {
                border-left: 3px solid @accent_bg_color;
                padding: 4px 8px;
                margin-bottom: 4px;
                background-color: alpha(@view_fg_color, 0.05);
                border-radius: 4px;
            }
            .quote-sender {
                font-size: small;
                font-weight: bold;
                color: @accent_color;
            }
            .quote-text {
                font-size: small;
                opacity: 0.75;
            }
            .reply-bar {
                padding: 4px 8px;
                margin-bottom: 4px;
                border-left: 3px solid @accent_bg_color;
                background-color: alpha(@view_fg_color, 0.05);
                border-radius: 4px;
            }
            .reply-label {
                font-size: small;
                opacity: 0.8;
            }
            .pinned-bar {
                background-color: alpha(@accent_bg_color, 0.08);
                border-bottom: 1px solid alpha(@view_fg_color, 0.12);
            }
            /* Delivery / read ticks next to the timestamp. */
            .message-tick {
                font-size: small;
                opacity: 0.60;
                margin-left: 2px;
                letter-spacing: -3px;
            }
            .message-tick-read {
                font-size: small;
                color: @success_color;
                opacity: 1;
                margin-left: 2px;
                letter-spacing: -3px;
            }
            .message-tick-failed {
                font-size: small;
                color: @error_color;
                opacity: 1;
                margin-left: 2px;
            }
            /* Floating "disconnected" pill over the chat area. */
            .connection-banner {
                background-color: alpha(@view_fg_color, 0.80);
                color: @view_bg_color;
                padding: 6px 14px;
                border-radius: 18px;
                box-shadow: 0 2px 8px alpha(@view_fg_color, 0.25);
            }
            .connection-banner-label {
                font-size: small;
            }
        """;
    }
}
