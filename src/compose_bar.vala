namespace Dc {

    /**
     * Compose bar at the bottom of the message view.
     * Contains a text entry, file attach button, and send button.
     */
    public class ComposeBar : Gtk.Box {

        /* When false (default), Return sends and Shift+Return inserts a
           newline. When true, the roles are swapped. */
        public bool shift_enter_sends { get; set; default = false; }

        /* Strip known tracking parameters from URLs in pasted text. */
        public bool clean_pasted_links { get; set; default = false; }

        /* Ask for Open Graph previews of pasted links (see LinkPreview);
           the owner fetches them and hands the images back through
           add_link_preview(). */
        public bool link_previews { get; set; default = false; }
        /* `generation` identifies the composer state the request was
           made for; add_link_preview() drops results for a stale one. */
        public signal void link_previews_requested (string[] urls,
            uint generation);

        public signal void send_message (string text, string? file_path,
            string? file_name, int quote_msg_id);
        /* `text` is the transcription typed into the composer alongside the
           recording, empty for a plain voice message. `temporary` marks a file
           the receiver of this signal owns and must delete after sending; a
           voice draft restored from the blob directory is not temporary. */
        public signal void send_voice_message (string file_path, string text,
            int quote_msg_id, bool temporary);
        public signal void edit_message (int msg_id, string new_text);
        public signal void edit_last_requested ();
        public signal void draft_changed (string text, string? file_path,
            string? file_name, int quote_msg_id, bool voice);

        private Gtk.TextView text_view;
        private Gtk.Label placeholder_label;
        private string placeholder_default = "Type a message";
        private Gtk.Button attach_button;
        private Gtk.MenuButton emoji_button;
        private const string EMOJI_TRIGGER_START_MARK = "parla-emoji-trigger-start";
        private const string EMOJI_TRIGGER_END_MARK = "parla-emoji-trigger-end";
        private Gtk.Button cancel_attach_button;
        private Gtk.Button cancel_edit_button;
        private Gtk.Stack send_stack;
        private Gtk.MenuButton sticker_button;
        private Gtk.Stack compose_mode_stack;
        private Gtk.Label recording_time_label;
        private Gtk.Stack recording_action_stack;
        private Gtk.Button recording_stop_button;
        private Gtk.Button transcribe_button;
        private AudioRecorder? audio_recorder = null;
        /* Path being transcribed for the composer, null when idle. */
        private string? transcribing_path = null;
        private ulong transcriber_handler = 0;
        private int64 recording_started_us = 0;
        private uint recording_timer = 0;
        private Gtk.Label reply_label;
        private Gtk.Box reply_bar;
        private Gtk.Box attachment_bar;
        private Gtk.Box long_msg_bar;
        private Gtk.Picture attachment_picture;
        private Gtk.Image attachment_icon;
        private Gtk.Label attachment_name_label;
        private Gtk.Label attachment_meta_label;
        private string? pending_file = null;
        private string? pending_file_name = null;
        private bool pending_file_is_temp = false;
        /* The pending attachment is a voice recording: it must be sent as a
           Voice message, not as a plain audio file. */
        private bool pending_file_is_voice = false;
        private string[] extra_pending_files = {};
        private string[] extra_pending_file_names = {};
        private string[] extra_pending_temp_files = {};
        /* Caption sent with each extra file; "" for plain attachments,
           the page title/description for a link preview. */
        private string[] extra_pending_captions = {};
        /* Bumped whenever the pending attachments are cleared or the
           composer switches chats, so late preview fetches for an old
           state are discarded. */
        private uint preview_generation = 1;
        private string[] previewed_urls = {};
        private int editing_msg_id = 0;
        private int replying_msg_id = 0;
        private MentionRoster? mention_roster = null;
        private Gtk.Popover mention_popover;
        private Gtk.ListBox mention_list;
        private bool mention_popup_visible = false;
        private int mention_index = 0;
        private GenericArray<string> mention_tokens = new GenericArray<string> ();
        private const string MENTION_ANCHOR_MARK = "parla-mention-anchor";
        public const string VOICE_FILE_NAME = "voice-message.m4a";
        private bool suppress_draft_signal = false;
        private bool has_suspended_draft = false;
        private string suspended_draft_text = "";
        private string? suspended_draft_file = null;
        private string? suspended_draft_file_name = null;
        private bool suspended_draft_file_is_temp = false;
        private bool suspended_draft_file_is_voice = false;
        private string[] suspended_extra_draft_files = {};
        private string[] suspended_extra_draft_file_names = {};
        private string[] suspended_extra_draft_captions = {};
        private int suspended_replying_msg_id = 0;
        private string suspended_reply_label = "";
        private bool closed = false;
        /* Last natural height a resize was queued for; guards the
           vadjustment-driven requeue below against self-feeding. */

        public ComposeBar () {
            Object (
                orientation: Gtk.Orientation.VERTICAL,
                spacing: 0
            );
            add_css_class ("compose-bar");
            hexpand = true;
            halign = Gtk.Align.FILL;
            margin_start = 8;
            margin_end = 8;
            margin_top = 6;
            margin_bottom = 6;

            reply_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            reply_bar.add_css_class ("reply-bar");
            reply_bar.visible = false;

            reply_label = new Gtk.Label ("");
            reply_label.add_css_class ("reply-label");
            reply_label.halign = Gtk.Align.START;
            reply_label.valign = Gtk.Align.START;
            reply_label.hexpand = true;
            reply_label.xalign = 0;
            reply_label.wrap = true;
            reply_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            reply_label.lines = 3;
            reply_label.ellipsize = Pango.EllipsizeMode.END;
            reply_bar.append (reply_label);

            var cancel_reply_button = icon_button (
                "window-close-symbolic", "Cancel reply", true);
            cancel_reply_button.clicked.connect (cancel_reply);
            reply_bar.append (cancel_reply_button);

            append (reply_bar);

            attachment_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            attachment_bar.add_css_class ("attachment-bar");
            attachment_bar.visible = false;

            attachment_picture = new Gtk.Picture ();
            attachment_picture.add_css_class ("attachment-preview-image");
            attachment_picture.content_fit = Gtk.ContentFit.COVER;
            attachment_picture.set_size_request (72, 72);
            attachment_picture.can_shrink = true;
            attachment_bar.append (attachment_picture);

            attachment_icon = new Gtk.Image ();
            attachment_icon.add_css_class ("attachment-preview-icon");
            attachment_icon.pixel_size = 36;
            attachment_icon.valign = Gtk.Align.CENTER;
            attachment_bar.append (attachment_icon);

            var attachment_info = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            attachment_info.valign = Gtk.Align.CENTER;
            attachment_info.hexpand = true;

            attachment_name_label = new Gtk.Label ("");
            attachment_name_label.add_css_class ("attachment-preview-name");
            attachment_name_label.halign = Gtk.Align.START;
            attachment_name_label.xalign = 0;
            attachment_name_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            attachment_name_label.max_width_chars = 40;
            attachment_name_label.single_line_mode = true;
            attachment_info.append (attachment_name_label);

            attachment_meta_label = new Gtk.Label ("");
            attachment_meta_label.add_css_class ("attachment-preview-meta");
            attachment_meta_label.halign = Gtk.Align.START;
            attachment_meta_label.xalign = 0;
            attachment_meta_label.ellipsize = Pango.EllipsizeMode.END;
            attachment_info.append (attachment_meta_label);

            attachment_bar.append (attachment_info);

            var remove_attachment_button = icon_button (
                "window-close-symbolic", "Remove attachment", true);
            remove_attachment_button.clicked.connect (clear_attachment);
            attachment_bar.append (remove_attachment_button);

            append (attachment_bar);

            long_msg_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            long_msg_bar.add_css_class ("long-message-bar");
            long_msg_bar.visible = false;
            var long_msg_icon = new Gtk.Image.from_icon_name (
                "dialog-information-symbolic");
            long_msg_bar.append (long_msg_icon);
            var long_msg_label = new Gtk.Label (
                "Long message: recipients get a shortened preview with a "
                + "“Show Full Message” button, and it cannot be "
                + "edited after sending");
            long_msg_label.add_css_class ("long-message-label");
            long_msg_label.halign = Gtk.Align.START;
            long_msg_label.xalign = 0;
            long_msg_label.wrap = true;
            long_msg_bar.append (long_msg_label);
            append (long_msg_bar);

            var input_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            input_row.hexpand = true;
            input_row.halign = Gtk.Align.FILL;

            /* Action buttons stay pinned to the bottom of the row, so they
               keep their place next to the last text line when a
               multi-line draft makes the entry grow. */
            attach_button = icon_button (
                "mail-attachment-symbolic", "Attach file");
            attach_button.clicked.connect (on_attach_clicked);
            attach_button.valign = Gtk.Align.END;
            input_row.append (attach_button);

            emoji_button = new Gtk.MenuButton ();
            emoji_button.icon_name = "face-smile-symbolic";
            emoji_button.add_css_class ("flat");
            emoji_button.tooltip_text = "Insert emoji";
            emoji_button.valign = Gtk.Align.END;
            var emoji_chooser = create_emoji_chooser ();
            if (emoji_chooser != null) {
                emoji_chooser.emoji_picked.connect (on_emoji_picked);
                emoji_chooser.closed.connect (() => {
                    GLib.Idle.add (() => {
                        clear_emoji_trigger_marks ();
                        return GLib.Source.REMOVE;
                    });
                });
                emoji_button.set_popover (emoji_chooser);
            } else {
                emoji_button.sensitive = false;
                emoji_button.tooltip_text = "Emoji picker unavailable";
            }
            input_row.append (emoji_button);

            cancel_attach_button = icon_button (
                "edit-clear-symbolic", "Remove attachment");
            cancel_attach_button.clicked.connect (clear_attachment);
            cancel_attach_button.visible = false;
            cancel_attach_button.valign = Gtk.Align.END;
            input_row.append (cancel_attach_button);

            cancel_edit_button = icon_button (
                "edit-undo-symbolic", "Cancel editing");
            cancel_edit_button.clicked.connect (cancel_edit);
            cancel_edit_button.visible = false;
            cancel_edit_button.valign = Gtk.Align.END;
            input_row.append (cancel_edit_button);

            text_view = new Gtk.TextView ();
            text_view.wrap_mode = Gtk.WrapMode.WORD_CHAR;
            text_view.accepts_tab = false;
            /* Symmetric margins define the pill height (no CSS min-height),
               so the text is always vertically centered. */
            text_view.top_margin = 8;
            text_view.bottom_margin = 8;
            text_view.left_margin = 12;
            text_view.right_margin = 12;
            text_view.pixels_above_lines = 0;
            text_view.pixels_below_lines = 0;
            text_view.pixels_inside_wrap = 0;
            text_view.hexpand = true;
            text_view.vexpand = false;
            text_view.add_css_class ("compose-entry");

            /* Placeholder is anchored to the top with the exact same
               top margin as the text view, so its baseline matches the
               first line of typed text instead of relying on valign. */
            placeholder_label = new Gtk.Label (placeholder_default);
            placeholder_label.add_css_class ("compose-placeholder");
            placeholder_label.halign = Gtk.Align.START;
            placeholder_label.valign = Gtk.Align.START;
            placeholder_label.margin_start = 12;
            placeholder_label.margin_top = 8;
            placeholder_label.can_target = false;
            placeholder_label.ellipsize = Pango.EllipsizeMode.END;

            /* The entry grows with its content only up to a cap, then
               scrolls internally. Without the cap a long draft makes the
               compose bar taller than the window and pushes the send
               button out of sight. The scrolled window also owns the text
               view's vadjustment, replacing the manual stale-height
               workaround a bare TextView needed here before. */
            var entry_scroll = new Gtk.ScrolledWindow ();
            entry_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            /* AUTOMATIC (EXTERNAL skips natural-height propagation and
               renders a restored multi-line draft blank). The scrollbar
               slider's 40px theme minimum would put a two-row floor under
               the empty entry, so it is shrunk in the CSS
               (.compose-entry-scroll scrollbar slider). */
            entry_scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            entry_scroll.propagate_natural_height = true;
            entry_scroll.min_content_height = 36;
            entry_scroll.max_content_height = 220;
            entry_scroll.add_css_class ("compose-entry-scroll");
            entry_scroll.child = text_view;

            var entry_overlay = new Gtk.Overlay ();
            entry_overlay.child = entry_scroll;
            entry_overlay.add_overlay (placeholder_label);
            entry_overlay.hexpand = true;
            entry_overlay.halign = Gtk.Align.FILL;
            entry_overlay.valign = Gtk.Align.CENTER;

            text_view.buffer.changed.connect (() => {
                update_placeholder ();
                update_send_stack ();
                notify_draft_changed ();
                update_mention_popup ();
                update_long_message_hint ();
            });
            /* AppKit invokes this action signal directly for Command+V, so
               handle the signal rather than relying only on GDK key events. */
            text_view.paste_clipboard.connect (on_paste_clipboard);
            update_placeholder ();

            var focus_ctrl = new Gtk.EventControllerFocus ();
            focus_ctrl.enter.connect (() => { set_entry_active (true); });
            focus_ctrl.leave.connect (() => {
                set_entry_active (false);
                hide_mention_popup ();
            });
            text_view.add_controller (focus_ctrl);

            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.key_pressed.connect (on_entry_key_pressed);
            text_view.add_controller (key_ctrl);
            input_row.append (entry_overlay);

            var send_button = icon_button (
                "go-up-symbolic", "Send message", true, "suggested-action");
            send_button.clicked.connect (on_send);

            sticker_button = new Gtk.MenuButton ();
            sticker_button.icon_name = "sticker-symbolic";
            sticker_button.add_css_class ("flat");
            sticker_button.add_css_class ("circular");
            sticker_button.tooltip_text = "Send a sticker";
            sticker_button.valign = Gtk.Align.CENTER;
            var sticker_picker = new StickerPicker ();
            sticker_picker.sticker_picked.connect (on_sticker_picked);
            sticker_button.set_popover (sticker_picker);

            var idle_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            idle_actions.append (sticker_button);
            var record_button = icon_button (
                "audio-input-microphone-symbolic", "Record a voice message", true);
            record_button.clicked.connect (start_audio_recording);
            idle_actions.append (record_button);

            /* Idle actions collapse to one send button as soon as text appears. */
            send_stack = new Gtk.Stack ();
            send_stack.valign = Gtk.Align.END;
            send_stack.hhomogeneous = false;
            send_stack.add_named (send_button, "send");
            send_stack.add_named (idle_actions, "idle");
            input_row.append (send_stack);
            update_send_stack ();

            var recording_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            recording_row.hexpand = true;

            var cancel_recording_button = icon_button (
                "window-close-symbolic", "Cancel voice message", true);
            cancel_recording_button.clicked.connect (cancel_audio_recording);
            recording_row.append (cancel_recording_button);

            recording_time_label = new Gtk.Label ("00:00");
            recording_time_label.hexpand = true;
            recording_time_label.halign = Gtk.Align.CENTER;
            recording_row.append (recording_time_label);

            recording_stop_button = icon_button (
                "media-playback-stop-symbolic", "Stop recording", true,
                "destructive-action");
            recording_stop_button.clicked.connect (stop_audio_recording);
            /* Offered once the recording is finished: transcribe it and move
               both the audio and its text into the composer, so the message
               carries a readable version of what was said. */
            transcribe_button = new Gtk.Button.with_label ("Transcribe");
            transcribe_button.add_css_class ("flat");
            transcribe_button.valign = Gtk.Align.CENTER;
            transcribe_button.tooltip_text =
                "Transcribe the recording into the message text";
            transcribe_button.visible = false;
            transcribe_button.clicked.connect (transcribe_audio_recording);
            recording_row.append (transcribe_button);

            var recording_send_button = icon_button (
                "go-up-symbolic", "Send voice message", true,
                "suggested-action");
            recording_send_button.clicked.connect (send_audio_recording);

            recording_action_stack = new Gtk.Stack ();
            recording_action_stack.valign = Gtk.Align.CENTER;
            recording_action_stack.add_named (recording_stop_button, "stop");
            recording_action_stack.add_named (recording_send_button, "send");
            recording_row.append (recording_action_stack);

            compose_mode_stack = new Gtk.Stack ();
            compose_mode_stack.add_named (input_row, "compose");
            compose_mode_stack.add_named (recording_row, "recording");
            compose_mode_stack.visible_child_name = "compose";
            append (compose_mode_stack);

            build_mention_popover ();
        }

        /** Release resources that are parented outside the normal box tree or
            connected to process-wide helpers. ConversationView calls this
            before removing an evicted chat from its GtkStack. */
        public void close () {
            if (closed) return;
            closed = true;
            stop_recording_timer ();
            if (transcriber_handler != 0) {
                Transcriber.shared ().disconnect (transcriber_handler);
                transcriber_handler = 0;
            }
            if (audio_recorder != null) {
                audio_recorder.cancel ();
                audio_recorder = null;
            }
            mention_popup_visible = false;
            mention_popover.popdown ();
            if (mention_popover.get_parent () != null)
                mention_popover.unparent ();
        }

        public override void dispose () {
            close ();
            base.dispose ();
        }

        private void build_mention_popover () {
            mention_list = new Gtk.ListBox ();
            mention_list.selection_mode = Gtk.SelectionMode.SINGLE;
            mention_list.add_css_class ("menu");
            mention_list.row_activated.connect ((row) => {
                mention_index = row.get_index ();
                accept_mention ();
            });

            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.propagate_natural_width = true;
            scroll.max_content_height = 260;
            /* Without a floor the popover collapses to the widest glyph and the
               names ellipsize to "…". */
            scroll.min_content_width = 260;
            scroll.max_content_width = 360;
            scroll.child = mention_list;

            mention_popover = new Gtk.Popover ();
            /* autohide=false keeps focus in the entry so typing keeps filtering
               the list; we drive show/hide ourselves. */
            mention_popover.autohide = false;
            mention_popover.has_arrow = false;
            mention_popover.position = Gtk.PositionType.TOP;
            mention_popover.add_css_class ("mention-popover");
            mention_popover.child = scroll;
            mention_popover.set_parent (text_view);
        }

        private Gtk.Button icon_button (string icon_name, string tooltip,
                                        bool circular = false,
                                        string style = "flat") {
            var button = new Gtk.Button.from_icon_name (icon_name);
            button.add_css_class (style);
            if (circular) button.add_css_class ("circular");
            button.tooltip_text = tooltip;
            button.valign = Gtk.Align.CENTER;
            return button;
        }

        public void set_mention_roster (MentionRoster? roster) {
            this.mention_roster = roster;
            if (roster == null) hide_mention_popup ();
        }

        /* Show/refresh the mention popup when the caret sits in an "@query"
           token that starts the message or follows whitespace. */
        private void update_mention_popup () {
            if (mention_roster == null || !mention_roster.has_members ()
                || editing_msg_id > 0) {
                hide_mention_popup ();
                return;
            }

            Gtk.TextIter cursor;
            text_view.buffer.get_iter_at_mark (out cursor,
                                               text_view.buffer.get_insert ());

            Gtk.TextIter at_iter = cursor;
            bool found = false;
            Gtk.TextIter probe = cursor;
            int steps = 0;
            while (probe.backward_char ()) {
                unichar ch = probe.get_char ();
                if (ch == '@') {
                    Gtk.TextIter before = probe;
                    bool boundary = !before.backward_char ()
                        || before.get_char ().isspace ();
                    if (boundary) {
                        found = true;
                        at_iter = probe;
                    }
                    break;
                }
                if (ch.isspace ()) break;
                if (++steps > 64) break;
            }

            if (!found) {
                hide_mention_popup ();
                return;
            }

            Gtk.TextIter q = at_iter;
            q.forward_char ();
            string query = text_view.buffer.get_text (q, cursor, false);

            populate_mention_list (query);
            if (mention_tokens.length == 0) {
                hide_mention_popup ();
                return;
            }

            var buf = text_view.buffer;
            var mark = buf.get_mark (MENTION_ANCHOR_MARK);
            if (mark != null) buf.move_mark (mark, at_iter);
            else buf.create_mark (MENTION_ANCHOR_MARK, at_iter, true);

            position_and_show_mention_popup (cursor);
        }

        private void populate_mention_list (string query) {
            clear_listbox (mention_list);
            mention_tokens = new GenericArray<string> ();

            string q = query.down ();
            var members = mention_roster.members;
            for (int i = 0; i < members.length && mention_tokens.length < 12; i++) {
                var m = members[i];
                if (m.is_self) continue;
                string name = m.display_name;
                if (name.length > 0
                    && (q.length == 0 || name.down ().contains (q))) {
                    add_mention_row (name, m.address.length > 0 ? m.address : null,
                        name, m.avatar_path, name);
                }
                if (m.address.length > 0 && mention_tokens.length < 12
                    && (q.length == 0 || m.address.down ().contains (q))) {
                    add_mention_row (m.address, name.length > 0 ? name : null,
                        m.address, m.avatar_path, name.length > 0 ? name : m.address);
                }
            }

            mention_index = 0;
            select_mention_index ();
        }

        private void add_mention_row (string title, string? subtitle,
                                      string token, string? avatar_path,
                                      string avatar_text) {
            var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row_box.margin_start = 8;
            row_box.margin_end = 8;
            row_box.margin_top = 4;
            row_box.margin_bottom = 4;
            row_box.hexpand = true;

            row_box.append (presence_avatar (28, avatar_text, avatar_path, false));

            var text_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            text_box.valign = Gtk.Align.CENTER;
            text_box.hexpand = true;

            var t = new Gtk.Label (title);
            t.xalign = 0;
            t.halign = Gtk.Align.START;
            t.hexpand = true;
            t.ellipsize = Pango.EllipsizeMode.END;
            text_box.append (t);

            if (subtitle != null && subtitle.length > 0) {
                var s = new Gtk.Label (subtitle);
                s.add_css_class ("dim-label");
                s.add_css_class ("caption");
                s.xalign = 0;
                s.halign = Gtk.Align.START;
                s.hexpand = true;
                s.ellipsize = Pango.EllipsizeMode.END;
                text_box.append (s);
            }

            row_box.append (text_box);

            var row = new Gtk.ListBoxRow ();
            row.child = row_box;
            mention_list.append (row);
            mention_tokens.add (token);
        }

        private void position_and_show_mention_popup (Gtk.TextIter cursor) {
            Gdk.Rectangle loc;
            text_view.get_iter_location (cursor, out loc);
            int wx, wy;
            text_view.buffer_to_window_coords (Gtk.TextWindowType.WIDGET,
                loc.x, loc.y, out wx, out wy);
            Gdk.Rectangle r = { wx, wy, 1, loc.height };
            mention_popover.set_pointing_to (r);
            if (!mention_popup_visible) {
                mention_popover.popup ();
                mention_popup_visible = true;
            }
        }

        private void select_mention_index () {
            var row = mention_list.get_row_at_index (mention_index);
            if (row != null) mention_list.select_row (row);
        }

        private void move_mention_selection (int delta) {
            int n = (int) mention_tokens.length;
            if (n == 0) return;
            mention_index = int.min (n - 1, int.max (0, mention_index + delta));
            select_mention_index ();
        }

        private void accept_mention () {
            if (mention_index < 0 || mention_index >= mention_tokens.length) {
                hide_mention_popup ();
                return;
            }
            string token = mention_tokens[mention_index];
            var buf = text_view.buffer;
            var mark = buf.get_mark (MENTION_ANCHOR_MARK);
            if (mark == null) {
                hide_mention_popup ();
                return;
            }
            Gtk.TextIter at_iter, cursor;
            buf.get_iter_at_mark (out at_iter, mark);
            buf.get_iter_at_mark (out cursor, buf.get_insert ());
            buf.@delete (ref at_iter, ref cursor);
            string insert = "@" + token + " ";
            buf.insert (ref at_iter, insert, insert.length);
            hide_mention_popup ();
            text_view.grab_focus ();
        }

        private void hide_mention_popup () {
            if (mention_popup_visible) {
                mention_popover.popdown ();
                mention_popup_visible = false;
            }
            var mark = text_view.buffer.get_mark (MENTION_ANCHOR_MARK);
            if (mark != null) text_view.buffer.delete_mark (mark);
        }

        public void grab_entry_focus () {
            if (is_recording_mode ()) return;
            /* Gtk.TextView does not select text on grab_focus the way
               Gtk.Entry does, so a plain grab_focus is safe here.
               Defer to idle so focus lands after the current event
               (e.g. a global shortcut) has finished dispatching. */
            text_view.grab_focus ();
            GLib.Idle.add (() => {
                text_view.grab_focus ();
                return GLib.Source.REMOVE;
            });
        }

        /* Insert text at the cursor and take focus. Used by the window's
           type-ahead so pressing a key anywhere starts a message. */
        public void type_text (string text) {
            if (is_recording_mode ()) return;
            bool open_emoji = text == ":" && previous_char_is_colon ();
            text_view.buffer.insert_at_cursor (text, text.length);
            text_view.grab_focus ();
            if (open_emoji) open_emoji_picker_after_typed_colon ();
        }

        /* Replace the entry text with the cursor at the end, scrolled on
           screen once the text view has validated the new content. */
        private void set_entry_text (string text) {
            text_view.buffer.text = text;
            Gtk.TextIter end_iter;
            text_view.buffer.get_end_iter (out end_iter);
            text_view.buffer.place_cursor (end_iter);
            GLib.Idle.add (() => {
                text_view.scroll_mark_onscreen (text_view.buffer.get_insert ());
                return GLib.Source.REMOVE;
            });
        }

        private string get_text () {
            Gtk.TextIter start, end;
            text_view.buffer.get_bounds (out start, out end);
            return text_view.buffer.get_text (start, end, false);
        }

        private void notify_draft_changed () {
            if (suppress_draft_signal || editing_msg_id > 0) return;
            draft_changed (get_text (), pending_file, pending_file_name,
                replying_msg_id, pending_file_is_voice);
        }

        private void update_placeholder () {
            placeholder_label.visible = text_view.buffer.get_char_count () == 0;
        }

        /* Sticker and microphone actions sit in the send slot only while
           there is nothing to send. Typing immediately hides the microphone. */
        private void update_send_stack () {
            if (send_stack == null) return;
            bool idle = text_view.buffer.get_char_count () == 0
                && pending_file == null && editing_msg_id == 0;
            send_stack.visible_child_name = idle ? "idle" : "send";
        }

        private void on_sticker_picked (Sticker sticker) {
            if (editing_msg_id > 0) return;
            int qid = replying_msg_id;
            send_message ("", StickerStore.sticker_path (sticker.file_name),
                sticker.display_name, qid);
            suppress_draft_signal = true;
            cancel_reply ();
            suppress_draft_signal = false;
            notify_draft_changed ();
            text_view.grab_focus ();
        }

        private void start_audio_recording () {
            if (is_recording_mode () || editing_msg_id > 0
                || pending_file != null
                || text_view.buffer.get_char_count () > 0) return;

            AudioPlayback.shared ().stop ();

            var recorder = new AudioRecorder (
                AudioPlayer.prefer_system || Platform.is_macos ());
            recorder.completed.connect (() => {
                if (audio_recorder != recorder) return;
                recording_action_stack.visible_child_name = "send";
                /* Only a finished file can be handed to whisper. */
                transcribe_button.visible = Transcriber.available ();
            });
            recorder.failed.connect ((message) => {
                if (audio_recorder != recorder) return;
                leave_audio_recording_mode ();
                show_recording_error (message);
            });

            try {
                recorder.start ();
            } catch (Error e) {
                recorder.cancel ();
                show_recording_error (e.message);
                return;
            }

            audio_recorder = recorder;
            recording_started_us = GLib.get_monotonic_time ();
            recording_time_label.label = "00:00";
            recording_action_stack.visible_child_name = "stop";
            recording_stop_button.sensitive = true;
            recording_stop_button.tooltip_text = "Stop recording";
            compose_mode_stack.visible_child_name = "recording";
            recording_timer = Timeout.add_seconds (1, update_recording_time);
        }

        private bool update_recording_time () {
            int elapsed = (int) ((GLib.get_monotonic_time ()
                - recording_started_us) / 1000000);
            recording_time_label.label = "%02d:%02d".printf (
                elapsed / 60, elapsed % 60);
            return Source.CONTINUE;
        }

        private void stop_audio_recording () {
            if (audio_recorder == null) return;
            stop_recording_timer ();
            update_recording_time ();
            recording_stop_button.sensitive = false;
            recording_stop_button.tooltip_text = "Finishing recording…";
            audio_recorder.stop ();
        }

        /* Run whisper over the finished recording; on_transcription_updated
           moves the result into the composer. */
        private void transcribe_audio_recording () {
            if (audio_recorder == null || transcribing_path != null) return;
            string path = audio_recorder.output_path;
            if (path.length == 0) return;

            var transcriber = Transcriber.shared ();
            transcribing_path = path;
            transcribe_button.sensitive = false;
            transcribe_button.label = "Transcribing…";
            if (transcriber_handler == 0) {
                transcriber_handler = transcriber.updated.connect (
                    on_transcription_updated);
            }
            transcriber.transcribe (path);
        }

        private void on_transcription_updated (string path) {
            if (transcribing_path == null || path != transcribing_path) return;
            var transcriber = Transcriber.shared ();
            if (transcriber.is_running (path)) return;

            string? text = transcriber.result_for (path);
            transcribing_path = null;
            reset_transcribe_button ();
            if (text == null) {
                show_compose_toast ("Transcription is unavailable");
                return;
            }
            attach_recording_with_text (text);
        }

        /* Leave recording mode carrying the recording over as a pending voice
           attachment, with its transcription ready to edit in the entry. */
        private void attach_recording_with_text (string text) {
            if (audio_recorder == null) return;
            /* Take the file first: leaving recording mode discards whatever
               the recorder still owns. */
            string path = audio_recorder.take_output ();
            leave_audio_recording_mode ();
            if (path.length == 0) return;

            suppress_draft_signal = true;
            set_pending_attachment (path, VOICE_FILE_NAME, true);
            pending_file_is_voice = true;
            if (text.length > 0) set_entry_text (text);
            suppress_draft_signal = false;
            notify_draft_changed ();

            text_view.grab_focus ();
            if (text.length == 0) {
                show_compose_toast (
                    "No speech detected; the voice message is still attached");
            }
        }

        private void reset_transcribe_button () {
            transcribe_button.sensitive = true;
            transcribe_button.label = "Transcribe";
        }

        private void send_audio_recording () {
            if (audio_recorder == null) return;
            send_voice_message (audio_recorder.take_output (), "",
                replying_msg_id, true);
            leave_audio_recording_mode ();

            suppress_draft_signal = true;
            cancel_reply ();
            suppress_draft_signal = false;
            notify_draft_changed ();
        }

        private void cancel_audio_recording () {
            if (!is_recording_mode ()) return;
            leave_audio_recording_mode ();
        }

        private void leave_audio_recording_mode () {
            stop_recording_timer ();
            transcribing_path = null;
            reset_transcribe_button ();
            transcribe_button.visible = false;
            if (audio_recorder != null) {
                audio_recorder.cancel ();
                audio_recorder = null;
            }
            compose_mode_stack.visible_child_name = "compose";
            update_send_stack ();
        }

        private void stop_recording_timer () {
            if (recording_timer == 0) return;
            Source.remove (recording_timer);
            recording_timer = 0;
        }

        private bool is_recording_mode () {
            return compose_mode_stack.visible_child_name == "recording";
        }

        private void show_recording_error (string message) {
            show_compose_toast ("Recording failed: " + message);
        }

        private void show_compose_toast (string message) {
            var window = get_root () as Dc.Window;
            if (window != null) window.show_toast (message);
            else warning ("compose bar: %s", message);
        }

        private void set_entry_active (bool active) {
            if (active) {
                text_view.add_css_class ("compose-entry-active");
            } else {
                text_view.remove_css_class ("compose-entry-active");
            }
        }

        public bool can_accept_attachment () {
            return editing_msg_id == 0 && !is_recording_mode ();
        }

        public void set_pending_attachment (string file_path,
                                            string? file_name = null,
                                            bool is_temp = false,
                                            string caption = "") {
            string name = file_name ?? Path.get_basename (file_path);
            if (pending_file == null) {
                pending_file = file_path;
                pending_file_name = name;
                pending_file_is_temp = is_temp;
                populate_attachment_preview (file_path, name);
            } else {
                extra_pending_files += file_path;
                extra_pending_file_names += name;
                extra_pending_captions += caption;
                if (is_temp) extra_pending_temp_files += file_path;
                int count = 1 + extra_pending_files.length;
                attachment_picture.paintable = null;
                attachment_picture.visible = false;
                attachment_icon.icon_name = "mail-attachment-symbolic";
                attachment_icon.visible = true;
                attachment_name_label.label = "%d attachments".printf (count);
                attachment_meta_label.label = "%s + %d more".printf (
                    pending_file_name, count - 1);
                attachment_bar.visible = true;
            }
            cancel_attach_button.visible = true;
            update_send_stack ();
            notify_draft_changed ();
        }

        /** State token to pass along with link_previews_requested. */
        public uint current_preview_generation () {
            return preview_generation;
        }

        /** Attaches a fetched link preview image. Returns false (and
            takes no ownership of `image_path`) when the composer has
            moved on since `generation` was issued or cannot take
            attachments any more. */
        public bool add_link_preview (uint generation, string image_path,
                                      string file_name, string? title,
                                      string? description) {
            if (generation != preview_generation) return false;
            if (!can_accept_attachment ()) return false;
            string caption = title ?? "";
            if (description != null && description.length > 0)
                caption = caption.length > 0
                    ? "%s\n%s".printf (caption, description) : description;
            bool primary = pending_file == null;
            set_pending_attachment (image_path, file_name, true, caption);
            if (primary) {
                /* Show what the page advertises rather than the temp
                   file's name and size. */
                if (title != null && title.length > 0)
                    attachment_name_label.label = title;
                if (description != null && description.length > 0)
                    attachment_meta_label.label = description;
                else if (title != null && title.length > 0)
                    attachment_meta_label.label = "Link preview";
            }
            return true;
        }

        private void request_link_previews (string text) {
            string[] fresh = {};
            foreach (string url in LinkPreview.pick_urls (text)) {
                bool seen = false;
                foreach (string u in previewed_urls) {
                    if (u == url) { seen = true; break; }
                }
                if (seen) continue;
                previewed_urls += url;
                fresh += url;
            }
            if (fresh.length > 0)
                link_previews_requested (fresh, preview_generation);
        }

        private void populate_attachment_preview (string file_path, string file_name) {
            string mime = guess_mime (file_path);
            bool is_image = mime != null && mime.has_prefix ("image/");
            attachment_picture.visible = false;
            attachment_icon.visible = false;
            if (is_image) {
                try {
                    var pixbuf = new Gdk.Pixbuf.from_file_at_scale (
                        file_path, 256, 256, true);
                    var texture = texture_from_pixbuf (pixbuf);
                    attachment_picture.paintable = texture;
                    attachment_picture.visible = true;
                } catch (Error e) {
                    is_image = false;
                }
            }
            if (!is_image) {
                attachment_icon.icon_name = mime_icon_name (mime, file_path);
                attachment_icon.visible = true;
            }
            attachment_name_label.label = file_name;
            string size_str = format_size (file_size_or_zero (file_path));
            attachment_meta_label.label = mime != null
                ? "%s · %s".printf (mime, size_str)
                : size_str;
            attachment_bar.visible = true;
        }

        private static string? guess_mime (string file_path) {
            try {
                var info = GLib.File.new_for_path (file_path).query_info (
                    "standard::content-type",
                    GLib.FileQueryInfoFlags.NONE);
                string? ct = info.get_content_type ();
                if (ct != null) {
                    var mime = GLib.ContentType.get_mime_type (ct);
                    if (mime != null && mime.length > 0) return mime;
                }
            } catch (Error e) {
            }
            return null;
        }

        private static string mime_icon_name (string? mime, string file_path) {
            if (mime != null) {
                if (mime.has_prefix ("video/")) return "video-x-generic-symbolic";
                if (mime.has_prefix ("audio/")) return "audio-x-generic-symbolic";
                if (mime.has_prefix ("image/")) return "image-x-generic-symbolic";
                if (mime == "application/pdf") return "application-pdf-symbolic";
                if (mime.has_prefix ("text/")) return "text-x-generic-symbolic";
                if (mime == "application/zip" || mime == "application/x-tar" ||
                    mime == "application/gzip" || mime == "application/x-7z-compressed" ||
                    mime == "application/x-rar-compressed" ||
                    mime == "application/x-bzip" || mime == "application/x-bzip2")
                    return "package-x-generic-symbolic";
            }
            var lower = file_path.down ();
            if (lower.has_suffix (".pdf")) return "application-pdf-symbolic";
            if (lower.has_suffix (".zip") || lower.has_suffix (".tar") ||
                lower.has_suffix (".tgz") || lower.has_suffix (".gz") ||
                lower.has_suffix (".7z") || lower.has_suffix (".rar") ||
                lower.has_suffix (".bz2"))
                return "package-x-generic-symbolic";
            return "mail-attachment-symbolic";
        }

        private static int64 file_size_or_zero (string file_path) {
            try {
                var info = GLib.File.new_for_path (file_path).query_info (
                    "standard::size",
                    GLib.FileQueryInfoFlags.NONE);
                return info.get_size ();
            } catch (Error e) {
                return 0;
            }
        }

        private static string format_size (int64 bytes) {
            if (bytes <= 0) return "—";
            double v = bytes;
            string[] units = { "B", "KB", "MB", "GB" };
            int u = 0;
            while (v >= 1024.0 && u < units.length - 1) {
                v /= 1024.0;
                u++;
            }
            if (u == 0) return "%s %s".printf (((int64) v).to_string (), units[u]);
            return "%.1f %s".printf (v, units[u]);
        }

        private void clear_attachment () {
            if (pending_file_is_temp && pending_file != null) {
                try {
                    var f = GLib.File.new_for_path (pending_file);
                    f.@delete ();
                } catch (Error e) {
                }
            }
            pending_file = null;
            pending_file_name = null;
            pending_file_is_temp = false;
            pending_file_is_voice = false;
            foreach (string path in extra_pending_temp_files) {
                try {
                    var f = GLib.File.new_for_path (path);
                    f.@delete ();
                } catch (Error e) {
                }
            }
            extra_pending_files = {};
            extra_pending_file_names = {};
            extra_pending_temp_files = {};
            extra_pending_captions = {};
            preview_generation++;
            previewed_urls = {};
            cancel_attach_button.visible = false;
            attachment_bar.visible = false;
            attachment_picture.paintable = null;
            attachment_name_label.label = "";
            attachment_meta_label.label = "";
            placeholder_label.label = placeholder_default;
            update_send_stack ();
            notify_draft_changed ();
        }

        /* Mirrors core's truncate_by_lines() (tools.rs): a text is sent
           truncated once it reaches 38 effective lines, where a line
           wraps into a new one every 100 characters. Such messages get
           the has_html flag: recipients see a shortened bubble plus a
           "Show Full Message" button and the message cannot be edited
           after sending, so warn while composing. */
        private bool message_would_be_truncated (string text) {
            const int MAX_LINES = 38;
            const int MAX_LINE_LEN = 100;
            int lines = 0;
            int line_chars = 0;
            int i = 0;
            unichar c;
            while (text.get_next_char (ref i, out c)) {
                if (c == '\n') {
                    line_chars = 0;
                    lines++;
                } else {
                    line_chars++;
                    if (line_chars > MAX_LINE_LEN) {
                        line_chars = 1;
                        lines++;
                    }
                }
                if (lines == MAX_LINES) return true;
            }
            return false;
        }

        private void update_long_message_hint () {
            long_msg_bar.visible = editing_msg_id == 0
                && message_would_be_truncated (get_text ().strip ());
        }

        private void on_send () {
            hide_mention_popup ();
            string text = get_text ().strip ();
            if (editing_msg_id > 0) {
                if (text.length == 0) return;
                edit_message (editing_msg_id, text);
                cancel_edit ();
                return;
            }
            if (text.length == 0 && pending_file == null) return;
            int qid = replying_msg_id;
            if (pending_file != null && pending_file_is_voice) {
                /* Sent as a Voice message so it stays playable as a voice note
                   everywhere; the transcription rides along as its text. */
                send_voice_message (pending_file, text, qid,
                    pending_file_is_temp);
            } else if (pending_file != null) {
                send_message (text, pending_file,
                    pending_file_name ?? Path.get_basename (pending_file), qid);
            } else {
                send_message (text, null, null, qid);
            }
            for (int i = 0; i < extra_pending_files.length; i++) {
                send_message (
                    i < extra_pending_captions.length ? extra_pending_captions[i] : "",
                    extra_pending_files[i], extra_pending_file_names[i], 0);
            }
            suppress_draft_signal = true;
            cancel_reply ();
            /* Hand temp-file ownership to the in-flight async RPC. */
            pending_file_is_temp = false;
            extra_pending_temp_files = {};
            text_view.buffer.text = "";
            clear_attachment ();
            suppress_draft_signal = false;
            notify_draft_changed ();
        }

        public void begin_reply (int msg_id, string sender_name, string preview) {
            cancel_edit ();
            replying_msg_id = msg_id;
            reply_label.label = "%s: %s".printf (sender_name, shorten_preview (preview));
            reply_bar.visible = true;
            text_view.grab_focus ();
            notify_draft_changed ();
        }

        /* Keep at most 3 lines and bound total length so the reply bar
           never explodes when quoting long messages. The label itself
           also wraps + ellipsizes at 3 lines as a hard cap. */
        private static string shorten_preview (string text) {
            return Markdown.preview (text, 3, 240);
        }

        private void cancel_reply () {
            replying_msg_id = 0;
            reply_bar.visible = false;
            reply_label.label = "";
            notify_draft_changed ();
        }

        public void begin_edit (int msg_id, string current_text) {
            cancel_audio_recording ();
            suspend_current_draft ();
            suppress_draft_signal = true;
            cancel_reply ();
            clear_attachment ();
            editing_msg_id = msg_id;
            set_entry_text (current_text);
            suppress_draft_signal = false;
            placeholder_label.label = "Edit message…";
            cancel_edit_button.visible = true;
            attach_button.sensitive = false;
            update_send_stack ();
            text_view.grab_focus ();
        }

        private void cancel_edit () {
            if (editing_msg_id == 0) return;
            suppress_draft_signal = true;
            editing_msg_id = 0;
            text_view.buffer.text = "";
            placeholder_label.label = placeholder_default;
            cancel_edit_button.visible = false;
            attach_button.sensitive = true;
            restore_suspended_draft ();
            suppress_draft_signal = false;
            update_send_stack ();
            notify_draft_changed ();
        }

        private void suspend_current_draft () {
            has_suspended_draft = has_unsent_content ();
            if (!has_suspended_draft) return;

            suspended_draft_text = get_text ();
            suspended_draft_file = pending_file;
            suspended_draft_file_name = pending_file_name;
            suspended_draft_file_is_temp = pending_file_is_temp;
            suspended_draft_file_is_voice = pending_file_is_voice;
            suspended_extra_draft_files = extra_pending_files;
            suspended_extra_draft_file_names = extra_pending_file_names;
            suspended_extra_draft_captions = extra_pending_captions;
            suspended_replying_msg_id = replying_msg_id;
            suspended_reply_label = reply_label.label;
        }

        private void restore_suspended_draft () {
            /* Whether or not a draft comes back, previews requested for
               the previous chat must not land here. */
            preview_generation++;
            previewed_urls = {};
            if (!has_suspended_draft) return;

            text_view.buffer.text = suspended_draft_text;
            if (suspended_draft_file != null &&
                GLib.FileUtils.test (suspended_draft_file, GLib.FileTest.EXISTS)) {
                set_pending_attachment (suspended_draft_file,
                    suspended_draft_file_name, suspended_draft_file_is_temp);
                pending_file_is_voice = suspended_draft_file_is_voice;
            }
            for (int i = 0; i < suspended_extra_draft_files.length; i++) {
                string path = suspended_extra_draft_files[i];
                if (!GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) continue;
                set_pending_attachment (path,
                    i < suspended_extra_draft_file_names.length
                        ? suspended_extra_draft_file_names[i]
                        : Path.get_basename (path),
                    false,
                    i < suspended_extra_draft_captions.length
                        ? suspended_extra_draft_captions[i] : "");
            }
            if (suspended_replying_msg_id > 0) {
                replying_msg_id = suspended_replying_msg_id;
                reply_label.label = suspended_reply_label;
                reply_bar.visible = true;
            }

            has_suspended_draft = false;
            suspended_draft_text = "";
            suspended_draft_file = null;
            suspended_draft_file_name = null;
            suspended_extra_draft_files = {};
            suspended_extra_draft_file_names = {};
            suspended_extra_draft_captions = {};
            suspended_replying_msg_id = 0;
            suspended_reply_label = "";
        }

        public void restore_draft (Message draft) {
            if (editing_msg_id > 0 || has_unsent_content ()) return;

            suppress_draft_signal = true;
            cancel_reply ();
            clear_attachment ();

            set_entry_text (draft.text ?? "");

            if (draft.file_path != null && draft.file_path.length > 0 &&
                GLib.FileUtils.test (draft.file_path, GLib.FileTest.EXISTS)) {
                set_pending_attachment (draft.file_path, draft.file_name);
                pending_file_is_voice = draft.view_type != null
                    && draft.view_type.down () == "voice";
            }

            if (draft.quote_msg_id > 0) {
                replying_msg_id = draft.quote_msg_id;
                string sender = draft.quote_sender_name ?? "Message";
                string preview = draft.quote_text ?? draft.quote_msg_id.to_string ();
                reply_label.label = "%s: %s".printf (sender, shorten_preview (preview));
                reply_bar.visible = true;
            }

            suppress_draft_signal = false;
            update_placeholder ();
        }

        public bool has_active_mode () {
            return editing_msg_id != 0 || replying_msg_id != 0
                || pending_file != null || is_recording_mode ();
        }

        public bool has_unsent_content () {
            return text_view.buffer.get_char_count () > 0
                || replying_msg_id != 0 || pending_file != null
                || is_recording_mode ();
        }

        public bool entry_has_focus () {
            var root = get_root () as Gtk.Window;
            if (root == null) return false;
            var fw = root.get_focus ();
            return fw != null
                && (fw == text_view || fw.is_ancestor (text_view));
        }

        public void cancel_active_mode () {
            if (is_recording_mode ()) {
                cancel_audio_recording ();
                return;
            }
            cancel_edit ();
            cancel_reply ();
            clear_attachment ();
        }

        private void on_emoji_picked (string emoji) {
            if (!replace_emoji_trigger (emoji)) {
                text_view.buffer.insert_at_cursor (emoji, emoji.length);
            }
            /* The chooser restores focus to its menu button while closing,
               so defer a second focus grab until that has finished. */
            grab_entry_focus ();
        }

        private void on_attach_clicked () {
            var dialog = new Gtk.FileDialog ();
            dialog.title = "Select files to attach";
            var window = (Gtk.Window) get_root ();
            dialog.open_multiple.begin (window, null, (obj, res) => {
                try {
                    var files = dialog.open_multiple.end (res);
                    for (uint i = 0; i < files.get_n_items (); i++) {
                        var file = files.get_item (i) as GLib.File;
                        if (file == null) continue;
                        var path = file.get_path ();
                        if (path != null)
                            set_pending_attachment (path, file.get_basename ());
                    }
                } catch (Error e) {
                    if (!is_dialog_dismissal (e))
                        warning ("attachment picker: %s", e.message);
                }
            });
        }

        private bool on_entry_key_pressed (uint keyval, uint keycode,
                                           Gdk.ModifierType state) {
            /* While the mention autocomplete is open it owns navigation keys so
               Return picks a suggestion instead of sending, etc. */
            if (mention_popup_visible) {
                if (keyval == Gdk.Key.Down || keyval == Gdk.Key.KP_Down) {
                    move_mention_selection (1);
                    return true;
                }
                if (keyval == Gdk.Key.Up || keyval == Gdk.Key.KP_Up) {
                    move_mention_selection (-1);
                    return true;
                }
                if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter
                    || keyval == Gdk.Key.ISO_Enter || keyval == Gdk.Key.Tab) {
                    accept_mention ();
                    return true;
                }
                if (keyval == Gdk.Key.Escape) {
                    hide_mention_popup ();
                    return true;
                }
            }

            /* Escape (and dropping the active reply/edit/attachment mode) is
               handled centrally in the window key handler so the two-press
               behavior is consistent. */
            /* The emoji picker is opened by typing a second colon ("::"),
               so it only fires when one is already in front of the cursor. */
            if (is_plain_colon_key (keyval, state) && previous_char_is_colon ()) {
                open_emoji_picker_after_typed_colon ();
                return false;
            }

            if ((keyval == Gdk.Key.Up || keyval == Gdk.Key.KP_Up)
                && (state & (Gdk.ModifierType.SHIFT_MASK
                             | Gdk.ModifierType.CONTROL_MASK
                             | Gdk.ModifierType.ALT_MASK)) == 0
                && text_view.buffer.get_char_count () == 0
                && !has_active_mode ()) {
                edit_last_requested ();
                return true;
            }

            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (keyval == Gdk.Key.Return
                || keyval == Gdk.Key.KP_Enter
                || keyval == Gdk.Key.ISO_Enter) {
                bool should_send = shift_enter_sends ? shift : !shift;
                if (!should_send) return false; /* let TextView insert a newline */
                on_send ();
                return true;
            }

            bool primary_v = Platform.has_primary_modifier (state)
                          && (keyval == Gdk.Key.v || keyval == Gdk.Key.V);
            if (!primary_v && !(shift && keyval == Gdk.Key.Insert)) return false;

            start_clipboard_paste ();
            return true;
        }

        private void on_paste_clipboard () {
            /* The default handler converts clipboard text through a temporary
               GtkTextBuffer. Reading the string directly also works when the
               macOS clipboard contents predate application startup. */
            GLib.Signal.stop_emission_by_name (text_view, "paste-clipboard");
            start_clipboard_paste ();
        }

        private void start_clipboard_paste () {
            var clipboard = get_display ().get_clipboard ();
            bool replace_selection = text_view.buffer.has_selection;
            bool has_files = false;
            bool has_texture = false;
            if (can_accept_attachment ()) {
                var formats = clipboard.get_formats ();
                has_files = formats.contain_gtype (typeof (Gdk.FileList));
                has_texture = formats.contain_gtype (typeof (Gdk.Texture));
            }
            paste_from_clipboard.begin (clipboard, has_files, has_texture,
                replace_selection);
        }

        private static bool is_plain_colon_key (uint keyval, Gdk.ModifierType state) {
            if (keyval != Gdk.Key.colon) return false;
            var mods = state & (Gdk.ModifierType.CONTROL_MASK
                              | Gdk.ModifierType.ALT_MASK
                              | Gdk.ModifierType.SUPER_MASK
                              | Gdk.ModifierType.META_MASK);
            return mods == 0;
        }

        private bool previous_char_is_colon () {
            Gtk.TextIter cursor;
            Gtk.TextIter selection_start, selection_end;
            if (text_view.buffer.get_selection_bounds (out selection_start,
                                                        out selection_end)) {
                cursor = selection_start;
            } else {
                text_view.buffer.get_iter_at_mark (out cursor,
                                                   text_view.buffer.get_insert ());
            }
            Gtk.TextIter previous = cursor;
            if (!previous.backward_char ()) return false;
            return previous.get_char () == ':';
        }

        private void open_emoji_picker_after_typed_colon () {
            GLib.Idle.add (() => {
                if (emoji_button.get_popover () != null
                    && remember_typed_colon_trigger ()) {
                    emoji_button.popup ();
                }
                return GLib.Source.REMOVE;
            });
        }

        private bool remember_typed_colon_trigger () {
            clear_emoji_trigger_marks ();

            Gtk.TextIter end;
            text_view.buffer.get_iter_at_mark (out end, text_view.buffer.get_insert ());
            Gtk.TextIter start = end;
            if (!start.backward_char () || !start.backward_char ()) return false;
            if (text_view.buffer.get_text (start, end, false) != "::") return false;

            text_view.buffer.create_mark (EMOJI_TRIGGER_START_MARK, start, true);
            text_view.buffer.create_mark (EMOJI_TRIGGER_END_MARK, end, false);
            return true;
        }

        private bool replace_emoji_trigger (string emoji) {
            var start_mark = text_view.buffer.get_mark (EMOJI_TRIGGER_START_MARK);
            var end_mark = text_view.buffer.get_mark (EMOJI_TRIGGER_END_MARK);
            if (start_mark == null || end_mark == null) return false;

            Gtk.TextIter start, end;
            text_view.buffer.get_iter_at_mark (out start, start_mark);
            text_view.buffer.get_iter_at_mark (out end, end_mark);
            if (start.compare (end) >= 0
                || text_view.buffer.get_text (start, end, false) != "::") {
                clear_emoji_trigger_marks ();
                return false;
            }

            text_view.buffer.@delete (ref start, ref end);
            text_view.buffer.insert (ref start, emoji, emoji.length);
            clear_emoji_trigger_marks ();
            return true;
        }

        private void clear_emoji_trigger_marks () {
            var start_mark = text_view.buffer.get_mark (EMOJI_TRIGGER_START_MARK);
            if (start_mark != null) text_view.buffer.delete_mark (start_mark);

            var end_mark = text_view.buffer.get_mark (EMOJI_TRIGGER_END_MARK);
            if (end_mark != null) text_view.buffer.delete_mark (end_mark);
        }

        /* Prefer an advertised file or texture, then fall back to text if a
           remote URI, stale path, or conversion failure cannot be attached. */
        private async void paste_from_clipboard (Gdk.Clipboard clipboard,
                                                 bool try_files, bool try_texture,
                                                 bool replace_selection) {
            if (try_files) {
                try {
                    var value = yield clipboard.read_value_async (typeof (Gdk.FileList),
                                                                  Priority.DEFAULT, null);
                    var fl = value == null ? null : (Gdk.FileList?) value.get_boxed ();
                    var gf = fl == null || fl.get_files () == null
                        ? null : fl.get_files ().data;
                    var path = gf == null ? null : gf.get_path ();
                    if (path != null && GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) {
                        set_pending_attachment (path, gf.get_basename ());
                        return;
                    }
                } catch (Error e) {
                }
            }
            if (try_texture) {
                string? tmp_path = null;
                try {
                    var texture = yield clipboard.read_texture_async (null);
                    if (texture != null) {
                        GLib.FileIOStream stream;
                        var tmp = GLib.File.new_tmp ("parla-XXXXXX.png", out stream);
                        tmp_path = tmp.get_path ();
                        stream.close ();
                        if (texture.save_to_png (tmp_path)) {
                            set_pending_attachment (tmp_path, "pasted-image.png",
                                true);
                            return;
                        }
                    }
                } catch (Error e) {
                }
                if (tmp_path != null) GLib.FileUtils.unlink (tmp_path);
            }

            try {
                var text = yield clipboard.read_text_async (null);
                if (text == null || text.length == 0 || !text_view.editable) return;
                if (clean_pasted_links) text = LinkCleaner.clean_text (text);
                if (link_previews && can_accept_attachment ())
                    request_link_previews (text);

                var buffer = text_view.buffer;
                buffer.begin_user_action ();
                if (replace_selection)
                    buffer.delete_selection (true, text_view.editable);
                buffer.insert_at_cursor (text, text.length);
                buffer.end_user_action ();
                text_view.scroll_mark_onscreen (buffer.get_insert ());
            } catch (Error e) {
            }
        }
    }
}
