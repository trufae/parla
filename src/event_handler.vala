namespace Dc {

    [DBus (name = "org.freedesktop.Notifications")]
    private interface DesktopNotificationServer : Object {
        public abstract string[] get_capabilities () throws GLib.Error;
    }

    public class EventHandler : Object {

        private unowned RpcClient rpc;
        private unowned GLib.Application? app = null;
        private bool _listening = false;
        private uint chats_reload_timer = 0;
        private uint messages_reload_timer = 0;
        /* -1 means the notification server has not been queried yet. */
        private int notification_actions_supported = -1;

        public int active_chat_id { get; set; default = 0; }

        public signal void chats_reload_fired ();
        public signal void messages_reload_fired ();
        public signal void incoming_msg_received (int acct_id, int chat_id, int msg_id);
        public signal void incoming_reaction_received (int acct_id, int chat_id,
                                                       int msg_id, int contact_id,
                                                       string reaction);
        public signal void chat_messages_changed (int acct_id, int chat_id);
        public signal void account_unread_changed (int acct_id);
        public signal void contacts_changed (int acct_id);
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
                        string? comment = json_str (event, "comment");
                        configure_progress (ctx, progress, comment);
                        continue;
                    }

                    if (kind == "IncomingMsgBunch") {
                        if (ctx == rpc.account_id) {
                            chat_messages_changed (ctx, 0);
                            schedule_messages_reload ();
                            schedule_chats_reload ();
                        }
                        account_unread_changed (ctx);
                        continue;
                    }

                    /* Notification-driving events, handled identically for
                       every account (docs/notifications.md T1, W1). */
                    if (kind == "IncomingMsg") {
                        incoming_msg_received (ctx,
                            (int) event.get_int_member ("chatId"),
                            (int) event.get_int_member ("msgId"));
                        account_unread_changed (ctx);
                        continue;
                    }
                    if (kind == "IncomingReaction") {
                        incoming_reaction_received (ctx,
                            (int) event.get_int_member ("chatId"),
                            (int) event.get_int_member ("msgId"),
                            (int) event.get_int_member ("contactId"),
                            event.get_string_member ("reaction"));
                        continue;
                    }
                    if (kind == "MsgsNoticed") {
                        clear_notifications_for_chat (ctx,
                            (int) event.get_int_member ("chatId"));
                        account_unread_changed (ctx);
                        if (ctx == rpc.account_id) schedule_chats_reload ();
                        continue;
                    }

                    if (ctx != rpc.account_id) {
                        dispatch_background (ctx, kind);
                        continue;
                    }
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
            case "MsgsChanged":
                int changed_chat = (int) event.get_int_member ("chatId");
                chat_messages_changed (rpc.account_id, changed_chat);
                if (changed_chat == 0 || changed_chat == active_chat_id) {
                    schedule_messages_reload ();
                }
                account_unread_changed (rpc.account_id);
                break;

            case "MsgDelivered":
            case "MsgRead":
            case "MsgReadCountChanged":
            case "MsgFailed":
            case "MsgDeleted":
            case "ReactionsChanged":
                int msg_chat = (int) event.get_int_member ("chatId");
                chat_messages_changed (rpc.account_id, msg_chat);
                if (msg_chat == active_chat_id) {
                    schedule_messages_reload ();
                }
                if (kind == "MsgDeleted") account_unread_changed (rpc.account_id);
                break;

            case "ChatlistChanged":
            case "ChatlistItemChanged":
                int list_chat = event_chat_id (event);
                if (list_chat > 0) {
                    chat_messages_changed (rpc.account_id, list_chat);
                }
                schedule_chats_reload ();
                account_unread_changed (rpc.account_id);
                break;

            case "ChatModified":
            case "ChatDeleted":
                schedule_chats_reload ();
                account_unread_changed (rpc.account_id);
                break;

            case "ContactsChanged":
                contacts_changed (rpc.account_id);
                schedule_messages_reload ();
                schedule_chats_reload ();
                break;

            case "WebxdcStatusUpdate":
                Webxdc.status_update ((int) event.get_int_member ("msgId"));
                break;

            case "WebxdcInstanceDeleted":
                Webxdc.instance_deleted ((int) event.get_int_member ("msgId"));
                break;

            default:
                break;
            }
        }

        private static int event_chat_id (Json.Object event) {
            return (int) json_int (event, "chatId");
        }

        /* Events from an account other than the active one. We can't touch
           the visible chat/message lists (they belong to the current
           account); notifications are handled before dispatch, so only the
           unread badges need refreshing here. */
        private void dispatch_background (int acct_id, string kind) {
            switch (kind) {
            case "MsgsChanged":
            case "MsgDeleted":
            case "ChatlistChanged":
            case "ChatlistItemChanged":
            case "ChatModified":
            case "ChatDeleted":
                account_unread_changed (acct_id);
                break;

            default:
                break;
            }
        }

        /* Show a banner for new activity in a chat. Uses a per-chat
           notification id, so a newer banner for the same chat replaces the
           previous one and MsgsNoticed withdraws exactly the chats the user
           has read. chat_id 0 is the account-wide group banner.
           Behavioral contract: docs/notifications.md */
        public void send_chat_notification (int acct_id, int chat_id,
                                            string title, string body) {
            if (app == null || acct_id <= 0) return;
            var n = new GLib.Notification (title);
            n.set_body (body);
            n.set_priority (GLib.NotificationPriority.NORMAL);
            set_open_chat_action (n, acct_id, chat_id);
            app.send_notification (notification_id (acct_id, chat_id), n);
        }

        public void clear_notifications_for_chat (int acct_id, int chat_id) {
            if (acct_id <= 0 || chat_id <= 0) return;
            withdraw_notification_id (notification_id (acct_id, chat_id));
            withdraw_notification_id (mention_notification_id (acct_id, chat_id));
            /* The user is reading this account: retire its group banner too. */
            withdraw_notification_id (notification_id (acct_id, 0));
        }

        /* Notify about a mention regardless of the chat's mute state — a
           dedicated, high-priority notification separate from the unread-count
           one (which is suppressed for muted chats). */
        public void send_mention_notification (int acct_id, int chat_id,
                                               string title, string body) {
            if (app == null || acct_id <= 0 || chat_id <= 0) return;
            var n = new GLib.Notification (title);
            n.set_body (body);
            n.set_priority (GLib.NotificationPriority.HIGH);
            set_open_chat_action (n, acct_id, chat_id);
            app.send_notification (mention_notification_id (acct_id, chat_id), n);
        }

        private void set_open_chat_action (GLib.Notification notification,
                                           int acct_id, int chat_id) {
            if (!server_supports_actions ()) return;
            notification.set_default_action_and_target_value ("app.open-chat",
                new Variant ("(ii)", acct_id, chat_id));
        }

        /* Some lightweight notification servers (notably notify-osd, often
           used with dwm) advertise no action support. Sending a default action
           to those servers produces a generic Cancel/OK dialog instead of a
           transient desktop banner. Keep those notifications action-free so
           the server can place and expire its normal unobtrusive popup. */
        private bool server_supports_actions () {
            if (notification_actions_supported >= 0)
                return notification_actions_supported == 1;

            /* Preserve the existing action on platforms/backends without the
               freedesktop notification interface (for example macOS). */
            bool supported = true;
            try {
                DesktopNotificationServer server =
                    Bus.get_proxy_sync<DesktopNotificationServer> (
                        BusType.SESSION,
                        "org.freedesktop.Notifications",
                        "/org/freedesktop/Notifications");
                supported = false;
                foreach (string capability in server.get_capabilities ()) {
                    if (capability == "actions") {
                        supported = true;
                        break;
                    }
                }
            } catch (Error e) {
                debug ("Could not query notification capabilities: %s",
                    e.message);
            }
            notification_actions_supported = supported ? 1 : 0;
            return supported;
        }

        private static string mention_notification_id (int acct_id, int chat_id) {
            return "dc-mention-%d-%d".printf (acct_id, chat_id);
        }

        public async void reconcile_desktop_notifications () {
            if (app == null || !rpc.is_connected) return;
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node == null) return;
                var accounts = accounts_node.get_array ();
                for (uint i = 0; i < accounts.get_length (); i++) {
                    int acct_id = (int) accounts.get_object_element (i).get_int_member ("id");
                    if (acct_id <= 0) continue;
                    try { yield reconcile_account_notifications (acct_id); }
                    catch (Error e) { /* unconfigured/removed account */ }
                }
            } catch (Error e) {
                warning ("Failed to reconcile desktop notifications: %s", e.message);
            }
        }

        private static string notification_id (int acct_id, int chat_id) {
            return "dc-chat-%d-%d".printf (acct_id, chat_id);
        }

        private static string legacy_notification_id (int acct_id, int msg_id) {
            return "dc-msg-%d-%d".printf (acct_id, msg_id);
        }

        private void withdraw_notification_id (string id) {
            if (app == null || id.length == 0) return;
            app.withdraw_notification (id);
        }

        private async void reconcile_account_notifications (int acct_id) throws Error {
            withdraw_notification_id (notification_id (acct_id, 0));
            var entries = yield rpc.get_chatlist_entries_for (acct_id);
            if (entries == null) return;

            for (uint i = 0; i < entries.get_length (); i++) {
                int chat_id = (int) entries.get_int_element (i);
                clear_notifications_for_chat (acct_id, chat_id);
                yield withdraw_legacy_notifications_for_chat (acct_id, chat_id);
            }
        }

        private async void withdraw_legacy_notifications_for_chat (
                int acct_id, int chat_id) throws Error {
            var msg_ids = yield rpc.get_message_ids_for (acct_id, chat_id);
            if (msg_ids == null) return;
            for (uint i = 0; i < msg_ids.get_length (); i++) {
                int msg_id = (int) msg_ids.get_int_element (i);
                if (msg_id <= 0) continue;
                withdraw_notification_id (legacy_notification_id (acct_id, msg_id));
            }
        }

        private async void nap (uint ms) {
            Timeout.add (ms, nap.callback);
            yield;
        }
    }
}
