namespace Dc {

    public class PinnedMessagesManager : Object {

        public Gtk.Revealer revealer { get; private set; }

        public signal void scroll_requested (int msg_id);
        public signal void operation_failed (string message);

        private unowned RpcClient? rpc = null;
        private Gtk.Box bar_content;
        private int[] msg_ids = {};
        private HashTable<int, bool> dismissed_ids =
            new HashTable<int, bool> (direct_hash, direct_equal);
        private int current_chat_id = 0;
        private unowned GLib.ListStore message_store;
        private unowned SettingsManager settings;
        private bool rpc_available = true;
        private uint load_generation = 0;
        private uint bar_generation = 0;


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

        public void set_rpc (RpcClient r) { this.rpc = r; }

        public async void load_for_chat (int chat_id) {
            if (chat_id != current_chat_id) dismissed_ids.remove_all ();
            current_chat_id = chat_id;
            uint generation = ++load_generation;
            if (!rpc_available) {
                load_local_for_chat (chat_id);
                sync_store_state ();
                return;
            }
            if (rpc == null) {
                msg_ids = {};
                return;
            }

            try {
                int[] loaded_ids = yield rpc.get_pinned_messages (chat_id);
                if (generation != load_generation || chat_id != current_chat_id)
                    return;
                msg_ids = loaded_ids;
                sync_store_state ();
            } catch (Error e) {
                if (generation != load_generation) return;
                if (is_missing_pin_rpc (e)) {
                    rpc_available = false;
                    load_local_for_chat (chat_id);
                    sync_store_state ();
                } else {
                    warning ("load pinned messages: %s", e.message);
                }
            }
        }

        public bool is_pinned (int msg_id) {
            foreach (int id in msg_ids) {
                if (id == msg_id) return true;
            }
            return false;
        }

        public async void toggle_pin (int msg_id) {
            if (!rpc_available) {
                toggle_local_pin (msg_id);
                yield update_bar ();
                return;
            }
            if (rpc == null) {
                operation_failed (_("Failed to update pin: RPC is not connected"));
                return;
            }

            var loaded_message = find_message (message_store, msg_id);
            bool current_state = loaded_message != null
                ? loaded_message.is_pinned : is_pinned (msg_id);
            bool new_state = !current_state;
            try {
                yield rpc.set_pinned_message_state (msg_id, new_state);
                set_cached_state (msg_id, new_state);
                update_message_state (msg_id, new_state);

                /* Core orders pins by message date, so refresh instead of
                   treating the local insertion order as authoritative. */
                yield load_for_chat (current_chat_id);
                yield update_bar ();
            } catch (Error e) {
                if (is_missing_pin_rpc (e)) {
                    rpc_available = false;
                    /* v2.57 and older do not expose message pinning. Keep
                       Parla's previous on-device behavior on those engines. */
                    toggle_local_pin (msg_id);
                    yield update_bar ();
                } else {
                    operation_failed (_("Failed to update pin: ") + e.message);
                }
            }
        }

        public async void update_bar () {
            uint generation = ++bar_generation;
            var next_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            next_content.add_css_class ("pinned-bar");

            if (msg_ids.length == 0) {
                if (generation != bar_generation) return;
                bar_content = next_content;
                revealer.child = bar_content;
                revealer.reveal_child = false;
                return;
            }

            int[] displayed_ids = msg_ids;
            foreach (int pin_id in displayed_ids) {
                if (dismissed_ids.contains (pin_id)) continue;
                string? text = null;
                string? sender = null;

                /* Find the message in the backing store */
                var m = find_message (message_store, pin_id);
                if (m != null) {
                    text = m.text;
                    sender = m.is_outgoing ? _("You") : (m.sender_name ?? "");
                }

                /* Fetch from RPC if not in the loaded batch */
                if (text == null && sender == null && rpc != null) {
                    try {
                        var fetched = yield rpc.fetch_message (pin_id);
                        if (fetched != null) {
                            text = fetched.text;
                            sender = fetched.is_outgoing ? _("You") : (fetched.sender_name ?? "");
                        }
                    } catch (Error e) { /* skip on error */ }
                }

                if (generation != bar_generation) return;
                if (text == null && sender == null) continue;

                var row_btn = new Gtk.Button ();
                row_btn.add_css_class ("flat");

                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

                var pin_icon = new Gtk.Label ("\xf0\x9f\x93\x8c");
                row_box.append (pin_icon);

                var text_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
                text_box.hexpand = true;

                if (sender != null && sender.length > 0) {
                    var sender_lbl = new Gtk.Label (sender);
                    sender_lbl.add_css_class ("caption");
                    sender_lbl.add_css_class ("dim-label");
                    sender_lbl.halign = Gtk.Align.START;
                    sender_lbl.single_line_mode = true;
                    sender_lbl.ellipsize = Pango.EllipsizeMode.END;
                    sender_lbl.max_width_chars = 15;
                    text_box.append (sender_lbl);
                }

                var text_lbl = new Gtk.Label (null);
                text_lbl.set_markup (Markdown.format (text ?? _("(attachment)"))
                    .replace ("\r", " ").replace ("\n", " "));
                text_lbl.xalign = 0;
                text_lbl.hexpand = true;
                text_lbl.ellipsize = Pango.EllipsizeMode.END;
                text_lbl.max_width_chars = 50;
                text_lbl.single_line_mode = true;
                text_box.append (text_lbl);

                row_box.append (text_box);
                row_btn.child = row_box;

                int captured_id = pin_id;
                row_btn.clicked.connect (() => {
                    scroll_requested (captured_id);
                });

                var outer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                outer.append (row_btn);
                row_btn.hexpand = true;

                var close_btn = new Gtk.Button.from_icon_name (
                    "window-close-symbolic");
                close_btn.add_css_class ("flat");
                close_btn.add_css_class ("circular");
                close_btn.valign = Gtk.Align.CENTER;
                close_btn.tooltip_text = _("Close");
                close_btn.clicked.connect (() => {
                    // Subscribers can dismiss a preview without unpinning for everyone.
                    dismissed_ids.insert (captured_id, true);
                    update_bar.begin ();
                });
                outer.append (close_btn);

                next_content.append (outer);
            }

            if (generation != bar_generation) return;
            bar_content = next_content;
            revealer.child = bar_content;
            revealer.reveal_child = bar_content.get_first_child () != null;
        }

        private void set_cached_state (int msg_id, bool pinned) {
            int[] next_ids = {};
            foreach (int id in msg_ids) {
                if (id != msg_id) next_ids += id;
            }
            if (pinned) next_ids += msg_id;
            else dismissed_ids.remove (msg_id);
            msg_ids = next_ids;
        }

        private void toggle_local_pin (int msg_id) {
            bool new_state = !is_pinned (msg_id);
            set_cached_state (msg_id, new_state);
            save_local_for_chat (current_chat_id, msg_ids);
            update_message_state (msg_id, new_state);
        }

        private void load_local_for_chat (int chat_id) {
            msg_ids = {};
            var kf = new KeyFile ();
            try {
                kf.load_from_file (SettingsManager.get_config_path (),
                                   KeyFileFlags.NONE);
                string value = kf.get_string ("PinnedMessages",
                    "chat_%d".printf (chat_id));
                foreach (string item in value.split (",")) {
                    string id = item.strip ();
                    if (id.length > 0) msg_ids += int.parse (id);
                }
            } catch (Error e) { /* No local pins for this chat. */ }
        }

        private void save_local_for_chat (int chat_id, int[] ids) {
            string key = "chat_%d".printf (chat_id);
            settings.save_to_file ((kf) => {
                if (ids.length == 0) {
                    try {
                        kf.remove_key ("PinnedMessages", key);
                    } catch (Error e) { }
                    return;
                }

                var value = new StringBuilder ();
                foreach (int id in ids) {
                    if (value.len > 0) value.append (",");
                    value.append (id.to_string ());
                }
                kf.set_string ("PinnedMessages", key, value.str);
            });
        }

        private void sync_store_state () {
            dismissed_ids.foreach_remove ((id, dismissed) => !is_pinned (id));
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var msg = (Message) message_store.get_item (i);
                update_message_state (msg.id, is_pinned (msg.id));
            }
        }

        private void update_message_state (int msg_id, bool pinned) {
            var msg = find_message (message_store, msg_id);
            if (msg == null || msg.is_pinned == pinned) return;
            msg.is_pinned = pinned;
            msg.notify_property ("is-pinned");
        }

        private static bool is_missing_pin_rpc (Error e) {
            string msg = e.message.down ();
            return "method not found" in msg
                || "procedure not found" in msg
                || "unknown method" in msg;
        }
    }
}
