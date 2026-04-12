namespace Dc {

    public class PinnedMessagesManager : Object {

        public Gtk.Revealer revealer { get; private set; }

        private unowned Window? window = null;
        private unowned RpcClient? rpc = null;
        private Gtk.Box bar_content;
        private int[] msg_ids = {};
        private int current_chat_id = 0;
        private unowned GLib.ListStore message_store;
        private unowned SettingsManager settings;


        public PinnedMessagesManager (GLib.ListStore message_store,
                                      SettingsManager settings) {
            this.message_store = message_store;
            this.settings = settings;

            bar_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            bar_content.add_css_class ("pinned-bar");
            revealer = new Gtk.Revealer ();
            revealer.child = bar_content;
            revealer.reveal_child = false;
            revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
        }

        public void set_window (Window w) { this.window = w; }
        public void set_rpc (RpcClient r) { this.rpc = r; }

        public void load_for_chat (int chat_id) {
            current_chat_id = chat_id;
            msg_ids = {};
            var kf = new KeyFile ();
            try {
                kf.load_from_file (SettingsManager.get_config_path (),
                                   KeyFileFlags.NONE);
                string key = "chat_%d".printf (chat_id);
                string val = kf.get_string ("PinnedMessages", key);
                foreach (string s in val.split (",")) {
                    string trimmed = s.strip ();
                    if (trimmed.length > 0) {
                        msg_ids += int.parse (trimmed);
                    }
                }
            } catch (Error e) { /* no pinned messages for this chat */ }
        }

        public bool is_pinned (int msg_id) {
            foreach (int id in msg_ids) {
                if (id == msg_id) return true;
            }
            return false;
        }

        public void toggle_pin (int msg_id) {
            if (is_pinned (msg_id)) {
                int[] new_ids = {};
                foreach (int id in msg_ids) {
                    if (id != msg_id) new_ids += id;
                }
                msg_ids = new_ids;
            } else {
                msg_ids += msg_id;
            }
            save_for_chat (current_chat_id, msg_ids);

            var m = find_message (message_store, msg_id);
            if (m != null) {
                m.is_pinned = is_pinned (msg_id);
                refresh_in_store (msg_id);
            }
            update_bar.begin ();
        }

        public async void update_bar () {
            /* Clear existing pinned entries */
            Gtk.Widget? child;
            while ((child = bar_content.get_first_child ()) != null) {
                bar_content.remove (child);
            }

            if (msg_ids.length == 0) {
                revealer.reveal_child = false;
                return;
            }

            foreach (int pin_id in msg_ids) {
                string? text = null;
                string? sender = null;

                /* Find the message in the backing store */
                var m = find_message (message_store, pin_id);
                if (m != null) {
                    text = m.text;
                    sender = m.is_outgoing ? "You" : (m.sender_name ?? "");
                }

                /* Fetch from RPC if not in the loaded batch */
                if (text == null && sender == null && rpc != null) {
                    try {
                        var msg_obj = yield rpc.get_message (rpc.account_id, pin_id);
                        if (msg_obj != null) {
                            var fetched = RpcClient.parse_message (msg_obj, rpc.self_email);
                            text = fetched.text;
                            sender = fetched.is_outgoing ? "You" : (fetched.sender_name ?? "");
                        }
                    } catch (Error e) { /* skip on error */ }
                }

                if (text == null && sender == null) continue;

                var row_btn = new Gtk.Button ();
                row_btn.add_css_class ("flat");

                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

                var pin_icon = new Gtk.Label ("\xf0\x9f\x93\x8c");
                row_box.append (pin_icon);

                var text_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                text_box.hexpand = true;

                if (sender != null && sender.length > 0) {
                    var sender_lbl = new Gtk.Label (sender);
                    sender_lbl.add_css_class ("caption");
                    sender_lbl.add_css_class ("dim-label");
                    sender_lbl.halign = Gtk.Align.START;
                    text_box.append (sender_lbl);
                }

                var text_lbl = new Gtk.Label (text ?? "(attachment)");
                text_lbl.halign = Gtk.Align.START;
                text_lbl.ellipsize = Pango.EllipsizeMode.END;
                text_lbl.max_width_chars = 50;
                text_lbl.lines = 1;
                text_box.append (text_lbl);

                row_box.append (text_box);
                row_btn.child = row_box;

                int captured_id = pin_id;
                row_btn.clicked.connect (() => {
                    if (window != null) window.scroll_to_message (captured_id);
                });

                var outer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                outer.append (row_btn);
                row_btn.hexpand = true;

                var unpin_btn = new Gtk.Button.from_icon_name (
                    "window-close-symbolic");
                unpin_btn.add_css_class ("flat");
                unpin_btn.add_css_class ("circular");
                unpin_btn.valign = Gtk.Align.CENTER;
                unpin_btn.tooltip_text = "Unpin";
                unpin_btn.clicked.connect (() => {
                    toggle_pin (captured_id);
                });
                outer.append (unpin_btn);

                bar_content.append (outer);
            }

            revealer.reveal_child = bar_content.get_first_child () != null;
        }

        private void save_for_chat (int chat_id, int[] ids) {
            string key = "chat_%d".printf (chat_id);
            settings.save_to_file ((kf) => {
                if (ids.length > 0) {
                    var sb = new StringBuilder ();
                    foreach (int id in ids) {
                        if (sb.len > 0) sb.append (",");
                        sb.append (id.to_string ());
                    }
                    kf.set_string ("PinnedMessages", key, sb.str);
                } else {
                    try {
                        kf.remove_key ("PinnedMessages", key);
                    } catch (Error e) { }
                }
            });
        }

        private void refresh_in_store (int msg_id) {
            int idx = find_message_index (message_store, msg_id);
            if (idx < 0) return;
            var m = (Message) message_store.get_item (idx);
            Object[] replacements = { m };
            message_store.splice (idx, 1, replacements);
        }
    }
}
