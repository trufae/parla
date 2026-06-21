namespace Dc {

    /**
     * In-conversation shortcuts for moving between chats:
     * Alt+Up/Down and Ctrl+Page Up/Down (Command on macOS).
     */
    public class ChatSwitcher : Object {

        public const string[] SHORTCUT_ENTRIES = {
            "Next conversation (in chat)",     "<Alt>Down",
            "Previous conversation (in chat)", "<Alt>Up",
            "Next conversation (in chat)",     "<Primary>Page_Down",
            "Previous conversation (in chat)", "<Primary>Page_Up",
        };

        private unowned Window window;
        private unowned Gtk.ListBox chat_listbox;
        private unowned GLib.ListStore chat_store;
        private unowned Gtk.Box sidebar_box;
        private unowned Adw.OverlaySplitView split_view;

        public ChatSwitcher (Window window,
                             Gtk.ListBox chat_listbox,
                             GLib.ListStore chat_store,
                             Gtk.Box sidebar_box,
                             Adw.OverlaySplitView split_view) {
            this.window = window;
            this.chat_listbox = chat_listbox;
            this.chat_store = chat_store;
            this.sidebar_box = sidebar_box;
            this.split_view = split_view;
        }

        public bool handle_key (uint keyval, Gdk.ModifierType state) {
            if (!can_switch ()) return false;

            bool alt_arrows = (state & Gdk.ModifierType.ALT_MASK) != 0
                && (state & (Gdk.ModifierType.CONTROL_MASK
                             | Gdk.ModifierType.SUPER_MASK
                             | Gdk.ModifierType.META_MASK)) == 0;
            bool primary_page = Platform.has_primary_modifier (state)
                && (state & Gdk.ModifierType.ALT_MASK) == 0;

            if (!alt_arrows && !primary_page) return false;

            if (keyval == Gdk.Key.Up || keyval == Gdk.Key.KP_Up
                || (primary_page && (keyval == Gdk.Key.Page_Up
                                     || keyval == Gdk.Key.KP_Page_Up))) {
                return select_adjacent (-1);
            }
            if (keyval == Gdk.Key.Down || keyval == Gdk.Key.KP_Down
                || (primary_page && (keyval == Gdk.Key.Page_Down
                                     || keyval == Gdk.Key.KP_Page_Down))) {
                return select_adjacent (1);
            }
            return false;
        }

        public void append_shortcut_rows (Gtk.ListBox list) {
            for (int i = 0; i + 1 < SHORTCUT_ENTRIES.length; i += 2) {
                var row = new Adw.ActionRow ();
                row.title = SHORTCUT_ENTRIES[i];
                var lbl = new Gtk.Label (shortcut_label_text (SHORTCUT_ENTRIES[i + 1]));
                lbl.valign = Gtk.Align.CENTER;
                lbl.add_css_class ("dim-label");
                row.add_suffix (lbl);
                list.append (row);
            }
        }

        private bool can_switch () {
            if (window.current_view () == null) return false;
            if (window.shortcuts_modal_open ()) return false;

            var focus = window.shortcuts_focus_widget ();
            if (focus == null) return true;

            for (var w = focus; w != null; w = w.get_parent ()) {
                if (w is Gtk.Popover || w is Adw.Dialog) return false;
                if (w is Gtk.SearchEntry) return false;
                if (w == sidebar_box && split_view.show_sidebar) return false;
            }
            return true;
        }

        private bool select_adjacent (int delta) {
            int[] visible_ids = {};
            Gtk.ListBoxRow? row;
            int idx = 0;

            while ((row = chat_listbox.get_row_at_index (idx)) != null) {
                if (window.shortcuts_filter_chat_row (row)) {
                    var chat_row = row.child as ChatRow;
                    if (chat_row != null) {
                        visible_ids += chat_row.chat_id;
                    }
                }
                idx++;
            }

            if (visible_ids.length == 0) {
                return select_adjacent_from_store (delta);
            }
            if (visible_ids.length == 1) return true;

            int current_index = -1;
            for (int i = 0; i < visible_ids.length; i++) {
                if (visible_ids[i] == window.current_chat_id) {
                    current_index = i;
                    break;
                }
            }

            if (current_index < 0) {
                return window.select_chat_by_id (
                    visible_ids[delta > 0 ? 0 : visible_ids.length - 1]);
            }
            if (delta < 0 && current_index == 0) {
                return true;
            }
            if (delta > 0 && current_index == visible_ids.length - 1) {
                return true;
            }

            return window.select_chat_by_id (visible_ids[current_index + delta]);
        }

        private bool select_adjacent_from_store (int delta) {
            uint n = chat_store.get_n_items ();
            if (n == 0) return false;
            if (n == 1) return true;

            int current_index = -1;
            for (uint i = 0; i < n; i++) {
                var entry = (ChatEntry) chat_store.get_item (i);
                if (entry.id == window.current_chat_id) {
                    current_index = (int) i;
                    break;
                }
            }

            if (current_index < 0) {
                var target = (ChatEntry) chat_store.get_item (
                    delta > 0 ? 0 : n - 1);
                return window.select_chat_by_id (target.id);
            }
            if (delta < 0 && current_index == 0) {
                return true;
            }
            if (delta > 0 && current_index == (int) n - 1) {
                return true;
            }

            var next = (ChatEntry) chat_store.get_item ((uint) (current_index + delta));
            return window.select_chat_by_id (next.id);
        }

        private static string shortcut_label_text (string accelerator) {
            uint key;
            Gdk.ModifierType mods;
            var resolved = accelerator.replace ("<Primary>",
                Platform.primary_accelerator_prefix ());
            if (!Gtk.accelerator_parse (resolved, out key, out mods)) {
                return resolved;
            }
            return Gtk.accelerator_get_label (key, mods);
        }
    }
}