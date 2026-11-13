using Dc;
using Parla.Terminal;

/** All RPC operations capture an account before yielding. */
internal class CliTerminal : Object {
    private class MessageEdit : Object {
        public int id;
        public bool saving;
    }
    private class History : Object {
        public Buffer buffer;
        public string[] signatures = {};
        public Message[] messages = {};
        public string[]? members;
        public MessageEdit? edit;
        public History (Buffer buffer) { this.buffer = buffer; }
    }
    private class AccountState : Object {
        public int id;
        public string address = "";
        public string connection = "Core connected";
        public View view = new View ();
        public ChatEntry[] chats = {};
        public HashTable<string, History> histories = new HashTable<string, History> (str_hash, str_equal);
        public HashTable<int, string> contact_names = new HashTable<int, string> (direct_hash, direct_equal);
        public HashTable<string, bool> pinning = new HashTable<string, bool> (str_hash, str_equal);
        public HashTable<int, bool> reacting = new HashTable<int, bool> (direct_hash, direct_equal);
        public AccountState (int id) { this.id = id; }
    }
    private const string[] COMMANDS = { "account", "accounts", "bottom", "clear", "close", "color", "edit", "help",
        "info", "invite", "join", "list", "msg", "part", "qr", "query", "quit", "react", "refresh", "reply", "set", "unreact", "version", "window" };
    private const string HELP_TEXT = """# Parla commands
/help [COMMAND]             Show help
/account [ID|next|prev]      List or switch accounts; /accounts also lists them
/list [FILTER]              List conversations in this account
/query NAME|ADDRESS|ID      Open a chat or start one with a contact
/join CHAT                  Open an existing conversation by ID or name
/msg CHAT_ID TEXT           Send to a conversation in this account
/edit                      Edit selected/last editable own message; Enter updates, Escape cancels
/reply [TEXT]               Reply to selected/latest incoming message; no text selects with j/k then Enter
/reply @USER TEXT           Reply to that user's latest message; #ID targets a message explicitly
/react [#ID] EMOJI          Add your reaction to selected/latest incoming message
/unreact [#ID] [EMOJI]      Remove one reaction, or all your reactions if omitted
/window next|prev|CHAT      Switch tabs or open a conversation
/close, /part               Close this tab, preserving its draft
/set [OPTION[=VALUE]]       Show or save terminal preferences
/color [ROLE[=FG[:BG]]]     Show or save colors; /color theme=ocean picks a palette
/info                       Show current chat information
/invite [self]              Show an invite link and QR code; self shares your account
/refresh, /bottom, /clear   Reload, follow latest, or clear this view
/version                    Show the Parla version
/quit                       Exit from any chat
Tab completes /commands, options and @members; Shift-Tab cycles backwards.
Ctrl-G focuses contacts; j/k or arrows select, Enter opens.
In contacts: ? shows keys, g groups private/group chats, a toggles A–Z/recent, p pins/unpins.
Esc+x or middle-click closes a tab; Esc+1..9 (0 for 10) selects a tab.
Alt-Left/Right switch tabs. Ctrl-W deletes the word before the caret.
Ctrl-B/F or Page Up/Down scroll history; the wheel scrolls one row.
Ctrl-P/N or Up/Down recall shared input history; Ctrl-U clears the draft.
Enter sends; Alt-Enter/Ctrl-J inserts a newline. Ctrl-L redraws.
Use //text to send a literal leading slash.
/set chat_info=on shows members and disappearing message settings.
/color theme=ocean selects a palette; /color status=white:blue customizes it.
Command output goes to the Parla tab.
Click a message to select it; Escape clears the selection. Image/file links use terminal hyperlinks.
""";
    private CoreSession core = new CoreSession ();
    private CliOptions options = new CliOptions ();
    private Parla.Terminal.Completion completion = new Parla.Terminal.Completion ();
    private InputHistory input_history = new InputHistory ();
    private HashTable<int, AccountState> accounts = new HashTable<int, AccountState> (direct_hash, direct_equal);
    private int[] account_ids = {};
    private AccountState current;
    private Session? terminal;
    private MainLoop loop = new MainLoop ();
    private uint refresh_source;
    private uint options_source;
    private bool refreshing;
    private bool refresh_pending;
    private bool switching;
    private bool applying_options;
    private bool running = true;
    private int status;

    private AccountState state_for (int id) {
        var state = accounts[id];
        if (state != null) return state;
        state = new AccountState (id);
        accounts[id] = state;
        state.view.input_history = input_history;
        var home = state.view.add_tab ("home", "Parla");
        home.closable = false;
        home.append (HELP_TEXT);
        state.view.set_contacts ({});
        options.apply (state.view);
        state.view.quit_requested.connect (() => terminal.close ());
        state.view.submitted.connect ((buffer, text) => submit.begin (state, buffer, text));
        state.view.contact_activated.connect ((contact) => open_chat (state, contact.id, contact.name));
        state.view.contact_pin_requested.connect ((contact, pinned) => pin_chat.begin (state, contact, pinned));
        state.view.message_selected.connect (() => update_status (state));
        state.view.input_cancelled.connect ((buffer) => {
            var history = state.histories[buffer.id];
            if (history == null || history.edit == null || history.edit.saving) return;
            history.edit = null;
            buffer.editor.clear ();
            completion.reset ();
            update_status (state);
        });
        state.view.message_selection_confirmed.connect ((buffer, action) => {
            buffer.editor.clear ();
            buffer.editor.insert (action + " ");
            update_status (state);
        });
        state.view.tab_changed.connect ((buffer) => {
            completion.reset ();
            if (buffer.id == "home") buffer.set_unread (0);
            state.view.set_info ("Chat information", state.histories.contains (buffer.id) ? "Loading…" : "Select a conversation");
            update_status (state);
            if (state == current) schedule_refresh ();
        });
        state.view.completion_requested.connect ((buffer, backwards) => {
            complete.begin (state, buffer, backwards);
        });
        state.view.option_changed.connect ((name, value) => {
            if (applying_options) return;
            try {
                options.change (name, value, false);
                if (options_source == 0) options_source = Timeout.add (200, () => {
                    options_source = 0;
                    try { options.save (); }
                    catch (Error e) { reply (state, "Cannot save preference: " + e.message); }
                    return Source.REMOVE;
                });
            }
            catch (Error e) { reply (state, "Cannot save preference: " + e.message); }
        });
        return state;
    }

    public int run () {
        current = state_for (0);
        current.view.set_status ("Starting Chatmail Core…");
        try { terminal = new Session (current.view); }
        catch (Error e) { stderr.printf ("%s\n", e.message); return 1; }
        terminal.closed.connect (() => { running = false; loop.quit (); });
        terminal.failed.connect ((message) => { status = 1; stderr.printf ("%s\n", message); });
        terminal.use_theme (options.theme ());
        start.begin ();
        if (running) loop.run ();
        running = false;
        if (refresh_source != 0) Source.remove (refresh_source);
        if (options_source != 0) {
            Source.remove (options_source);
            try { options.save (); } catch (Error e) { stderr.printf ("%s\n", e.message); }
        }
        terminal.close ();
        core.rpc.stop ();
        return status;
    }

    private async void start () {
        try {
            yield core.start ();
            if (!running) return;
            core.rpc.disconnected.connect ((reason) => {
                if (!running) return;
                status = 1;
                terminal.close ();
                stderr.printf ("Disconnected: %s\n", reason);
            });
            string? description, notice;
            yield core.prepare_accounts (out description, out notice);
            if (!running) return;
            current = state_for (core.rpc.account_id);
            if (current.id > 0) current.address = (yield core.rpc.get_account_address (current.id)) ?? "";
            if (!running) return;
            terminal.set_view (current.view);
            var home = current.view.add_tab ("home", "Parla");
            if (description != null) home.append_text (description);
            if (notice != null) home.append_text (notice);
            update_status (current);
            schedule_refresh ();
            events.begin ();
            yield load_accounts ();
        } catch (Error e) {
            status = 1;
            terminal.close ();
            stderr.printf ("%s\n", e.message);
        }
    }

    private void update_status (AccountState state) {
        if (state.id <= 0) { state.view.set_status ("No configured account"); return; }
        var buffer = state.view.active_buffer;
        string chat = buffer == null || !state.histories.contains (buffer.id) ? "%d conversations".printf (state.chats.length) :
            "%s (#%s) · %d unread".printf (buffer.title, buffer.id, buffer.unread_count);
        if (buffer != null && buffer.selected_message_id != "") chat +=
            (state.view.selecting_messages ? " · Selecting #" : " · Selected #") + buffer.selected_message_id;
        var history = buffer == null ? null : state.histories[buffer.id];
        if (history != null && history.edit != null) {
            var edit = history.edit;
            string editing = edit.id == 0 ? "Loading edit… (Esc cancels)" : edit.saving ?
                "Saving edit #%d…".printf (edit.id) : "Editing #%d (Enter updates, Esc cancels)".printf (edit.id);
            chat = editing + " · " + chat;
        }
        state.view.set_status ("Account %d %s · %s · %s".printf (state.id, state.address, chat, state.connection));
    }

    private void reply (AccountState state, string text) {
        var home = state.view.add_tab ("home", "Parla");
        home.append_text (text);
        if (state.view.active_buffer == home) state.view.scroll (-int.MAX);
        else home.set_unread (home.unread_count + 1);
    }

    private void open_chat (AccountState state, string id, owned string name) {
        foreach (var chat in state.chats) if (chat.id.to_string () == id) { name = chat_label (chat); break; }
        var buffer = state.view.add_tab (id, name);
        if (!state.histories.contains (id)) state.histories[id] = new History (buffer);
        state.view.select_tab (id);
        state.view.set_info ("Chat information", "Loading…");
        if (state == current) schedule_refresh ();
        update_status (state);
    }

    private void schedule_refresh () {
        if (!running || current.id <= 0) return;
        refresh_pending = true;
        if (refresh_source != 0 || refreshing) return;
        refresh_source = Timeout.add (100, () => {
            refresh_source = 0; refresh.begin (); return Source.REMOVE;
        });
    }

    private void show_contacts (AccountState state) {
        Parla.Terminal.Contact[] contacts = {};
        foreach (var chat in state.chats) {
            string label = chat_label (chat);
            ContactKind kind = label.has_prefix ("#") ? ContactKind.GROUP : label.has_prefix ("@") ? ContactKind.DIRECT : ContactKind.OTHER;
            string time = chat.timestamp > 0 && !chat.is_draft ? new DateTime.from_unix_local (chat.timestamp).format (options.value ("time_format")) : "";
            string preview = chat.last_message ?? "";
            if (chat.is_draft) preview = "Draft: " + preview;
            else if (chat.summary_prefix != null && chat.summary_prefix != "") preview = chat.summary_prefix + ": " + preview;
            contacts += new Parla.Terminal.Contact (chat.id.to_string (), chat_label (chat),
                chat.unread_count > 0 ? "(%d)".printf (chat.unread_count) : "", chat.unread_count,
                kind, chat.is_pinned, chat.timestamp, time, preview);
        }
        state.view.set_contacts (contacts);
    }

    private async void pin_chat (AccountState state, Parla.Terminal.Contact contact, bool pinned) {
        if (state.pinning.contains (contact.id)) return;
        state.pinning[contact.id] = true;
        try {
            yield core.rpc.set_chat_visibility_for (state.id, int.parse (contact.id), pinned ? "Pinned" : "Normal");
            if (!running) return;
            foreach (var chat in state.chats) if (chat.id.to_string () == contact.id) chat.is_pinned = pinned;
            show_contacts (state);
            if (state == current) schedule_refresh ();
        } catch (Error e) { if (running) reply (state, "Cannot change pin: " + e.message); }
        finally { state.pinning.remove (contact.id); }
    }

    private static string chat_label (ChatEntry chat) {
        string prefix = chat.kind == ChatKind.GROUP || chat.chat_type == "InBroadcast" || chat.chat_type == "Mailinglist" ? "#" :
            chat.kind == ChatKind.DIRECT ? "@" : "";
        return chat.name.has_prefix (prefix) ? chat.name : prefix + chat.name;
    }

    private async void load_chats (AccountState state) throws Error {
        var ids = yield core.rpc.get_chatlist_entries_for (state.id, null, RpcClient.GCL_NO_SPECIALS);
        if (!running || ids == null) return;
        var items = yield core.rpc.get_chatlist_items_by_entries_for (state.id, ids);
        if (!running || items == null) return;
        ChatEntry[] chats = {};
        for (uint i = 0; i < ids.get_length (); i++) {
            int id = (int) ids.get_int_element (i);
            var item = json_obj (items, id.to_string ());
            if (item != null) chats += RpcParsers.parse_chat_item (id, item);
        }
        state.chats = chats;
        show_contacts (state);
    }

    private void render_history (AccountState state, History history, Message[] messages, bool force = false) {
        string[] signatures = {};
        foreach (var message in messages)
            signatures += "%d:%lld:%d:%s:%s:%s:%s:%s:%s:%s:%d:%s:%s:%s:%s".printf (message.id, message.timestamp, message.state,
                message.is_outgoing.to_string (), message.sender_name ?? "", message.sender_address ?? "",
                message.text ?? "", message.file_name ?? "", message.file_path ?? "", message.reactions ?? "",
                message.quote_msg_id, message.quote_text ?? "", message.quote_sender_name ?? "",
                message.file_mime ?? "", message.has_local_file.to_string ());
        bool prefix = !force && history.signatures.length <= signatures.length;
        for (int i = 0; prefix && i < history.signatures.length; i++)
            if (history.signatures[i] != signatures[i]) prefix = false;
        var buffer = history.buffer;
        int offset = buffer.scroll_offset;
        string selection = buffer.selected_message_id;
        int start = prefix ? history.signatures.length : 0;
        if (!prefix) buffer.clear ();
        for (int i = start; i < messages.length; i++) {
            var message = messages[i];
            string time = options.enabled ("timestamps") ? (!message.is_pending && message.timestamp > 0 ?
                new DateTime.from_unix_local (message.timestamp).format (options.value ("time_format")) : "--:--") : "";
            string nick = message.sender_name ?? message.sender_address ?? "?";
            string label = "", uri = "";
            if (message.has_file) {
                label = "[%s: %s]".printf (message.is_image_file () ? "Image" : "File", message.display_file_name ());
                if (message.has_local_file) {
                    uri = File.new_for_path (message.file_path).get_uri ();
                    label += " " + message.file_path;
                } else label += " (not downloaded)";
            }
            string body = message.text ?? "";
            if (message.quote_text != null && message.quote_text != "") body = "> " +
                (message.quote_sender_name ?? "") + ": " + message.quote_text.replace ("\n", " ") + "\n" + body;
            string suffix = message.is_failed ? "[failed]" : "";
            if (message.reactions != null && message.reactions != "") suffix += " [" + message.reactions.replace (",", " ") + "]";
            buffer.append_message (time, nick, body, suffix,
                message.sender_address ?? nick, message.is_outgoing, options.enabled ("markdown"),
                options.enabled ("nick_colors"), options.value ("message_layout") == "compact", message.id.to_string (), label, uri);
        }
        if (!prefix && selection != "") buffer.select_message (selection);
        if (!prefix && offset > 0 && state.view.active_buffer == buffer) state.view.scroll (offset);
        history.signatures = signatures;
        history.messages = messages;
    }

    private async void refresh () {
        refreshing = true;
        refresh_pending = false;
        var state = current;
        try {
            yield load_chats (state);
            if (!running) return;
            var buffer = state.view.active_buffer;
            if (buffer == null || !state.histories.contains (buffer.id)) return;
            var history = state.histories[buffer.id];
            int chat_id = int.parse (buffer.id);
            var entries = yield core.rpc.get_message_ids_for (state.id, chat_id);
            if (!running || entries == null) return;
            int[] ids = {};
            for (int i = int.max (0, (int) entries.get_length () - 100); i < entries.get_length (); i++)
                ids += (int) entries.get_int_element (i);
            var messages = yield core.rpc.get_parsed_messages_for (state.id, ids);
            if (!running) return;
            render_history (state, history, messages);
            if (state.view.info_visible) yield load_info (state, buffer);
            if (state == current && state.view.active_buffer == buffer) {
                int[] unread = {};
                foreach (var message in messages)
                    if (!message.is_outgoing && message.state < MessageState.IN_SEEN) unread += message.id;
                if (unread.length > 0) yield core.rpc.mark_seen_msgs_for (state.id, unread);
                if (!running || state != current || state.view.active_buffer != buffer) return;
                if (buffer.unread_count > 0) yield core.rpc.marknoticed_chat_for (state.id, chat_id);
                if (!running) return;
                foreach (var chat in state.chats) if (chat.id == chat_id) chat.unread_count = 0;
                show_contacts (state);
                buffer.set_unread (0);
            }
        } catch (Error e) {
            if (running) reply (state, "Refresh failed: " + e.message);
        } finally {
            update_status (state);
            refreshing = false;
            if (refresh_pending) schedule_refresh ();
        }
    }

    private async void events () {
        while (running && core.rpc.is_connected) {
            try {
                var ev = yield core.rpc.get_next_event ();
                if (!running || ev == null) return;
                var state = current;
                if (json_int (ev, "contextId") != state.id) continue;
                var detail = json_obj (ev, "event");
                if (detail == null) continue;
                switch (json_str (detail, "kind") ?? "") {
                case "ContactsChanged":
                    state.contact_names.remove_all ();
                    foreach (var history in state.histories.get_values ()) history.members = null;
                    schedule_refresh (); break;
                case "ChatModified":
                    foreach (var history in state.histories.get_values ()) history.members = null;
                    schedule_refresh (); break;
                case "IncomingMsg": case "IncomingMsgBunch": case "MsgsChanged": case "MsgsNoticed":
                case "ChatlistChanged": case "MsgDelivered": case "MsgFailed": case "MsgRead":
                case "ChatEphemeralTimerModified": case "ReactionsChanged": case "IncomingReaction":
                    schedule_refresh (); break;
                case "ConnectivityChanged":
                    int connectivity = yield core.rpc.get_connectivity (state.id);
                    state.connection = connectivity >= 4000 ? "Connected" : connectivity >= 3000 ? "Syncing" : "Connecting";
                    if (running) update_status (state);
                    break;
                }
            } catch (Error e) {
                if (running) reply (current, "Event stream: " + e.message);
                return;
            }
        }
    }

    private async void load_accounts () throws Error {
        var node = yield core.rpc.get_all_accounts ();
        if (node == null) return;
        int[] ids = {};
        var list = node.get_array ();
        for (uint i = 0; i < list.get_length (); i++) {
            int id = (int) json_int (list.get_object_element (i), "id");
            if (id > 0 && (yield core.rpc.is_configured (id))) ids += id;
        }
        account_ids = ids;
    }

    private async string load_info (AccountState state, Buffer buffer) throws Error {
        if (!state.histories.contains (buffer.id)) return "Select a conversation";
        var chat = yield core.rpc.get_full_chat_by_id_for (state.id, int.parse (buffer.id));
        if (chat == null) {
            if (state.view.active_buffer == buffer) state.view.set_info ("Chat information", "Unavailable");
            return "Chat information unavailable";
        }
        int64 timer = json_int (chat, "ephemeralTimer");
        int64 amount = timer;
        string unit = "second";
        if (timer > 0 && timer % 86400 == 0) { amount = timer / 86400; unit = "day"; }
        else if (timer > 0 && timer % 3600 == 0) { amount = timer / 3600; unit = "hour"; }
        else if (timer > 0 && timer % 60 == 0) { amount = timer / 60; unit = "minute"; }
        string expiry = timer <= 0 ? "Off" : "%lld %s%s".printf (amount, unit, amount == 1 ? "" : "s");
        var text = new StringBuilder ();
        text.append_printf ("%s\n%s\n\nDisappearing messages\n%s\n\n%s\n",
            json_str (chat, "name") ?? buffer.title, json_str (chat, "chatType") ?? "Chat", expiry,
            json_bool (chat, "canSend") ? "Can send messages" : "Read-only");
        string[] members = {};
        if (chat.has_member ("contactIds")) {
            var ids = chat.get_array_member ("contactIds");
            text.append_printf ("\nMembers (%u)\n", ids.get_length ());
            for (uint i = 0; i < uint.min (ids.get_length (), 200); i++) {
                int id = (int) ids.get_int_element (i);
                string? name = state.contact_names[id];
                if (name == null) {
                    var contact = yield core.rpc.get_contact_for (state.id, id);
                    if (!running) return "";
                    if (contact != null) {
                        name = json_str (contact, "displayName") ?? json_str (contact, "name") ?? json_str (contact, "address") ?? id.to_string ();
                        // Completion inserts trusted plain text, never control sequences.
                        name = new Parla.Terminal.Text.plain (name).wrap (80).get (0).plain_text ().strip ();
                        state.contact_names[id] = name;
                    }
                }
                if (name != null && name != "") { members += name; text.append (name + "\n"); }
            }
            if (ids.get_length () > 200) text.append ("… more members\n");
        }
        state.histories[buffer.id].members = members;
        if (state.view.active_buffer == buffer) state.view.set_info ("Chat information", text.str);
        return text.str;
    }

    private async void list_accounts (AccountState state, Buffer buffer) throws Error {
        yield load_accounts ();
        var text = new StringBuilder ("Accounts:\n");
        foreach (int id in account_ids) {
            string address = (yield core.rpc.get_account_address (id)) ?? "";
            text.append_printf ("%s%d  %s\n", id == current.id ? "* " : "  ", id, address);
        }
        reply (state, text.str);
    }

    private async void switch_account (string value) throws Error {
        if (switching) throw new IOError.PENDING ("An account switch is already in progress");
        switching = true;
        try {
            yield load_accounts ();
            int id = 0;
            if (value == "next" || value == "prev") {
                if (account_ids.length == 0) throw new IOError.NOT_FOUND ("No configured accounts");
                int index = 0;
                for (int i = 0; i < account_ids.length; i++) if (account_ids[i] == current.id) index = i;
                id = account_ids[(index + (value == "next" ? 1 : account_ids.length - 1)) % account_ids.length];
            } else if (!int.try_parse (value, out id) || id <= 0)
                throw new IOError.INVALID_ARGUMENT ("Usage: /account ID|next|prev");
            bool found = false;
            foreach (int configured in account_ids) if (configured == id) found = true;
            if (!found) throw new IOError.NOT_FOUND ("Account is not configured");
            if (id == current.id) return;
            string address = (yield core.rpc.get_account_address (id)) ?? "";
            yield core.rpc.select_account (id);
            if (!running) return;
            core.rpc.account_id = id;
            core.rpc.self_email = null;
            current = state_for (id);
            applying_options = true;
            options.apply (current.view);
            applying_options = false;
            input_history.reset ();
            current.address = address;
            completion.reset ();
            terminal.set_view (current.view);
            update_status (current);
            schedule_refresh ();
        } finally { switching = false; }
    }

    private async ChatEntry find_chat (AccountState state, string value) throws Error {
        if (state.id <= 0) throw new IOError.NOT_INITIALIZED ("Select an account first");
        if (state.chats.length == 0) yield load_chats (state);
        ChatEntry? found = null;
        foreach (var chat in state.chats) {
            string label = chat_label (chat);
            if (chat.id.to_string () == value || chat.name.casefold () == value.casefold () || label.casefold () == value.casefold ()) return chat;
            if (chat.name.casefold ().has_prefix (value.casefold ()) || label.casefold ().has_prefix (value.casefold ())) {
                if (found != null) throw new IOError.INVALID_ARGUMENT ("Ambiguous chat name; use its ID from /list");
                found = chat;
            }
        }
        if (found == null || value == "") throw new IOError.NOT_FOUND ("Unknown chat; use /list");
        return found;
    }

    private async void query (AccountState state, string value) throws Error {
        if (value == "") throw new IOError.INVALID_ARGUMENT ("Usage: /query NAME|ADDRESS|ID");
        string address = value.has_prefix ("@") ? value.substring (1) : value;
        if (address.contains ("@") && !address.contains (" ")) {
            yield query_contact (state, value);
            return;
        }
        try {
            var target = yield find_chat (state, value);
            open_chat (state, target.id.to_string (), target.name);
        } catch (IOError.NOT_FOUND e) {
            int chat_id;
            // Explicit group names and IDs refer only to existing conversations.
            if (value.has_prefix ("#") || int.try_parse (value, out chat_id)) throw e;
            yield query_contact (state, value);
        }
    }

    private async void query_contact (AccountState state, owned string value) throws Error {
        if (state.id <= 0) throw new IOError.NOT_INITIALIZED ("Select an account first");
        if (value.has_prefix ("@")) value = value.substring (1);
        if (value == "") throw new IOError.INVALID_ARGUMENT ("Usage: /query NAME|ADDRESS|ID");
        int contact_id = 0;
        if (value.contains ("@") && !value.contains (" ")) {
            contact_id = yield core.rpc.get_or_create_contact_for (state.id, value);
        } else {
            var ids = yield core.rpc.get_contact_ids_for (state.id, value);
            int exact = 0, partial = 0, matches = 0, exact_matches = 0;
            if (ids != null) for (uint i = 0; i < ids.get_length (); i++) {
                int id = (int) ids.get_int_element (i);
                var contact = yield core.rpc.get_contact_for (state.id, id);
                if (contact == null) continue;
                string name = json_str (contact, "displayName") ?? json_str (contact, "name") ?? "";
                if (name.casefold () == value.casefold ()) { exact = id; exact_matches++; }
                partial = id; matches++;
            }
            if (exact_matches > 1 || (exact_matches == 0 && matches > 1))
                throw new IOError.INVALID_ARGUMENT ("Ambiguous contact name; use an address");
            contact_id = exact_matches == 1 ? exact : matches == 1 ? partial : 0;
        }
        if (contact_id <= 0) throw new IOError.NOT_FOUND ("Contact not found; use an address to add one");
        var contact = yield core.rpc.get_contact_for (state.id, contact_id);
        int chat_id = yield core.rpc.get_or_create_chat_by_contact_for (state.id, contact_id);
        if (!running) return;
        if (chat_id <= 0) throw new IOError.FAILED ("Cannot open this contact's chat");
        string name = contact == null ? value : json_str (contact, "displayName") ?? json_str (contact, "name") ?? value;
        open_chat (state, chat_id.to_string (), name.has_prefix ("@") ? name : "@" + name);
    }

    private async void invite (AccountState state, Buffer buffer, string arg) throws Error {
        if (state.id <= 0) throw new IOError.NOT_INITIALIZED ("Select an account first");
        if (arg != "" && arg != "self") throw new IOError.INVALID_ARGUMENT ("Usage: /invite [self]");
        int chat_id = 0;
        if (arg != "self" && state.histories.contains (buffer.id)) {
            var chat = yield core.rpc.get_full_chat_by_id_for (state.id, int.parse (buffer.id));
            string kind = chat == null ? "" : json_str (chat, "chatType") ?? "";
            if (kind == "Group" || kind == "Broadcast" || kind == "OutBroadcast") chat_id = int.parse (buffer.id);
        }
        string link = yield core.rpc.get_chat_securejoin_qr_code (state.id, chat_id);
        if (!running) return;
        reply (state, (chat_id == 0 ? "Your contact invite:\n" : "Chat invite:\n") + link);
        string svg = yield core.rpc.create_qr_svg (link);
        if (!running) return;
        int columns, rows;
        string qr = CliQr.render (svg, out columns, out rows);
        reply (state, "QR code (%d columns × %d rows; enlarge the terminal if needed):".printf (columns, rows));
        state.view.add_tab ("home", "Parla").append_block (qr, columns, Style.QR);
        if (state.view.active_buffer.id == "home") state.view.scroll (-int.MAX);
    }

    private async Message message_target (AccountState state, Buffer buffer, string arg, bool editable,
                                         out string text) throws Error {
        text = arg;
        if (state.id <= 0 || !state.histories.contains (buffer.id))
            throw new IOError.NOT_INITIALIZED ("Open a conversation first");
        int chat_id = int.parse (buffer.id), id = 0;
        string sender = "";
        string[] parts = arg.split (" ", 2);
        if (arg.has_prefix ("#") && int.try_parse (parts[0].substring (1), out id) && id > 0) {
            text = parts.length > 1 ? parts[1].strip () : "";
        } else if (arg.has_prefix ("@")) {
            sender = parts[0].substring (1);
            text = parts.length > 1 ? parts[1].strip () : "";
            // A member's display name can contain spaces: choose the longest match.
            var history = state.histories[buffer.id];
            string rest = arg.substring (1);
            foreach (var message in history.messages) {
                string name = message.sender_name ?? "";
                if (name.length > sender.length && rest.casefold ().has_prefix (name.casefold () + " ")) {
                    sender = name;
                    text = rest.substring (name.length).strip ();
                }
            }
            if (sender == "") throw new IOError.INVALID_ARGUMENT ("Specify a sender after @");
            id = 0;
        } else {
            id = int.parse (buffer.selected_message_id);
        }
        if (id > 0) {
            var message = yield core.rpc.fetch_message_for (state.id, id);
            if (message == null || message.id != id || message.chat_id != chat_id)
                throw new IOError.NOT_FOUND ("Selected message is not available in this chat");
            return message;
        }
        var ids = yield core.rpc.get_message_ids_for (state.id, chat_id);
        // Search newest first in bounded batches, including older messages not in scrollback.
        for (int end = ids == null ? 0 : (int) ids.get_length (); end > 0;) {
            int begin = int.max (0, end - 100);
            int[] batch = {};
            for (int i = begin; i < end; i++) batch += (int) ids.get_int_element (i);
            var messages = yield core.rpc.get_parsed_messages_for (state.id, batch);
            for (int i = messages.length - 1; i >= 0; i--) {
                var message = messages[i];
                if (message.chat_id != chat_id || message.is_info) continue;
                if (editable) {
                    if (message.can_edit_text) return message;
                    continue;
                }
                if (sender == "" ? !message.is_outgoing :
                    (message.sender_name ?? "").casefold () == sender.casefold () ||
                    (message.sender_address ?? "").casefold () == sender.casefold ()) return message;
            }
            end = begin;
        }
        throw new IOError.NOT_FOUND (editable ? "No editable message in this chat" :
            sender == "" ? "No incoming message in this chat" : "No message from @" + sender);
    }

    private async void begin_edit (AccountState state, Buffer buffer, string arg) throws Error {
        if (arg != "") throw new IOError.INVALID_ARGUMENT ("Usage: /edit");
        var history = state.histories[buffer.id];
        if (state.id <= 0 || history == null) throw new IOError.NOT_INITIALIZED ("Open a conversation first");
        var edit = new MessageEdit ();
        history.edit = edit;
        update_status (state);
        try {
            string unused;
            var message = yield message_target (state, buffer, "", true, out unused);
            if (!running || history.edit != edit) return;
            if (!message.can_edit_text) throw new IOError.INVALID_ARGUMENT ("Selected message cannot be edited");
            if (buffer.editor.text != "") throw new IOError.PENDING ("Input changed while loading the message; run /edit again");
            edit.id = message.id;
            buffer.editor.insert (message.text);
        } catch (Error e) {
            if (history.edit != edit) return;
            history.edit = null;
            throw e;
        } finally { update_status (state); }
    }

    private async void save_edit (AccountState state, History history, string text) throws Error {
        var edit = history.edit;
        if (edit.id == 0 || edit.saving) throw new IOError.PENDING ("An edit is still in progress");
        edit.saving = true;
        update_status (state);
        try {
            yield core.rpc.send_edit_request_for (state.id, edit.id, text);
            history.edit = null;
            if (!running) return;
            if (history.buffer.selected_message_id == edit.id.to_string ()) history.buffer.select_message ("");
            reply (state, "Updated #%d".printf (edit.id));
            if (state == current) schedule_refresh ();
        } finally {
            edit.saving = false;
            update_status (state);
        }
    }

    private async void message_action (AccountState state, Buffer buffer, string command, string arg) throws Error {
        if (arg == "" && (command == "/reply" || command == "/react")) {
            if (!state.histories.contains (buffer.id) || !state.view.begin_message_selection (command))
                throw new IOError.NOT_FOUND ("No messages to select in this chat");
            return;
        }
        string text;
        var message = yield message_target (state, buffer, arg, false, out text);
        if (!running) return;
        if (command == "/reply") {
            if (text == "") throw new IOError.INVALID_ARGUMENT ("Usage: /reply [@USER|#ID] TEXT");
            yield core.rpc.send_msg_for (state.id, int.parse (buffer.id), text, null, null, message.id);
            if (!running) return;
            if (buffer.selected_message_id == message.id.to_string ()) buffer.select_message ("");
            reply (state, "Replied to #%d".printf (message.id));
            update_status (state);
        } else {
            if (state.reacting.contains (message.id)) throw new IOError.PENDING ("A reaction update is still in progress");
            state.reacting[message.id] = true;
            try {
                var reactions = yield core.rpc.get_message_reactions_for (state.id, message.id);
                RpcParsers.parse_reactions (reactions, message);
                string[] wanted = text == "" ? new string[] {} : text.split (" ");
                if (command == "/react" && wanted.length == 0) throw new IOError.INVALID_ARGUMENT ("Usage: /react [#ID] EMOJI");
                string[] mine = {};
                if (message.my_reactions != null) foreach (var emoji in message.my_reactions.split (",")) {
                    bool remove = command == "/unreact" && (text == "" || emoji in wanted);
                    if (!remove && emoji != "") mine += emoji;
                }
                if (command == "/react") foreach (var emoji in wanted)
                    if (emoji != "" && !(emoji in mine)) mine += emoji;
                yield core.rpc.send_reaction_for (state.id, message.id, mine);
                if (running) reply (state, "Updated reactions on #%d".printf (message.id));
            } finally { state.reacting.remove (message.id); }
        }
        if (running && state == current) schedule_refresh ();
    }

    private string[] candidates (AccountState state, Editor editor) {
        string prefix = editor.text.substring (0, editor.cursor);
        bool assignment = (prefix.has_prefix ("/set ") || prefix.has_prefix ("/color ")) && prefix.contains ("=");
        if (assignment) prefix = prefix.replace ("=", " ");
        string[] words = prefix.split (" ");
        string[] result = {};
        if (words.length == 1) foreach (var command in COMMANDS) result += "/" + command;
        else if (words[0] == "/set") {
            if (words.length == 2) foreach (var name in CliOptions.NAMES) result += "/set " + name;
            else {
                string[] values = {};
                switch (words[1]) {
                case "chat_info": case "timestamps": case "markdown": case "nick_colors": case "contacts_grouped": values = { "on", "off" }; break;
                case "contacts_sort": values = { "recent", "alphabetical" }; break;
                case "time_format": values = { "%H:%M", "%H:%M:%S" }; break;
                case "message_layout": values = { "compact", "stacked" }; break;
                case "theme": values = { "default", "light", "ocean" }; break;
                }
                if (words[1].has_prefix ("color_")) values = { "inherit", "default", "red", "green", "blue", "cyan", "magenta", "yellow", "white", "black", "bright_blue" };
                foreach (var value in values) result += "/set " + words[1] + " " + value;
            }
        } else if (words[0] == "/color") {
            if (words.length == 2) {
                result += "/color theme";
                foreach (var role in Theme.ROLES) result += "/color " + role;
            } else {
                string[] colors = words[1] == "theme" ? new string[] { "default", "light", "ocean" } :
                    new string[] { "inherit", "default", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "bright_blue" };
                foreach (var value in colors) result += "/color " + words[1] + " " + value;
            }
        } else if (words[0] == "/account") {
            result = { "/account next", "/account prev" };
            foreach (int id in account_ids) result += "/account " + id.to_string ();
        } else if (words[0] == "/help") {
            foreach (var command in COMMANDS) result += "/help " + command;
        } else if (words[0] == "/query" || words[0] == "/join" || words[0] == "/msg" || words[0] == "/window") {
            if (words[0] == "/window") result = { "/window next", "/window prev", "/window close", "/window home", "/window contacts" };
            foreach (var chat in state.chats) {
                result += words[0] + " " + chat.id.to_string ();
                if (words[0] != "/msg") {
                    result += words[0] + " " + chat.name;
                    if (chat_label (chat) != chat.name) result += words[0] + " " + chat_label (chat);
                }
            }
        }
        if (assignment) for (int i = 0; i < result.length; i++) {
            int separator = result[i].index_of (" ", words[0].length + 1);
            if (separator > 0) result[i] = result[i].substring (0, separator) + "=" + result[i].substring (separator + 1);
        }
        return result;
    }

    private async void complete (AccountState state, Buffer buffer, bool backwards) {
        if (state.histories.contains (buffer.id) && state.histories[buffer.id].edit != null) return;
        var editor = buffer.editor;
        string text = editor.text;
        int cursor = editor.cursor;
        string prefix = text.substring (0, cursor);
        int at = Parla.Terminal.Completion.mention_start (prefix);
        string[] choices = {};
        if (!prefix.has_prefix ("/") && at >= 0) {
            var history = state.histories[buffer.id];
            if (history != null) {
                try { if (history.members == null) yield load_info (state, buffer); }
                catch (Error e) { reply (state, "Cannot complete members: " + e.message); return; }
                if (history.members != null) foreach (var name in history.members)
                    choices += prefix.substring (0, at) + "@" + name;
            }
        } else choices = candidates (state, editor);
        if (!running || state != current || state.view.active_buffer != buffer || editor.text != text || editor.cursor != cursor) return;
        completion.complete (editor, choices, backwards);
        state.view.set_completion_hint (completion.hint);
    }

    private void setting (AccountState state, Buffer buffer, string arg) throws Error {
        string[] parts = arg.contains ("=") ? arg.split ("=", 2) : arg.split (" ", 2);
        if (arg == "") {
            var text = new StringBuilder ("Terminal settings:\n");
            foreach (var name in CliOptions.NAMES) text.append_printf ("%s = %s\n", name, options.value (name));
            reply (state, text.str);
            return;
        }
        string name = parts[0].strip ().down ();
        if (options.value (name) == "") throw new IOError.INVALID_ARGUMENT ("Unknown setting: " + name);
        if (parts.length == 1) { reply (state, name + " = " + options.value (name)); return; }
        options.change (name, parts[1].strip ());
        applying_options = true;
        foreach (var account in accounts.get_values ()) {
            if (name == "time_format") show_contacts (account);
            if (name.has_prefix ("contacts") || name == "chat_info") options.apply (account.view);
            else if (name != "theme" && !name.has_prefix ("color_")) foreach (var history in account.histories.get_values ())
                render_history (account, history, history.messages, true);
        }
        applying_options = false;
        if (name == "theme" || name.has_prefix ("color_")) terminal.use_theme (options.theme ());
        if (name == "chat_info") schedule_refresh ();
        reply (state, (name.has_prefix ("color_") ? name.substring (6) : name) + " = " + options.value (name));
    }

    private void color (AccountState state, Buffer buffer, string arg) throws Error {
        if (arg == "") {
            var text = new StringBuilder ("Colors (foreground[:background], ANSI names or #RRGGBB):\n");
            var theme = options.theme ();
            text.append_printf ("theme = %s\n", options.value ("theme"));
            foreach (var role in Theme.ROLES) text.append_printf ("%s = %s\n", role, theme.get_color (role));
            reply (state, text.str);
            return;
        }
        string[] parts = arg.contains ("=") ? arg.split ("=", 2) : arg.split (" ", 2);
        string role = parts[0].strip ().down ();
        string name = role == "theme" ? "theme" : "color_" + role;
        if (options.value (name) == "") throw new IOError.INVALID_ARGUMENT ("Unknown color role: " + role);
        if (parts.length == 1) {
            reply (state, role + " = " + (role == "theme" ? options.value ("theme") : options.theme ().get_color (role)));
            return;
        }
        setting (state, buffer, name + "=" + parts[1].strip ());
    }

    private async void submit (AccountState state, Buffer buffer, owned string text) {
        completion.reset ();
        try {
            var history = state.histories[buffer.id];
            if (history != null && history.edit != null) {
                yield save_edit (state, history, text);
                return;
            }
            if (text.has_prefix ("/") && !text.has_prefix ("//")) {
                string[] parts = text.strip ().split (" ", 2);
                string command = parts[0].down ();
                string arg = parts.length > 1 ? parts[1].strip () : "";
                switch (command) {
                case "/quit": terminal.close (); return;
                case "/version": reply (state, "Parla " + Parla.VERSION); return;
                case "/help": reply (state, HELP_TEXT); return;
                case "/set": setting (state, buffer, arg); return;
                case "/color": color (state, buffer, arg); return;
                case "/info": reply (state, yield load_info (state, buffer)); return;
                case "/edit": yield begin_edit (state, buffer, arg); return;
                case "/invite": case "/qr": yield invite (state, buffer, arg); return;
                case "/reply": case "/react": case "/unreact": yield message_action (state, buffer, command, arg); return;
                case "/accounts": yield list_accounts (state, buffer); return;
                case "/account":
                    if (arg == "") yield list_accounts (state, buffer); else yield switch_account (arg);
                    return;
                case "/refresh": schedule_refresh (); return;
                case "/bottom": state.view.scroll (-int.MAX); return;
                case "/clear": buffer.clear (); return;
                case "/close": case "/part": state.view.close_tab (buffer.id); return;
                case "/list":
                    if (state.id <= 0) throw new IOError.NOT_INITIALIZED ("Select an account first");
                    yield load_chats (state);
                    var list = new StringBuilder ("Conversations:\n");
                    foreach (var chat in state.chats) if (arg == "" || chat.name.casefold ().contains (arg.casefold ()))
                        list.append_printf ("%d  %s  (%d unread)\n", chat.id, chat_label (chat), chat.unread_count);
                    reply (state, list.str);
                    return;
                case "/window":
                    if (arg == "next" || arg == "prev") {
                        state.view.handle_key (arg == "next" ? Key.NEXT_TAB : Key.PREVIOUS_TAB); return;
                    }
                    if (arg == "close") { state.view.close_tab (buffer.id); return; }
                    if (arg == "home") { state.view.select_tab ("home"); return; }
                    if (arg == "contacts") {
                        state.view.handle_key (Key.FOCUS); return;
                    }
                    var target = yield find_chat (state, arg);
                    open_chat (state, target.id.to_string (), target.name);
                    return;
                case "/query": yield query (state, arg); return;
                case "/join":
                    var target = yield find_chat (state, arg);
                    open_chat (state, target.id.to_string (), target.name);
                    return;
                case "/msg":
                    string[] args = arg.split (" ", 2);
                    if (args.length != 2 || args[1] == "") throw new IOError.INVALID_ARGUMENT ("Usage: /msg CHAT_ID TEXT");
                    var target = yield find_chat (state, args[0]);
                    int sent = yield core.rpc.send_msg_for (state.id, target.id, args[1]);
                    reply (state, "Sent %d to %s".printf (sent, target.name));
                    schedule_refresh ();
                    return;
                default: throw new IOError.INVALID_ARGUMENT ("Unknown command: " + command + ". Use /help.");
                }
            }
            string message = text.has_prefix ("//") ? text.substring (1) : text;
            if (state.id <= 0 || !state.histories.contains (buffer.id)) throw new IOError.NOT_INITIALIZED ("Open a conversation with /query or select a contact");
            yield core.rpc.send_msg_for (state.id, int.parse (buffer.id), message);
            if (running && state == current) schedule_refresh ();
        } catch (Error e) {
            if (!running) return;
            reply (state, "Error: " + e.message);
            if (buffer.editor.text == "") buffer.editor.insert (text);
        }
    }
}
