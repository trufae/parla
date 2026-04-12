namespace Dc {

    public class ChatContextMenu : Object {

        private unowned Window window;
        private unowned RpcClient rpc;
        private unowned GLib.ListStore chat_store;

        public ChatContextMenu (Window window, RpcClient rpc,
                                GLib.ListStore chat_store) {
            this.window = window;
            this.rpc = rpc;
            this.chat_store = chat_store;
        }

        public void show (int chat_id, double x, double y, Gtk.Widget parent) {
            bool is_pinned = false;
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) is_pinned = entry.is_pinned;

            var menu = new GLib.Menu ();
            menu.append (is_pinned ? "Unpin" : "Pin", "win.chat-pin");
            menu.append ("Chat Info", "win.chat-info");
            menu.append ("Delete for Me", "win.chat-delete");

            var pin_action = new SimpleAction ("chat-pin", null);
            pin_action.activate.connect (() => {
                toggle_pin.begin (chat_id, is_pinned);
            });
            var info_action = new SimpleAction ("chat-info", null);
            info_action.activate.connect (() => {
                show_info.begin (chat_id);
            });
            var delete_action = new SimpleAction ("chat-delete", null);
            delete_action.activate.connect (() => {
                confirm_delete.begin (chat_id);
            });

            window.add_action (pin_action);
            window.add_action (info_action);
            window.add_action (delete_action);

            var popover = new Gtk.PopoverMenu.from_model (menu);
            popover.set_parent (parent);
            popover.set_pointing_to ({ (int) x, (int) y, 1, 1 });
            popover.popup ();
        }

        private async void toggle_pin (int chat_id, bool currently_pinned) {
            try {
                string visibility = currently_pinned ? "Normal" : "Pinned";
                yield rpc.set_chat_visibility (rpc.account_id, chat_id, visibility);
                yield window.load_chats ();
            } catch (Error e) {
                window.show_toast ("Failed to update pin: " + e.message);
            }
        }

        private async void show_info (int chat_id) {
            var dialog = new ChatInfoDialog (rpc, rpc.account_id, chat_id);

            dialog.chat_deleted.connect ((cid) => {
                window.show_toast ("Chat deleted");
                if (window.current_chat_id == cid)
                    window.clear_chat_view ();
                window.request_reload_chats ();
            });

            dialog.chat_changed.connect (() => {
                window.request_reload_chats ();
                if (window.current_chat_id == chat_id)
                    window.request_messages_reload ();
            });

            dialog.present (window);
        }

        private async void confirm_delete (int chat_id) {
            string chat_name = "this chat";
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry != null) chat_name = entry.name;

            var dialog = new Adw.AlertDialog (
                "Delete for Me",
                "Remove \"%s\" from your chat list? You may still receive messages if you are a group member.".printf (chat_name)
            );
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("delete", "Delete for Me");
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";

            dialog.response.connect ((resp) => {
                if (resp == "delete") do_delete.begin (chat_id);
            });

            dialog.present (window);
        }

        private async void do_delete (int chat_id) {
            try {
                yield rpc.delete_chat (rpc.account_id, chat_id);
                window.show_toast ("Chat deleted");
                if (window.current_chat_id == chat_id)
                    window.clear_chat_view ();
                yield window.load_chats ();
            } catch (Error e) {
                window.show_toast ("Delete failed: " + e.message);
            }
        }
    }
}
