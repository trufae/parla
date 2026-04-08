namespace Dc {

    /**
     * A single row in the chat list sidebar.
     * Shows avatar placeholder, chat name, last message preview, time, and unread badge.
     */
    public class ChatRow : Gtk.Box {

        public int chat_id { get; private set; }

        private Gtk.Label name_label;
        private Gtk.Label preview_label;
        private Gtk.Label time_label;
        private Gtk.Label? badge_label = null;

        public ChatRow (ChatEntry entry) {
            Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 10);
            this.chat_id = entry.id;
            add_css_class ("chat-row");
            margin_start = 8;
            margin_end = 8;
            margin_top = 4;
            margin_bottom = 4;

            /* Avatar circle */
            var avatar = new Adw.Avatar (40, entry.name, true);
            if (entry.avatar_path != null && entry.avatar_path.length > 0 &&
                FileUtils.test (entry.avatar_path, FileTest.EXISTS)) {
                try {
                    var texture = Gdk.Texture.from_filename (entry.avatar_path);
                    avatar.custom_image = texture;
                } catch (Error e) {
                    /* fallback to initials */
                }
            }
            append (avatar);

            /* Middle: name + preview */
            var mid = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            mid.hexpand = true;
            mid.valign = Gtk.Align.CENTER;

            /* Top row: name + time */
            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);

            if (entry.unread_count > 0) {
                var dot = new Gtk.Label ("\u25CF");
                dot.add_css_class ("unread-dot");
                top.append (dot);
            }

            name_label = new Gtk.Label (entry.name);
            name_label.add_css_class ("heading");
            name_label.ellipsize = Pango.EllipsizeMode.END;
            name_label.hexpand = true;
            name_label.halign = Gtk.Align.START;
            name_label.xalign = 0;
            top.append (name_label);

            time_label = new Gtk.Label (format_time (entry.timestamp));
            time_label.add_css_class ("dim-label");
            time_label.add_css_class ("caption");
            top.append (time_label);

            mid.append (top);

            /* Bottom row: preview + badge */
            var bot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            preview_label = new Gtk.Label (entry.last_message ?? "");
            preview_label.add_css_class ("dim-label");
            preview_label.ellipsize = Pango.EllipsizeMode.END;
            preview_label.hexpand = true;
            preview_label.halign = Gtk.Align.START;
            preview_label.xalign = 0;
            preview_label.max_width_chars = 30;
            bot.append (preview_label);

            if (entry.unread_count > 0) {
                badge_label = new Gtk.Label (entry.unread_count.to_string ());
                badge_label.add_css_class ("unread-badge");
                badge_label.halign = Gtk.Align.END;
                badge_label.valign = Gtk.Align.CENTER;
                bot.append (badge_label);
            }

            mid.append (bot);
            append (mid);
        }

        /**
         * Update the row contents when the chat entry changes.
         */
        public void update (ChatEntry entry) {
            name_label.label = entry.name;
            preview_label.label = entry.last_message ?? "";
            time_label.label = format_time (entry.timestamp);
        }

        private static string format_time (int64 timestamp) {
            if (timestamp <= 0) return "";

            var now = new DateTime.now_local ();
            var dt = new DateTime.from_unix_local (timestamp);

            /* Same day: show time, otherwise show date */
            if (now.get_year () == dt.get_year () &&
                now.get_day_of_year () == dt.get_day_of_year ()) {
                return dt.format ("%H:%M");
            }
            /* This week: show day name */
            int diff = (int) (now.to_unix () - dt.to_unix ());
            if (diff < 7 * 86400) {
                return dt.format ("%a");
            }
            /* Older: show date */
            return dt.format ("%d/%m/%y");
        }
    }
}
