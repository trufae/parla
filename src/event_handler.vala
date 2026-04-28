namespace Dc {

    public class EventHandler : Object {

        private unowned RpcClient rpc;
        private unowned GLib.Application? app = null;
        private bool _listening = false;
        private uint chats_reload_timer = 0;
        private uint messages_reload_timer = 0;

        public int active_chat_id { get; set; default = 0; }

        public signal void chats_reload_fired ();
        public signal void messages_reload_fired ();
        public signal void incoming_msg_received (int chat_id, int msg_id);
        public signal void imex_progress (int context_id, int progress);
        public signal void configure_progress (int context_id, int progress,
                                                string? comment);

        public EventHandler (RpcClient rpc) {
            this.rpc = rpc;
        }

        public void set_app (GLib.Application a) { this.app = a; }

        public bool is_listening { get { return _listening; } }

        public async void start () {
            if (_listening) return;
            _listening = true;

            while (rpc.is_connected) {
                try {
                    var ev = yield rpc.get_next_event ();
                    if (ev == null) continue;

                    int ctx = (int) ev.get_int_member ("contextId");

                    var event = ev.get_object_member ("event");
                    if (event == null) continue;

                    string kind = event.get_string_member ("kind");

                    /* ImexProgress / ConfigureProgress can come from a
                       non-current account during account creation. */
                    if (kind == "ImexProgress") {
                        int progress = (int) event.get_int_member ("progress");
                        imex_progress (ctx, progress);
                        continue;
                    }
                    if (kind == "ConfigureProgress") {
                        int progress = (int) event.get_int_member ("progress");
                        string? comment = null;
                        if (event.has_member ("comment") &&
                            !event.get_member ("comment").is_null ()) {
                            comment = event.get_string_member ("comment");
                        }
                        configure_progress (ctx, progress, comment);
                        continue;
                    }

                    if (ctx != rpc.account_id) continue;
                    dispatch (kind, event);
                } catch (Error e) {
                    if (rpc.is_connected) {
                        warning ("Event loop error: %s", e.message);
                        yield nap (1000);
                    }
                }
            }

            _listening = false;
        }

        public void schedule_chats_reload () {
            if (chats_reload_timer > 0) return;
            chats_reload_timer = Timeout.add (150, () => {
                chats_reload_timer = 0;
                chats_reload_fired ();
                return Source.REMOVE;
            });
        }

        public void schedule_messages_reload () {
            if (messages_reload_timer > 0 || active_chat_id <= 0) return;
            messages_reload_timer = Timeout.add (150, () => {
                messages_reload_timer = 0;
                messages_reload_fired ();
                return Source.REMOVE;
            });
        }

        private void dispatch (string kind, Json.Object event) {
            switch (kind) {
            case "IncomingMsg":
                int chat_id = (int) event.get_int_member ("chatId");
                int msg_id = (int) event.get_int_member ("msgId");
                incoming_msg_received (chat_id, msg_id);
                break;

            case "MsgsChanged":
                int changed_chat = (int) event.get_int_member ("chatId");
                if (changed_chat == 0 || changed_chat == active_chat_id) {
                    schedule_messages_reload ();
                }
                break;

            case "MsgDelivered":
            case "MsgRead":
            case "MsgFailed":
            case "MsgDeleted":
            case "ReactionsChanged":
                int msg_chat = (int) event.get_int_member ("chatId");
                if (msg_chat == active_chat_id) {
                    schedule_messages_reload ();
                }
                break;

            case "ChatlistChanged":
            case "ChatlistItemChanged":
            case "MsgsNoticed":
            case "ChatModified":
            case "ChatDeleted":
                schedule_chats_reload ();
                break;

            default:
                break;
            }
        }

        public async void send_notification (int chat_id, int msg_id) {
            if (app == null) return;
            try {
                var msg = yield rpc.fetch_message (msg_id);
                if (msg == null) return;
                if (msg.is_outgoing || msg.is_info) return;

                string title = msg.sender_name ?? msg.sender_address ?? "New message";
                try {
                    var chat_obj = yield rpc.get_full_chat_by_id (chat_id);
                    if (chat_obj != null && chat_obj.has_member ("name")) {
                        string chat_name = chat_obj.get_string_member ("name");
                        if (chat_name != null && chat_name.length > 0
                            && chat_name != title) {
                            title = "%s (%s)".printf (title, chat_name);
                        }
                    }
                } catch (Error e) { /* fall back to sender */ }

                string body = (msg.text != null && msg.text.length > 0) ? msg.text
                    : (msg.file_name != null && msg.file_name.length > 0) ? msg.file_name
                    : "New message";

                var n = new GLib.Notification (title);
                n.set_body (body);
                n.set_priority (GLib.NotificationPriority.NORMAL);
                app.send_notification ("dc-msg-%d".printf (msg_id), n);
            } catch (Error e) {
                warning ("Failed to send notification: %s", e.message);
            }
        }

        private async void nap (uint ms) {
            Timeout.add (ms, nap.callback);
            yield;
        }
    }
}
