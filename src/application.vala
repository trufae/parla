namespace Dc {

    public class Application : Adw.Application {

        public RpcClient rpc { get; private set; }

        public Application () {
            Object (
                application_id: "org.deltachat.Gnome",
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
        }

        private void load_css () {
            var provider = new Gtk.CssProvider ();
            provider.load_from_string (CSS);
            Gtk.StyleContext.add_provider_for_display (
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
                background-color: @accent_bg_color;
                color: @accent_fg_color;
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
            .compose-bar { border-top: 1px solid alpha(@view_fg_color, 0.12); }
            .compose-entry { min-height: 36px; border-radius: 18px; }
            .chat-row { border-radius: 8px; padding: 4px; }
            .unread-badge {
                background-color: @accent_bg_color;
                color: @accent_fg_color;
                border-radius: 10px;
                padding: 0 6px;
                min-width: 20px; min-height: 20px;
                font-size: small; font-weight: bold;
            }
            .message-new {
                background-color: alpha(@accent_bg_color, 0.15);
                transition: background-color 2s ease-out;
            }
        """;
    }
}
