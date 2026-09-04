namespace Dc {

    /** Conversation-level controls for the currently selected voice note. */
    public class ConversationMediaBar : Gtk.Box {

        public int message_id { get; private set; default = 0; }

        public signal void previous_requested ();
        public signal void next_requested ();
        public signal void message_requested (int account_id, int chat_id,
                                              int message_id);

        private AudioPlayback playback;
        private Gtk.Revealer revealer;
        private Gtk.Box content;
        private Adw.Avatar avatar;
        private Gtk.Button previous_button;
        private Gtk.Button play_button;
        private Gtk.Button next_button;
        private Gtk.Button close_button;
        private Gtk.Label sender_label;
        private Gtk.Label sent_label;
        private Gtk.Label time_label;
        private Gtk.Scale progress;
        private Gtk.DropDown speed_dropdown;
        private bool syncing_speed = false;
        private ulong current_handler = 0;
        private ulong item_handler = 0;
        private ulong playing_handler = 0;
        private ulong seekable_handler = 0;
        private ulong external_handler = 0;
        private ulong position_handler = 0;
        private ulong duration_handler = 0;
        private ulong rate_handler = 0;
        private ulong previous_handler = 0;
        private ulong next_handler = 0;

        public ConversationMediaBar () {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            playback = AudioPlayback.shared ();
            add_css_class ("conversation-media-bar");

            revealer = new Gtk.Revealer ();
            revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
            revealer.reveal_child = false;

            content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            content.margin_start = 10;
            content.margin_end = 10;
            content.margin_top = 6;
            content.margin_bottom = 6;

            avatar = new Adw.Avatar (40, "Voice message", true);
            avatar.valign = Gtk.Align.CENTER;
            content.append (avatar);

            previous_button = media_button (
                "media-skip-backward-symbolic", "Previous voice message");
            previous_button.clicked.connect (() => { previous_requested (); });
            content.append (previous_button);

            play_button = media_button (
                "media-playback-start-symbolic", "Play");
            play_button.add_css_class ("suggested-action");
            play_button.clicked.connect (() => { playback.toggle (); });
            content.append (play_button);

            next_button = media_button (
                "media-skip-forward-symbolic", "Next voice message");
            next_button.clicked.connect (() => { next_requested (); });
            content.append (next_button);

            var details = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
            details.hexpand = true;
            details.valign = Gtk.Align.CENTER;

            var metadata = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            sender_label = new Gtk.Label ("");
            sender_label.add_css_class ("conversation-media-sender");
            sender_label.xalign = 0;
            sender_label.ellipsize = Pango.EllipsizeMode.END;
            metadata.append (sender_label);

            sent_label = new Gtk.Label ("");
            sent_label.add_css_class ("conversation-media-sent");
            sent_label.xalign = 0;
            sent_label.ellipsize = Pango.EllipsizeMode.END;
            metadata.append (sent_label);

            speed_dropdown = new Gtk.DropDown.from_strings ({
                "0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×",
                "3×", "4×", "5×"
            });
            speed_dropdown.add_css_class ("conversation-media-speed");
            speed_dropdown.valign = Gtk.Align.CENTER;
            speed_dropdown.tooltip_text = "Playback speed";
#if A11Y
            speed_dropdown.update_property (
                Gtk.AccessibleProperty.LABEL, "Playback speed", -1);
#endif
            speed_dropdown.notify["selected"].connect (() => {
                if (syncing_speed) return;
                playback.change_playback_rate (
                    AudioPlayback.rate_for_index (speed_dropdown.selected));
                sync_speed ();
            });
            metadata.append (speed_dropdown);
            details.append (metadata);

            progress = new Gtk.Scale.with_range (
                Gtk.Orientation.HORIZONTAL, 0.0, 1.0, 0.001);
            progress.draw_value = false;
            progress.hexpand = true;
            progress.valign = Gtk.Align.CENTER;
            progress.add_css_class ("conversation-media-progress");
            progress.change_value.connect ((scroll, value) => {
                playback.seek_fraction (value);
                return false;
            });
            details.append (progress);
            content.append (details);

            time_label = new Gtk.Label ("0:00");
            time_label.add_css_class ("conversation-media-time");
            time_label.width_chars = 11;
            time_label.xalign = 1;
            time_label.valign = Gtk.Align.CENTER;
            content.append (time_label);

            close_button = media_button (
                "window-close-symbolic", "Close player");
            close_button.clicked.connect (() => { playback.stop (); });
            content.append (close_button);

            revealer.child = content;
            /* A revealer only scales the axis it animates, so a collapsed
               SLIDE_DOWN revealer still reports its child's full width. That
               pinned the whole window to this bar's ~330px minimum even with
               no voice note playing, and once the window was forced narrower
               the conversation overflowed and clipped from the right — taking
               the compose bar's send button with it. An invisible child
               measures 0, so drop it out of measurement while collapsed. */
            content.visible = false;
            revealer.notify["child-revealed"].connect (() => {
                if (!revealer.reveal_child && !revealer.child_revealed) {
                    content.visible = false;
                }
            });
            append (revealer);

            var click = new Gtk.GestureClick ();
            click.button = Gdk.BUTTON_PRIMARY;
            click.released.connect ((n_press, x, y) => {
                var item = playback.current_item;
                if (item != null && !pointer_is_on_control (x, y)) {
                    message_requested (item.account_id, item.chat_id,
                                       item.message_id);
                }
            });
            add_controller (click);

            item_handler = playback.notify["current-item"].connect (sync_item);
            current_handler = playback.notify["current-message-id"].connect (
                sync_playback);
            playing_handler = playback.notify["playing"].connect (sync_playback);
            seekable_handler = playback.notify["can-seek"].connect (sync_playback);
            external_handler = playback.notify["external-backend"].connect (
                sync_playback);
            position_handler = playback.notify["position-us"].connect (sync_playback);
            duration_handler = playback.notify["duration-us"].connect (sync_playback);
            rate_handler = playback.notify["playback-rate"].connect (sync_speed);
            previous_handler = playback.notify["has-previous"].connect (
                sync_navigation);
            next_handler = playback.notify["has-next"].connect (sync_navigation);
            sync_item ();
        }

        private Gtk.Button media_button (string icon_name, string tooltip) {
            var button = new Gtk.Button.from_icon_name (icon_name);
            button.add_css_class ("flat");
            button.add_css_class ("circular");
            button.valign = Gtk.Align.CENTER;
            button.tooltip_text = tooltip;
            return button;
        }

        private void sync_playback () {
            bool matches = message_id > 0
                && playback.current_message_id == message_id;
            bool is_playing = matches && playback.playing;
            play_button.icon_name = is_playing
                ? "media-playback-pause-symbolic"
                : "media-playback-start-symbolic";
            play_button.tooltip_text = is_playing ? "Pause" : "Play";

            int64 position = matches ? playback.position_us : 0;
            int64 duration = matches ? playback.duration_us : 0;
            double fraction = duration > 0
                ? double.min (1.0, (double) position / (double) duration) : 0.0;
            progress.set_value (fraction);
            progress.visible = !playback.external_backend;
            progress.sensitive = matches && playback.can_seek;
            progress.tooltip_text = progress.sensitive
                ? "Drag to seek"
                : (playback.external_backend
                    ? "Seeking is unavailable with the system audio player"
                    : "Seeking will be available after the audio loads");
            time_label.label = format_playing_time (position, duration);
            sync_speed ();
        }

        private void sync_speed () {
            syncing_speed = true;
            speed_dropdown.selected = AudioPlayback.index_for_rate (
                playback.playback_rate);
            syncing_speed = false;
            speed_dropdown.sensitive = message_id > 0
                && playback.can_change_speed;
            speed_dropdown.tooltip_text = playback.can_change_speed
                ? "Playback speed"
                : "Install GstPlay, mpv, or ffplay to change playback speed";
        }

        private void sync_item () {
            var item = playback.current_item;
            if (item == null) {
                message_id = 0;
                revealer.reveal_child = false;
                return;
            }
            message_id = item.message_id;
            avatar.text = item.sender_name;
            avatar.custom_image = load_avatar (item.avatar_path);
            avatar.tooltip_text = item.sender_name;
            sender_label.label = item.sender_name;
            sender_label.tooltip_text = item.sender_address ?? item.sender_name;
            sent_label.label = format_sent_timestamp (item.sent_timestamp);
            sent_label.tooltip_text = sent_label.label;
            /* Must precede reveal_child: the revealer measures a hidden child
               as zero, so the slide-down would have nothing to animate. */
            content.visible = true;
            revealer.reveal_child = true;
            sync_navigation ();
            sync_playback ();
        }

        private void sync_navigation () {
            previous_button.sensitive = playback.current_item != null
                && playback.has_previous;
            next_button.sensitive = playback.current_item != null
                && playback.has_next;
        }

        private bool pointer_is_on_control (double x, double y) {
            Gtk.Widget? widget = pick (x, y, Gtk.PickFlags.DEFAULT);
            while (widget != null && widget != this) {
                if (widget == previous_button || widget == play_button
                        || widget == next_button || widget == close_button
                        || widget == progress || widget == speed_dropdown)
                    return true;
                widget = widget.get_parent ();
            }
            return false;
        }

        private static string format_sent_timestamp (int64 timestamp) {
            var when = format_date_time (timestamp);
            return when.length > 0 ? "Sent " + when : "";
        }

        internal static string format_playing_time (int64 position_us,
                                                    int64 duration_us) {
            string position = format_duration (position_us);
            return duration_us > 0
                ? "%s / %s".printf (position, format_duration (duration_us))
                : position;
        }

        private static string format_duration (int64 microseconds) {
            int64 total_seconds = int64.max (0, microseconds) / 1000000;
            int64 hours = total_seconds / 3600;
            int64 minutes = (total_seconds % 3600) / 60;
            int64 seconds = total_seconds % 60;
            string minutes_text = minutes.to_string ("%02" + int64.FORMAT);
            string seconds_text = seconds.to_string ("%02" + int64.FORMAT);
            return hours > 0
                ? "%s:%s:%s".printf (
                    hours.to_string (), minutes_text, seconds_text)
                : "%s:%s".printf (minutes.to_string (), seconds_text);
        }

        public override void dispose () {
            ulong[] handlers = {
                current_handler, item_handler, playing_handler, seekable_handler,
                external_handler, position_handler, duration_handler,
                previous_handler, next_handler, rate_handler
            };
            foreach (ulong handler in handlers) {
                if (handler != 0) playback.disconnect (handler);
            }
            current_handler = item_handler = playing_handler = 0;
            seekable_handler = previous_handler = next_handler = 0;
            external_handler = position_handler = duration_handler = 0;
            rate_handler = 0;
            base.dispose ();
        }
    }
}
