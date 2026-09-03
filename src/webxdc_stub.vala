/* No-op stand-in for webxdc.vala, compiled when -Dwebxdc=false so the rest
 * of the code links without WebKitGTK. */
namespace Dc.Webxdc {

    public const bool AVAILABLE = false;

    public class CardInfo {
        public string? name;
        public Gdk.Texture? icon;
    }

    public class Monitor : Object {
        public signal void changed (int msg_id);
        private static Monitor? instance = null;
        public static Monitor get_default () {
            if (instance == null) instance = new Monitor ();
            return instance;
        }
    }

    public void setup (RpcClient rpc, SettingsManager settings) { }

    public bool enabled () { return false; }

    public async CardInfo card_info (int msg_id) { return new CardInfo (); }

    public void open (Gtk.Window? parent, RpcClient rpc, Message msg) { }

    public void status_update (int msg_id) { }

    public void instance_deleted (int msg_id) { }

    public void set_active_chat (int account_id, int chat_id,
                                 bool window_visible) { }

    public bool is_running (int msg_id) { return false; }

    public int[] running_apps (int account_id, int chat_id) { return {}; }

    public void stop_app (int msg_id) { }

    public void present_app (int msg_id) { }

    public void minimize_app (int msg_id) { }
}
