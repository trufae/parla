namespace Dc {

    /**
     * Per-chat conversation view. One instance per chat, cached by the
     * window so each conversation keeps its own draft, scroll position,
     * message store, search state, and pinned bar across chat switches.
     */
    public class ConversationView : Gtk.Box {

        public int chat_id { get; construct; }

        private unowned Window window;
        private unowned RpcClient rpc;
        private unowned SettingsManager settings;
        private ChatKind chat_kind = ChatKind.UNKNOWN;
        private bool chat_kind_loaded = false;

        private Gtk.ListView message_listview;
        private Gtk.ScrolledWindow message_scroll;
        private GLib.ListStore message_store;
        private Gtk.FilterListModel filtered_message_store;
        private Gtk.CustomFilter message_filter;
        private ComposeBar compose_bar;
        private Gtk.Box selection_bar;
        private Gtk.Button selection_delete_btn;
        private Gtk.Button selection_forward_btn;
        private Gtk.Box request_bar;
        private bool is_contact_request = false;
        private bool selection_mode = false;
        private Gtk.Button scroll_down_btn;
        private Gtk.Revealer loading_more_revealer;
        private Gtk.Spinner loading_more_spinner;
        private Gtk.Revealer message_search_revealer;
        private Gtk.SearchEntry message_search_entry;
        private bool search_toggling;
        private FileDropTarget? file_drop_target;

        private bool stick_to_bottom = true;
        private int[] pending_seen_ids = {};
        private Json.Array? all_msg_ids = null;
        private uint loaded_start_index = 0;
        private bool loading_more = false;
        private bool loading_chat = false;
        private bool messages_loaded = false;
        private int64 scroll_freeze_until_us = 0;

        private PinnedMessagesManager pinned;
        private MessageActions msg_actions;

        public ConversationView (int chat_id, Window window, RpcClient rpc,
                                 SettingsManager settings,
                                 ChatKind chat_kind = ChatKind.UNKNOWN) {
            Object (
                orientation: Gtk.Orientation.VERTICAL,
                spacing: 0,
                chat_id: chat_id
            );
            this.window = window;
            this.rpc = rpc;
            this.settings = settings;
            this.chat_kind = chat_kind;
            this.chat_kind_loaded = chat_kind != ChatKind.UNKNOWN;
            hexpand = true;
            vexpand = true;
            halign = Gtk.Align.FILL;
            valign = Gtk.Align.FILL;

            /* Marker for the custom-background rules (see
               Application.apply_background): when a custom window background
               is active, the message area is made transparent so the chosen
               color/gradient shows behind the messages in every chat. */
            add_css_class ("conversation-view");

            message_store = new GLib.ListStore (typeof (Message));
            pinned = new PinnedMessagesManager (message_store, settings);
            pinned.set_rpc (rpc);
            pinned.scroll_requested.connect ((mid) => { scroll_to_message (mid); });

            build_ui ();

            msg_actions = new MessageActions (window, rpc, message_store,
                                              pinned, compose_bar, settings);
            msg_actions.select_requested.connect ((mid) => {
                begin_selection_mode (mid);
            });
        }

        private void build_ui () {
            message_scroll = new Gtk.ScrolledWindow ();
            message_scroll.hexpand = true;
            message_scroll.vexpand = true;
            message_scroll.halign = Gtk.Align.FILL;
            message_scroll.valign = Gtk.Align.FILL;
            message_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            message_scroll.vadjustment.notify["upper"].connect (on_scroll_bounds_changed);
            message_scroll.vadjustment.notify["page-size"].connect (on_scroll_bounds_changed);
            message_scroll.vadjustment.notify["value"].connect (() => {
                if (loading_chat) return;
                if (GLib.get_monotonic_time () < scroll_freeze_until_us) return;
                stick_to_bottom = is_near_bottom ();
                scroll_down_btn.visible = !stick_to_bottom;
                if (is_near_top () && !loading_more && loaded_start_index > 0) {
                    load_earlier_messages.begin ();
                }
            });

            message_filter = new Gtk.CustomFilter ((item) => {
                if (!message_search_revealer.reveal_child) return true;
                string query = message_search_entry.text.strip ().down ();
                if (query.length == 0) return true;
                var msg = (Message) item;
                return msg.text != null && msg.text.down ().contains (query);
            });
            filtered_message_store = new Gtk.FilterListModel (message_store, message_filter);

            var factory = new Gtk.SignalListItemFactory ();
            factory.bind.connect ((obj) => {
                var li = (Gtk.ListItem) obj;
                var msg = (Message) li.item;
                Message? prev = null;
                uint pos = li.position;
                if (pos > 0) {
                    prev = (Message) filtered_message_store.get_item (pos - 1);
                }

                bool is_img_continuation;
                var trailing = collect_trailing_irc_images (
                    msg, prev, pos, out is_img_continuation);

                var row = new MessageRow (
                    msg, prev, trailing, is_img_continuation,
                    settings.bubble_avatar_display,
                    bubble_avatars_apply_to_this_chat ());
                row.selection_toggled.connect ((mid, active) => {
                    update_selection_actions ();
                });
                row.quote_clicked.connect ((qid) => { scroll_to_message (qid); });
                row.full_message_requested.connect ((mid) => {
                    load_full_message.begin (mid);
                });
                if (msg.highlighted) {
                    msg.highlighted = false;
                    row.highlight ();
                }
                li.child = row;
                /* Non-focusable rows: else a focused item gets re-scrolled into
                   view when a popover closes, jerking the chat to the top. */
                li.selectable = false;
                li.activatable = false;
                li.focusable = false;
            });

            var selection = new Gtk.NoSelection (filtered_message_store);
            message_listview = new Gtk.ListView (selection, factory);
            message_listview.hexpand = true;
            message_listview.vexpand = true;
            message_listview.halign = Gtk.Align.FILL;
            message_listview.valign = Gtk.Align.FILL;
            message_listview.add_css_class ("boxed-list-separate");

            var message_key = new Gtk.EventControllerKey ();
            message_key.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            message_key.key_pressed.connect ((keyval, keycode, state) => {
                if (!is_context_menu_trigger (message_key, keyval, state)) {
                    return false;
                }
                return show_focused_message_context_menu ();
            });
            message_listview.add_controller (message_key);

            /* One gesture pair on the listview, not per-row: a per-row
               left-click controller competes with the label's link gesture
               and breaks URL clicks. */
            var rc = new Gtk.GestureClick ();
            rc.button = 3;
            rc.pressed.connect ((n, x, y) => {
                var row = pick_message_row (x, y);
                if (row != null)
                    msg_actions.show_context_menu (row.message_id,
                        row.is_outgoing, x, y, message_listview);
            });
            message_listview.add_controller (rc);

            var dc = new Gtk.GestureClick ();
            dc.button = 1;
            /* Run in the capture phase: the listview's own click handling
               claims double-click presses before they bubble up, so a
               bubble-phase gesture never sees the second press of a real
               double click. Capturing lets us observe every press first.
               Keep the row action timing separate from the standard
               multi-press text selection count. */
            dc.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            int dc_last_id = -1;
            int64 dc_last_time = 0;
            dc.pressed.connect ((n, x, y) => {
                var row = pick_message_row (x, y);
                if (row == null) return;
                if (selection_mode) {
                    dc_last_id = -1;
                    dc_last_time = 0;
                    return;
                }
                bool text_selection_area = pointer_on_selectable_text (x, y) ||
                    (row.has_selectable_text () &&
                        pointer_on_message_bubble (x, y));
                if (n >= 3 && text_selection_area && row.select_all_text ()) {
                    dc.set_state (Gtk.EventSequenceState.CLAIMED);
                    dc_last_id = -1;
                    dc_last_time = 0;
                    return;
                }
                /* Let selectable message text own multi-click selection. */
                if (text_selection_area || pointer_on_audio (x, y)) {
                    dc_last_id = -1;
                    dc_last_time = 0;
                    return;
                }
                hold_scroll_on_focus_shift ();
                int64 now = get_monotonic_time () / 1000;
                int dct = 400;
                var gs = Gtk.Settings.get_default ();
                if (gs != null) dct = gs.gtk_double_click_time;
                if (row.message_id == dc_last_id && now - dc_last_time <= dct) {
                    dc_last_id = -1;
                    dc_last_time = 0;
                    msg_actions.handle_double_click (row.message_id,
                        row.is_outgoing, x, y, message_listview);
                } else {
                    dc_last_id = row.message_id;
                    dc_last_time = now;
                    var msg = find_message (message_store, row.message_id);
                    if (msg != null &&
                        should_activate_message_at_pointer (
                            msg, pointer_on_visual_media (x, y))) {
                        on_message_activated (msg);
                    }
                }
            });
            message_listview.add_controller (dc);

            message_scroll.child = message_listview;

            message_search_entry = new Gtk.SearchEntry ();
            message_search_entry.placeholder_text = "Search in conversation\u2026";
            message_search_entry.hexpand = true;
            message_search_entry.margin_start = 8;
            message_search_entry.margin_end = 8;
            message_search_entry.margin_top = 4;
            message_search_entry.margin_bottom = 4;
            message_search_entry.search_changed.connect (() => {
                message_filter.changed (Gtk.FilterChange.DIFFERENT);
            });
            message_search_revealer = new Gtk.Revealer ();
            message_search_revealer.child = message_search_entry;
            message_search_revealer.reveal_child = false;
            message_search_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;

            append (message_search_revealer);
            append (pinned.revealer);

            scroll_down_btn = new Gtk.Button ();
            scroll_down_btn.icon_name = "go-down-symbolic";
            scroll_down_btn.add_css_class ("circular");
            scroll_down_btn.add_css_class ("osd");
            scroll_down_btn.add_css_class ("scroll-down-btn");
            scroll_down_btn.halign = Gtk.Align.CENTER;
            scroll_down_btn.valign = Gtk.Align.END;
            scroll_down_btn.margin_bottom = 12;
            scroll_down_btn.visible = false;
            scroll_down_btn.clicked.connect (() => { scroll_to_bottom (); });

            /* "Loading…" pill shown at the top while older messages are
               pulled from the JSON-RPC server (see load_earlier_messages). */
            var loading_pill = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            loading_pill.add_css_class ("osd");
            loading_pill.add_css_class ("loading-pill");
            loading_more_spinner = new Gtk.Spinner ();
            loading_pill.append (loading_more_spinner);
            loading_pill.append (new Gtk.Label ("Loading…"));

            loading_more_revealer = new Gtk.Revealer ();
            loading_more_revealer.child = loading_pill;
            loading_more_revealer.reveal_child = false;
            loading_more_revealer.transition_type = Gtk.RevealerTransitionType.CROSSFADE;
            loading_more_revealer.halign = Gtk.Align.CENTER;
            loading_more_revealer.valign = Gtk.Align.START;
            loading_more_revealer.margin_top = 12;
            /* Non-interactive so it never intercepts scroll/clicks on the
               messages underneath it. */
            loading_more_revealer.can_target = false;

            var scroll_overlay = new Gtk.Overlay ();
            scroll_overlay.child = message_scroll;
            scroll_overlay.hexpand = true;
            scroll_overlay.vexpand = true;
            scroll_overlay.halign = Gtk.Align.FILL;
            scroll_overlay.valign = Gtk.Align.FILL;
            scroll_overlay.add_overlay (scroll_down_btn);
            scroll_overlay.add_overlay (loading_more_revealer);
            append (scroll_overlay);

            compose_bar = new ComposeBar ();
            compose_bar.hexpand = true;
            compose_bar.halign = Gtk.Align.FILL;
            settings.bind_property ("shift-enter-sends", compose_bar,
                                    "shift-enter-sends", BindingFlags.SYNC_CREATE);
            compose_bar.send_message.connect (on_send_message);
            compose_bar.edit_message.connect ((msg_id, new_text) => {
                msg_actions.edit_message.begin (msg_id, new_text);
            });
            compose_bar.edit_last_requested.connect (() => {
                msg_actions.start_editing_last ();
            });
            append (compose_bar);

            selection_bar = build_selection_bar ();
            append (selection_bar);

            /* For contact-request chats the compose bar is hidden and this
               Accept/Block bar takes its place until the request is resolved
               (see set_contact_request / accept_request / block_request). */
            request_bar = build_request_bar ();
            append (request_bar);

            install_file_drop_target ();
        }

        private void on_scroll_bounds_changed () {
            if (loading_chat) return;
            maybe_autoscroll ();
            scroll_down_btn.visible = !is_near_bottom ();
        }

        private GLib.GenericArray<Message>? collect_trailing_irc_images (
                Message msg, Message? prev, uint pos, out bool is_continuation) {
            is_continuation = false;
            if (settings.message_style != MessageStyle.IRC || !msg.is_image_only) return null;
            if (prev != null && prev.is_image_only && MessageRow.same_irc_sender (prev, msg)) {
                is_continuation = true;
                return null;
            }

            var trailing = new GLib.GenericArray<Message> ();
            for (uint i = pos + 1, n = filtered_message_store.get_n_items ();
                    i < n && trailing.length < 5; i++) {
                var next = (Message) filtered_message_store.get_item (i);
                if (next == null || !next.is_image_only ||
                    !MessageRow.same_irc_sender (msg, next)) break;
                trailing.add (next);
            }
            return trailing;
        }

        private Gtk.Box build_selection_bar () {
            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            bar.add_css_class ("selection-action-bar");
            bar.margin_start = 8;
            bar.margin_end = 8;
            bar.margin_top = 8;
            bar.margin_bottom = 8;
            bar.halign = Gtk.Align.FILL;
            bar.hexpand = true;
            bar.visible = false;

            selection_delete_btn = new Gtk.Button.with_label ("Delete");
            selection_delete_btn.add_css_class ("destructive-action");
            selection_delete_btn.hexpand = true;
            selection_delete_btn.clicked.connect (() => {
                delete_selected_messages ();
            });
            bar.append (selection_delete_btn);

            selection_forward_btn = new Gtk.Button.with_label ("Forward");
            selection_forward_btn.hexpand = true;
            selection_forward_btn.clicked.connect (() => {
                forward_selected_messages ();
            });
            bar.append (selection_forward_btn);

            var cancel_btn = new Gtk.Button.with_label ("Cancel");
            cancel_btn.hexpand = true;
            cancel_btn.clicked.connect (() => {
                end_selection_mode ();
            });
            bar.append (cancel_btn);

            return bar;
        }

        /* Bottom bar shown instead of the compose box while the chat is an
           unaccepted contact request: a short notice plus Block and Accept
           actions that drive the accept_chat / block_chat JSON-RPC calls. */
        private Gtk.Box build_request_bar () {
            var bar = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            bar.add_css_class ("contact-request-bar");
            bar.margin_start = 8;
            bar.margin_end = 8;
            bar.margin_top = 8;
            bar.margin_bottom = 8;
            bar.visible = false;

            var notice = new Gtk.Label ("This chat is a contact request. "
                + "Accept it to reply, or block the sender.");
            notice.add_css_class ("dim-label");
            notice.wrap = true;
            notice.justify = Gtk.Justification.CENTER;
            notice.halign = Gtk.Align.CENTER;
            bar.append (notice);

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            buttons.halign = Gtk.Align.CENTER;

            var block_btn = new Gtk.Button.with_label ("Block");
            block_btn.add_css_class ("destructive-action");
            block_btn.add_css_class ("pill");
            block_btn.clicked.connect (() => { block_request.begin (); });
            buttons.append (block_btn);

            var accept_btn = new Gtk.Button.with_label ("Accept");
            accept_btn.add_css_class ("suggested-action");
            accept_btn.add_css_class ("pill");
            accept_btn.clicked.connect (() => { accept_request.begin (); });
            buttons.append (accept_btn);

            bar.append (buttons);
            return bar;
        }

        /* Swap the compose box for the Accept/Block bar (or back). Called by
           the window when a chat is opened, and by accept_request once the
           request has been accepted. */
        public void set_contact_request (bool is_request) {
            is_contact_request = is_request;
            sync_bottom_bars ();
        }

        private void sync_bottom_bars () {
            selection_bar.visible = selection_mode;
            request_bar.visible = !selection_mode && is_contact_request;
            compose_bar.visible = !selection_mode && !is_contact_request;
        }

        private void begin_selection_mode (int initial_msg_id) {
            selection_mode = true;
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var msg = (Message) message_store.get_item (i);
                msg.selection_visible = true;
                msg.notify_property ("selection-visible");
                if (msg.id == initial_msg_id) {
                    msg.selected = true;
                    msg.notify_property ("selected");
                }
            }
            sync_bottom_bars ();
            update_selection_actions ();
        }

        private void end_selection_mode () {
            selection_mode = false;
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var msg = (Message) message_store.get_item (i);
                msg.selected = false;
                msg.selection_visible = false;
                msg.notify_property ("selected");
                msg.notify_property ("selection-visible");
            }
            sync_bottom_bars ();
            update_selection_actions ();
        }

        private int selected_message_count () {
            int count = 0;
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var msg = (Message) message_store.get_item (i);
                if (msg.selected) count++;
            }
            return count;
        }

        private int[] selected_message_ids () {
            int[] ids = {};
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var msg = (Message) message_store.get_item (i);
                if (msg.selected) ids += msg.id;
            }
            return ids;
        }

        private bool selected_messages_all_outgoing () {
            bool found = false;
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var msg = (Message) message_store.get_item (i);
                if (!msg.selected) continue;
                found = true;
                if (!msg.is_outgoing) return false;
            }
            return found;
        }

        private void update_selection_actions () {
            if (selection_delete_btn == null || selection_forward_btn == null) {
                return;
            }
            bool has_selection = selected_message_count () > 0;
            selection_delete_btn.sensitive = has_selection;
            selection_forward_btn.sensitive = has_selection;
        }

        private void forward_selected_messages () {
            int[] ids = selected_message_ids ();
            if (ids.length == 0) return;
            msg_actions.start_forwarding_many (ids);
            end_selection_mode ();
        }

        private void delete_selected_messages () {
            int[] ids = selected_message_ids ();
            if (ids.length == 0) return;
            string title = ids.length == 1
                ? "Delete Message?"
                : "Delete Messages?";
            if (selected_messages_all_outgoing ()) {
                string body = ids.length == 1
                    ? "Delete the selected message from your device only, or from all participants? This cannot be undone."
                    : "Delete %d selected messages from your device only, or from all participants? This cannot be undone.".printf (ids.length);
                confirm_delete_options (window, title, body,
                    () => { delete_selected_messages_confirmed.begin (ids, false); },
                    () => { delete_selected_messages_confirmed.begin (ids, true); });
            } else {
                string body = ids.length == 1
                    ? "Delete the selected message from your device? This cannot be undone."
                    : "Delete %d selected messages from your device? This cannot be undone.".printf (ids.length);
                confirm_delete_options (window, title, body,
                    () => { delete_selected_messages_confirmed.begin (ids, false); },
                    null);
            }
        }

        private async void delete_selected_messages_confirmed (int[] ids,
                                                               bool for_all) {
            try {
                if (for_all) {
                    yield rpc.delete_messages_for_all (ids);
                } else {
                    yield rpc.delete_messages (ids);
                }
                for (int i = ids.length - 1; i >= 0; i--) {
                    int idx = find_message_index (message_store, ids[i]);
                    if (idx >= 0) message_store.remove (idx);
                }
                end_selection_mode ();
            } catch (Error e) {
                window.show_toast ("Delete failed: " + e.message);
            }
        }

        public void set_chat_kind (ChatKind kind) {
            if (kind == ChatKind.UNKNOWN) return;
            chat_kind = kind;
            chat_kind_loaded = true;
        }

        private async void accept_request () {
            try {
                yield rpc.accept_chat (chat_id);
                set_contact_request (false);
                compose_bar.grab_entry_focus ();
                window.request_reload_chats ();
            } catch (Error e) {
                window.show_toast ("Failed to accept request: " + e.message);
            }
        }

        private async void block_request () {
            try {
                yield rpc.block_chat (chat_id);
                if (window.current_chat_id == chat_id) {
                    window.clear_chat_view ();
                }
                window.request_reload_chats ();
            } catch (Error e) {
                window.show_toast ("Failed to block request: " + e.message);
            }
        }

        /* ================================================================
         *  Public API (called by Window)
         * ================================================================ */

        public void on_activated (bool focus_compose = true) {
            if (!messages_loaded) {
                messages_loaded = true;
                load_messages.begin ();
            }
            if (focus_compose && !is_contact_request && !selection_mode)
                compose_bar.grab_entry_focus ();
        }

        public void on_reselected () {
            scroll_to_bottom ();
            if (!selection_mode) compose_bar.grab_entry_focus ();
        }

        public void attach_dropped_file_path (string path) {
            attach_local_file (path, Path.get_basename (path));
        }

        public void focus_entry () {
            if (selection_mode) return;
            compose_bar.grab_entry_focus ();
        }

        public bool has_active_compose_mode () {
            return selection_mode || compose_bar.has_active_mode ();
        }

        public bool compose_entry_has_focus () {
            if (selection_mode) return true;
            return compose_bar.entry_has_focus ();
        }

        public void cancel_active_compose_mode () {
            if (selection_mode) {
                end_selection_mode ();
                return;
            }
            compose_bar.cancel_active_mode ();
        }

        public void type_into_entry (string text) {
            if (selection_mode) return;
            compose_bar.type_text (text);
        }

        public async void reload_messages () {
            yield load_messages (true);
        }

        public async void handle_incoming_msg (int msg_id) {
            try {
                var msg = yield rpc.fetch_message (msg_id);
                if (msg == null) return;
                bool is_current = (window.current_chat_id == this.chat_id);
                if (is_current) msg.highlighted = true;
                msg.is_pinned = pinned.is_pinned (msg.id);
                msg.selection_visible = selection_mode;
                insert_message_sorted (msg);
                if (is_current && window.is_active) {
                    yield rpc.mark_seen_msgs (new int[] { msg_id });
                } else if (is_current) {
                    /* On screen but the window is unfocused: defer the seen
                       mark until the user actually looks at the chat. */
                    pending_seen_ids += msg_id;
                }
            } catch (Error e) {
                warning ("handle_incoming_msg: %s", e.message);
            }
        }

        /* Send the deferred seen-marks for messages that arrived while the
           window was unfocused. Called when the user is looking at this chat
           again (window refocused or chat re-entered). */
        public void flush_pending_seen () {
            if (pending_seen_ids.length == 0) return;
            int[] ids = pending_seen_ids;
            pending_seen_ids = {};
            rpc.mark_seen_msgs.begin (ids, (o, res) => {
                try {
                    rpc.mark_seen_msgs.end (res);
                } catch (Error e) {
                    /* non-critical */
                }
            });
        }

        public void toggle_search () {
            if (search_toggling) return;
            search_toggling = true;
            bool was_active = message_search_revealer.reveal_child;
            message_search_revealer.reveal_child = !was_active;
            if (was_active) message_search_entry.text = "";
            Idle.add (() => {
                if (!was_active) message_search_entry.grab_focus ();
                search_toggling = false;
                return Source.REMOVE;
            });
        }

        /**
         * Replace a single message in the store while keeping the visible
         * scroll position unchanged. Used by reaction/edit updates that
         * resize a row but should not jump the viewport.
         */
        public void replace_message (int msg_id, Message new_msg) {
            int idx = find_message_index (message_store, msg_id);
            if (idx < 0) return;
            var old_msg = (Message) message_store.get_item (idx);
            new_msg.is_pinned = old_msg.is_pinned;
            new_msg.selection_visible = old_msg.selection_visible;
            new_msg.selected = old_msg.selected;

            var adj = message_scroll.vadjustment;
            double saved_value = adj.value;
            bool was_at_bottom = is_near_bottom ();
            bool was_loading = loading_chat;
            loading_chat = true;
            freeze_scroll_handler (700);

            Object[] replacements = { new_msg };
            message_store.splice (idx, 1, replacements);

            /* Wait for row height changes to update the scroll range. */
            message_listview.add_tick_callback ((w, clock) => {
                restore_scroll_value (was_at_bottom ? max_scroll_value () : saved_value);
                loading_chat = was_loading;
                stick_to_bottom = was_at_bottom;
                scroll_down_btn.visible = !is_near_bottom ();
                return Source.REMOVE;
            });
        }

        private async void load_full_message (int msg_id) {
            var msg = find_message (message_store, msg_id);
            if (msg == null) return;

            try {
                if (msg.can_download_full_message) {
                    yield rpc.download_full_message (msg_id);
                    yield load_messages (true);
                    return;
                }

                if (msg.has_html) {
                    string? html = yield rpc.get_message_html (msg_id);
                    if (html != null && html.length > 0) {
                        show_full_message_text (msg_id, html_to_text (html));
                        return;
                    }
                }

                window.show_toast ("Full message unavailable");
            } catch (Error e) {
                window.show_toast ("Full message failed: " + e.message);
            }
        }

        private static string html_to_text (string html) {
            string text = html;
            try {
                var hidden = new Regex ("<(head|script|style)\\b[^>]*>.*?</\\1>",
                    RegexCompileFlags.CASELESS | RegexCompileFlags.DOTALL);
                var breaks = new Regex ("<br\\s*/?>", RegexCompileFlags.CASELESS);
                var blocks = new Regex ("</(p|div|section|article|li|tr|h[1-6])>",
                    RegexCompileFlags.CASELESS);
                var tags = new Regex ("<[^>]+>");

                text = hidden.replace (text, -1, 0, "");
                text = breaks.replace (text, -1, 0, "\n");
                text = blocks.replace (text, -1, 0, "\n");
                text = tags.replace (text, -1, 0, "");
            } catch (RegexError e) {
            }
            return decode_basic_html_entities (text).strip ();
        }

        private static string decode_basic_html_entities (string text) {
            return text
                .replace ("&nbsp;", " ")
                .replace ("&quot;", "\"")
                .replace ("&apos;", "'")
                .replace ("&lt;", "<")
                .replace ("&gt;", ">")
                .replace ("&amp;", "&");
        }

        private void show_full_message_text (int msg_id, string full_text) {
            var dialog = new Adw.Dialog ();
            dialog.title = "Message %d".printf (msg_id);
            dialog.content_width = 640;
            dialog.content_height = 520;

            var toolbar = new Adw.ToolbarView ();
            var header = new Adw.HeaderBar ();
            toolbar.add_top_bar (header);

            var scroller = new Gtk.ScrolledWindow ();
            scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroller.vexpand = true;

            var text = new Gtk.TextView ();
            text.editable = false;
            text.cursor_visible = false;
            text.wrap_mode = Gtk.WrapMode.WORD_CHAR;
            text.buffer.text = full_text;
            scroller.child = text;

            toolbar.content = scroller;
            dialog.child = toolbar;
            install_escape_close (dialog);
            dialog.present (window);
        }

        /**
         * Suppress the value-notify handler's "near top / near bottom"
         * recalculation for `ms` milliseconds. Used to silence spurious
         * scroll movements triggered by popovers, focus shifts, or row
         * resizes after a reaction / edit.
         */
        public void freeze_scroll_handler (uint ms) {
            int64 until = GLib.get_monotonic_time () + (int64) ms * 1000;
            if (until > scroll_freeze_until_us) scroll_freeze_until_us = until;
        }

        public double get_scroll_value () {
            return message_scroll.vadjustment.value;
        }

        public void restore_scroll_value (double v) {
            var a = message_scroll.vadjustment;
            v = double.min (v, max_scroll_value ());
            if (Math.fabs (a.value - v) > 0.5) a.value = v;
        }

        /* Re-assert position after GtkListView's focus scroll has run. */
        public void restore_scroll_value_deferred (double v) {
            freeze_scroll_handler (250);
            message_listview.add_tick_callback ((w, clock) => {
                restore_scroll_value (v);
                return Source.REMOVE;
            });
        }

        /* Hold position when a row click would otherwise focus-scroll. */
        private void hold_scroll_on_focus_shift () {
            if (stick_to_bottom) return;
            restore_scroll_value_deferred (message_scroll.vadjustment.value);
        }

        public bool close_search_if_active () {
            if (!message_search_revealer.reveal_child) return false;
            message_search_revealer.reveal_child = false;
            message_search_entry.text = "";
            return true;
        }

        public void scroll_to_message (int msg_id) {
            int pos = find_message_index (filtered_message_store, msg_id);
            if (pos < 0) return;
            var msg = (Message) filtered_message_store.get_item (pos);
            msg.highlighted = true;
            message_listview.scroll_to (pos, Gtk.ListScrollFlags.FOCUS, null);
            stick_to_bottom = is_near_bottom ();
        }

        /* ================================================================
         *  Message loading
         * ================================================================ */

        private async void load_messages (bool preserve_scroll = false) {
            if (rpc.account_id <= 0) return;

            try {
                yield load_chat_kind_if_needed ();

                bool was_near_bottom = stick_to_bottom;
                double previous_scroll_value = 0;
                if (preserve_scroll) {
                    was_near_bottom = is_near_bottom ();
                    previous_scroll_value = message_scroll.vadjustment.value;
                }

                all_msg_ids = yield rpc.get_message_ids_for (
                    rpc.account_id, chat_id);
                if (all_msg_ids == null) return;

                loaded_start_index = all_msg_ids.get_length () > 30
                    ? all_msg_ids.get_length () - 30 : 0;

                var messages = yield fetch_messages_batch (
                    loaded_start_index, all_msg_ids.get_length ());

                pinned.load_for_chat (chat_id);

                loading_chat = true;
                stick_to_bottom = preserve_scroll ? was_near_bottom : true;

                message_store.splice (0, message_store.get_n_items (),
                    pinned_message_batch (messages));
                loading_chat = false;
                if (messages.length > 0) {
                    if (!preserve_scroll || was_near_bottom) {
                        scroll_to_bottom ();
                    } else {
                        Idle.add (() => {
                            restore_scroll_value (previous_scroll_value);
                            stick_to_bottom = false;
                            scroll_down_btn.visible = !is_near_bottom ();
                            return Source.REMOVE;
                        });
                    }
                }

                pinned.update_bar.begin ();
            } catch (Error e) {
                window.show_toast ("Failed to load messages: " + e.message);
            }
        }

        private async void load_chat_kind_if_needed () {
            if (chat_kind_loaded || chat_kind != ChatKind.UNKNOWN) return;
            chat_kind_loaded = true;
            try {
                var chat = yield rpc.get_full_chat_by_id_for (
                    rpc.account_id, chat_id);
                if (chat != null) chat_kind = RpcParsers.parse_chat_kind (chat);
            } catch (Error e) {
                /* Non-critical: unknown chats simply do not match scoped
                   avatar settings until metadata is available. */
            }
        }

        private bool bubble_avatars_apply_to_this_chat () {
            switch (chat_kind) {
            case ChatKind.DIRECT:
                return settings.bubble_avatars_in_direct_chats;
            case ChatKind.GROUP:
                return true;
            default:
                return false;
            }
        }

        private async GLib.GenericArray<Message> fetch_messages_batch (
                uint start, uint end) throws Error {
            uint count = end - start;
            int[] ids = new int[count];
            for (uint i = 0; i < count; i++) {
                ids[i] = (int) all_msg_ids.get_int_element (start + i);
            }
            var map = yield rpc.get_messages_for (rpc.account_id, ids);
            var result = new GLib.GenericArray<Message> ();
            if (map != null) {
                foreach (int mid in ids) {
                    string k = mid.to_string ();
                    if (map.has_member (k)) {
                        result.add (RpcParsers.parse_message (
                            map.get_object_member (k), rpc.self_email));
                    }
                }
            }
            return result;
        }

        private GLib.Object[] pinned_message_batch (GLib.GenericArray<Message> messages) {
            var batch = new GLib.Object[messages.length];
            for (uint i = 0; i < messages.length; i++) {
                messages[i].is_pinned = pinned.is_pinned (messages[i].id);
                messages[i].selection_visible = selection_mode;
                batch[i] = messages[i];
            }
            return batch;
        }

        private async void load_earlier_messages () {
            if (loading_more || all_msg_ids == null || loaded_start_index == 0) return;
            loading_more = true;
            set_loading_more_visible (true);

            uint new_start = loaded_start_index > 100
                ? loaded_start_index - 100 : 0;

            try {
                var messages = yield fetch_messages_batch (new_start, loaded_start_index);

                var adj = message_scroll.vadjustment;
                double old_upper = adj.upper;
                double old_value = adj.value;

                /* One splice avoids a per-row ListView relayout storm. */
                message_store.splice (0, 0, pinned_message_batch (messages));

                loaded_start_index = new_start;

                Idle.add (() => {
                    var a = message_scroll.vadjustment;
                    a.value = old_value + (a.upper - old_upper);
                    loading_more = false;
                    set_loading_more_visible (false);
                    return Source.REMOVE;
                });
            } catch (Error e) {
                loading_more = false;
                set_loading_more_visible (false);
                window.show_toast ("Failed to load earlier messages: " + e.message);
            }
        }

        /* Toggle the top "Loading…" pill while older messages are fetched.
           Spinning is tied to visibility so the animation only runs when shown. */
        private void set_loading_more_visible (bool visible) {
            loading_more_spinner.spinning = visible;
            loading_more_revealer.reveal_child = visible;
        }

        /* ================================================================
         *  Scroll helpers
         * ================================================================ */

        private bool is_near_bottom () {
            var adj = message_scroll.vadjustment;
            if (adj.upper <= adj.page_size) return true;
            return (adj.upper - adj.value - adj.page_size) < 80;
        }

        private bool is_near_top () {
            var adj = message_scroll.vadjustment;
            return adj.value < 80;
        }

        private double max_scroll_value () {
            var adj = message_scroll.vadjustment;
            double value = adj.upper - adj.page_size;
            return value > 0 ? value : 0;
        }

        private void maybe_autoscroll () {
            if (!stick_to_bottom) return;
            message_scroll.vadjustment.value = max_scroll_value ();
        }

        public void scroll_to_bottom () {
            stick_to_bottom = true;
            maybe_autoscroll ();
            uint n = filtered_message_store.get_n_items ();
            if (n > 0) {
                message_listview.scroll_to (n - 1, Gtk.ListScrollFlags.NONE, null);
            }
        }

        private void insert_message_sorted (Message msg) {
            int count = (int) message_store.get_n_items ();
            if (count > 0) {
                var last = (Message) message_store.get_item (count - 1);
                if (msg.timestamp > last.timestamp ||
                    (msg.timestamp == last.timestamp && msg.id >= last.id)) {
                    message_store.append (msg);
                    return;
                }
            }
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var m = (Message) message_store.get_item (i);
                if (m.timestamp > msg.timestamp ||
                    (m.timestamp == msg.timestamp && m.id > msg.id)) {
                    message_store.insert ((int) i, msg);
                    return;
                }
            }
            message_store.append (msg);
        }

        /* ================================================================
         *  Sending & attachments
         * ================================================================ */

        private void on_send_message (string text, string? file_path, string? file_name, int quote_msg_id) {
            do_send.begin (text, file_path, file_name, quote_msg_id);
        }

        private async void do_send (string text, string? file_path, string? file_name, int quote_msg_id) {
            try {
                string? send_text = text.length > 0 ? text : null;
                int msg_id = yield rpc.send_msg (chat_id,
                                                  send_text, file_path, file_name,
                                                  quote_msg_id);
                if (msg_id > 0) {
                    var msg = yield rpc.fetch_message (msg_id);
                    if (msg != null) {
                        msg.selection_visible = selection_mode;
                        insert_message_sorted (msg);
                        scroll_to_bottom ();
                    }
                }
            } catch (Error e) {
                window.show_toast ("Send failed: " + e.message);
            }
        }

        private bool can_accept_file_attachment () {
            return !selection_mode && !is_contact_request &&
                compose_bar.can_accept_attachment ();
        }

        private void attach_local_file (string path, string name) {
            if (!can_accept_file_attachment ()) {
                window.show_toast ("Attach failed: cannot attach here");
                return;
            }
            if (path.strip ().length == 0 ||
                !GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) {
                window.show_toast ("Attach failed: file not found");
                return;
            }
            compose_bar.set_pending_attachment (path, name);
            compose_bar.grab_entry_focus ();
        }

        private void install_file_drop_target () {
            file_drop_target = new FileDropTarget (this);
            file_drop_target.accept.connect (can_accept_file_attachment);
            file_drop_target.dropped.connect (attach_local_file);
            file_drop_target.failed.connect ((message) => {
                window.show_toast ("Attach failed: " + message);
            });
        }

        private MessageRow? pick_message_row (double x, double y) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                w = w.get_parent ();
            }
            return w as MessageRow;
        }

        private MessageRow? find_message_row_descendant (Gtk.Widget? widget) {
            if (widget == null || widget == message_listview) return null;
            var row = widget as MessageRow;
            if (row != null) return row;

            for (Gtk.Widget? child = widget.get_first_child ();
                    child != null;
                    child = child.get_next_sibling ()) {
                row = find_message_row_descendant (child);
                if (row != null) return row;
            }
            return null;
        }

        private MessageRow? focused_message_row () {
            for (var w = window.focus_widget; w != null; w = w.get_parent ()) {
                var row = w as MessageRow;
                if (row != null) return row;
                row = find_message_row_descendant (w);
                if (row != null) return row;
                if (w == message_listview) break;
            }
            return null;
        }

        private MessageRow? fallback_visible_message_row () {
            double x = message_listview.get_width () / 2.0;
            double[] ys = {
                message_listview.get_height () / 2.0,
                24.0,
                double.max (24.0, message_listview.get_height () - 24.0)
            };
            foreach (double y in ys) {
                var row = pick_message_row (x, y);
                if (row != null) return row;
            }
            return null;
        }

        private bool show_focused_message_context_menu () {
            var row = focused_message_row ();
            if (row == null) row = fallback_visible_message_row ();
            if (row == null) return false;

            double x;
            double y;
            Graphene.Rect bounds;
            if (row.compute_bounds (message_listview, out bounds)) {
                x = bounds.get_x () + bounds.get_width () / 2.0;
                y = bounds.get_y () + bounds.get_height () / 2.0;
            } else {
                x = message_listview.get_width () / 2.0;
                y = message_listview.get_height () / 2.0;
            }
            msg_actions.show_context_menu (row.message_id, row.is_outgoing,
                x, y, message_listview);
            return true;
        }

        /* True when the pointer sits over a selectable text label (the
           message body). There the I-beam cursor invites text selection,
           so a double click should select a word rather than fire the
           reply/react action. */
        private bool pointer_on_selectable_text (double x, double y) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                var lbl = w as Gtk.Label;
                if (lbl != null && lbl.selectable) return true;
                w = w.get_parent ();
            }
            return false;
        }

        private bool pointer_on_message_bubble (double x, double y) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            return w != null && w.has_css_class ("message-bubble");
        }

        /* True when the pointer sits over the inline audio player. Its own
           play/stop button drives playback, so the press must reach it rather
           than triggering the row action or arming a double-click reaction. */
        private bool pointer_on_audio (double x, double y) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                if (w is AudioPlayer) return true;
                w = w.get_parent ();
            }
            return false;
        }

        private bool pointer_on_visual_media (double x, double y) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                if (w.has_css_class ("message-image") ||
                    w.has_css_class ("message-video-frame")) {
                    return true;
                }
                w = w.get_parent ();
            }
            return false;
        }

        private bool should_activate_message_at_pointer (
                Message msg, bool pointer_on_media) {
            if (msg.is_image_file () || msg.is_video_file ()) {
                return pointer_on_media;
            }
            return true;
        }

        private void on_message_activated (Message msg) {
            if (!msg.has_file) return;
            if (!msg.has_local_file) {
                window.show_toast ("File not available");
                return;
            }
            if (msg.is_image_file ()) {
                string[] paths;
                int start;
                collect_image_paths (msg.file_path, out paths, out start);
                window.show_image_list (paths, start);
            } else if (msg.is_video_file ()) {
                window.show_video (msg.file_path, msg.file_name);
            } else if (msg.is_audio_file ()) {
                /* Audio plays inline via its own play/pause button. */
            } else {
                window.save_attachment.begin (msg.file_path, msg.file_name);
            }
        }

        private void collect_image_paths (string current_path,
                                          out string[] paths,
                                          out int start_index) {
            var list = new GLib.GenericArray<string> ();
            int found = -1;
            uint n = message_store.get_n_items ();
            for (uint i = 0; i < n; i++) {
                var m = (Message) message_store.get_item (i);
                if (m == null) continue;
                if (!m.has_local_file || !m.is_image_file ()) continue;
                if (m.file_path == current_path) found = (int) list.length;
                list.add (m.file_path);
            }
            paths = list.steal ();
            start_index = found >= 0 ? found : 0;
        }
    }
}
