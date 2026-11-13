namespace Parla.Terminal {
    /** One tab, including its independent draft and scroll position. */
    public class Buffer : Object {
        private class Entry : Object {
            public Text text;
            public int bytes;
            public string message_id;
            public Entry (Text text, int bytes, string message_id) { this.text = text; this.bytes = bytes; this.message_id = message_id; }
        }
        public string id { get; construct; }
        public string title { get; private set; }
        public Editor editor { get; private set; }
        public bool closable { get; set; default = true; }
        public int scroll_offset { get; internal set; default = 0; }
        public int unread_count { get; private set; default = 0; }
        public string selected_message_id { get; private set; default = ""; }
        public signal void changed ();
        public signal void activity_changed ();
        private GenericArray<Entry> entries = new GenericArray<Entry> ();
        private GenericArray<Row> rows = new GenericArray<Row> ();
        private int columns = 0;
        private int retained_bytes = 0;
        private uint skipped_rows = 0;
        // Bound both parsing work per message and retained scrollback.
        public const int MAX_ENTRIES = 300;
        public const int MAX_ENTRY_BYTES = 16384;
        public const int MAX_HISTORY_BYTES = 1048576;
        private const uint MAX_ROWS = 4000;

        public Buffer (string id, string title) {
            Object (id: id);
            this.title = title;
            editor = new Editor ();
        }

        public void append (string markdown) { add (markdown, true); }
        public void append_text (string text) { add (text, false); }

        internal void rename (string title) {
            if (this.title == title) return;
            this.title = title;
            activity_changed ();
        }

        public void append_block (string text, int minimum_columns, Style style = Style.NORMAL) {
            string value = limited (text, 65536);
            add_text (new Text.block (value, minimum_columns, style), value.length);
        }

        public void set_unread (int count) {
            count = int.max (0, count);
            if (unread_count == count) return;
            unread_count = count;
            activity_changed ();
        }

        private static string limited (string value, int maximum) {
            if (value.length <= maximum) return value;
            int end = maximum;
            while (end > 0 && (value[end] & 0xc0) == 0x80) end--;
            return value.substring (0, end) + "…";
        }

        public void append_message (string time, string nick, string markdown,
                                    string state = "", string color_key = "", bool outgoing = false,
                                    bool render_markdown = true, bool nick_colors = true, bool compact = true,
                                    string message_id = "", string attachment_label = "", string attachment_uri = "") {
            string body = limited (markdown, MAX_ENTRY_BYTES);
            string name = limited (nick, 80);
            string clock = limited (time, 64);
            string suffix = limited (state, 1024);
            string label = limited (attachment_label, 1024);
            add_text (new Text.message (clock, name, body, suffix, color_key, outgoing, render_markdown, nick_colors, compact, label, attachment_uri),
                body.length + name.length + clock.length + suffix.length + label.length + attachment_uri.length, message_id);
        }

        private void add (owned string value, bool markdown) {
            value = limited (value, MAX_ENTRY_BYTES);
            var entry = markdown ? new Text.markdown (value) : new Text.plain (value);
            add_text (entry, value.length);
        }

        private void add_text (Text entry, int bytes, string message_id = "") {
            entries.add (new Entry (entry, bytes, message_id));
            retained_bytes += bytes;
            if (columns > 0) {
                int count = entry.line_count (columns);
                var added = entry.wrap (columns, int.max (0, count - (int) MAX_ROWS), (int) MAX_ROWS);
                skipped_rows += count - added.length;
                foreach (var row in added) { row.message_id = message_id; rows.add (row); }
                if (scroll_offset > 0) scroll_offset += count;
            }
            while (entries.length > MAX_ENTRIES || retained_bytes > MAX_HISTORY_BYTES) {
                var removed = entries.get (0);
                if (columns > 0) {
                    uint count = (uint) removed.text.line_count (columns);
                    uint skipped = uint.min (count, skipped_rows);
                    skipped_rows -= skipped;
                    rows.remove_range (0, uint.min (count - skipped, rows.length));
                }
                retained_bytes -= removed.bytes;
                if (selected_message_id == removed.message_id) selected_message_id = "";
                entries.remove_index (0);
            }
            trim ();
            changed ();
        }

        private void trim () {
            if (rows.length > MAX_ROWS) {
                uint count = rows.length - MAX_ROWS;
                skipped_rows += count;
                rows.remove_range (0, count);
            }
            scroll_offset = int.min (scroll_offset, int.max (0, (int) rows.length - 1));
        }

        public void clear () {
            entries.remove_range (0, entries.length);
            rows.remove_range (0, rows.length);
            retained_bytes = 0;
            skipped_rows = 0;
            scroll_offset = 0;
            selected_message_id = "";
            changed ();
        }

        internal unowned GenericArray<Row> layout (int width) {
            width = int.max (1, width);
            if (columns != width) {
                columns = width;
                rows = new GenericArray<Row> ();
                skipped_rows = 0;
                foreach (var entry in entries) {
                    int count = entry.text.line_count (width);
                    var wrapped = entry.text.wrap (width, int.max (0, count - (int) MAX_ROWS), (int) MAX_ROWS);
                    skipped_rows += count - wrapped.length;
                    foreach (var row in wrapped) { row.message_id = entry.message_id; rows.add (row); }
                    // Bound the temporary cache during reflow as well as at rest.
                    if (rows.length > MAX_ROWS) {
                        skipped_rows += rows.length - MAX_ROWS;
                        rows.remove_range (0, rows.length - MAX_ROWS);
                    }
                }
                trim ();
            }
            return rows;
        }

        public bool select_message (string id) {
            if (id != "") {
                bool found = false;
                foreach (var entry in entries) if (entry.message_id == id) found = true;
                if (!found) return false;
            }
            if (selected_message_id != id) { selected_message_id = id; changed (); }
            return true;
        }

        internal bool move_message_selection (int step) {
            string[] ids = {};
            int selected = -1;
            foreach (var entry in entries) if (entry.message_id != "") {
                if (entry.message_id == selected_message_id) selected = ids.length;
                ids += entry.message_id;
            }
            if (ids.length == 0) return false;
            return select_message (ids[selected < 0 ? ids.length - 1 : (selected + step).clamp (0, ids.length - 1)]);
        }

        internal void reveal_selected_message (int height) {
            int first = -1, last = -1;
            for (int i = 0; i < rows.length; i++) if (rows.get (i).message_id == selected_message_id) {
                if (first < 0) first = i;
                last = i;
            }
            if (first < 0) return;
            int start = int.max (0, (int) rows.length - height - scroll_offset);
            if (first < start || last - first >= height) scroll_offset = int.max (0, (int) rows.length - height - first);
            else if (last >= start + height) scroll_offset = int.max (0, (int) rows.length - last - 1);
        }
    }

    public enum ContactKind { OTHER, DIRECT, GROUP }
    public enum ContactSort { RECENT, ALPHABETICAL }

    public class Contact : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string status { get; construct; }
        public int unread_count { get; construct; }
        public ContactKind kind { get; construct; }
        public bool pinned { get; construct; }
        public int64 timestamp { get; construct; }
        public string time { get; construct; }
        public string preview { get; construct; }
        internal string sort_key;
        internal int order;
        public Contact (string id, string name, string status = "", int unread_count = 0,
                        ContactKind kind = ContactKind.OTHER, bool pinned = false,
                        int64 timestamp = 0, string time = "", string preview = "") {
            string snippet = preview.make_valid ().replace ("\r", " ").replace ("\n", " ");
            if (snippet.length > 1024) {
                int end = 1024;
                while ((snippet[end] & 0xc0) == 0x80) end--;
                snippet = snippet.substring (0, end);
            }
            Object (id: id, name: name, status: status, unread_count: int.max (0, unread_count),
                kind: kind, pinned: pinned, timestamp: timestamp, time: time, preview: snippet);
            sort_key = (name.has_prefix ("@") || name.has_prefix ("#") ? name.substring (1) : name).casefold ().collate_key ();
        }
    }

    /** BitchX-style layout and interaction, independent of terminal IO and RPC.
     * All methods and signals belong to the default GLib main context. */
    public class View : Object {
        public const string CONTACTS_TAB = "__contacts";
        private const string CONTACTS_HELP = """Contacts keys (? or Esc hides this help)
j/k or Up/Down: select · Enter or click: open
g: group private/group chats · a: A–Z/recent
p: pin/unpin · Mouse wheel: move one row
Ctrl-B/F or Page Up/Down: page through contacts
/: start command · Esc: edit input · Ctrl-G: focus list
Esc+1..9 (0 for 10): switch tab · Alt-Left/Right: previous/next
""";
        public InputHistory input_history { get; set; default = new InputHistory (); }
        public signal void invalidated ();
        public signal void submitted (Buffer buffer, string text);
        public signal void contact_activated (Contact contact);
        public signal void contact_pin_requested (Contact contact, bool pinned);
        public signal void quit_requested ();
        public signal void redraw_requested ();
        public signal void tab_changed (Buffer buffer);
        public signal void completion_requested (Buffer buffer, bool backwards);
        public signal void option_changed (string name, string value);
        public signal void message_selected (Buffer buffer);
        public signal void message_selection_confirmed (Buffer buffer, string action);
        private GenericArray<Buffer> tabs = new GenericArray<Buffer> ();
        private HashTable<string, Buffer> closed_tabs = new HashTable<string, Buffer> (str_hash, str_equal);
        private Contact[] contacts = {};
        private Contact[] source_contacts = {};
        private int[] contact_rows = {};
        private int[] contact_positions = {};
        private bool _contacts_grouped = false;
        private ContactSort _contacts_sort = ContactSort.RECENT;
        public bool contacts_grouped { get { return _contacts_grouped; } }
        public ContactSort contacts_sort { get { return _contacts_sort; } }
        private int selected_contact = 0;
        private int selected_tab = 0;
        private bool contacts_focus = false;
        private bool contacts_help_visible = false;
        private bool escape_pending = false;
        private string selection_action = "";
        private string previous_message_selection = "";
        private string[] message_hits = {};
        public bool selecting_messages { get { return selection_action != ""; } }
        private string status = "";
        private string completion_hint = "";
        private Frame? frame;
        private bool body_dirty = true;
        private bool tabs_dirty = true;
        private bool footer_dirty = true;
        private int input_height = 1;
        private int body_height = 1;
        private int[] tab_hits = {};
        private int[] contact_hits = {};
        private bool _info_visible = false;
        public bool info_visible { get { return _info_visible; } }
        private string info_title = "Chat information";
        private string info_text = "Select a conversation";
        private int info_width = 0;
        private int info_offset = 0;
        private GenericArray<Row>? info_rows;
        private int info_columns = 0;

        public Buffer? active_buffer { get { return tabs.length > 0 ? tabs.get (selected_tab) : null; } }
        private bool contacts_tab_active { get { return active_buffer != null && active_buffer.id == CONTACTS_TAB; } }

        public Buffer add_tab (string id, string title) {
            foreach (var existing in tabs) if (existing.id == id) return existing;
            Buffer? buffer = closed_tabs[id];
            if (buffer != null) closed_tabs.remove (id);
            else {
                buffer = new Buffer (id, title);
                buffer.changed.connect (buffer_changed);
                buffer.activity_changed.connect (activity_changed);
                buffer.editor.changed.connect (draft_changed);
            }
            tabs.add (buffer);
            foreach (var contact in contacts) if (contact.id == id) buffer.set_unread (contact.unread_count);
            update_contacts_badge ();
            tabs_dirty = body_dirty = footer_dirty = true;
            invalidated ();
            return buffer;
        }

        private bool tab_open (string id) {
            foreach (var tab in tabs) if (tab.id == id) return true;
            return false;
        }

        private void update_contacts_badge () {
            Buffer? contact_tab = null;
            foreach (var tab in tabs) if (tab.id == CONTACTS_TAB) contact_tab = tab;
            if (contact_tab == null) return;
            int64 unread = 0;
            foreach (var contact in contacts) if (!tab_open (contact.id)) unread += contact.unread_count;
            contact_tab.set_unread ((int) int64.min (unread, int.MAX));
        }

        private void activity_changed (Buffer buffer) {
            if (!tab_open (buffer.id)) return;
            tabs_dirty = true;
            invalidated ();
        }

        public bool close_tab (string id) {
            if (tabs.length <= 1) return false;
            for (int i = 0; i < tabs.length; i++) {
                var buffer = tabs.get (i);
                if (buffer.id != id) continue;
                if (!buffer.closable) return false;
                bool active = i == selected_tab;
                closed_tabs.insert (id, buffer);
                tabs.remove_index (i);
                update_contacts_badge ();
                if (i < selected_tab) selected_tab--;
                selected_tab = int.min (selected_tab, (int) tabs.length - 1);
                if (active) { contacts_focus = contacts_tab_active; input_history.reset (); selection_action = ""; }
                tabs_dirty = body_dirty = footer_dirty = true;
                invalidated ();
                if (active) tab_changed (active_buffer);
                return true;
            }
            return false;
        }

        private bool in_contacts (int x, int y) {
            return contacts_tab_active && y >= 1 && y <= body_height && x < frame.width;
        }

        public void set_info_visible (bool visible) {
            if (_info_visible == visible) return;
            _info_visible = visible;
            body_dirty = footer_dirty = true;
            invalidated ();
            option_changed ("chat_info", visible ? "on" : "off");
        }

        public void set_info (string title, string text) {
            if (info_title == title && info_text == text) return;
            info_title = title;
            info_text = text;
            info_rows = null;
            info_offset = 0;
            body_dirty = true;
            invalidated ();
        }

        private void buffer_changed (Buffer buffer) {
            if (active_buffer != buffer) return;
            body_dirty = footer_dirty = true;
            invalidated ();
        }

        private void draft_changed (Editor editor) {
            if (active_buffer == null || active_buffer.editor != editor) return;
            footer_dirty = true;
            invalidated ();
        }

        public void select_tab (string id) {
            for (int i = 0; i < tabs.length; i++) {
                if (tabs.get (i).id != id) continue;
                if (selected_tab == i) return;
                selected_tab = i;
                selection_action = "";
                contacts_focus = contacts_tab_active;
                input_history.reset ();
                set_completion_hint ("");
                tabs_dirty = body_dirty = footer_dirty = true;
                invalidated ();
                tab_changed (tabs.get (i));
                return;
            }
        }

        public void set_contacts (Contact[] items) {
            add_tab (CONTACTS_TAB, "Contacts").closable = false;
            bool same = source_contacts.length == items.length;
            for (int i = 0; same && i < source_contacts.length; i++) {
                var old = source_contacts[i]; var item = items[i];
                if (old.id != item.id || old.name != item.name || old.status != item.status ||
                    old.unread_count != item.unread_count || old.kind != item.kind || old.pinned != item.pinned ||
                    old.timestamp != item.timestamp || old.time != item.time || old.preview != item.preview) same = false;
            }
            if (same) return;
            source_contacts = items;
            foreach (var contact in items) {
                foreach (var tab in tabs) if (tab.id == contact.id) {
                    tab.set_unread (contact.unread_count);
                    tab.rename (contact.name);
                }
                var closed = closed_tabs[contact.id];
                if (closed != null) { closed.set_unread (contact.unread_count); closed.rename (contact.name); }
            }
            reorder_contacts ();
        }

        public void set_contacts_grouped (bool grouped) {
            if (contacts_grouped == grouped) return;
            _contacts_grouped = grouped;
            reorder_contacts ();
            option_changed ("contacts_grouped", grouped ? "on" : "off");
        }

        public void set_contacts_sort (ContactSort sort) {
            if (contacts_sort == sort) return;
            _contacts_sort = sort;
            reorder_contacts ();
            option_changed ("contacts_sort", sort == ContactSort.ALPHABETICAL ? "alphabetical" : "recent");
        }

        private int contact_group (Contact contact) {
            return contact.pinned ? 0 : contact.kind == ContactKind.DIRECT ? 1 : contact.kind == ContactKind.GROUP ? 2 : 3;
        }

        private void reorder_contacts () {
            string selected_id = contacts.length > 0 ? contacts[selected_contact].id : "";
            var ordered = new GenericArray<Contact> ();
            for (int i = 0; i < source_contacts.length; i++) {
                source_contacts[i].order = i;
                ordered.add (source_contacts[i]);
            }
            ordered.sort_with_data ((a, b) => {
                if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
                if (contacts_grouped && contact_group (a) != contact_group (b)) return contact_group (a) - contact_group (b);
                if (contacts_sort == ContactSort.ALPHABETICAL) {
                    int compare = strcmp (a.sort_key, b.sort_key);
                    if (compare != 0) return compare;
                } else if (a.timestamp != b.timestamp) return a.timestamp > b.timestamp ? -1 : 1;
                return a.order - b.order;
            });
            contacts = new Contact[ordered.length];
            for (int i = 0; i < ordered.length; i++) contacts[i] = ordered.get (i);
            update_contacts_badge ();
            selected_contact = 0;
            contact_rows = {};
            contact_positions = new int[contacts.length];
            int previous_group = -1;
            for (int i = 0; i < contacts.length; i++) {
                int group = contact_group (contacts[i]);
                if (contacts_grouped && previous_group != group) contact_rows += -group - 1;
                previous_group = group;
                contact_positions[i] = contact_rows.length;
                contact_rows += i;
                if (contacts[i].id == selected_id) selected_contact = i;
            }
            if (contacts_tab_active) body_dirty = footer_dirty = true;
            invalidated ();
        }

        public void set_status (string text) {
            if (status == text) return;
            status = text;
            footer_dirty = true;
            invalidated ();
        }

        public void set_completion_hint (string text) {
            if (completion_hint == text) return;
            completion_hint = text;
            body_dirty = footer_dirty = true;
            invalidated ();
        }

        public void scroll (int lines) {
            if (contacts_tab_active || contacts_focus) {
                selected_contact = (int) ((int64) selected_contact - lines).clamp (0, int.max (0, contacts.length - 1));
                body_dirty = footer_dirty = true;
                invalidated ();
                return;
            }
            var buffer = active_buffer;
            if (buffer == null) return;
            int count = (int) buffer.layout (frame == null ? 80 : frame.width - info_width).length;
            int offset = (int) ((int64) buffer.scroll_offset + lines).clamp (0, int.max (0, count - body_height));
            if (offset == buffer.scroll_offset) return;
            buffer.scroll_offset = offset;
            body_dirty = footer_dirty = true;
            invalidated ();
        }

        public void handle_key (Key key, string text = "") {
            var buffer = active_buffer;
            // Also accept a deliberate Esc then digit, after the input timeout.
            bool escaped = escape_pending;
            escape_pending = false;
            if (escaped && key == Key.TEXT && text.length == 1) {
                if (text[0] >= '0' && text[0] <= '9') key = Key.SELECT_TAB;
                else if (text == "x") key = Key.CLOSE_TAB;
            }
            if (key != Key.COMPLETE && key != Key.COMPLETE_PREVIOUS) set_completion_hint ("");
            if (selection_action != "" && buffer != null) {
                if (key == Key.UP || key == Key.DOWN || (key == Key.TEXT && (text == "j" || text == "k"))) {
                    buffer.move_message_selection (key == Key.UP || text == "k" ? -1 : 1);
                    reveal_message_selection (buffer);
                    return;
                }
                if (key == Key.ENTER) {
                    string action = selection_action;
                    selection_action = "";
                    body_dirty = footer_dirty = true;
                    message_selection_confirmed (buffer, action);
                    invalidated ();
                    return;
                }
                if (key == Key.ESCAPE) {
                    selection_action = "";
                    buffer.select_message (previous_message_selection);
                    message_selected (buffer);
                    body_dirty = footer_dirty = true;
                    invalidated ();
                    return;
                }
                if (key == Key.TEXT || key == Key.NEWLINE || key == Key.HISTORY_PREVIOUS || key == Key.HISTORY_NEXT) return;
            }
            switch (key) {
            case Key.COMPLETE: case Key.COMPLETE_PREVIOUS:
                if (buffer != null && !contacts_focus) completion_requested (buffer, key == Key.COMPLETE_PREVIOUS);
                return;
            case Key.QUIT: quit_requested (); return;
            case Key.CLEAR_INPUT:
                if (buffer != null && !contacts_focus) buffer.editor.clear ();
                return;
            case Key.REDRAW: redraw_requested (); return;
            case Key.CLOSE_TAB:
                if (buffer != null) close_tab (buffer.id);
                return;
            case Key.FOCUS:
                if (!contacts_tab_active) { select_tab (CONTACTS_TAB); return; }
                contacts_focus = !contacts_focus; body_dirty = footer_dirty = true; break;
            case Key.ESCAPE:
                if (contacts_tab_active && contacts_help_visible) {
                    contacts_help_visible = false;
                    body_dirty = true;
                    break;
                }
                escape_pending = true;
                if (buffer != null) { buffer.select_message (""); message_selected (buffer); }
                contacts_focus = false; body_dirty = footer_dirty = true; break;
            case Key.SELECT_TAB:
                int number = int.parse (text);
                int index = number == 0 ? 9 : number - 1;
                if (index >= 0 && index < tabs.length) select_tab (tabs.get (index).id);
                return;
            case Key.NEXT_TAB: case Key.PREVIOUS_TAB:
                if (tabs.length > 0) {
                    int next = (selected_tab + (key == Key.NEXT_TAB ? 1 : (int) tabs.length - 1)) % (int) tabs.length;
                    select_tab (tabs.get (next).id);
                }
                return;
            case Key.PAGE_UP: scroll (int.max (1, body_height - 1)); return;
            case Key.PAGE_DOWN: scroll (-int.max (1, body_height - 1)); return;
            case Key.HISTORY_PREVIOUS: case Key.HISTORY_NEXT:
                if (buffer != null) {
                    contacts_focus = false; body_dirty = true;
                    input_history.recall (buffer.editor, key == Key.HISTORY_PREVIOUS);
                }
                return;
            default:
                if (contacts_focus && key == Key.TEXT && text == "/") {
                    contacts_focus = false;
                    body_dirty = true;
                }
                if (contacts_focus) {
                    if (key == Key.TEXT && text == "?") {
                        contacts_help_visible = !contacts_help_visible;
                        body_dirty = true;
                        break;
                    }
                    if (key == Key.TEXT && text == "g") { set_contacts_grouped (!contacts_grouped); return; }
                    if (key == Key.TEXT && text == "a") {
                        set_contacts_sort (contacts_sort == ContactSort.RECENT ? ContactSort.ALPHABETICAL : ContactSort.RECENT); return;
                    }
                    if (key == Key.TEXT && text == "p") {
                        if (contacts.length > 0) contact_pin_requested (contacts[selected_contact], !contacts[selected_contact].pinned);
                        return;
                    }
                    if (key == Key.UP || (key == Key.TEXT && text == "k"))
                        selected_contact = int.max (0, selected_contact - 1);
                    if (key == Key.DOWN || (key == Key.TEXT && text == "j"))
                        selected_contact = int.max (0, int.min (contacts.length - 1, selected_contact + 1));
                    if (key == Key.ENTER && contacts.length > 0) {
                        contacts_focus = false;
                        contact_activated (contacts[selected_contact]);
                    }
                    body_dirty = footer_dirty = true;
                } else if (buffer != null) {
                    if (key == Key.ENTER) {
                        if (buffer.editor.text.strip () != "") {
                            string draft = buffer.editor.text;
                            input_history.remember (draft);
                            buffer.editor.clear ();
                            submitted (buffer, draft);
                        }
                    } else if (key == Key.UP || key == Key.DOWN) input_history.recall (buffer.editor, key == Key.UP);
                    else if (key == Key.TEXT) buffer.editor.insert (text);
                    else if (key == Key.NEWLINE) buffer.editor.insert ("\n");
                    else buffer.editor.handle (key, frame == null ? 80 : frame.width - 2);
                    footer_dirty = true;
                }
                break;
            }
            invalidated ();
        }

        public bool begin_message_selection (string action) {
            var buffer = active_buffer;
            if (buffer == null) return false;
            previous_message_selection = buffer.selected_message_id;
            if (!buffer.move_message_selection (0)) return false;
            contacts_focus = false;
            selection_action = action;
            reveal_message_selection (buffer);
            return true;
        }

        private void reveal_message_selection (Buffer buffer) {
            buffer.layout (frame == null ? 80 : frame.width - info_width);
            buffer.reveal_selected_message (body_height);
            message_selected (buffer);
            body_dirty = footer_dirty = true;
            invalidated ();
        }

        public void handle_mouse (MouseEvent event) {
            if (frame == null) return;
            if (!event.pressed || event.motion || event.x < 0 || event.y < 0 ||
                event.x >= frame.width || event.y >= frame.height) return;
            if (event.button == MouseButton.WHEEL_UP || event.button == MouseButton.WHEEL_DOWN) {
                int step = event.button == MouseButton.WHEEL_UP ? -1 : 1;
                if (event.y == 0 && tabs.length > 0) {
                    handle_key (step < 0 ? Key.PREVIOUS_TAB : Key.NEXT_TAB);
                } else if (info_width > 0 && event.x >= frame.width - info_width && event.y <= body_height) {
                    info_offset = (info_offset + step).clamp (0, info_rows == null ? 0 : int.max (0, (int) info_rows.length - body_height + 1));
                    body_dirty = true;
                    invalidated ();
                } else if (in_contacts (event.x, event.y)) {
                    contacts_focus = true;
                    selected_contact = (selected_contact + step).clamp (0, int.max (0, contacts.length - 1));
                    body_dirty = footer_dirty = true;
                    invalidated ();
                } else if (event.y >= 1 && event.y <= body_height) scroll (-step);
                return;
            }
            if (event.button == MouseButton.MIDDLE && event.y == 0 && tab_hits[event.x] >= 0) {
                close_tab (tabs.get (tab_hits[event.x]).id);
                return;
            }
            if (event.button != MouseButton.LEFT) return;
            if (event.y == 0 && event.x < tab_hits.length && tab_hits[event.x] >= 0) {
                contacts_focus = false;
                body_dirty = footer_dirty = true;
                select_tab (tabs.get (tab_hits[event.x]).id);
            } else if (in_contacts (event.x, event.y)) {
                contacts_focus = true;
                int index = contact_hits[event.y];
                if (index >= 0 && index < contacts.length) {
                    selected_contact = index;
                    contacts_focus = false;
                    contact_activated (contacts[index]);
                }
                body_dirty = footer_dirty = true;
            } else if (event.y >= frame.height - input_height && active_buffer != null) {
                selection_action = "";
                contacts_focus = false;
                var editor = active_buffer.editor;
                editor.place_cursor (int.max (1, frame.width - 2), int.max (0, event.x - 2),
                    event.y - (frame.height - input_height) + editor.first_visible_row);
                body_dirty = footer_dirty = true;
            } else if (event.y <= body_height && active_buffer != null && event.y < message_hits.length &&
                       (info_width == 0 || event.x < frame.width - info_width) && message_hits[event.y] != "") {
                contacts_focus = false;
                active_buffer.select_message (message_hits[event.y]);
                message_selected (active_buffer);
                body_dirty = footer_dirty = true;
            } else return;
            invalidated ();
        }

        public Frame draw (int width, int height) {
            width = int.max (1, width); height = int.max (1, height);
            if (frame == null || frame.width != width || frame.height != height) {
                frame = new Frame (width, height);
                tab_hits = new int[width];
                contact_hits = new int[height];
                message_hits = new string[height];
                tabs_dirty = body_dirty = footer_dirty = true;
            }
            int new_info = info_visible && !contacts_tab_active && width >= 72 ? int.min (28, width / 3) : 0;
            if (info_width != new_info) { info_width = new_info; body_dirty = true; }
            if (!footer_dirty && !body_dirty && !tabs_dirty) return frame;
            int cx = 0, cy = 0;
            var buffer = active_buffer;
            int available = int.max (1, height - 3);
            var input_rows = buffer == null ? new Text.plain ("").wrap (int.max (1, width - 2)) :
                buffer.editor.layout (int.max (1, width - 2), out cx, out cy, int.min (5, available));
            int new_height = int.min (int.min (5, available), (int) input_rows.length);
            if (input_height != new_height) { input_height = new_height; body_dirty = footer_dirty = true; }
            int hint_height = completion_hint != "" && height > input_height + 3 ? 1 : 0;
            body_height = int.max (0, height - input_height - 2 - hint_height);
            bool paint_contact_list = body_dirty || (contacts_focus && footer_dirty);
            frame.cursor_visible = !contacts_focus && selection_action == "";
            if (tabs_dirty) {
                for (int i = 0; i < tab_hits.length; i++) tab_hits[i] = -1;
                var row = new Row (width, Style.TAB);
                int x = 0;
                // Start with the active tab if the strip would overflow.
                int first = 0, used = 0;
                for (int i = 0; i <= selected_tab; i++) {
                    used += (int) tab_label (tabs.get (i), i).char_count () + 1;
                    if (used > width) first = selected_tab;
                }
                for (int i = first; i < tabs.length && x < width; i++) {
                    int tab_start = x;
                    var tab = tabs.get (i);
                    string label = tab_label (tab, i);
                    Style tab_style = tab.unread_count > 0 ? Style.UNREAD_TAB | Style.BOLD : Style.TAB;
                    if (i == selected_tab) tab_style |= Style.ACTIVE_TAB | Style.BOLD;
                    row.text (x, label, tab_style);
                    var clean = new Text.plain (label);
                    foreach (var cell in clean.glyphs) x += cell.width;
                    for (int hit = tab_start; hit < int.min (width, x); hit++) tab_hits[hit] = i;
                    row.text (x++, "│", Style.SEPARATOR);
                }
                frame.set_row (0, row);
                tabs_dirty = false;
            }
            if (body_dirty) {
                for (int i = 0; i < message_hits.length; i++) message_hits[i] = "";
                for (int i = 0; i < contact_hits.length; i++) contact_hits[i] = -1;
                unowned GenericArray<Row>? messages = buffer == null ? null : buffer.layout (width - info_width);
                int count = messages == null ? 0 : (int) messages.length;
                if (buffer != null) buffer.scroll_offset = buffer.scroll_offset.clamp (0, int.max (0, count - body_height));
                int start = int.max (0, count - body_height - (buffer == null ? 0 : buffer.scroll_offset));
                for (int y = 0; y < body_height; y++) {
                    var row = new Row (width);
                    if (messages != null && start + y < count) {
                        var message = messages.get (start + y);
                        message_hits[y + 1] = message.message_id;
                        for (int x = 0; x < message.width; x++) {
                            var cell = message.cells[x];
                            if (message.message_id != "" && message.message_id == buffer.selected_message_id) cell.style |= Style.SELECTED | Style.MESSAGE;
                            row.put (x, cell);
                        }
                    }
                    frame.set_row (y + 1, row);
                }
                if (info_width > 0) {
                    if (info_rows == null || info_columns != info_width - 2) {
                        info_columns = info_width - 2;
                        info_rows = new Text.plain (info_text).wrap (info_columns, 0, 2000);
                    }
                    for (int y = 1; y <= body_height; y++) {
                        var row = new Row (width);
                        var old = frame.get_row (y);
                        for (int x = 0; x < width; x++) row.put (x, old.cells[x]);
                        int info_start = width - info_width;
                        row.text (info_start, "│", Style.SEPARATOR);
                        if (y == 1) row.text (info_start + 1, info_title, Style.INFO | Style.BOLD, info_width - 1);
                        else if (y - 2 + info_offset < info_rows.length) {
                            var info = info_rows.get (y - 2 + info_offset);
                            for (int x = 0; x < info.width; x++) {
                                var cell = info.cells[x]; cell.style |= Style.INFO;
                                row.put (info_start + 2 + x, cell);
                            }
                        }
                        frame.set_row (y, row);
                    }
                }
                body_dirty = false;
            }
            if (footer_dirty) {
                if (hint_height > 0) {
                    var hint_row = new Row (width);
                    hint_row.text (0, completion_hint, Style.COMPLETION);
                    frame.set_row (height - input_height - 2, hint_row);
                }
                int status_y = height - input_height - 1;
                var row = new Row (width, Style.STATUS);
                string prefix = buffer != null && buffer.scroll_offset > 0 ? "[scroll %d] ".printf (buffer.scroll_offset) : "";
                row.text (0, contacts_focus ? "Contacts · " +
                    (contacts.length > 0 ? contacts[selected_contact].name : "empty") : prefix + status,
                    contacts_focus ? Style.STATUS | Style.DIM : Style.STATUS);
                frame.set_row (status_y, row);
                int input_start = int.max (0, cy - input_height + 1);
                for (int y = 0; y < input_height; y++) {
                    row = new Row (width, Style.INPUT);
                    row.text (0,
                        contacts_focus ? (y == 0 ? "[input inactive]" : "") : (y == 0 ? "> " : "  "),
                        contacts_focus ? Style.INPUT | Style.DIM : Style.INPUT);
                    if (!contacts_focus && input_start + y < input_rows.length) {
                        var input = input_rows.get (input_start + y);
                        for (int x = 0; x < input.width; x++) {
                            var cell = input.cells[x]; cell.style |= Style.INPUT;
                            row.put (x + 2, cell);
                        }
                    }
                    frame.set_row (height - input_height + y, row);
                }
                frame.cursor_x = int.min (width - 1, cx + 2);
                frame.cursor_y = height - input_height + cy - input_start;
                footer_dirty = false;
            }
            if (paint_contact_list && contacts_tab_active) paint_contacts ();
            return frame;
        }

        private string tab_label (Buffer tab, int index) {
            return " %d:%s".printf (index + 1, tab.title) + (tab.unread_count > 0 ? " (%d)".printf (tab.unread_count) : "") + " ";
        }

        private void paint_contacts () {
            int columns = frame.width;
            int name_start = 0;
            var help_rows = contacts_help_visible ? new Text.plain (CONTACTS_HELP, Style.CONTACT).wrap (columns) : null;
            int help_height = help_rows == null ? 0 : int.min ((int) help_rows.length, body_height);
            int selected_row = contacts.length > 0 ? contact_positions[selected_contact] : 0;
            int top = int.max (0, selected_row - int.max (0, body_height - help_height - 2));
            bool details = columns >= 48;
            int name_width = details ? int.min (36, columns / 3) : columns;
            int preview_start = name_start + name_width + 11;
            for (int y = 1; y <= body_height; y++) {
                if (y <= help_height) {
                    frame.set_row (y, help_rows.get (y - 1));
                    continue;
                }
                var row = new Row (frame.width);
                var old = frame.get_row (y);
                for (int x = 0; x < frame.width; x++) row.put (x, old.cells[x]);
                row.text (0, string.nfill (columns, ' '), Style.CONTACT);
                if (y == help_height + 1) {
                    row.text (name_start, " Contacts" + (contacts_sort == ContactSort.ALPHABETICAL ? " · A–Z" : ""), Style.CONTACT | Style.BOLD, name_width);
                    if (details) {
                        row.text (name_start + name_width + 1, "Time", Style.CONTACT | Style.BOLD);
                        row.text (preview_start, "Last message", Style.CONTACT | Style.BOLD);
                    }
                } else if (top + y - help_height - 2 < contact_rows.length) {
                    int index = contact_rows[top + y - help_height - 2];
                    if (index < 0) {
                        string[] headings = { "Pinned", "Private chats", "Group chats", "Other chats" };
                        row.text (name_start, " " + headings[-index - 1], Style.CONTACT | Style.BOLD, columns);
                        frame.set_row (y, row);
                        continue;
                    }
                    contact_hits[y] = index;
                    var contact = contacts[index];
                    Style style = tab_open (contact.id) ? Style.OPEN_CONTACT : Style.CONTACT;
                    if (active_buffer != null && active_buffer.id == contact.id) style |= Style.ACTIVE_CONTACT | Style.BOLD;
                    if (contacts_focus && index == selected_contact) style |= Style.SELECTED;
                    row.text (name_start, string.nfill (columns, ' '), style, columns);
                    // Reserve columns for unread (1+1 space) and pin (2+1 space),
                    // including when either marker is absent.
                    row.text (name_start, contact.unread_count > 0 ? "*" : " ", style, 1);
                    row.text (name_start + 2, contact.pinned ? "📌" : "  ", style, 2);
                    row.text (name_start + 5, contact.name +
                        (contact.status == "" ? "" : " " + contact.status), style, int.max (0, name_width - 5));
                    if (details) {
                        row.text (name_start + name_width + 1, contact.time, style | Style.PREVIEW, 8);
                        row.text (preview_start, contact.preview, style | Style.PREVIEW, columns - (preview_start - name_start));
                    }
                }
                frame.set_row (y, row);
            }
        }
    }
}
