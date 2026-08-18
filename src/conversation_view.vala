namespace Dc {

    private class PendingSend : Object {
        public string text;
        public string? file_path;
        public string? file_name;
        public int quote_msg_id;
        public bool voice;
        /* Delete file_path once the send RPC returns. False for a voice draft
           restored from the blob directory, which the message keeps using. */
        public bool owns_file;

        public PendingSend (string text, string? file_path,
                            string? file_name, int quote_msg_id,
                            bool voice = false, bool owns_file = false) {
            this.text = text;
            this.file_path = file_path;
            this.file_name = file_name;
            this.quote_msg_id = quote_msg_id;
            this.voice = voice;
            this.owns_file = owns_file;
        }
    }

    /* Signal closures connected to widgets owned by a ConversationView can
       otherwise form view -> widget -> closure -> view reference cycles.
       Keep their ids together so close() can break every cycle explicitly. */
    private class ConversationSignalHandler : Object {
        private GLib.Object? source;
        private ulong handler_id;

        public ConversationSignalHandler (GLib.Object source,
                                          ulong handler_id) {
            this.source = source;
            this.handler_id = handler_id;
        }

        public void disconnect_handler () {
            if (source != null && handler_id != 0 &&
                    SignalHandler.is_connected (source, handler_id)) {
                source.disconnect (handler_id);
            }
            handler_id = 0;
            source = null;
        }
    }

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
        private LinkPreviewFetcher? link_preview_fetcher = null;
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
        private Gtk.Label loading_pill_label;
        private Gtk.Revealer loading_more_revealer;
        private Gtk.Spinner loading_more_spinner;
        private Gtk.Revealer message_search_revealer;
        private Gtk.SearchEntry message_search_entry;
        private bool search_toggling;
        private FileDropTarget? file_drop_target;
        private ConversationMediaBar media_bar;
        private ulong playback_message_handler = 0;
        private ulong playback_finished_handler = 0;
        private GenericArray<ConversationSignalHandler> signal_handlers =
            new GenericArray<ConversationSignalHandler> ();
        private uint[] tick_callback_ids = {};
        private bool closed = false;

        /* Exactly one owner of the vertical position at any time:
           BOTTOM follows the newest message, ANCHOR pins one row while a
           jump or history prepend settles (enforced by the tick loop in
           anchor_message), FREE means the user owns the viewport and
           nothing may correct it. Historically stick-to-bottom, the
           prepend anchor and the jump hold each wrote to the adjustment
           independently; two of them active at once bounced the viewport
           until both gave up. */
        private enum ViewportGoal { FREE, BOTTOM, ANCHOR }
        private ViewportGoal goal = ViewportGoal.BOTTOM;
        /* Bumped on every anchor handoff; stale anchor loops see a
           mismatch and stop. */
        private uint goal_generation = 0;
        private int[] pending_seen_ids = {};
        private Json.Array? all_msg_ids = null;
        private uint loaded_start_index = 0;
        private bool loading_more = false;
        private int pending_scroll_message_id = 0;
        private int pending_voice_direction = 0;
        private bool loading_chat = false;
        private bool messages_loaded = false;
        private bool messages_stale = false;
        private bool draft_loaded = false;
        private bool draft_rpc_available = true;
        private uint draft_save_timer = 0;
        private bool draft_save_pending = false;
        private string pending_draft_text = "";
        private string? pending_draft_file_path = null;
        private string? pending_draft_file_name = null;
        private int pending_draft_quote_msg_id = 0;
        private bool pending_draft_voice = false;

        private enum DraftSaveResult {
            UNAVAILABLE,
            FAILED,
            SAVED
        }

        private int64 scroll_freeze_until_us = 0;
        private Queue<PendingSend> send_queue = new Queue<PendingSend> ();
        private bool sending_queue = false;

        private PinnedMessagesManager pinned;
        private WebxdcAppsBar webxdc_bar;
        private MessageActions msg_actions;

        /* Roster of chat members for mention rendering + composer autocomplete.
           Built lazily for group chats; null for direct chats. */
        private MentionRoster? mention_roster = null;
        /* Contact metadata used by reaction popovers. Unlike mentions, this is
           useful in both direct and group chats. */
        private MentionRoster? reaction_roster = null;
        private bool roster_loaded = false;

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
            track_signal (pinned, pinned.scroll_requested.connect ((mid) => {
                scroll_to_message (mid);
            }));
            track_signal (pinned, pinned.operation_failed.connect ((message) => {
                window.show_toast (message);
            }));

            webxdc_bar = new WebxdcAppsBar ();
            webxdc_bar.set_rpc (rpc);
            webxdc_bar.set_pinned (pinned);
            track_signal (webxdc_bar, webxdc_bar.scroll_requested.connect ((mid) => {
                scroll_to_message (mid);
            }));
            track_signal (webxdc_bar, webxdc_bar.forward_requested.connect ((mid) => {
                msg_actions.start_forwarding (mid);
            }));
            track_signal (webxdc_bar, webxdc_bar.save_requested.connect ((mid) => {
                save_webxdc_from_bar.begin (mid);
            }));

            media_bar = new ConversationMediaBar ();
            track_signal (media_bar, media_bar.previous_requested.connect (() => {
                window.navigate_voice_playback (-1);
            }));
            track_signal (media_bar, media_bar.next_requested.connect (() => {
                window.navigate_voice_playback (1);
            }));
            track_signal (media_bar, media_bar.message_requested.connect (
                    (acct_id, origin_chat_id, mid) => {
                window.open_media_message.begin (
                    acct_id, origin_chat_id, mid);
            }));

            var playback = AudioPlayback.shared ();
            playback_message_handler = connect_playback_updates (playback, this);
            playback_finished_handler = connect_playback_finished (playback, this);

            build_ui ();

            msg_actions = new MessageActions (window, rpc, message_store,
                                              pinned, compose_bar, settings);
            msg_actions.set_reaction_roster (reaction_roster);
            track_signal (msg_actions, msg_actions.select_requested.connect ((mid) => {
                begin_selection_mode (mid);
            }));
        }

        private void track_signal (GLib.Object source, ulong handler_id) {
            signal_handlers.add (
                new ConversationSignalHandler (source, handler_id));
        }

        /* Tick callbacks are registered directly on message_listview and
           only their ids are tracked here (storing an owned delegate makes
           valac emit code clang rejects under -Werror=unused-value).  Every
           callback must bail out with end_tick_callback() when the view is
           closed and use it instead of a bare Source.REMOVE so the id list
           stays in sync. */
        private void track_tick_callback (uint callback_id) {
            tick_callback_ids += callback_id;
        }

        private bool end_tick_callback (uint callback_id) {
            forget_tick_callback (callback_id);
            return Source.REMOVE;
        }

        private void forget_tick_callback (uint callback_id) {
            uint[] remaining = {};
            foreach (uint id in tick_callback_ids) {
                if (id != callback_id) remaining += id;
            }
            tick_callback_ids = remaining;
        }

        private static ulong connect_playback_updates (
                AudioPlayback playback, ConversationView target) {
            WeakRef view_ref = WeakRef (target);
            return playback.notify["current-item"].connect (() => {
                var view = view_ref.get () as ConversationView;
                if (view != null && !view.closed)
                    view.update_conversation_media_bar ();
            });
        }

        private static ulong connect_playback_finished (
                AudioPlayback playback, ConversationView target) {
            WeakRef view_ref = WeakRef (target);
            return playback.finished.connect ((mid) => {
                var view = view_ref.get () as ConversationView;
                if (view == null || view.closed) return;
                var item = AudioPlayback.shared ().current_item;
                if (item != null && item.account_id == view.rpc.account_id
                        && item.chat_id == view.chat_id
                        && item.message_id == mid) {
                    view.queue_next_voice_message (mid);
                }
            });
        }

        private void build_ui () {
            message_scroll = new Gtk.ScrolledWindow ();
            message_scroll.hexpand = true;
            message_scroll.vexpand = true;
            message_scroll.halign = Gtk.Align.FILL;
            message_scroll.valign = Gtk.Align.FILL;
            message_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            var adjustment = message_scroll.vadjustment;
            track_signal (adjustment,
                adjustment.notify["upper"].connect (on_scroll_bounds_changed));
            track_signal (adjustment,
                adjustment.notify["page-size"].connect (on_scroll_bounds_changed));
            track_signal (adjustment, adjustment.notify["value"].connect (() => {
                if (loading_chat) return;
                if (GLib.get_monotonic_time () < scroll_freeze_until_us) return;
                /* While a row is anchored the engine owns the viewport:
                   value changes are its own corrections plus ListView
                   estimation churn, never user intent (real input cancels
                   the anchor through the controllers below). */
                if (goal == ViewportGoal.ANCHOR) {
                    update_date_pill ();
                    return;
                }
                goal = is_near_bottom ()
                    ? ViewportGoal.BOTTOM : ViewportGoal.FREE;
                scroll_down_btn.visible = goal != ViewportGoal.BOTTOM;
                update_date_pill ();
                if (is_near_top () && !loading_more && loaded_start_index > 0) {
                    load_earlier_messages.begin ();
                }
            }));

            /* Real user input outranks every programmatic scroll: wheel or
               touchpad over the list and any press on the scrollbar cancel
               an active anchor and a still-loading jump on the spot.
               BOTTOM needs no cancelling — the value handler above already
               re-evaluates it as the user moves. */
            var wheel = new Gtk.EventControllerScroll (
                Gtk.EventControllerScrollFlags.BOTH_AXES);
            wheel.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            track_signal (wheel, wheel.scroll.connect ((dx, dy) => {
                on_user_scroll_input ();
                return false;
            }));
            message_scroll.add_controller (wheel);

            var scrollbar_press = new Gtk.GestureClick ();
            scrollbar_press.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            track_signal (scrollbar_press, scrollbar_press.pressed.connect ((n, x, y) => {
                on_user_scroll_input ();
            }));
            message_scroll.get_vscrollbar ().add_controller (scrollbar_press);

            message_filter = create_message_filter (this);
            filtered_message_store = new Gtk.FilterListModel (message_store, message_filter);

            var factory = new Gtk.SignalListItemFactory ();
            track_signal (factory, factory.bind.connect ((obj) => {
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

                /* Wrap the row in a vertical box so we can prepend a date
                   separator when the day changes. */
                var container = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

                /* Date separator: show when the day differs from the
                   previous message (or for the very first message). */
                if (prev == null || !MessageRow.same_day (msg.timestamp, prev.timestamp)) {
                    container.append (MessageRow.build_date_separator (msg.timestamp));
                }

                /* While search narrows the list, adjacent rows are not
                   adjacent messages — disable sender-grouping then. */
                var row = new MessageRow (
                    msg, search_filter_active () ? null : prev,
                    trailing, is_img_continuation,
                    settings.bubble_avatar_display,
                    bubble_avatars_apply_to_this_chat (),
                    chat_kind != ChatKind.DIRECT,
                    mention_roster,
                    reaction_roster,
                    rpc.account_id);
                Signal.connect_object (row, "selection-toggled",
                    (Callback) on_row_selection_toggled,
                    this, (ConnectFlags) 0);
                Signal.connect_object (row, "quote-clicked",
                    (Callback) on_row_quote_clicked,
                    this, (ConnectFlags) 0);
                Signal.connect_object (row, "action-requested",
                    (Callback) on_message_row_action_requested,
                    this, (ConnectFlags) 0);
                Signal.connect_object (row, "full-message-requested",
                    (Callback) on_row_full_message_requested,
                    this, (ConnectFlags) 0);
                Signal.connect_object (row, "full-message-view-requested",
                    (Callback) on_row_full_message_view_requested,
                    this, (ConnectFlags) 0);
                Signal.connect_object (row, "checkbox-toggle-requested",
                    (Callback) on_row_checkbox_toggle_requested,
                    this, (ConnectFlags) 0);
                if (msg.highlighted) {
                    msg.highlighted = false;
                    row.highlight ();
                }
                container.append (row);
                li.child = container;
                /* Non-focusable rows: else a focused item gets re-scrolled into
                   view when a popover closes, jerking the chat to the top. */
                li.selectable = false;
                li.activatable = false;
                li.focusable = false;
            }));
            /* bind builds a fresh row tree; drop it as soon as the list item
               is recycled so widgets, textures, and messages can finalize. */
            factory.unbind.connect (unbind_message_list_item);

            var selection = new Gtk.NoSelection (filtered_message_store);
            message_listview = new Gtk.ListView (selection, factory);
            message_listview.hexpand = true;
            message_listview.vexpand = true;
            message_listview.halign = Gtk.Align.FILL;
            message_listview.valign = Gtk.Align.FILL;
            message_listview.add_css_class ("boxed-list-separate");
            /* Workspace rows are flush, full-width lines: give the list some
               air above the compose bar so the last message never looks
               clipped. Bubbles/IRC carry their own spacing already. */
            if (settings.message_style == MessageStyle.WORKSPACE) {
                message_listview.margin_bottom = 10;
            }

            /* One gesture pair on the listview, not per-row: a per-row
               left-click controller competes with the label's link gesture
               and breaks URL clicks. */
            var rc = new Gtk.GestureClick ();
            rc.button = 3;
            track_signal (rc, rc.pressed.connect ((n, x, y) => {
                var row = pick_message_row (x, y);
                if (row != null)
                    msg_actions.show_context_menu (row.message_id,
                        row.is_outgoing, x, y, message_listview);
            }));
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
            track_signal (dc, dc.pressed.connect ((n, x, y) => {
                var row = pick_message_row (x, y);
                if (row == null) return;
                if (selection_mode) {
                    dc_last_id = -1;
                    dc_last_time = 0;
                    return;
                }
                /* These are real buttons, not message-row activation areas.
                   Deny the capture gesture for this pointer sequence so the
                   first click reaches the button unambiguously. */
                if (pointer_on_css (x, y, { "message-full-text-button",
                                            "webxdc-card" })) {
                    dc.set_state (Gtk.EventSequenceState.DENIED);
                    dc_last_id = -1;
                    dc_last_time = 0;
                    return;
                }
                /* Presses on interactive bits (reaction badges, task
                   checkboxes, the hover action bar) belong to them. */
                if (pointer_on_css (x, y, { "reaction-badge",
                                            "markdown-task-toggle",
                                            "message-actions-bar" })) {
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
                            msg, pointer_on_css (x, y, { "message-image",
                                                         "message-video-frame" }))) {
                        on_message_activated (msg);
                    }
                }
            }));
            message_listview.add_controller (dc);

            message_scroll.child = message_listview;

            message_search_entry = new Gtk.SearchEntry ();
            message_search_entry.placeholder_text = "Search in conversation\u2026";
            message_search_entry.hexpand = true;
            message_search_entry.margin_start = 8;
            message_search_entry.margin_end = 8;
            message_search_entry.margin_top = 4;
            message_search_entry.margin_bottom = 4;
            track_signal (message_search_entry,
                message_search_entry.search_changed.connect (() => {
                message_filter.changed (Gtk.FilterChange.DIFFERENT);
            }));
            message_search_revealer = new Gtk.Revealer ();
            message_search_revealer.child = message_search_entry;
            message_search_revealer.reveal_child = false;
            message_search_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;

            append (message_search_revealer);
            append (media_bar);
            append (pinned.revealer);
            append (webxdc_bar.revealer);

            scroll_down_btn = new Gtk.Button ();
            scroll_down_btn.icon_name = "go-down-symbolic";
            scroll_down_btn.add_css_class ("circular");
            scroll_down_btn.add_css_class ("osd");
            scroll_down_btn.add_css_class ("scroll-down-btn");
            scroll_down_btn.halign = Gtk.Align.CENTER;
            scroll_down_btn.valign = Gtk.Align.END;
            scroll_down_btn.margin_bottom = 12;
            scroll_down_btn.visible = false;
            track_signal (scroll_down_btn, scroll_down_btn.clicked.connect (() => {
                scroll_to_bottom ();
            }));

            /* "Loading…" pill shown at the top while older messages are
               pulled from the JSON-RPC server (see load_earlier_messages).
               Reused as the floating date pill when scrolled away from
               the bottom. */
            var loading_pill = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            loading_pill.add_css_class ("osd");
            loading_pill.add_css_class ("loading-pill");
            loading_more_spinner = new Gtk.Spinner ();
            loading_pill.append (loading_more_spinner);
            loading_pill_label = new Gtk.Label ("Loading…");
            loading_pill.append (loading_pill_label);

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
            settings.bind_property ("clean-pasted-links", compose_bar,
                                    "clean-pasted-links", BindingFlags.SYNC_CREATE);
            settings.bind_property ("link-previews", compose_bar,
                                    "link-previews", BindingFlags.SYNC_CREATE);
            track_signal (compose_bar, compose_bar.link_previews_requested.connect (
                on_link_previews_requested));
            track_signal (compose_bar, compose_bar.send_message.connect (
                on_send_message));
            track_signal (compose_bar, compose_bar.send_voice_message.connect (
                on_send_voice_message));
            track_signal (compose_bar, compose_bar.draft_changed.connect (
                on_draft_changed));
            track_signal (compose_bar, compose_bar.edit_message.connect (
                    (msg_id, new_text) => {
                msg_actions.edit_message.begin (msg_id, new_text);
            }));
            track_signal (compose_bar, compose_bar.edit_last_requested.connect (() => {
                msg_actions.start_editing_last ();
            }));
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

        private static void on_message_row_action_requested (
                MessageRow row, string action, Gtk.Widget anchor,
                ConversationView view) {
            if (view.closed) return;
            view.on_row_action (row.message_id, row.is_outgoing,
                                action, anchor);
        }

        private static void on_row_selection_toggled (
                MessageRow row, int msg_id, bool active,
                ConversationView view) {
            if (!view.closed) view.update_selection_actions ();
        }

        private static void on_row_quote_clicked (
                MessageRow row, int quote_id, ConversationView view) {
            if (!view.closed) view.scroll_to_message (quote_id);
        }

        private static void on_row_full_message_requested (
                MessageRow row, int msg_id, ConversationView view) {
            if (!view.closed) view.toggle_full_message.begin (msg_id);
        }

        private static void on_row_full_message_view_requested (
                MessageRow row, int msg_id, ConversationView view) {
            if (!view.closed) view.view_full_message.begin (msg_id);
        }

        private static void on_row_checkbox_toggle_requested (
                MessageRow row, int msg_id, string new_text,
                ConversationView view) {
            if (!view.closed)
                view.msg_actions.edit_message.begin (msg_id, new_text);
        }

        private static Gtk.CustomFilter create_message_filter (
                ConversationView target) {
            WeakRef view_ref = WeakRef (target);
            return new Gtk.CustomFilter ((item) => {
                var view = view_ref.get () as ConversationView;
                return view == null || view.closed || view.filter_message (item);
            });
        }

        private bool filter_message (GLib.Object item) {
            if (!message_search_revealer.reveal_child) return true;
            string query = message_search_entry.text.strip ().down ();
            if (query.length == 0) return true;
            var msg = (Message) item;
            return msg.text != null && msg.text.down ().contains (query);
        }

        private static void unbind_message_list_item (Object obj) {
            var item = (Gtk.ListItem) obj;
            item.child = null;
        }

        private void queue_next_voice_message (int current_msg_id) {
            var playback = AudioPlayback.shared ();
            var current_item = playback.current_item;
            if (current_item == null
                    || current_item.message_id != current_msg_id) return;
            var next = find_adjacent_voice_message (current_msg_id, 1);
            if (next == null) return;
            Idle.add (() => {
                if (!playback.playing && playback.current_item == current_item)
                    playback.play_message (next, rpc.account_id);
                return Source.REMOVE;
            });
        }

        private Message? find_adjacent_voice_message (int current_msg_id,
                                                       int direction) {
            int current = find_message_index (message_store, current_msg_id);
            int count = (int) message_store.get_n_items ();
            if (current < 0 || direction == 0) return null;
            for (int i = current + direction;
                    i >= 0 && i < count; i += direction) {
                var msg = (Message) message_store.get_item ((uint) i);
                if (msg.has_local_file && msg.is_audio_file ()) return msg;
            }
            return null;
        }

        public async void play_adjacent_voice_message (int direction) {
            var playback = AudioPlayback.shared ();
            var current_item = playback.current_item;
            if (current_item == null || current_item.account_id != rpc.account_id
                    || current_item.chat_id != chat_id) return;
            var msg = find_adjacent_voice_message (
                current_item.message_id, direction);
            if (msg != null) {
                playback.play_message (msg, rpc.account_id);
                return;
            }
            if (direction >= 0 || loading_more || all_msg_ids == null
                    || loaded_start_index == 0) return;

            int current_id = current_item.message_id;
            double anchor_top;
            var anchor = find_message_row (
                message_listview, 0, out anchor_top);
            int anchor_id = anchor != null ? anchor.message_id : 0;
            loading_more = true;
            set_loading_more_visible (true);
            /* Prepending batches must not trigger bottom-following. */
            if (goal == ViewportGoal.BOTTOM) goal = ViewportGoal.FREE;

            try {
                while (loaded_start_index > 0
                        && playback.current_item == current_item) {
                    uint new_start = loaded_start_index > 100
                        ? loaded_start_index - 100 : 0;
                    var messages = yield fetch_messages_batch (
                        new_start, loaded_start_index);
                    message_store.splice (
                        0, 0, pinned_message_batch (messages));
                    flush_pending_seen ();
                    loaded_start_index = new_start;
                    update_conversation_media_bar ();

                    msg = find_adjacent_voice_message (current_id, -1);
                    if (msg != null) break;
                }

                if (msg != null && playback.current_item == current_item)
                    playback.play_message (msg, rpc.account_id);

                int anchor_pos = anchor_id != 0
                    ? find_message_index (filtered_message_store, anchor_id)
                    : -1;
                if (anchor_pos >= 0) {
                    anchor_message (anchor_id, (uint) anchor_pos, anchor_top);
                }
                finish_loading_earlier ();
            } catch (Error e) {
                finish_loading_earlier (false);
                window.show_toast (
                    "Failed to load previous voice message: " + e.message);
            }
        }

        private void update_conversation_media_bar () {
            var playback = AudioPlayback.shared ();
            var item = playback.current_item;
            if (item == null || item.account_id != rpc.account_id
                    || item.chat_id != chat_id) return;
            int current_id = item.message_id;
            var msg = find_message (message_store, current_id);
            if (msg == null) return;
            playback.set_navigation (
                find_adjacent_voice_message (current_id, -1) != null
                    || loaded_start_index > 0,
                find_adjacent_voice_message (current_id, 1) != null);
        }

        /* Workspace-style hover action bar: dispatch a button press to the
           matching message action. Popovers are anchored to the long-lived
           listview (pointing at the button), not to the button itself: rows
           are rebuilt on every message reload, which would tear down an open
           popover parented to one of their children. */
        private void on_row_action (int msg_id, bool is_outgoing,
                                    string action, Gtk.Widget anchor) {
            if (selection_mode) return;
            double ax = 0, ay = 0;
            Graphene.Rect bounds;
            if (anchor.compute_bounds (message_listview, out bounds)) {
                ax = bounds.origin.x + bounds.size.width / 2;
                ay = bounds.origin.y + bounds.size.height;
            }
            switch (action) {
            case "react":
                msg_actions.show_reaction_menu (msg_id, message_listview,
                                                ax, ay);
                break;
            case "reply":
                msg_actions.start_replying (msg_id);
                break;
            case "forward":
                msg_actions.start_forwarding (msg_id);
                break;
            case "pin":
                pinned.toggle_pin.begin (msg_id);
                break;
            case "webxdc":
                var msg = find_message (message_store, msg_id);
                if (msg != null)
                    window.prompt_webxdc_app.begin (window, rpc, msg);
                break;
            default:
                msg_actions.show_context_menu (msg_id, is_outgoing,
                                               ax, ay, message_listview);
                break;
            }
        }

        private void on_scroll_bounds_changed () {
            if (loading_chat) return;
            maybe_autoscroll ();
            scroll_down_btn.visible = !is_near_bottom ();
            update_date_pill ();
        }

        /** Wheel / scrollbar / touchpad input: the user owns the viewport
            now. Cancel an active anchor and a jump that is still loading
            history; load_until_pending_message notices the cleared ID and
            stops fetching. */
        private void on_user_scroll_input () {
            pending_scroll_message_id = 0;
            pending_voice_direction = 0;
            if (goal == ViewportGoal.ANCHOR) {
                goal_generation++;
                goal = ViewportGoal.FREE;
            }
        }

        private GLib.GenericArray<Message>? collect_trailing_irc_images (
                Message msg, Message? prev, uint pos, out bool is_continuation) {
            is_continuation = false;
            if (settings.message_style != MessageStyle.IRC || !msg.is_image_only) return null;
            if (prev != null && prev.is_image_only && MessageRow.same_sender (prev, msg)) {
                is_continuation = true;
                return null;
            }

            var trailing = new GLib.GenericArray<Message> ();
            for (uint i = pos + 1, n = filtered_message_store.get_n_items ();
                    i < n && trailing.length < 5; i++) {
                var next = (Message) filtered_message_store.get_item (i);
                if (next == null || !next.is_image_only ||
                    !MessageRow.same_sender (msg, next)) break;
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
            track_signal (selection_delete_btn,
                selection_delete_btn.clicked.connect (() => {
                delete_selected_messages.begin ();
            }));
            bar.append (selection_delete_btn);

            selection_forward_btn = new Gtk.Button.with_label ("Forward");
            selection_forward_btn.hexpand = true;
            track_signal (selection_forward_btn,
                selection_forward_btn.clicked.connect (() => {
                forward_selected_messages ();
            }));
            bar.append (selection_forward_btn);

            var cancel_btn = new Gtk.Button.with_label ("Cancel");
            cancel_btn.hexpand = true;
            track_signal (cancel_btn, cancel_btn.clicked.connect (() => {
                end_selection_mode ();
            }));
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
            track_signal (block_btn, block_btn.clicked.connect (() => {
                block_request.begin ();
            }));
            buttons.append (block_btn);

            var accept_btn = new Gtk.Button.with_label ("Accept");
            accept_btn.add_css_class ("suggested-action");
            accept_btn.add_css_class ("pill");
            track_signal (accept_btn, accept_btn.clicked.connect (() => {
                accept_request.begin ();
            }));
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

        private async void delete_selected_messages () {
            int[] ids = selected_message_ids ();
            if (ids.length == 0) return;
            string title = ids.length == 1
                ? "Delete Message?"
                : "Delete Messages?";
            bool all_outgoing = selected_messages_all_outgoing ();
            string body;
            if (all_outgoing) {
                body = ids.length == 1
                    ? "Delete the selected message from your device only, or from all participants? This cannot be undone."
                    : "Delete %d selected messages from your device only, or from all participants? This cannot be undone.".printf (ids.length);
            } else {
                body = ids.length == 1
                    ? "Delete the selected message from your device? This cannot be undone."
                    : "Delete %d selected messages from your device? This cannot be undone.".printf (ids.length);
            }
            var choice = yield confirm_delete_options (
                window, title, body, all_outgoing);
            if (choice == DeleteChoice.FOR_ME)
                delete_selected_messages_confirmed.begin (ids, false);
            else if (choice == DeleteChoice.FOR_EVERYONE)
                delete_selected_messages_confirmed.begin (ids, true);
        }

        private async void delete_selected_messages_confirmed (int[] ids,
                                                               bool for_all) {
            try {
                if (for_all) {
                    yield rpc.delete_messages_for_all (ids);
                } else {
                    yield rpc.delete_messages (ids);
                }
                var playback = AudioPlayback.shared ();
                if (int_array_contains (ids, playback.current_message_id))
                    playback.stop ();
                for (int i = ids.length - 1; i >= 0; i--) {
                    int idx = find_message_index (message_store, ids[i]);
                    if (idx >= 0) message_store.remove (idx);
                }
                update_conversation_media_bar ();
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
            } else if (messages_stale) {
                reload_messages.begin ();
            }
            if (!draft_loaded) {
                draft_loaded = true;
                load_draft.begin ();
            }
            if (focus_compose && !is_contact_request && !selection_mode)
                compose_bar.grab_entry_focus ();
        }

        public void on_reselected (bool focus_compose = true) {
            scroll_to_bottom ();
            if (focus_compose && !selection_mode) compose_bar.grab_entry_focus ();
        }

        public void attach_dropped_file_path (string path) {
            attach_local_file (path, Path.get_basename (path));
        }

        public void attach_dropped_file (string path, string name) {
            attach_local_file (path, name);
        }

        public bool can_accept_dropped_file () {
            return can_accept_file_attachment ();
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

        public void mark_messages_stale () {
            messages_stale = true;
        }

        public async bool handle_incoming_msg (int msg_id) {
            try {
                if (find_message (message_store, msg_id) != null) {
                    if (window.is_chat_visible (this.chat_id)) {
                        yield rpc.mark_seen_msgs (new int[] { msg_id });
                    } else if (window.current_chat_id == this.chat_id) {
                        queue_pending_seen (msg_id);
                    }
                    return true;
                }
                var msg = yield rpc.fetch_message (msg_id);
                if (msg == null) {
                    mark_messages_stale ();
                    return false;
                }
                bool is_current = (window.current_chat_id == this.chat_id);
                if (is_current) msg.highlighted = true;
                msg.selection_visible = selection_mode;
                insert_message_sorted (msg);
                if (window.is_chat_visible (this.chat_id)
                    && should_mark_message_seen (msg)) {
                    yield rpc.mark_seen_msgs (new int[] { msg_id });
                } else if (is_current && should_mark_message_seen (msg)) {
                    /* On screen but the window is unfocused: defer the seen
                       mark until the user actually looks at the chat. */
                    queue_pending_seen (msg_id);
                }
                return true;
            } catch (Error e) {
                warning ("handle_incoming_msg: %s", e.message);
                mark_messages_stale ();
                return false;
            }
        }

        /* Send the deferred seen-marks for messages that arrived while the
           window was unfocused. Called when the user is looking at this chat
           again (window refocused or chat re-entered). */
        public void flush_pending_seen () {
            if (!window.is_chat_visible (chat_id)) return;

            int[] ids = loaded_incoming_message_ids ();
            foreach (int msg_id in pending_seen_ids) {
                if (!int_array_contains (ids, msg_id)) ids += msg_id;
            }
            pending_seen_ids = {};
            send_seen_ids (ids);
        }

        private int[] loaded_incoming_message_ids () {
            int[] ids = {};
            uint n = message_store.get_n_items ();
            for (uint i = 0; i < n; i++) {
                var msg = (Message) message_store.get_item (i);
                if (!should_mark_message_seen (msg)) continue;
                if (!int_array_contains (ids, msg.id)) ids += msg.id;
            }
            return ids;
        }

        private static bool should_mark_message_seen (Message msg) {
            return msg.id > 0 && !msg.is_outgoing && !msg.is_info;
        }

        private void queue_pending_seen (int msg_id) {
            if (msg_id <= 0 || int_array_contains (pending_seen_ids, msg_id))
                return;
            pending_seen_ids += msg_id;
        }

        private static bool int_array_contains (int[] ids, int needle) {
            foreach (int id in ids) {
                if (id == needle) return true;
            }
            return false;
        }

        private void send_seen_ids (int[] ids) {
            if (ids.length == 0) return;
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
            new_msg.selection_visible = old_msg.selection_visible;
            new_msg.selected = old_msg.selected;
            preserve_full_message_state (old_msg, new_msg);

            var adj = message_scroll.vadjustment;
            double saved_value = adj.value;
            bool was_at_bottom = is_near_bottom ();
            bool was_loading = loading_chat;
            loading_chat = true;
            freeze_scroll_handler (700);

            Object[] replacements = { new_msg };
            message_store.splice (idx, 1, replacements);
            update_conversation_media_bar ();

            /* Wait for row height changes to update the scroll range. */
            uint tick_id = 0;
            tick_id = message_listview.add_tick_callback ((w, clock) => {
                if (closed) return end_tick_callback (tick_id);
                restore_scroll_value (was_at_bottom ? max_scroll_value () : saved_value);
                loading_chat = was_loading;
                if (goal != ViewportGoal.ANCHOR) {
                    goal = was_at_bottom
                        ? ViewportGoal.BOTTOM : ViewportGoal.FREE;
                }
                scroll_down_btn.visible = !is_near_bottom ();
                return end_tick_callback (tick_id);
            });
            track_tick_callback (tick_id);
        }

        /** Rebind a row after changing transient properties on its existing
         * Message object. Gtk.ListView keeps the old widget when the same
         * instance reappears at a position, so splice a fresh copy instead. */
        private void refresh_message_row (int msg_id) {
            var msg = find_message (message_store, msg_id);
            if (msg != null) replace_message (msg_id, msg.dup ());
        }

        private async void toggle_full_message (int msg_id) {
            var msg = find_message (message_store, msg_id);
            if (msg == null) return;

            if (msg.full_message_expanded) {
                msg.full_message_expanded = false;
                refresh_message_row (msg_id);
                return;
            }

            try {
                if (msg.can_download_full_message) {
                    yield rpc.download_full_message (msg_id);
                    yield load_messages (true);
                    return;
                }

                string? full_text = msg.full_message_text;
                if (full_text == null) {
                    set_full_message_loading (msg, true);
                    full_text = yield fetch_full_message_text (msg_id);
                }

                var current = find_message (message_store, msg_id);
                if (current != null) {
                    current.full_message_loading = false;
                    if (full_text != null && full_text.length > 0) {
                        current.full_message_text = full_text;
                        current.full_message_expanded = true;
                        refresh_message_row (msg_id);
                        return;
                    }
                }

                clear_full_message_loading (msg_id);
                window.show_toast ("Full message unavailable");
            } catch (Error e) {
                clear_full_message_loading (msg_id);
                window.show_toast ("Full message failed: " + e.message);
            }
        }

        private async void view_full_message (int msg_id) {
            var msg = find_message (message_store, msg_id);
            if (msg == null) return;
            try {
                string? full_text = msg.full_message_text;
                if (full_text == null) {
                    full_text = yield fetch_full_message_text (msg_id);
                }

                var current = find_message (message_store, msg_id);
                if (current != null && full_text != null
                        && full_text.length > 0) {
                    /* Cache silently. Viewing must not rebuild or otherwise
                       alter the inline bubble; Expand/Collapse owns that. */
                    current.full_message_text = full_text;
                    show_full_message_text (msg_id, full_text);
                    return;
                }

                window.show_toast ("Full message unavailable");
            } catch (Error e) {
                window.show_toast ("Full message failed: " + e.message);
            }
        }

        private async string? fetch_full_message_text (int msg_id)
                throws Error {
            var msg = find_message (message_store, msg_id);
            if (msg == null || !msg.has_html) return null;
            string? html = yield rpc.get_message_html (msg_id);
            return html != null && html.length > 0
                ? html_to_text (html) : null;
        }

        private void set_full_message_loading (Message msg, bool loading) {
            msg.full_message_loading = loading;
            refresh_message_row (msg.id);
        }

        private void clear_full_message_loading (int msg_id) {
            var msg = find_message (message_store, msg_id);
            if (msg == null) return;
            msg.full_message_loading = false;
            refresh_message_row (msg_id);
        }

        private static void preserve_full_message_state (Message old_msg,
                                                         Message new_msg) {
            if (old_msg.text != new_msg.text) return;
            new_msg.full_message_text = old_msg.full_message_text;
            new_msg.full_message_expanded = old_msg.full_message_expanded;
            new_msg.full_message_loading = old_msg.full_message_loading;
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
            var msg = find_message (message_store, msg_id);
            if (msg == null) return;
            var dialog = new FullMessageDialog (window, rpc, msg_actions, msg,
                full_text, settings.effective_font_size ());
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

        /* Re-assert position after GtkListView's focus scroll has run.
           A no-op while a row is anchored — the anchor loop is already
           enforcing the position and a stale value would fight it. */
        public void restore_scroll_value_deferred (double v) {
            if (goal == ViewportGoal.ANCHOR) return;
            freeze_scroll_handler (250);
            uint tick_id = 0;
            tick_id = message_listview.add_tick_callback ((w, clock) => {
                if (closed) return end_tick_callback (tick_id);
                restore_scroll_value (v);
                return end_tick_callback (tick_id);
            });
            track_tick_callback (tick_id);
        }

        /* Hold position when a row click would otherwise focus-scroll.
           Only relevant while the user owns the viewport: BOTTOM re-snaps
           on its own and an anchor already enforces the position. */
        private void hold_scroll_on_focus_shift () {
            if (goal != ViewportGoal.FREE) return;
            restore_scroll_value_deferred (message_scroll.vadjustment.value);
        }

        public bool close_search_if_active () {
            if (!message_search_revealer.reveal_child) return false;
            message_search_revealer.reveal_child = false;
            message_search_entry.text = "";
            return true;
        }

        public void scroll_to_message (int msg_id) {
            if (msg_id <= 0) return;

            /* A filtered-out message has no ListView position. Close search
               first and let the filter model expose every message again. */
            if (close_search_if_active ()) {
                Idle.add (() => {
                    scroll_to_message (msg_id);
                    return Source.REMOVE;
                });
                return;
            }

            if (scroll_to_loaded_message (msg_id)) {
                pending_scroll_message_id = 0;
                resume_pending_voice_navigation ();
                return;
            }

            pending_scroll_message_id = msg_id;
            /* The jump load prepends big batches; bottom-following would
               snap the viewport to the end on every splice. */
            if (goal == ViewportGoal.BOTTOM) goal = ViewportGoal.FREE;
            if (!loading_more) load_until_pending_message.begin ();
        }

        public void request_voice_navigation (int direction) {
            var item = AudioPlayback.shared ().current_item;
            if (item == null || direction == 0 || item.account_id != rpc.account_id
                    || item.chat_id != chat_id) return;
            if (find_message (message_store, item.message_id) != null) {
                play_adjacent_voice_message.begin (direction);
                return;
            }
            pending_voice_direction = direction;
            scroll_to_message (item.message_id);
        }

        private bool scroll_to_loaded_message (int msg_id) {
            int pos = find_message_index (filtered_message_store, msg_id);
            if (pos < 0) return false;
            var msg = (Message) filtered_message_store.get_item (pos);
            msg.highlighted = true;
            message_listview.scroll_to (pos, Gtk.ListScrollFlags.FOCUS, null);
            if ((uint) pos + 1 == filtered_message_store.get_n_items ()) {
                /* Jumping to the last row is just going to the bottom. */
                goal_generation++;
                goal = ViewportGoal.BOTTOM;
                scroll_down_btn.visible = false;
            } else {
                /* 45-frame minimum: survive the focus-restore scroll of a
                   dialog that is still animating closed. */
                anchor_message (msg_id, (uint) pos, double.MAX, 45);
                scroll_down_btn.visible = true;
            }
            return true;
        }

        /** Pin msg_id where it currently sits (or at wanted_top when the
            caller measured one before a splice) until the layout has held
            still for a few frames, then hand the viewport back. scroll_to
            only guarantees visibility for the layout of that one frame:
            images and stickers in freshly realized rows finish decoding
            later, resize, and would push the target away. min_frames keeps
            the anchor enforcing for at least that many frames even when
            the layout is instantly stable — an explicit jump must outlive
            the closing dialog's focus restore, which scrolls the list a
            few hundred ms later. Starting a new anchor, scroll_to_bottom
            or user input cancels this one instantly via goal_generation. */
        private void anchor_message (int msg_id, uint position,
                                     double wanted_top = double.MAX,
                                     uint min_frames = 0) {
            goal = ViewportGoal.ANCHOR;
            uint generation = ++goal_generation;
            double want = wanted_top;
            uint stable_frames = 0;
            uint elapsed_frames = 0;
            uint tick_id = 0;
            tick_id = message_listview.add_tick_callback ((w, clock) => {
                if (closed || generation != goal_generation
                        || goal != ViewportGoal.ANCHOR)
                    return end_tick_callback (tick_id);

                double current_top;
                var row = find_message_row (
                    message_listview, msg_id, out current_top);
                bool in_viewport = row != null
                    && current_top + row.get_height () > 0
                    && current_top < message_scroll.get_height ();
                if (row == null) {
                    /* Not realized yet (or recycled away): re-request. */
                    message_listview.scroll_to (
                        position, Gtk.ListScrollFlags.NONE, null);
                    stable_frames = 0;
                } else if (want == double.MAX) {
                    /* Tick callbacks run BEFORE layout: right after
                       scroll_to the target can still sit realized at its
                       old off-screen offset (typical when jumping within
                       already-visited history). Capturing that offset
                       would anchor the jump to the pre-jump position and
                       snap the viewport straight back. Wait until the row
                       is actually inside the viewport. */
                    if (in_viewport) {
                        want = current_top;
                    } else {
                        message_listview.scroll_to (
                            position, Gtk.ListScrollFlags.NONE, null);
                        stable_frames = 0;
                    }
                } else {
                    double correction = current_top - want;
                    if (Math.fabs (correction) > 0.5) {
                        restore_scroll_value (
                            message_scroll.vadjustment.value + correction);
                        stable_frames = 0;
                    } else {
                        stable_frames++;
                    }
                }

                elapsed_frames++;
                bool settled = stable_frames >= 3
                    && elapsed_frames >= min_frames;
                if (!settled && elapsed_frames < min_frames + 60)
                    return Source.CONTINUE;

                /* Layout settled (or we give up): hand the viewport back
                   to whoever the position now implies. */
                goal = is_near_bottom ()
                    ? ViewportGoal.BOTTOM : ViewportGoal.FREE;
                scroll_down_btn.visible = goal != ViewportGoal.BOTTOM;
                return end_tick_callback (tick_id);
            });
            track_tick_callback (tick_id);
        }

        /* ================================================================
         *  Message loading
         * ================================================================ */

        private async void load_messages (bool preserve_scroll = false) {
            if (rpc.account_id <= 0) return;

            try {
                yield load_chat_kind_if_needed ();
                yield ensure_mention_roster ();

                bool was_near_bottom = goal == ViewportGoal.BOTTOM;
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

                yield pinned.load_for_chat (chat_id);
                webxdc_bar.load_for_chat.begin (chat_id);

                loading_chat = true;
                goal_generation++;
                goal = !preserve_scroll || was_near_bottom
                    ? ViewportGoal.BOTTOM : ViewportGoal.FREE;

                message_store.splice (0, message_store.get_n_items (),
                    pinned_message_batch (messages));
                update_conversation_media_bar ();
                messages_loaded = true;
                messages_stale = false;
                loading_chat = false;
                flush_pending_seen ();
                if (messages.length > 0) {
                    if (!preserve_scroll || was_near_bottom) {
                        scroll_to_bottom ();
                    } else {
                        Idle.add (() => {
                            restore_scroll_value (previous_scroll_value);
                            goal = ViewportGoal.FREE;
                            scroll_down_btn.visible = !is_near_bottom ();
                            return Source.REMOVE;
                        });
                    }
                }

                pinned.update_bar.begin ();
                resume_pending_message_scroll ();
            } catch (Error e) {
                messages_loaded = false;
                messages_stale = true;
                window.show_toast ("Failed to load messages: " + e.message);
            }
        }

        /* Build the mention roster once for group chats: chat members (for the
           composer autocomplete + name/address resolution) plus the window's
           self keys. Cheap to skip for direct chats. */
        private async void ensure_mention_roster () {
            if (roster_loaded) return;
            roster_loaded = true;

            try {
                var roster = new MentionRoster ();
                foreach (string key in window.self_mention_keys ()) {
                    roster.add_self_key (key);
                }

                var chat = yield rpc.get_full_chat_by_id_for (
                    rpc.account_id, chat_id);
                if (chat != null && chat.has_member ("contactIds")) {
                    var ids = chat.get_array_member ("contactIds");
                    for (uint i = 0; i < ids.get_length (); i++) {
                        int cid = (int) ids.get_int_element (i);
                        var cobj = yield rpc.get_contact_for (rpc.account_id, cid);
                        if (cobj == null) continue;
                        var c = RpcParsers.parse_contact (cid, cobj);
                        /* Core names the self contact "Me"; mentions must show
                           (and resolve by) the account's configured display
                           name, which is what other clients write. */
                        string name = cid == 1
                            && MessageRow.self_display_name != null
                            && MessageRow.self_display_name.strip ().length > 0
                            ? MessageRow.self_display_name.strip ()
                            : c.display_name;
                        roster.add_member (new MentionMember (
                            cid, name, c.address, cid == 1,
                            c.profile_image));
                    }
                }

                reaction_roster = roster;
                if (msg_actions != null)
                    msg_actions.set_reaction_roster (reaction_roster);
                /* Message text resolves mentions in every chat kind — a
                   one-to-one partner mentioning you must render like it does
                   in a group. Only the composer autocomplete is groups-only,
                   where picking someone out of a member list makes sense. */
                mention_roster = roster;
                compose_bar.set_mention_roster (
                    chat_kind == ChatKind.DIRECT ? null : roster);
            } catch (Error e) {
                /* Non-critical: retry on the next reload. */
                reaction_roster = null;
                mention_roster = null;
                if (msg_actions != null)
                    msg_actions.set_reaction_roster (null);
                compose_bar.set_mention_roster (null);
                roster_loaded = false;
            }
        }

        /* Force the roster to rebuild on the next message load, e.g. after a
           membership or contact change. */
        public void invalidate_mention_roster () {
            roster_loaded = false;
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
                        var msg = RpcParsers.parse_message (
                            map.get_object_member (k), rpc.self_email);
                        if (msg.state != MessageState.OUT_DRAFT) {
                            result.add (msg);
                        }
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
                var old_msg = find_message (message_store, messages[i].id);
                if (old_msg != null) {
                    preserve_full_message_state (old_msg, messages[i]);
                }
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

                double anchor_top;
                var anchor = find_message_row (
                    message_listview, 0, out anchor_top);
                int anchor_id = anchor != null ? anchor.message_id : 0;

                /* One splice avoids a per-row ListView relayout storm. */
                message_store.splice (0, 0, pinned_message_batch (messages));
                flush_pending_seen ();

                loaded_start_index = new_start;
                update_conversation_media_bar ();

                /* Preserve a real row because GtkListView's upper is estimated. */
                int anchor_pos = anchor_id != 0
                    ? find_message_index (filtered_message_store, anchor_id)
                    : -1;
                if (anchor_pos >= 0) {
                    anchor_message (anchor_id, (uint) anchor_pos, anchor_top);
                }
                finish_loading_earlier ();
            } catch (Error e) {
                pending_scroll_message_id = 0;
                pending_voice_direction = 0;
                finish_loading_earlier (false);
                window.show_toast ("Failed to load earlier messages: " + e.message);
            }
        }

        /* Load every missing history page between the current context and a
           requested message. Re-evaluate the pending ID after each RPC call
           so a newer click replaces an older jump without racing it. */
        private async void load_until_pending_message () {
            if (loading_more || pending_scroll_message_id == 0
                    || all_msg_ids == null) return;

            loading_more = true;
            set_loading_more_visible (true);
            /* Never bottom-follow while batches land: scroll_to_message
               demotes BOTTOM, but a fresh chat load (jump into a chat that
               was not open, e.g. gallery via a sidebar row's Details)
               re-establishes it between that demotion and this loop —
               every splice would then snap to the bottom and the anchor
               would drag it back up, once per batch. */
            if (goal == ViewportGoal.BOTTOM) goal = ViewportGoal.FREE;
            bool unavailable = false;

            try {
                while (pending_scroll_message_id != 0) {
                    int target_id = pending_scroll_message_id;
                    if (find_message (message_store, target_id) != null) break;

                    int target_index = MessageHistory.find_id (
                        all_msg_ids, target_id);
                    if (target_index < 0
                            || (uint) target_index >= loaded_start_index) {
                        if (pending_scroll_message_id == target_id)
                            pending_scroll_message_id = 0;
                        unavailable = true;
                        break;
                    }

                    /* Jumps (quotes, gallery "view in conversation") can
                       span thousands of messages; the regular 100-message
                       batches would mean dozens of sequential roundtrips
                       that look like nothing is happening. */
                    uint new_start = MessageHistory.earlier_batch_start (
                        loaded_start_index, (uint) target_index, 1000);
                    var messages = yield fetch_messages_batch (
                        new_start, loaded_start_index);

                    /* The user may have scrolled (which cancels the jump)
                       during the roundtrip. */
                    if (pending_scroll_message_id == 0) break;

                    /* Keep whatever is on screen exactly where it is while
                       the batch lands above it; without an anchor every
                       splice re-estimates the list height and visibly
                       jerks the viewport. */
                    double anchor_top;
                    var anchor_row = find_message_row (
                        message_listview, 0, out anchor_top);

                    /* Keep the complete context between the old viewport and
                       the target instead of inserting only the pinned row. */
                    message_store.splice (0, 0, pinned_message_batch (messages));
                    flush_pending_seen ();
                    loaded_start_index = new_start;
                    update_conversation_media_bar ();

                    if (anchor_row != null) {
                        int anchor_pos = find_message_index (
                            filtered_message_store, anchor_row.message_id);
                        if (anchor_pos >= 0) {
                            anchor_message (anchor_row.message_id,
                                            (uint) anchor_pos, anchor_top);
                        }
                    }
                }
            } catch (Error e) {
                pending_scroll_message_id = 0;
                finish_loading_earlier (false);
                window.show_toast ("Failed to load message: " + e.message);
                return;
            }

            finish_loading_earlier ();
            if (unavailable) {
                pending_voice_direction = 0;
                window.show_toast ("Message is no longer available");
            }
        }

        /* Find a row by ID, or the top visible row when message_id is zero. */
        private MessageRow? find_message_row (Gtk.Widget widget,
                                              int message_id,
                                              out double top) {
            top = double.MAX;
            var row = widget as MessageRow;
            if (row != null) {
                Graphene.Point point = Graphene.Point ();
                if ((message_id != 0 && row.message_id != message_id)
                        || !row.compute_point (message_scroll,
                            Graphene.Point () { x = 0, y = 0 }, out point))
                    return null;
                top = point.y;
                bool visible = top + row.get_height () > 0
                    && top < message_scroll.get_height ();
                return (message_id != 0 || visible) ? row : null;
            }

            MessageRow? result = null;
            for (Gtk.Widget? child = widget.get_first_child ();
                    child != null; child = child.get_next_sibling ()) {
                double child_top;
                var found = find_message_row (child, message_id, out child_top);
                if (found != null && child_top < top) {
                    result = found;
                    top = child_top;
                    if (message_id != 0) break;
                }
            }
            return result;
        }

        private void finish_loading_earlier (bool resume_pending = true) {
            loading_more = false;
            set_loading_more_visible (false);
            /* An anchor started by the prepend still owns the viewport;
               it hands the goal back itself once the layout settles. */
            if (goal != ViewportGoal.ANCHOR) {
                goal = is_near_bottom ()
                    ? ViewportGoal.BOTTOM : ViewportGoal.FREE;
            }
            scroll_down_btn.visible = !is_near_bottom ();
            update_date_pill ();
            if (resume_pending) resume_pending_message_scroll ();
        }

        private void resume_pending_message_scroll () {
            if (pending_scroll_message_id == 0) return;
            if (scroll_to_loaded_message (pending_scroll_message_id)) {
                pending_scroll_message_id = 0;
                resume_pending_voice_navigation ();
            } else if (!loading_more && all_msg_ids != null) {
                load_until_pending_message.begin ();
            }
        }

        private void resume_pending_voice_navigation () {
            if (pending_voice_direction == 0) return;
            int direction = pending_voice_direction;
            pending_voice_direction = 0;
            var item = AudioPlayback.shared ().current_item;
            if (item != null && item.account_id == rpc.account_id
                    && item.chat_id == chat_id)
                play_adjacent_voice_message.begin (direction);
        }

        /* Toggle the top "Loading…" pill while older messages are fetched.
           Spinning is tied to visibility so the animation only runs when shown. */
        private void set_loading_more_visible (bool visible) {
            loading_more_spinner.visible = visible;
            loading_more_spinner.spinning = visible;
            if (visible) {
                loading_pill_label.label = "Loading…";
            }
            loading_more_revealer.reveal_child = visible;
        }

        /* ================================================================
         *  Scroll helpers
         * ================================================================ */

        /** Update the floating date pill to show the date of the first
            visible message, or hide it when at the bottom. */
        private void update_date_pill () {
            if (goal == ViewportGoal.BOTTOM
                    || message_store.get_n_items () == 0) {
                loading_more_revealer.reveal_child = false;
                return;
            }

            /* Pick a widget near the top-center of the list view to find
               the first visible message row. */
            var w = message_listview.pick (
                message_listview.get_width () / 2, 5, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                w = w.get_parent ();
            }
            var row = w as MessageRow;
            if (row == null) {
                loading_more_revealer.reveal_child = false;
                return;
            }

            var msg = find_message (message_store, row.message_id);
            if (msg == null) {
                loading_more_revealer.reveal_child = false;
                return;
            }

            loading_more_spinner.spinning = false;
            loading_more_spinner.visible = false;
            loading_pill_label.label = MessageRow.format_date_label (msg.timestamp);
            loading_more_revealer.reveal_child = true;
        }

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
            if (goal != ViewportGoal.BOTTOM) return;
            message_scroll.vadjustment.value = max_scroll_value ();
        }

        public void scroll_to_bottom () {
            goal_generation++;
            goal = ViewportGoal.BOTTOM;
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
                    update_conversation_media_bar ();
                    return;
                }
            }
            for (uint i = 0; i < message_store.get_n_items (); i++) {
                var m = (Message) message_store.get_item (i);
                if (m.timestamp > msg.timestamp ||
                    (m.timestamp == msg.timestamp && m.id > msg.id)) {
                    message_store.insert ((int) i, msg);
                    update_conversation_media_bar ();
                    return;
                }
            }
            message_store.append (msg);
            update_conversation_media_bar ();
        }

        /** "Save to disk" from the apps bar context menu. */
        private async void save_webxdc_from_bar (int msg_id) {
            var msg = find_message (message_store, msg_id);
            if (msg == null) {
                try {
                    msg = yield rpc.fetch_message (msg_id);
                } catch (Error e) {
                    window.show_toast ("Failed to load app: " + e.message);
                    return;
                }
            }
            if (msg == null || msg.file_path == null
                || msg.file_path.length == 0) {
                window.show_toast ("The app file is not downloaded");
                return;
            }
            yield window.save_attachment (msg.file_path, msg.file_name);
        }

        /* ================================================================
         *  Sending & attachments
         * ================================================================ */

        /* One preview per pasted link, fetched concurrently; each lands
           in the composer as its own image attachment as soon as it is
           ready, or is dropped if the composer moved on meanwhile. */
        private void on_link_previews_requested (string[] urls, uint generation) {
            if (link_preview_fetcher == null)
                link_preview_fetcher = new LinkPreviewFetcher (rpc);
            foreach (string url in urls) {
                link_preview_fetcher.fetch.begin (url, settings.clean_pasted_links,
                    (obj, res) => {
                        var r = link_preview_fetcher.fetch.end (res);
                        if (r == null) return;
                        if (!compose_bar.add_link_preview (generation, r.image_path,
                                r.file_name, r.title, r.description))
                            GLib.FileUtils.unlink (r.image_path);
                    });
            }
        }

        private void on_send_message (string text, string? file_path,
                                      string? file_name, int quote_msg_id) {
            queue_send (new PendingSend (
                text, file_path, file_name, quote_msg_id));
        }

        /* `text` carries the transcription when the composer attached one to
           the recording; the message still goes out as a Voice message. */
        private void on_send_voice_message (string file_path, string text,
                                            int quote_msg_id, bool temporary) {
            queue_send (new PendingSend (text, file_path,
                ComposeBar.VOICE_FILE_NAME, quote_msg_id, true, temporary));
        }

        private void queue_send (PendingSend job) {
            discard_pending_draft_save ();
            remove_draft.begin ();
            send_queue.push_tail (job);
            process_send_queue.begin ();
        }

        private async void process_send_queue () {
            if (sending_queue) return;
            sending_queue = true;
            while (!send_queue.is_empty ()) {
                yield do_send (send_queue.pop_head ());
            }
            sending_queue = false;
        }

        private async void do_send (PendingSend job) {
            try {
                string? send_text = job.text.length > 0 ? job.text : null;
                string? view_type = job.voice ? "Voice"
                    : AttachmentTypes.infer_outgoing_view_type (
                        job.file_path, job.file_name);
                int msg_id = yield rpc.send_msg (chat_id,
                    send_text, job.file_path, job.file_name,
                    job.quote_msg_id, view_type);
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
            } finally {
                if (job.owns_file && job.file_path != null)
                    FileUtils.unlink (job.file_path);
            }
        }

        private void on_draft_changed (string text, string? file_path,
                                       string? file_name, int quote_msg_id,
                                       bool voice) {
            if (closed || !draft_rpc_available || rpc.account_id <= 0) return;
            cancel_pending_draft_timer ();
            draft_save_pending = true;
            pending_draft_text = text;
            pending_draft_file_path = file_path;
            pending_draft_file_name = file_name;
            pending_draft_quote_msg_id = quote_msg_id;
            pending_draft_voice = voice;
            draft_save_timer = Timeout.add (600, () => {
                draft_save_timer = 0;
                flush_pending_draft_save ();
                return Source.REMOVE;
            });
        }

        private void cancel_pending_draft_timer () {
            if (draft_save_timer == 0) return;
            Source.remove (draft_save_timer);
            draft_save_timer = 0;
        }

        private void clear_pending_draft_snapshot () {
            draft_save_pending = false;
            pending_draft_text = "";
            pending_draft_file_path = null;
            pending_draft_file_name = null;
            pending_draft_quote_msg_id = 0;
            pending_draft_voice = false;
        }

        private void discard_pending_draft_save () {
            cancel_pending_draft_timer ();
            clear_pending_draft_snapshot ();
        }

        private void flush_pending_draft_save () {
            cancel_pending_draft_timer ();
            if (!draft_save_pending) return;

            string text = pending_draft_text;
            string? file_path = pending_draft_file_path;
            string? file_name = pending_draft_file_name;
            int quote_msg_id = pending_draft_quote_msg_id;
            bool voice = pending_draft_voice;
            clear_pending_draft_snapshot ();

            /* The RPC owns only this immutable snapshot, not the view. An
               evicted conversation can therefore finalize even if the
               transport takes a long time to answer. */
            start_detached_draft_save (this, text, file_path, file_name,
                quote_msg_id, voice);
        }

        private async void load_draft () {
            if (!draft_rpc_available || rpc.account_id <= 0) return;
            try {
                var draft = yield rpc.get_draft (chat_id);
                if (draft == null || compose_bar.has_unsent_content ()) return;
                compose_bar.restore_draft (draft);
            } catch (Error e) {
                draft_rpc_available = !is_missing_draft_rpc (e);
                if (draft_rpc_available) warning ("load_draft: %s", e.message);
            }
        }

        private static void start_detached_draft_save (
                ConversationView target, string text, string? file_path,
                string? file_name, int quote_msg_id, bool voice) {
            WeakRef view_ref = WeakRef (target);
            save_draft_snapshot.begin (target.rpc, target.chat_id,
                text, file_path, file_name, quote_msg_id,
                voice, (obj, result) => {
                    var outcome = save_draft_snapshot.end (result);
                    var view = view_ref.get () as ConversationView;
                    if (view != null && !view.closed) {
                        view.draft_rpc_available =
                            outcome != DraftSaveResult.UNAVAILABLE;
                        if (outcome == DraftSaveResult.SAVED)
                            view.window.request_reload_chats ();
                    }
                });
        }

        private static async DraftSaveResult save_draft_snapshot (
                RpcClient rpc, int chat_id, string text,
                string? file_path, string? file_name, int quote_msg_id,
                bool voice) {
            if (rpc.account_id <= 0) return DraftSaveResult.FAILED;
            try {
                bool has_text = text.length > 0;
                bool has_file = file_path != null && file_path.length > 0;
                bool has_quote = quote_msg_id > 0;
                if (!has_text && !has_file && !has_quote) {
                    yield rpc.remove_draft (chat_id);
                } else {
                    yield rpc.set_draft (chat_id,
                        has_text ? text : null,
                        has_file ? file_path : null,
                        has_file ? file_name : null,
                        quote_msg_id,
                        has_file
                            ? (voice ? "Voice"
                                : AttachmentTypes.infer_outgoing_view_type (
                                    file_path, file_name))
                            : null);
                }
                return DraftSaveResult.SAVED;
            } catch (Error e) {
                bool available = !is_missing_draft_rpc (e);
                if (available) warning ("save_draft: %s", e.message);
                return available
                    ? DraftSaveResult.FAILED
                    : DraftSaveResult.UNAVAILABLE;
            }
        }

        private async void remove_draft () {
            if (!draft_rpc_available || rpc.account_id <= 0) return;
            try {
                yield rpc.remove_draft (chat_id);
                window.request_reload_chats ();
            } catch (Error e) {
                draft_rpc_available = !is_missing_draft_rpc (e);
                if (draft_rpc_available) warning ("remove_draft: %s", e.message);
            }
        }

        private static bool is_missing_draft_rpc (Error e) {
            string msg = e.message.down ();
            return "method not found" in msg
                || "procedure not found" in msg
                || "unknown method" in msg;
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
            track_signal (file_drop_target, file_drop_target.accept.connect (
                can_accept_file_attachment));
            track_signal (file_drop_target, file_drop_target.dropped.connect (
                attach_local_file));
            track_signal (file_drop_target, file_drop_target.failed.connect ((message) => {
                window.show_toast ("Attach failed: " + message);
            }));
        }

        private MessageRow? pick_message_row (double x, double y) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                w = w.get_parent ();
            }
            return w as MessageRow;
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
           play/pause button drives playback, so the press must reach it rather
           than triggering the row action or arming a double-click reaction. */
        private bool pointer_on_audio (double x, double y) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                if (w is AudioPlayer) return true;
                w = w.get_parent ();
            }
            return false;
        }

        private bool search_filter_active () {
            return message_search_revealer.reveal_child
                && message_search_entry.text.strip ().length > 0;
        }

        /* True when the picked widget or an ancestor inside the row carries
           one of the given CSS classes. */
        private bool pointer_on_css (double x, double y, string[] classes) {
            var w = message_listview.pick (x, y, Gtk.PickFlags.DEFAULT);
            while (w != null && !(w is MessageRow)) {
                foreach (unowned string cls in classes) {
                    if (w.has_css_class (cls)) return true;
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
            if (msg.is_webxdc ()) {
                window.prompt_webxdc_app.begin (window, rpc, msg);
                return;
            }
            if (!msg.has_local_file) {
                window.show_toast ("File not available");
                return;
            }
            if (msg.is_video_sticker_file ()) {
                window.show_video (msg.file_path, msg.file_name);
            } else if (msg.is_image_file ()) {
                string[] paths;
                int start;
                collect_image_paths (msg.file_path, out paths, out start);
                window.show_image_list (paths, start);
            } else if (msg.is_video_file ()) {
                window.show_video (msg.file_path, msg.file_name);
            } else if (msg.is_audio_file ()) {
                /* Audio plays inline via its own play/pause button. */
            } else if (msg.is_text_preview_file ()) {
                preview_text_attachment (msg);
            } else {
                window.save_attachment.begin (msg.file_path, msg.file_name);
            }
        }

        /* A Gtk.Label renders the whole buffer at once, so cap inline
           previews and fall back to the save flow for anything larger. */
        private const size_t TEXT_PREVIEW_MAX_BYTES = 1024 * 1024;

        private void preview_text_attachment (Message msg) {
            string path = msg.file_path;
            string content;
            size_t length;
            try {
                FileUtils.get_contents (path, out content, out length);
            } catch (Error e) {
                window.show_toast ("Preview failed: " + e.message);
                return;
            }
            if (length > TEXT_PREVIEW_MAX_BYTES) {
                window.save_attachment.begin (path, msg.file_name);
                return;
            }
            if (!content.validate ()) content = content.make_valid ();
            if (msg.is_html_file ()) content = html_to_text (content);
            if (content.strip ().length == 0) {
                window.show_toast ("File is empty");
                return;
            }
            var dialog = new FullMessageDialog.for_file (window,
                msg.display_file_name (), content,
                settings.effective_font_size (), msg.is_markdown_file ());
            dialog.present (window);
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

        /**
         * End every relationship that can outlive the GtkStack entry. This is
         * intentionally explicit: waiting for dispose would deadlock on the
         * signal cycles that close() is responsible for breaking.
         */
        public void close () {
            if (closed) return;
            closed = true;

            flush_pending_draft_save ();
            goal_generation++;
            pending_scroll_message_id = 0;
            pending_voice_direction = 0;
            loading_more = false;

            var active_ticks = tick_callback_ids;
            tick_callback_ids = {};
            foreach (uint callback_id in active_ticks) {
                message_listview.remove_tick_callback (callback_id);
            }

            for (uint i = 0; i < signal_handlers.length; i++) {
                signal_handlers[i].disconnect_handler ();
            }
            if (signal_handlers.length > 0)
                signal_handlers.remove_range (0, signal_handlers.length);

            var playback = AudioPlayback.shared ();
            if (playback_message_handler != 0) {
                playback.disconnect (playback_message_handler);
                playback_message_handler = 0;
            }
            if (playback_finished_handler != 0) {
                playback.disconnect (playback_finished_handler);
                playback_finished_handler = 0;
            }

            webxdc_bar.close ();
            compose_bar.close ();

            /* Detach the virtualized rows before clearing the store. This
               immediately releases row widgets, textures, and messages even
               if an already-running async RPC briefly keeps this view alive. */
            message_listview.set_model (null);
            message_listview.set_factory (null);
            filtered_message_store.set_model (null);
            message_store.remove_all ();
            all_msg_ids = null;
            pending_seen_ids = {};
            mention_roster = null;
            reaction_roster = null;
            msg_actions.set_reaction_roster (null);
            compose_bar.set_mention_roster (null);
        }

        public override void dispose () {
            close ();
            base.dispose ();
        }
    }
}
