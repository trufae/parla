namespace Dc {

    /**
     * Comfortable, scrollable reader for the unabridged message body.
     * Also serves as a read-only previewer for text-like attachments
     * (see the `for_file` constructor).
     * Reading preferences are deliberately local to this dialog.
     */
    public class FullMessageDialog : Adw.Dialog {

        private unowned Window window;
        private unowned RpcClient? rpc;
        private MessageActions? actions;
        private Message? msg;

        private string base_title;
        private string message_text;
        private string edit_original_text;
        private int reader_font_size;
        private bool render_markdown;

        private Gtk.Stack content_stack;
        private Gtk.Label reader;
        private Gtk.TextView editor;
        private Gtk.MenuButton reading_button;
        private Gtk.Button? edit_button = null;
        private Gtk.Button? cancel_button = null;
        private Gtk.Button? save_button = null;
        private Gtk.Label? edit_status = null;

        public FullMessageDialog (Window window, RpcClient rpc,
                                  MessageActions actions, Message msg,
                                  string full_text, int initial_font_size) {
            this.window = window;
            this.rpc = rpc;
            this.actions = actions;
            this.msg = msg;
            this.render_markdown = Markdown.mode == MarkdownMode.ENABLED;
            build_ui (_("Message %d").printf (msg.id), full_text,
                      initial_font_size, msg.can_edit_text);
        }

        /** Read-only preview of a text-like attachment. */
        public FullMessageDialog.for_file (Window window, string file_title,
                                           string content,
                                           int initial_font_size,
                                           bool markdown_default) {
            this.window = window;
            this.render_markdown = markdown_default;
            build_ui (file_title, content, initial_font_size, false);
        }

        private void build_ui (string dialog_title, string full_text,
                               int initial_font_size, bool can_edit) {
            this.message_text = full_text;
            this.edit_original_text = full_text;
            this.reader_font_size = SettingsManager.clamp_font_size (
                initial_font_size);
            if (this.reader_font_size == FONT_SIZE_SYSTEM) {
                this.reader_font_size = FONT_SIZE_FALLBACK;
            }

            base_title = dialog_title;
            title = dialog_title;
            content_width = 680;
            content_height = 560;

            var toolbar = new Adw.ToolbarView ();
            var header = new Adw.HeaderBar ();
            toolbar.add_top_bar (header);

            reading_button = build_reading_button ();
            header.pack_end (reading_button);

            if (can_edit) {
                edit_button = new Gtk.Button.from_icon_name (
                    "document-edit-symbolic");
                edit_button.add_css_class ("flat");
                edit_button.tooltip_text = _("Edit message");
                edit_button.clicked.connect (enter_edit_mode);
                header.pack_end (edit_button);

                cancel_button = new Gtk.Button.with_label (_("Cancel"));
                cancel_button.visible = false;
                cancel_button.clicked.connect (leave_edit_mode);
                header.pack_end (cancel_button);

                save_button = new Gtk.Button.with_label (_("Save"));
                save_button.add_css_class ("suggested-action");
                save_button.visible = false;
                save_button.clicked.connect (() => { save_edit.begin (); });
                header.pack_end (save_button);
            }

            content_stack = new Gtk.Stack ();
            content_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            content_stack.vexpand = true;
            content_stack.add_named (build_reader (), "reader");
            content_stack.add_named (build_editor (), "editor");
            content_stack.visible_child_name = "reader";

            toolbar.content = content_stack;
            child = toolbar;
            install_escape_close (this);
            update_reader ();
            update_save_button ();
        }

        private Gtk.Widget build_reader () {
            reader = new Gtk.Label ("");
            reader.halign = Gtk.Align.FILL;
            reader.valign = Gtk.Align.START;
            reader.xalign = 0;
            reader.yalign = 0;
            reader.hexpand = true;
            reader.wrap = true;
            reader.wrap_mode = Pango.WrapMode.WORD_CHAR;
            make_label_selectable (reader);
            reader.margin_start = 32;
            reader.margin_end = 32;
            reader.margin_top = 24;
            reader.margin_bottom = 24;
            reader.add_css_class ("full-message-reader");

            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            scroll.vexpand = true;
            scroll.child = reader;
            return scroll;
        }

        private Gtk.Widget build_editor () {
            editor = new Gtk.TextView ();
            editor.monospace = true;
            editor.wrap_mode = Gtk.WrapMode.WORD_CHAR;
            editor.accepts_tab = false;
            editor.top_margin = 24;
            editor.bottom_margin = 24;
            editor.left_margin = 32;
            editor.right_margin = 32;
            editor.buffer.text = message_text;
            editor.buffer.changed.connect (update_save_button);
            editor.add_css_class ("full-message-editor");

            edit_status = new Gtk.Label ("");
            edit_status.add_css_class ("dim-label");
            edit_status.halign = Gtk.Align.START;
            edit_status.xalign = 0;
            edit_status.margin_start = 32;
            edit_status.margin_end = 32;
            edit_status.margin_bottom = 8;

            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            scroll.vexpand = true;
            scroll.child = editor;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (scroll);
            box.append (edit_status);
            return box;
        }

        private Gtk.MenuButton build_reading_button () {
            var button = new Gtk.MenuButton ();
            var button_label = new Gtk.Label ("A");
            button_label.add_css_class ("heading");
            button.child = button_label;
            button.add_css_class ("flat");
            button.tooltip_text = _("Reading settings");

            var settings_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            settings_box.margin_start = 16;
            settings_box.margin_end = 16;
            settings_box.margin_top = 14;
            settings_box.margin_bottom = 14;
            settings_box.width_request = 280;

            var heading = new Gtk.Label (_("Reading settings"));
            heading.add_css_class ("heading");
            heading.halign = Gtk.Align.START;
            heading.xalign = 0;
            settings_box.append (heading);

            var size_label = new Gtk.Label (_("Text size"));
            size_label.halign = Gtk.Align.START;
            size_label.xalign = 0;
            settings_box.append (size_label);

            var size_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            var small_a = new Gtk.Label ("A");
            small_a.add_css_class ("caption");
            size_row.append (small_a);

            var scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL,
                FONT_SIZE_MIN, FONT_SIZE_MAX, 1.0);
            scale.hexpand = true;
            scale.draw_value = true;
            scale.digits = 0;
            scale.value_pos = Gtk.PositionType.RIGHT;
            scale.set_value (reader_font_size);
            scale.value_changed.connect (() => {
                reader_font_size = (int) scale.get_value ();
                update_reader ();
            });
            size_row.append (scale);

            var large_a = new Gtk.Label ("A");
            large_a.add_css_class ("title-3");
            size_row.append (large_a);
            settings_box.append (size_row);

            settings_box.append (
                new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var markdown_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            var markdown_labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            markdown_labels.hexpand = true;
            var markdown_title = new Gtk.Label (_("Render Markdown"));
            markdown_title.halign = Gtk.Align.START;
            markdown_title.xalign = 0;
            markdown_labels.append (markdown_title);
            var markdown_hint = new Gtk.Label (
                _("Format headings, emphasis, code, and links"));
            markdown_hint.add_css_class ("dim-label");
            markdown_hint.add_css_class ("caption");
            markdown_hint.halign = Gtk.Align.START;
            markdown_hint.xalign = 0;
            markdown_hint.wrap = true;
            markdown_labels.append (markdown_hint);
            markdown_row.append (markdown_labels);

            var markdown_switch = new Gtk.Switch ();
            markdown_switch.valign = Gtk.Align.CENTER;
            markdown_switch.active = render_markdown;
            markdown_switch.notify["active"].connect (() => {
                render_markdown = markdown_switch.active;
                update_reader ();
            });
            markdown_row.append (markdown_switch);
            settings_box.append (markdown_row);

            var popover = new Gtk.Popover ();
            popover.has_arrow = true;
            popover.child = settings_box;
            button.popover = popover;
            return button;
        }

        private void update_reader () {
            if (reader == null) return;
            var mode = render_markdown
                ? MarkdownMode.ENABLED : MarkdownMode.DISABLED;
            string body = Markdown.format_with_mode (message_text, mode);
            string markup = "<span size=\"%d\">%s</span>".printf (
                reader_font_size * Pango.SCALE, body);
            reader.set_markup (markup);
        }

        private void enter_edit_mode () {
            if (edit_button == null || cancel_button == null
                || save_button == null) return;
            edit_original_text = message_text;
            editor.buffer.text = message_text;
            if (edit_status != null) edit_status.label = "";
            content_stack.visible_child_name = "editor";
            title = _("Edit Message");
            reading_button.visible = false;
            edit_button.visible = false;
            cancel_button.visible = true;
            save_button.visible = true;
            update_save_button ();
            editor.grab_focus ();
            Gtk.TextIter end;
            editor.buffer.get_end_iter (out end);
            editor.buffer.place_cursor (end);
            Idle.add (() => {
                editor.scroll_mark_onscreen (editor.buffer.get_insert ());
                return Source.REMOVE;
            });
        }

        private void leave_edit_mode () {
            if (edit_button == null || cancel_button == null
                || save_button == null) return;
            editor.buffer.text = message_text;
            if (edit_status != null) edit_status.label = "";
            content_stack.visible_child_name = "reader";
            title = base_title;
            reading_button.visible = true;
            edit_button.visible = true;
            cancel_button.visible = false;
            save_button.visible = false;
        }

        private void update_save_button () {
            if (save_button == null || editor == null) return;
            string text = text_buffer_text (editor.buffer);
            save_button.sensitive = text != edit_original_text
                && text.strip ().length > 0;
            if (save_button.sensitive && edit_status != null) {
                edit_status.label = "";
            }
        }

        private async void save_edit () {
            if (save_button == null || cancel_button == null) return;
            string text = text_buffer_text (editor.buffer);
            if (text == edit_original_text || text.strip ().length == 0) return;

            save_button.sensitive = false;
            cancel_button.sensitive = false;
            editor.editable = false;
            if (edit_status != null) edit_status.label = _("Saving…");

            try {
                yield rpc.send_edit_request (msg.id, text);
                msg.text = text;
                msg.full_message_text = text;
                msg.is_edited = true;
                yield actions.update_row (msg.id);
                message_text = text;
                edit_original_text = text;
                update_reader ();
                leave_edit_mode ();
            } catch (Error e) {
                if (edit_status != null) {
                    edit_status.label = _("Edit failed: ") + e.message;
                }
                window.show_toast (_("Edit failed: ") + e.message);
            }

            editor.editable = true;
            cancel_button.sensitive = true;
            update_save_button ();
        }

        private static string text_buffer_text (Gtk.TextBuffer buffer) {
            Gtk.TextIter start;
            Gtk.TextIter end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            return buffer.get_text (start, end, false);
        }
    }
}
