namespace Dc {

    /**
     * Per-chat conversation view. One instance per chat, cached by the
     * window so each conversation keeps its own draft, scroll position,
     * message store, search state, and pinned bar across chat switches.
     */
    public class ConversationView : Gtk.Box {

        public int chat_id { get; construct; }

        private unowned Window window;
        private unowned RpcClient rpc;
        private unowned SettingsManager settings;

        private Gtk.ListView message_listview;
        private Gtk.ScrolledWindow message_scroll;
        private GLib.ListStore message_store;
        private Gtk.FilterListModel filtered_message_store;
        private Gtk.CustomFilter message_filter;
        private ComposeBar compose_bar;
        private Gtk.Button scroll_down_btn;
        private Gtk.Revealer message_search_revealer;
        private Gtk.SearchEntry message_search_entry;
        private bool search_toggling;

        private bool stick_to_bottom = true;
        private Json.Array? all_msg_ids = null;
        private uint loaded_start_index = 0;
        private bool loading_more = false;
        private bool loading_chat = false;
        private bool messages_loaded = false;

        public PinnedMessagesManager pinned { get; private set; }
        public MessageActions msg_actions { get; private set; }

        public ConversationView (int chat_id, Window window, RpcClient rpc,
                                 SettingsManager settings) {
            Object (
                orientation: Gtk.Orientation.VERTICAL,
                spacing: 0,
                chat_id: chat_id
            );
            this.window = window;
            this.rpc = rpc;
            this.settings = settings;

            message_store = new GLib.ListStore (typeof (Message));
            pinned = new PinnedMessagesManager (message_store, settings);
            pinned.set_rpc (rpc);
            pinned.scroll_requested.connect ((mid) => { scroll_to_message (mid); });

            build_ui ();

            msg_actions = new MessageActions (window, rpc, message_store,
                                              pinned, compose_bar, settings);
        }

        private void build_ui () {
            message_scroll = new Gtk.ScrolledWindow ();
            message_scroll.vexpand = true;
            message_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            message_scroll.vadjustment.notify["upper"].connect (() => {
                if (loading_chat) return;
                maybe_autoscroll ();
                scroll_down_btn.visible = !is_near_bottom ();
            });
            message_scroll.vadjustment.notify["page-size"].connect (() => {
                if (loading_chat) return;
                maybe_autoscroll ();
                scroll_down_btn.visible = !is_near_bottom ();
            });
            message_scroll.vadjustment.notify["value"].connect (() => {
                if (loading_chat) return;
                stick_to_bottom = is_near_bottom ();
                scroll_down_btn.visible = !stick_to_bottom;
                if (is_near_top () && !loading_more && loaded_start_index > 0) {
                    load_earlier_messages.begin ();
                }
            });

            message_filter = new Gtk.CustomFilter ((item) => {
                if (!message_search_revealer.reveal_child) return true;
                string query = message_search_entry.text.strip ().down ();
                if (query.length == 0) return true;
                var msg = (Message) item;
                return msg.text != null && msg.text.down ().contains (query);
            });
            filtered_message_store = new Gtk.FilterListModel (message_store, message_filter);

            var factory = new Gtk.SignalListItemFactory ();
            factory.bind.connect ((obj) => {
                var li = (Gtk.ListItem) obj;
                var msg = (Message) li.item;
                var row = new MessageRow (msg);
                row.quote_clicked.connect ((qid) => { scroll_to_message (qid); });
                if (msg.highlighted) {
                    msg.highlighted = false;
                    row.highlight ();
                }
                li.child = row;
            });

            var selection = new Gtk.NoSelection (filtered_message_store);
            message_listview = new Gtk.ListView (selection, factory);
            message_listview.add_css_class ("boxed-list-separate");

            /* One gesture pair on the listview, not per-row: a per-row
               left-click controller competes with the label's link gesture
               and breaks URL clicks. */
            var rc = new Gtk.GestureClick ();
            rc.button = 3;
            rc.pressed.connect ((n, x, y) => {
                var row = pick_message_row (x, y);
                if (row != null)
                    msg_actions.show_context_menu (row.message_id,
                        row.is_outgoing, x, y, message_listview);
            });
            message_listview.add_controller (rc);

            var dc = new Gtk.GestureClick ();
            dc.button = 1;
            dc.pressed.connect ((n, x, y) => {
                var row = pick_message_row (x, y);
                if (row == null) return;
                if (n == 2) msg_actions.handle_double_click (row.message_id);
                else {
                    var msg = find_message (message_store, row.message_id);
                    if (msg != null) on_message_activated (msg);
                }
            });
            message_listview.add_controller (dc);

            message_scroll.child = message_listview;

            message_search_entry = new Gtk.SearchEntry ();
            message_search_entry.placeholder_text = "Search in conversation\u2026";
            message_search_entry.hexpand = true;
            message_search_entry.margin_start = 8;
            message_search_entry.margin_end = 8;
            message_search_entry.margin_top = 4;
            message_search_entry.margin_bottom = 4;
            message_search_entry.search_changed.connect (() => {
                message_filter.changed (Gtk.FilterChange.DIFFERENT);
            });
            message_search_revealer = new Gtk.Revealer ();
            message_search_revealer.child = message_search_entry;
            message_search_revealer.reveal_child = false;
            message_search_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;

            append (message_search_revealer);
            append (pinned.revealer);

            scroll_down_btn = new Gtk.Button ();
            scroll_down_btn.icon_name = "go-down-symbolic";
            scroll_down_btn.add_css_class ("circular");
            scroll_down_btn.add_css_class ("osd");
            scroll_down_btn.add_css_class ("scroll-down-btn");
            scroll_down_btn.halign = Gtk.Align.CENTER;
            scroll_down_btn.valign = Gtk.Align.END;
            scroll_down_btn.margin_bottom = 12;
            scroll_down_btn.visible = false;
            scroll_down_btn.clicked.connect (() => { scroll_to_bottom (); });

            var scroll_overlay = new Gtk.Overlay ();
            scroll_overlay.child = message_scroll;
            scroll_overlay.vexpand = true;
            scroll_overlay.add_overlay (scroll_down_btn);
            append (scroll_overlay);

            compose_bar = new ComposeBar ();
            settings.bind_property ("shift-enter-sends", compose_bar,
                                    "shift-enter-sends", BindingFlags.SYNC_CREATE);
            compose_bar.send_message.connect (on_send_message);
            compose_bar.edit_message.connect ((msg_id, new_text) => {
                msg_actions.edit_message.begin (msg_id, new_text);
            });
            append (compose_bar);

            install_drop_target ();
        }

        /* ================================================================
         *  Public API (called by Window)
         * ================================================================ */

        public void on_activated () {
            if (!messages_loaded) {
                messages_loaded = true;
                load_messages.begin ();
            }
            compose_bar.grab_entry_focus ();
        }

        public void on_reselected () {
            scroll_to_bottom ();
            compose_bar.grab_entry_focus ();
        }

        public void focus_entry () {
            compose_bar.grab_entry_focus ();
        }

        public async void reload_messages () {
            yield load_messages ();
        }

        public async void handle_incoming_msg (int msg_id) {
            try {
                var msg = yield rpc.fetch_message (msg_id);
                if (msg == null) return;
                bool is_current = (window.current_chat_id == this.chat_id);
                if (is_current) msg.highlighted = true;
                msg.is_pinned = pinned.is_pinned (msg.id);
                insert_message_sorted (msg);
                if (is_current && window.is_active) {
                    yield rpc.mark_seen_msgs (new int[] { msg_id });
                }
            } catch (Error e) {
                warning ("handle_incoming_msg: %s", e.message);
            }
        }

        public void toggle_search () {
            if (search_toggling) return;
            search_toggling = true;
            bool was_active = message_search_revealer.reveal_child;
            message_search_revealer.reveal_child = !was_active;
            if (!was_active) {
                Idle.add (() => {
                    message_search_entry.grab_focus ();
                    search_toggling = false;
                    return Source.REMOVE;
                });
            } else {
                message_search_entry.text = "";
                Idle.add (() => {
                    search_toggling = false;
                    return Source.REMOVE;
                });
            }
        }

        public bool close_search_if_active () {
            if (!message_search_revealer.reveal_child) return false;
            message_search_revealer.reveal_child = false;
            message_search_entry.text = "";
            return true;
        }

        public void scroll_to_message (int msg_id) {
            int pos = -1;
            for (uint i = 0; i < filtered_message_store.get_n_items (); i++) {
                var m = (Message) filtered_message_store.get_item (i);
                if (m.id == msg_id) { pos = (int) i; break; }
            }
            if (pos < 0) return;
            var msg = (Message) filtered_message_store.get_item (pos);
            msg.highlighted = true;
            message_listview.scroll_to (pos, Gtk.ListScrollFlags.FOCUS, null);
            stick_to_bottom = is_near_bottom ();
        }

        /* ================================================================
         *  Message loading
         * ================================================================ */

        private async void load_messages () {
            if (rpc.account_id <= 0) return;

            try {
                all_msg_ids = yield rpc.get_message_ids (chat_id);
                if (all_msg_ids == null) return;

                loaded_start_index = all_msg_ids.get_length () > 30
                    ? all_msg_ids.get_length () - 30 : 0;

                var messages = yield fetch_messages_batch (
                    loaded_start_index, all_msg_ids.get_length ());

                pinned.load_for_chat (chat_id);

                loading_chat = true;
                stick_to_bottom = true;

                var batch = new GLib.Object[messages.length];
                for (uint i = 0; i < messages.length; i++) {
                    messages[i].is_pinned = pinned.is_pinned (messages[i].id);
                    batch[i] = messages[i];
                }
                message_store.splice (0, message_store.get_n_items (), batch);
                loading_chat = false;
                if (messages.length > 0) {
                    scroll_to_bottom ();
                }

                pinned.update_bar.begin ();
            } catch (Error e) {
                window.show_toast ("Failed to load messages: " + e.message);
            }
        }

        private async GLib.GenericArray<Message> fetch_messages_batch (
                uint start, uint end) throws Error {
            uint count = end - start;
            int[] ids = new int[count];
            for (uint i = 0; i < count; i++) {
                ids[i] = (int) all_msg_ids.get_int_element (start + i);
            }
            var map = yield rpc.get_messages (ids);
            var result = new GLib.GenericArray<Message> ();
            if (map != null) {
                foreach (int mid in ids) {
                    string k = mid.to_string ();
                    if (map.has_member (k)) {
                        result.add (RpcClient.parse_message (
                            map.get_object_member (k), rpc.self_email));
                    }
                }
            }
            return result;
        }

        private async void load_earlier_messages () {
            if (loading_more || all_msg_ids == null || loaded_start_index == 0) return;
            loading_more = true;

            uint new_start = loaded_start_index > 100
                ? loaded_start_index - 100 : 0;

            try {
                var messages = yield fetch_messages_batch (new_start, loaded_start_index);

                var adj = message_scroll.vadjustment;
                double old_upper = adj.upper;
                double old_value = adj.value;

                for (uint i = 0; i < messages.length; i++) {
                    var msg = messages[i];
                    msg.is_pinned = pinned.is_pinned (msg.id);
                    message_store.insert ((int) i, msg);
                }

                loaded_start_index = new_start;

                Idle.add (() => {
                    var a = message_scroll.vadjustment;
                    a.value = old_value + (a.upper - old_upper);
                    loading_more = false;
                    return Source.REMOVE;
                });
            } catch (Error e) {
                loading_more = false;
                window.show_toast ("Failed to load earlier messages: " + e.message);
            }
        }

        /* ================================================================
         *  Scroll helpers
         * ================================================================ */

        private bool is_near_bottom () {
            var adj = message_scroll.vadjustment;
            if (adj.upper <= adj.page_size) return true;
            return (adj.upper - adj.value - adj.page_size) < 80;
        }

        private bool is_near_top () {
            var adj = message_scroll.vadjustment;
            return adj.value < 80;
        }

        private void maybe_autoscroll () {
            if (!stick_to_bottom) return;
            var adj = message_scroll.vadjustment;
            if (adj.upper > adj.page_size) {
                adj.value = adj.upper - adj.page_size;
            }
        }

        public void scroll_to_bottom () {
            stick_to_bottom = true;
            maybe_autoscroll ();
            uint n = filtered_message_store.get_n_items ();
            if (n > 0) {
                message_listview.scroll_to (n - 1, Gtk.ListScrollFlags.NONE, null);
            }
        }

        private void insert_message_sorted (Message msg) {
            int count = (int) message_store.get_n_items ();
            if (count > 0) {
                var last = (Message) message_store.get_item (count - 1);
                if (msg.timestamp > last.timestamp ||
                    (msg.timestamp == last.timestamp && msg.id >= last.id)) {
                    message_store.append (msg);
                    return;
                }
            }
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var m = (Message) message_store.get_item (i);
                if (m.timestamp > msg.timestamp ||
                    (m.timestamp == msg.timestamp && m.id > msg.id)) {
                    message_store.insert ((int) i, msg);
                    return;
                }
            }
            message_store.append (msg);
        }

        /* ================================================================
         *  Sending & attachments
         * ================================================================ */

        private void on_send_message (string text, string? file_path, string? file_name, int quote_msg_id) {
            do_send.begin (text, file_path, file_name, quote_msg_id);
        }

        private async void do_send (string text, string? file_path, string? file_name, int quote_msg_id) {
            try {
                string? send_text = text.length > 0 ? text : null;
                int msg_id = yield rpc.send_msg (chat_id,
                                                  send_text, file_path, file_name,
                                                  quote_msg_id);
                if (msg_id > 0) {
                    var msg = yield rpc.fetch_message (msg_id);
                    if (msg != null) {
                        insert_message_sorted (msg);
                        scroll_to_bottom ();
                    }
                }
            } catch (Error e) {
                window.show_toast ("Send failed: " + e.message);
            }
        }

        private void install_drop_target () {
            var drop = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
            drop.accept.connect (() => {
                return compose_bar.can_accept_attachment ();
            });
            drop.enter.connect ((x, y) => {
                add_css_class ("chat-drop-active");
                return Gdk.DragAction.COPY;
            });
            drop.leave.connect (() => {
                remove_css_class ("chat-drop-active");
            });
            drop.drop.connect ((value, x, y) => {
                remove_css_class ("chat-drop-active");
                if (!compose_bar.can_accept_attachment ()) return false;
                var fl = (Gdk.FileList?) value.get_boxed ();
                if (fl == null) return false;
                var files = fl.get_files ();
                if (files == null || files.data == null) return false;
                attach_dropped_file.begin (files.data);
                return true;
            });
            add_controller (drop);
        }

        private async void attach_dropped_file (GLib.File file) {
            try {
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
                compose_bar.set_pending_attachment (path, name);
                compose_bar.grab_entry_focus ();
            } catch (Error e) {
                window.show_toast ("Attach failed: " + e.message);
            }
        }

        private MessageRow? pick_message_row (double x, double y) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                w = w.get_parent ();
            }
            return w as MessageRow;
        }

        private void on_message_activated (Message msg) {
            if (msg.file_path == null || msg.file_path.length == 0) return;
            if (!FileUtils.test (msg.file_path, FileTest.EXISTS)) {
                window.show_toast ("File not available");
                return;
            }
            if (MessageRow.is_image_file (msg)) {
                window.show_image (msg.file_path);
            } else {
                window.save_attachment.begin (msg.file_path, msg.file_name);
            }
        }
    }
}
