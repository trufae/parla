namespace Dc {

    /* True for links that the SecureJoin flow can act on: the "openpgp4fpr:"
       URI scheme (carried in QR codes / registered as a system handler) and
       the "https://i.delta.chat/" web fallback. Used both to claim clicks on
       in-message links and to recognise URIs passed on the command line. */
    public bool is_delta_invite_uri (string uri) {
        string u = uri.strip ().down ();
        return u.has_prefix ("openpgp4fpr:")
            || u.has_prefix ("https://i.delta.chat/");
    }

    public class Window : Adw.ApplicationWindow {

        /* Layout */
        private Adw.ToastOverlay toast_overlay;
        private Adw.OverlaySplitView split_view;
        private Adw.HeaderBar sidebar_header;
        private Adw.HeaderBar content_header;
        private Gtk.Label content_title_label;
        private Gtk.Image content_mute_icon;
        private Gtk.SearchEntry search_entry;
        private Gtk.Box sidebar_box;
        private Gtk.Button sidebar_toggle_btn;
        private Gtk.Button message_search_btn;
        private Gtk.Button gallery_btn;
        private Gtk.MenuButton sidebar_menu_button;
        private Adw.WindowTitle sidebar_title;

        /* Chat list */
        private Gtk.ListBox chat_listbox;
        public GLib.ListStore chat_store { get; private set; }

        /* Archived-chats view: the sidebar shows either the normal chatlist
           or the archived one; the toggle only exists while the account has
           at least one archived chat. */
        private Gtk.Button archived_toggle_btn;
        private Adw.ButtonContent archived_btn_content;
        private bool showing_archived = false;
        private int archived_count = 0;

        /* Keep the active chat and two recent neighbours warm. Every view can
           own a full message batch plus decoded media, so this cache must be
           bounded rather than growing for the lifetime of the process. */
        private HashTable<int, ConversationView> views;
        private int[] view_recency = {};

        /* Status */
        private Adw.StatusPage empty_status;
        private Gtk.Stack content_stack;

        /* Floating connection-status banner (revealed when RPC is down) */
        private Gtk.Revealer connection_banner;
        private Gtk.Label connection_banner_label;

        /* Profile avatar */
        private Gtk.MenuButton account_menu_button;
        private Adw.Avatar profile_avatar;
        private Gtk.Box profile_unread_badge;
        private Gtk.Popover account_popover;
        private Gtk.ListBox account_menu_list;
        /* Signature of the data last rendered in the account menu plus a
           generation counter, so overlapping reloads can't fight: stale
           runs bail out and no-change runs never touch the widgets
           (sync-event bursts used to make the open menu flash). */
        private string? account_menu_state = null;
        private int account_menu_load_gen = 0;
        private bool focus_current_account_on_menu_load = false;

        /* Down-cased identifiers (display name + transport addresses) used to
           detect when an incoming message mentions the local user. */
        private string[] self_mention_keys_cache = {};

        /* Chats of the current account with an unseen self-mention, kept in
           memory (reset on restart). Drives the sidebar row highlight. */
        private GenericSet<int> mentioned_chats = new GenericSet<int> (
            direct_hash, direct_equal);

        /* State */
        private unowned RpcClient rpc;
        private int _current_chat_id = 0;
        /* Row of the open chat. The list has no GTK selection (see the
           chat_listbox setup), so the highlight is tracked by hand. */
        private Gtk.ListBoxRow? current_chat_row = null;
        /* Day the chat rows were built on; their time labels are relative
           ("14:02" today, "Mon" later), so a new day forces a rebuild. */
        private int chat_rows_day = 0;
        public int current_chat_id {
            get { return _current_chat_id; }
            private set {
                _current_chat_id = value;
                if (events != null) events.active_chat_id = value;
                update_conversation_header_actions ();
                sync_webxdc_chat_visibility ();
            }
        }

        /* Feed the shown-chat state to the Webxdc runner so app windows in
           follow-chat mode track their chat. Deliberately based on `visible`
           and not `is_active`: focusing the app window itself unfocuses this
           one, and hiding on focus loss would fight the user. */
        private void sync_webxdc_chat_visibility () {
            Webxdc.set_active_chat (rpc != null ? rpc.account_id : 0,
                                    _current_chat_id, this.visible);
        }

        public bool is_chat_visible (int chat_id) {
            if (chat_id <= 0 || chat_id != current_chat_id) return false;
            /* Hidden in the tray or unfocused: the user cannot be reading
               this chat, however recently it was active. */
            if (!this.visible || !this.is_active) return false;
            if (split_view.collapsed && split_view.show_sidebar)
                return false;
            return true;
        }

        /* Extracted managers */
        public SettingsManager settings;
        private ImageViewer image_viewer;
        private VideoPlayer video_player;
        private EventHandler events;
        private ChatContextMenu chat_menu;
        private bool reconnecting_rpc = false;
        /* New-message/reaction events waiting to be shown as notifications;
           batched so a mailbox fetch produces one banner per chat. */
        private class PendingNotification {
            public int acct_id;
            public int chat_id;
            public int msg_id;
            public int contact_id;   /* reaction sender, 0 for a message */
            public string? reaction; /* reaction emoji, null for a message */
        }
        private GenericArray<PendingNotification> pending_notifications =
            new GenericArray<PendingNotification> ();
        private uint notification_flush_timer = 0;
        private uint font_update_source = 0;

        private const double FULL_SIDEBAR_MIN_WIDTH = 260;
        private const double FULL_SIDEBAR_MAX_WIDTH = 340;
        private const double COLLAPSED_SIDEBAR_MIN_WIDTH = 220;
        private const double COLLAPSED_SIDEBAR_MAX_WIDTH = 10000;
        private const double COMPACT_SIDEBAR_WIDTH = 48;
        private const uint FONT_UPDATE_INTERVAL_MS = 16;
        private const uint MAX_CACHED_CONVERSATION_VIEWS = 3;

        /* Modal dialog guard – only one at a time */
        private Adw.Dialog? active_modal = null;

        private bool can_show_account_modal () {
            return rpc.account_id > 0 && active_modal == null;
        }

        private bool can_show_rpc_modal () {
            if (active_modal != null) return false;
            if (events != null) return true;
            show_toast ("RPC not ready");
            return false;
        }

        /* Header-bar actions that only make sense with a conversation open
           (search, gallery). Kept in one place so new per-conversation
           actions stay in sync with chat selection. */
        private void update_conversation_header_actions () {
            bool has_chat = _current_chat_id > 0;
            if (message_search_btn != null) message_search_btn.visible = has_chat;
            if (gallery_btn != null) gallery_btn.visible = has_chat;
        }

        private void present_modal (Adw.Dialog dialog) {
            active_modal = dialog;
            dialog.closed.connect (() => { active_modal = null; });
            dialog.present (this);
        }

        private void reset_chat_ui () {
            discard_all_views ();
            chat_store.remove_all ();
            clear_listbox (chat_listbox);
            current_chat_row = null;
            search_entry.text = "";
            showing_archived = false;
            archived_count = 0;
            update_archived_toggle ();
            content_title_label.label = "Select a chat";
            content_mute_icon.visible = false;
        }

        private void show_empty_status (string icon_name, string title,
                                        string description,
                                        Gtk.Widget? child = null) {
            empty_status.child = child;
            empty_status.icon_name = icon_name;
            empty_status.title = title;
            empty_status.description = description;
            content_stack.visible_child_name = "empty";
        }

        /* An invite link received (via the system handler or an in-app click)
           before a profile was connected; opened once try_connect finishes. */
        private string? pending_invite_uri = null;

#if MACOS
        private MacosTray? tray = null;
#else
        private TrayIcon? tray = null;
#endif
        private bool held_in_background = false;
        private bool quit_requested = false;
        private NativeFileDropTarget? native_file_drop_target;

        /* Set after an Escape that had nothing transient to dismiss while a
           compose mode is active; a second consecutive Escape then drops the
           reply/edit/attachment. Any other key clears it. */
        private bool escape_armed = false;

        /* 360px is the narrowest width libadwaita's AdwPreferencesDialog
           can render: its navigation view carries a hardcoded 360px
           minimum. Below that the settings dialog is not laid out
           narrower, it is simply clipped by the window — rows lose their
           switches, dropdowns and the close button. Keep the window from
           ever getting narrower than the dialogs it hosts; 360px is also
           the smallest width the GNOME HIG asks apps to support. */
        public Window (Dc.Application app) {
            Object (
                application: app,
                default_width: 920,
                default_height: 640,
                width_request: 360,
                height_request: 320,
                title: "Parla"
            );
        }

        construct {
            chat_store = new GLib.ListStore (typeof (ChatEntry));
            views = new HashTable<int, ConversationView> (direct_hash, direct_equal);
            settings = new SettingsManager ();
            settings.load ();
            image_viewer = new ImageViewer ();
            image_viewer.set_window (this);
            video_player = new VideoPlayer ();
            video_player.set_window (this);
            /* Scope for the custom background CSS rule (see
               Application.apply_background). */
            this.add_css_class ("parla-custom-bg");
            build_ui ();
            native_file_drop_target = new NativeFileDropTarget (this);
            native_file_drop_target.path_dropped.connect (handle_native_file_drop);
            MessageRow.style = settings.message_style;
            MessageRow.animate_stickers = settings.animate_stickers;
            apply_current_appearance ();

            /* Highlight colors are baked into label markup, so rebuild the
               open chat whenever the effective dark/light style flips. */
            var style_manager = Adw.StyleManager.get_default ();
            SyntaxHighlight.dark_mode = style_manager.dark;
            style_manager.notify["dark"].connect (() => {
                SyntaxHighlight.dark_mode = style_manager.dark;
                rebuild_current_chat_view ();
            });

            settings.appearance_changed.connect (() => {
                MessageRow.style = settings.message_style;
                MessageRow.animate_stickers = settings.animate_stickers;
                apply_current_appearance ();
                rebuild_current_chat_view ();
            });
            settings.font_changed.connect (() => {
                queue_font_update ();
            });
            close_request.connect (on_close_request);

            /* Regaining focus with a chat on screen means the user has now
               seen its pending messages: reset the chat's unread badge and
               send the deferred seen-marks. */
            this.notify["is-active"].connect (() => {
                if (this.is_active) on_window_focused ();
            });

            /* The tray icon stays up the whole time "minimize to status bar"
               is on (like Discord/Telegram), not just while minimized. */
            settings.notify["minimize-to-tray"].connect (sync_tray);

            /* Keep the tray menu's show/minimize label matching the window. */
            this.notify["visible"].connect (() => {
                if (tray != null) tray.set_window_visible (this.visible);
                sync_webxdc_chat_visibility ();
            });

            /* Defer until the main loop — the tray's D-Bus connection and the
               application property aren't ready during construct. */
            Idle.add (() => {
                try_connect.begin ();
                sync_tray ();
                return Source.REMOVE;
            });
        }

        private void apply_current_appearance () {
            var app = this.application as Dc.Application;
            if (app == null) return;
            app.apply_theme_override (settings.theme_override);
            app.apply_accent_color (settings.accent_color);
            app.apply_background (
                settings.background_mode, settings.background_color);
            apply_current_font ();
        }

        private void apply_current_font () {
            var app = this.application as Dc.Application;
            if (app == null) return;
            app.apply_font (
                settings.font_family,
                settings.font_attribute,
                settings.font_size);
        }

        private void queue_font_update () {
            /* Collapse high-resolution wheel events to one style/layout
               invalidation per frame, always using the newest font value. */
            if (font_update_source != 0) return;
            font_update_source = add_font_update_timeout (this);
        }

        private static uint add_font_update_timeout (Window target) {
            WeakRef window_ref = WeakRef (target);
            return Timeout.add (FONT_UPDATE_INTERVAL_MS, () => {
                var window = window_ref.get () as Window;
                if (window == null) return Source.REMOVE;
                window.font_update_source = 0;
                window.apply_current_font ();
                var view = window.current_view ();
                if (view != null) view.queue_resize ();
                return Source.REMOVE;
            });
        }

        private void rebuild_current_chat_view () {
            int chat_id = current_chat_id;
            discard_all_views ();
            if (chat_id > 0) {
                current_chat_id = 0;
                select_chat_by_id (chat_id);
            }
        }

        private bool on_close_request () {
            if (quit_requested) return false;

#if MACOS
            /* Closing the window keeps Parla running with its Dock icon
               always visible; only an explicit quit (Cmd+Q, the tray menu,
               Dock > Quit) exits for real. */
            minimize_to_tray ();
            return true;
#else
            if (ensure_tray_visible ()) {
                minimize_to_tray ();
                return true;
            }
            /* Started with --background: the process outlives its window,
               so closing only hides it. Quit (Ctrl+Q, the tray menu) still
               exits for real via handle_primary_q. */
            if (runs_in_background ()) {
                minimize_to_tray ();
                return true;
            }
            release_background_hold ();
            return false;
#endif
        }

        private bool runs_in_background () {
            var app = this.application as Dc.Application;
            return app != null && app.background_mode;
        }

        public void set_minimize_to_tray (bool enabled) {
            settings.save_minimize_to_tray (enabled);
            sync_tray ();
        }

        public void quit_application () { handle_primary_q (); }

        public void handle_primary_q () {
            quit_requested = true;
            release_background_hold ();
            close_active_modal ();
            discard_all_views ();
            if (tray != null) tray.hide ();
            var app = this.application;
            this.close ();
            if (app != null) app.quit ();
        }

        public void handle_primary_w () {
#if MACOS
            minimize_to_tray ();
            return;
#else
            if (ensure_tray_visible () || runs_in_background ()) {
                minimize_to_tray ();
                return;
            }
            handle_primary_q ();
#endif
        }

        private void handle_native_file_drop (string path, double x, double y) {
            var chat_row = chat_row_at_point (x, y);
            if (chat_row != null) {
                attach_file_to_chat (chat_row.chat_id, path,
                                     Path.get_basename (path));
                return;
            }

            var v = current_view ();
            if (v == null) {
                show_toast ("Select a chat before dropping a file");
                return;
            }
            v.attach_dropped_file_path (path);
        }

        /* Single source of truth for the tray icon: create it on first need,
           then show/hide it to track the setting. */
        private void sync_tray () {
#if MACOS
            /* macOS keeps the reopen handler installed so a Dock click
               brings the hidden window back, even when no menu-bar icon
               is shown. */
            ensure_tray_backend ();
#endif

            if (!settings.minimize_to_tray) {
                if (tray != null) tray.hide ();
                /* In background/service mode the hidden window is
                   deliberate — the tray setting being off (or getting
                   toggled off) must not summon it. */
                if (runs_in_background ()) return;
                if (held_in_background || !this.visible) restore_from_tray ();
                else release_background_hold ();
                return;
            }

            ensure_tray_visible ();
        }

        /* Create the tray backend and wire its callbacks, without showing
           the status item. macOS needs this even when only the Dock icon
           keeps the app alive: constructing MacosTray installs the reopen
           handler that brings the hidden window back. */
        private void ensure_tray_backend () {
            if (tray != null) return;
#if MACOS
            tray = new MacosTray ();
#else
            var conn = this.application.get_dbus_connection ();
            if (conn == null) return;
            tray = new TrayIcon (conn);
#endif
            tray.show_on_current_desktop_requested.connect (
                show_from_tray_on_current_desktop);
            tray.window_toggle_requested.connect (
                toggle_window_from_tray);
            tray.quit_requested.connect (() => {
                handle_primary_q ();
            });
            tray.notifications_toggle_requested.connect ((enabled) => {
                set_notifications_enabled (enabled);
            });
        }

        private bool ensure_tray_visible () {
            if (!settings.minimize_to_tray) return false;

            ensure_tray_backend ();
            if (tray == null) return false;
            tray.set_notifications_enabled (settings.notifications_enabled);
            tray.set_window_visible (this.visible);
            return tray.show ();
        }

        private void minimize_to_tray () {
            close_active_modal ();
            this.set_visible (false);
            if (!held_in_background) {
                this.application.hold ();
                held_in_background = true;
            }
        }

        private void close_active_modal () {
            if (active_modal == null) return;
            var dialog = active_modal;
            active_modal = null;
            dialog.close ();
        }

        public void restore_from_tray () {
            release_background_hold ();
            this.present ();
        }

        /* The menu item toggles on the real window state, not the label the
           menu happens to show, so a stale label still does the right thing. */
        private void toggle_window_from_tray (string? activation_token) {
            if (this.visible) {
                minimize_to_tray ();
                return;
            }
            show_from_tray_on_current_desktop (activation_token);
        }

        private void show_from_tray_on_current_desktop (
                string? activation_token) {
            release_background_hold ();
            if (activation_token != null && activation_token.length > 0 &&
                request_activation_on_current_desktop (activation_token)) {
                return;
            }
            this.present ();
        }

        /* Re-activate with the tray click token so GTK presents Parla on the current desktop. */
        private bool request_activation_on_current_desktop (string token) {
            var app = this.application;
            if (app == null || app.application_id == null) return false;
            var conn = app.get_dbus_connection ();
            var path = app.get_dbus_object_path ();
            if (conn == null || path == null) return false;

            var platform_data = new VariantBuilder (new VariantType ("a{sv}"));
            platform_data.add (
                "{sv}", "activation-token", new Variant.string (token));
            platform_data.add (
                "{sv}", "desktop-startup-id", new Variant.string (token));
            conn.call.begin (
                app.application_id, path, "org.gtk.Application", "Activate",
                new Variant.tuple ({ platform_data.end () }),
                null, DBusCallFlags.NO_AUTO_START, -1, null,
                (obj, res) => {
                    try {
                        conn.call.end (res);
                    } catch (Error e) {
                        debug ("Tray activation fallback: %s", e.message);
                        this.present ();
                    }
                });
            return true;
        }

        private void release_background_hold () {
            if (!held_in_background) return;
            held_in_background = false;
            this.application.release ();
        }

        public void set_notifications_enabled (bool enabled) {
            settings.save_notifications_enabled (enabled);
            if (tray != null) tray.set_notifications_enabled (enabled);
            if (!enabled && events != null) {
                events.reconcile_desktop_notifications.begin ();
            }
        }

        private void build_ui () {
            /* ---- Sidebar ---- */
            sidebar_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            sidebar_header = new Adw.HeaderBar ();
            configure_phone_header (sidebar_header);
            sidebar_title = new Adw.WindowTitle ("Parla", "");
            sidebar_header.title_widget = sidebar_title;

            /* Profile/account menu button in header */
            profile_avatar = new Adw.Avatar (24, "", true);
            account_popover = build_account_popover ();
            account_popover.map.connect (() => {
                load_account_menu.begin ();
            });

            /* Small red dot stuck on the bottom-right of the avatar, shown when
               the current account has pending (notification-worthy) messages.
               The numeric counter lives only in the account list menu. */
            profile_unread_badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            profile_unread_badge.add_css_class ("account-unread-dot");
            profile_unread_badge.halign = Gtk.Align.END;
            profile_unread_badge.valign = Gtk.Align.END;
            profile_unread_badge.visible = false;

            var avatar_overlay = new Gtk.Overlay ();
            avatar_overlay.child = profile_avatar;
            avatar_overlay.add_overlay (profile_unread_badge);

            account_menu_button = new Gtk.MenuButton ();
            account_menu_button.child = avatar_overlay;
            account_menu_button.add_css_class ("flat");
            account_menu_button.add_css_class ("circular");
            account_menu_button.tooltip_text = "Account Menu (%s)".printf (
                Platform.primary_shortcut_text ("Shift+A"));
            /* GTK 4.22 widened the C setter from GtkPopover* to GtkWidget*,
               while Vala 0.56 still emits the old pointer type. The GObject
               property is stable across both signatures. */
            account_menu_button.set ("popover", account_popover);
            sidebar_header.pack_start (account_menu_button);

            /* Hamburger menu button on the right */
            sidebar_menu_button = new Gtk.MenuButton ();
            sidebar_menu_button.icon_name = "open-menu-symbolic";
            sidebar_menu_button.tooltip_text = "Main Menu";
            sidebar_menu_button.add_css_class ("flat");
            sidebar_menu_button.set ("popover", build_app_menu ());
            sidebar_menu_button.primary = true;
            sidebar_header.pack_end (sidebar_menu_button);


            sidebar_box.append (sidebar_header);

            /* Search */
            search_entry = new Gtk.SearchEntry ();
            search_entry.placeholder_text = "Search contacts…";
            search_entry.margin_start = 8;
            search_entry.margin_end = 8;
            search_entry.margin_top = 4;
            search_entry.margin_bottom = 4;
            search_entry.search_changed.connect (() => {
                chat_listbox.invalidate_filter ();
            });
            /* Return opens the first chat matching the search and puts the
               caret in the message entry; Tab/Down move focus into the chat
               list so it can be walked with the arrow keys. */
            search_entry.activate.connect (() => {
                var row = first_visible_chat_row ();
                if (row == null) return;
                var chat_row = row.child as ChatRow;
                if (chat_row == null) return;
                select_chat_by_id (chat_row.chat_id);
                search_entry.text = "";
                var v = current_view ();
                if (v != null) v.focus_entry ();
            });
            var search_keys = new Gtk.EventControllerKey ();
            search_keys.key_pressed.connect ((keyval, keycode, state) => {
                if ((state & (Gdk.ModifierType.CONTROL_MASK |
                              Gdk.ModifierType.SHIFT_MASK |
                              Gdk.ModifierType.ALT_MASK)) != 0) return false;
                if (keyval == Gdk.Key.Down || keyval == Gdk.Key.KP_Down ||
                    keyval == Gdk.Key.Tab || keyval == Gdk.Key.KP_Tab) {
                    var row = first_visible_chat_row ();
                    if (row != null) {
                        row.grab_focus ();
                        return true;
                    }
                }
                return false;
            });
            search_entry.add_controller (search_keys);
            sidebar_box.append (search_entry);

            /* Archived-chats toggle. Hidden until the account actually has
               archived chats; flips the list between normal and archived. */
            archived_btn_content = new Adw.ButtonContent ();
            archived_btn_content.icon_name = "archive-symbolic";
            archived_toggle_btn = new Gtk.Button ();
            archived_toggle_btn.child = archived_btn_content;
            archived_toggle_btn.add_css_class ("flat");
            archived_toggle_btn.margin_start = 8;
            archived_toggle_btn.margin_end = 8;
            archived_toggle_btn.margin_bottom = 4;
            archived_toggle_btn.visible = false;
            archived_toggle_btn.clicked.connect (() => {
                toggle_archived_view ();
            });
            sidebar_box.append (archived_toggle_btn);

            /* Chat list */
            var chat_scroll = new Gtk.ScrolledWindow ();
            chat_scroll.vexpand = true;
            chat_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            chat_listbox = new Gtk.ListBox ();
            /* No GTK selection: with SINGLE mode the selection follows the
               keyboard cursor, so arrowing through the list would open (and
               mark as read) every chat passed on the way. Arrow keys only
               move the focus ring; Enter or a click activates the row and
               opens the chat, and the open chat's row is highlighted by
               mark_current_chat_row. */
            chat_listbox.selection_mode = Gtk.SelectionMode.NONE;
            chat_listbox.add_css_class ("navigation-sidebar");
            chat_listbox.set_filter_func (filter_chats);
            chat_listbox.row_activated.connect ((row) => {
                open_chat_row (row);
                /* Activation commits to the chat, so move the caret to the
                   message entry. */
                var view = current_view ();
                if (view != null) view.focus_entry ();
            });

            /* Right-click context menu */
            var right_click = new Gtk.GestureClick ();
            right_click.button = 3; /* secondary button */
            right_click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            right_click.pressed.connect ((n, x, y) => {
                var row = chat_listbox.get_row_at_y ((int) y);
                if (row == null) return;
                var chat_row = row.child as ChatRow;
                if (chat_row == null) return;
                right_click.set_state (Gtk.EventSequenceState.CLAIMED);
                if (chat_menu != null)
                    chat_menu.show (chat_row.chat_id, x, y, chat_listbox);
            });
            chat_listbox.add_controller (right_click);

            /* Ctrl+Tab / Ctrl+Shift+Tab are GTK's chord for leaving a widget
               that consumes plain Tab. GtkListBox walks its rows on Tab (with
               or without Ctrl), so make the chord actually jump out of the
               list: backwards to the contact search entry, forwards to the
               message entry. This is plain Ctrl on every platform (not the
               primary modifier), matching GTK's own binding (#57). */
            var list_keys = new Gtk.EventControllerKey ();
            list_keys.key_pressed.connect ((keyval, keycode, state) => {
                if ((state & Gdk.ModifierType.CONTROL_MASK) == 0) return false;
                if ((state & Gdk.ModifierType.ALT_MASK) != 0) return false;
                if (keyval != Gdk.Key.Tab && keyval != Gdk.Key.ISO_Left_Tab &&
                    keyval != Gdk.Key.KP_Tab) return false;
                bool backward = (state & Gdk.ModifierType.SHIFT_MASK) != 0 ||
                                keyval == Gdk.Key.ISO_Left_Tab;
                if (backward) {
                    /* Hidden in compact sidebar mode; let GTK handle it then. */
                    if (!search_entry.visible) return false;
                    search_entry.grab_focus ();
                    return true;
                }
                /* In collapsed (mobile) mode the conversation is not on
                   screen while the list is; leave the default behaviour. */
                if (split_view.collapsed) return false;
                var v = current_view ();
                if (v == null) return false;
                v.focus_entry ();
                return true;
            });
            chat_listbox.add_controller (list_keys);

            chat_scroll.child = chat_listbox;
            sidebar_box.append (chat_scroll);

            /* ---- Content area ---- */
            var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            content_box.hexpand = true;
            content_box.vexpand = true;
            content_box.halign = Gtk.Align.FILL;
            content_box.valign = Gtk.Align.FILL;

            content_header = new Adw.HeaderBar ();
            configure_phone_header (content_header);
            content_title_label = new Gtk.Label ("Select a chat");
            content_title_label.add_css_class ("heading");
            content_title_label.ellipsize = Pango.EllipsizeMode.END;
            content_mute_icon = new Gtk.Image.from_icon_name (
                "notifications-disabled-symbolic");
            content_mute_icon.pixel_size = 14;
            content_mute_icon.add_css_class ("dim-label");
            content_mute_icon.tooltip_text = "Notifications muted";
            content_mute_icon.visible = false;
            var content_title_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            content_title_box.append (content_title_label);
            content_title_box.append (content_mute_icon);
            content_header.title_widget = content_title_box;

            /* Sidebar visibility button. On collapsed/mobile widths this
               opens the sidebar as the full-width overlay instead of compact. */
            sidebar_toggle_btn = new Gtk.Button.from_icon_name ("sidebar-show-symbolic");
            sidebar_toggle_btn.add_css_class ("flat");
            sidebar_toggle_btn.clicked.connect (() => { toggle_sidebar_button (); });
            content_header.pack_start (sidebar_toggle_btn);

            /* Per-conversation actions on the right side. Only meaningful
               with a conversation open, so they stay hidden on the empty
               page — see update_conversation_header_actions(). pack_end
               places the first-packed child rightmost, so the gallery
               button ends up to the right of the search button. */
            gallery_btn = new Gtk.Button.from_icon_name ("view-grid-symbolic");
            gallery_btn.tooltip_text = "Apps and media (%s)".printf (
                Platform.primary_shortcut_text ("M"));
            gallery_btn.clicked.connect (() => { show_gallery_dialog (); });
            content_header.pack_end (gallery_btn);

            message_search_btn = new Gtk.Button.from_icon_name ("edit-find-symbolic");
            message_search_btn.tooltip_text = "Search in conversation (%s)".printf (
                Platform.primary_shortcut_text ("F"));
            message_search_btn.clicked.connect (() => { toggle_message_search (); });
            content_header.pack_end (message_search_btn);

            update_conversation_header_actions ();

            content_box.append (content_header);

            /* Stack: empty status + one child per chat view (added lazily) */
            content_stack = new Gtk.Stack ();
            content_stack.hexpand = true;
            content_stack.vexpand = true;
            content_stack.halign = Gtk.Align.FILL;
            content_stack.valign = Gtk.Align.FILL;

            empty_status = new Adw.StatusPage ();
            empty_status.icon_name = "parla-welcome";
            empty_status.title = "Welcome to Parla";
            empty_status.description = "Select a chat to start messaging";
            content_stack.add_named (empty_status, "empty");
            content_stack.visible_child_name = "empty";
            content_box.append (content_stack);

            /* ---- Split view ---- */
            split_view = new Adw.OverlaySplitView ();
            split_view.sidebar = sidebar_box;
            split_view.content = content_box;
            split_view.max_sidebar_width = FULL_SIDEBAR_MAX_WIDTH;
            split_view.min_sidebar_width = FULL_SIDEBAR_MIN_WIDTH;
            split_view.sidebar_width_fraction = 0.32;
            split_view.enable_show_gesture = true;
            split_view.enable_hide_gesture = true;

            toast_overlay = new Adw.ToastOverlay ();
            toast_overlay.child = split_view;

            /* Auto-collapse on narrow widths — sidebar slides over content */
            string collapse_condition = Platform.is_sailfish ()
                ? "max-width: 720px" : "max-width: 600px";
            var breakpoint = new Adw.Breakpoint (
                Adw.BreakpointCondition.parse (collapse_condition));
            breakpoint.add_setter (split_view, "collapsed", true);
            this.add_breakpoint (breakpoint);

            /* min-sidebar-width is a hard minimum for the whole split view
               even while collapsed and hidden, so below ~280px it would force
               the window minimum to 260px and GTK would warn-loop at 100%
               CPU. Let the sidebar narrow along with the window instead. */
            var narrow_bp = new Adw.Breakpoint (
                Adw.BreakpointCondition.parse ("max-width: 280px"));
            narrow_bp.add_setter (split_view, "min-sidebar-width", 220.0);
            this.add_breakpoint (narrow_bp);

            /* When the window widens out of the collapsed breakpoint, re-apply
               the persisted mode so a chat-selected-while-narrow doesn't leave
               the sidebar stuck hidden. */
            split_view.notify["collapsed"].connect (() => {
                apply_sidebar_mode (!split_view.collapsed);
            });

            /* The sidebar always starts visible: hiding it (Ctrl+S) is a
               within-session state, not a preference worth restoring —
               a fresh launch with no chat list reads as broken. The
               FULL/COMPACT width choice does persist. */
            if (settings.sidebar_mode == SidebarMode.HIDDEN) {
                settings.save_sidebar_mode (SidebarMode.FULL);
            }
            apply_sidebar_mode (true);

            /* Fullscreen image viewer overlay */
            var image_overlay = new Gtk.Overlay ();
            image_overlay.child = toast_overlay;
            image_overlay.add_overlay (image_viewer.widget);
            image_overlay.add_overlay (video_player.widget);
            image_overlay.add_overlay (build_connection_banner ());

            this.content = image_overlay;

            /* Global keyboard shortcuts */
            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            key_ctrl.key_pressed.connect (on_window_key_pressed);
            ((Gtk.Widget) this).add_controller (key_ctrl);

            /* Ctrl+wheel font zoom, scoped to the chat content area: over
               the sidebar, dialogs (gallery, settings…) or the fullscreen
               viewers the wheel must not change a font the user cannot
               see. Those contexts handle the wheel themselves or ignore
               it. */
            var scroll_ctrl = new Gtk.EventControllerScroll (
                Gtk.EventControllerScrollFlags.VERTICAL |
                Gtk.EventControllerScrollFlags.DISCRETE);
            scroll_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            scroll_ctrl.scroll.connect (on_chat_scroll);
            content_stack.add_controller (scroll_ctrl);
        }

        private static void configure_phone_header (Adw.HeaderBar header) {
            if (!Platform.is_sailfish ()) return;
            /* Lipstick owns the phone window; desktop minimize/maximize/close
               buttons waste scarce header space and have no useful meaning. */
            header.show_start_title_buttons = false;
            header.show_end_title_buttons = false;
        }

        private Gtk.Popover build_account_popover () {
            var popover = new Gtk.Popover ();
            popover.has_arrow = true;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            box.margin_start = 10;
            box.margin_end = 10;
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.width_request = 300;

            var title = new Gtk.Label ("Profiles");
            title.add_css_class ("heading");
            title.halign = Gtk.Align.START;
            title.xalign = 0;
            box.append (title);

            account_menu_list = new Gtk.ListBox ();
            account_menu_list.selection_mode = Gtk.SelectionMode.NONE;
            account_menu_list.add_css_class ("boxed-list");
            account_menu_list.row_activated.connect (on_account_menu_row_activated);
            box.append (account_menu_list);

            popover.child = box;
            return popover;
        }

        private async void try_connect () {
            rpc = ((Dc.Application) this.application).rpc;

            /* Reset any error widget left from a previous failed attempt. */
            show_empty_status ("parla-welcome", "Welcome to Parla",
                "Select a chat to start messaging");

            /* Find the RPC server binary. Auto mode uses Parla/distro-owned
               standalone servers; Custom uses the explicit configured path. */
            string? rpc_path = AccountFinder.find_rpc_server (
                settings.effective_rpc_server_path (),
                settings.effective_rpc_server_source ());
            if (rpc_path == null) {
                set_connection_status (false, "RPC server not found");
                show_rpc_not_found ();
                return;
            }

            string data_dir = AccountFinder.get_data_dir ();
            string accounts_path = settings.effective_accounts_path ();

            /* Try to connect */
            try {
                yield rpc.start ({ rpc_path }, data_dir, accounts_path);
            } catch (Error e) {
                string msg = e.message;
                if ("already running" in msg.down () || "accounts.lock" in msg.down ()) {
                    show_toast ("Cannot connect - account store is already in use");
                    empty_status.description =
                        "The Delta Chat account store is already in use.\n\n" +
                        "Close the other Delta Chat or Parla process, then restart this app.";
                    set_connection_status (false, "Account store is already in use");
                } else {
                    show_toast ("RPC server error: " + msg);
                    empty_status.description = "Failed to start RPC server:\n\n" + Markup.escape_text (msg);
                    set_connection_status (false, "Cannot reach RPC server");
                }
                return;
            }

            /* Connected — hide any banner from a prior failure and register
               a handler in case the server goes away later. */
            set_connection_status (true);
            rpc.disconnected.connect ((reason) => {
                set_connection_status (false, "Disconnected — " + reason);
            });

            /* If we're running Parla's own downloaded server, optionally check
               for a newer release in the background and offer to update. */
            if (settings.rpc_auto_update_enabled () &&
                rpc_path == AccountFinder.get_managed_rpc_path ()) {
                check_managed_update.begin ();
            }

            /* Ensure we have an account */
            string? acct_desc, acct_toast;
            yield AccountFinder.ensure_configured (rpc,
                                                    settings.default_account_addr,
                                                    out acct_desc, out acct_toast);
            if (acct_toast != null) show_toast (acct_toast);
            if (acct_desc != null) empty_status.description = acct_desc;
            if (rpc.account_id > 0) {
                try {
                    yield apply_auto_download_limit ();
                    yield rpc.start_io_for_all_accounts ();
                } catch (Error e) {
                    show_toast ("Connection setup error: " + e.message);
                }
                refresh_tracking_filter.begin (false);
            }

            /* Create event handler and message actions now that rpc is ready */
            events = new EventHandler (rpc);
            Webxdc.setup (rpc, settings);
            events.set_app (this.application);
            events.chats_reload_fired.connect (() => {
                load_chats.begin ();
            });
            events.messages_reload_fired.connect (() => {
                var v = current_view ();
                if (v != null) v.reload_messages.begin ();
            });
            events.incoming_msg_received.connect ((acct_id, chat_id, msg_id) => {
                on_incoming_msg.begin (acct_id, chat_id, msg_id);
            });
            events.incoming_reaction_received.connect (
                (acct_id, chat_id, msg_id, contact_id, reaction) => {
                queue_chat_notification (acct_id, chat_id, msg_id,
                                         contact_id, reaction);
            });
            events.chat_messages_changed.connect ((acct_id, chat_id) => {
                on_chat_messages_changed (acct_id, chat_id);
            });
            events.account_unread_changed.connect ((acct_id) => {
                update_unread_indicators.begin ();
            });
            events.contacts_changed.connect ((acct_id) => {
                invalidate_all_mention_rosters ();
                refresh_self_mention_keys.begin ();
            });

            chat_menu = new ChatContextMenu (this, rpc, chat_store);
            if (rpc.account_id > 0) {
                yield load_self_identity ();
                yield load_chats ();
                yield load_profile_avatar ();
                events.start.begin ();
                events.reconcile_desktop_notifications.begin ();

                /* A link that arrived before the profile was ready (e.g. the
                   app was cold-started by clicking it) waited here. */
                if (pending_invite_uri != null) {
                    string uri = pending_invite_uri;
                    pending_invite_uri = null;
                    show_use_invite_link_dialog (uri);
                }
            }
        }

        private void clear_self_identity () {
            rpc.self_email = null;
            MessageRow.self_display_name = null;
            MessageRow.self_avatar_path = null;
            self_mention_keys_cache = {};
            mentioned_chats.remove_all ();
        }

        /* Down-cased tokens that count as "me" for mention detection: the
           display name plus every transport address of the current account. */
        public string[] self_mention_keys () {
            return self_mention_keys_cache;
        }

        private async void refresh_self_mention_keys () {
            var keys = new GenericArray<string> ();
            if (MessageRow.self_display_name != null
                && MessageRow.self_display_name.strip ().length > 0) {
                keys.add (MessageRow.self_display_name.strip ().down ());
            }
            if (rpc.self_email != null && rpc.self_email.length > 0) {
                keys.add (rpc.self_email.down ());
            }
            try {
                var transports = yield rpc.list_transports (rpc.account_id);
                if (transports != null
                    && transports.get_node_type () == Json.NodeType.ARRAY) {
                    var arr = transports.get_array ();
                    for (uint i = 0; i < arr.get_length (); i++) {
                        var obj = arr.get_object_element (i);
                        string? addr = obj != null ? json_str (obj, "addr") : null;
                        if (addr != null && addr.length > 0) keys.add (addr.down ());
                    }
                }
            } catch (Error e) { /* transports optional */ }

            string[] result = {};
            for (int i = 0; i < keys.length; i++) result += keys[i];
            self_mention_keys_cache = result;
        }

        /* Detect whether an incoming message mentions the local user and, if so,
           flag the chat in the sidebar and fire a notification that ignores mute
           (mentions should always reach the user). Best-effort for background
           accounts (name/address only, no transports). */
        private async void check_mention (int acct_id, int chat_id, int msg_id) {
            string[] keys = acct_id == rpc.account_id
                ? self_mention_keys_cache
                : yield background_self_keys (acct_id);
            if (keys.length == 0) return;

            Message? msg = null;
            try {
                msg = yield rpc.fetch_message_for (acct_id, msg_id, null);
            } catch (Error e) {
                return;
            }
            if (msg == null || msg.is_outgoing) return;
            if (!Mentions.mentions_self (msg.text, keys)) return;

            /* Already looking at it: nothing to flag or notify. */
            bool looking = acct_id == rpc.account_id
                && chat_id == current_chat_id && this.is_active;
            if (looking) return;

            if (acct_id == rpc.account_id && !mentioned_chats.contains (chat_id)) {
                mentioned_chats.add (chat_id);
                request_reload_chats ();
            }

            if (events != null && settings.notifications_enabled) {
                string title = msg.sender_name ?? msg.sender_address
                    ?? "New mention";
                string body = (msg.text != null && msg.text.length > 0)
                    ? msg.text : "Mentioned you";
                events.send_mention_notification (acct_id, chat_id,
                    "@ " + title, body);
            }
        }

        private async string[] background_self_keys (int acct_id) {
            string[] keys = {};
            try {
                string? dn = yield rpc.get_config ("displayname", acct_id);
                if (dn != null && dn.strip ().length > 0)
                    keys += dn.strip ().down ();
            } catch (Error e) { }
            try {
                string? addr = yield rpc.get_config ("addr", acct_id);
                if (addr != null && addr.length > 0) keys += addr.down ();
            } catch (Error e) { }
            return keys;
        }

        /* Rebuild mention rosters after a contact/membership change. */
        public void invalidate_all_mention_rosters () {
            var iter = HashTableIter<int, ConversationView> (views);
            int key;
            ConversationView v;
            while (iter.next (out key, out v)) {
                v.invalidate_mention_roster ();
            }
        }

        /* Open (or create) a direct chat for a clicked mention link. The href
           is "parla-mention:cid=N" or "parla-mention:addr=<email>". */
        public void open_mention (string uri) {
            if (!uri.has_prefix ("parla-mention:")) return;
            string spec = uri.substring ("parla-mention:".length);
            if (spec.has_prefix ("cid=")) {
                int cid = int.parse (spec.substring (4));
                if (cid > 0) open_mention_contact.begin (cid);
            } else if (spec.has_prefix ("addr=")) {
                string addr = Uri.unescape_string (spec.substring (5))
                    ?? spec.substring (5);
                open_mention_address.begin (addr);
            }
        }

        private async void open_mention_contact (int contact_id) {
            try {
                int chat_id = yield rpc.get_or_create_chat_by_contact (contact_id);
                if (chat_id <= 0) return;
                yield load_chats ();
                select_chat_by_id (chat_id);
            } catch (Error e) {
                show_toast ("Could not open chat: " + e.message);
            }
        }

        private async void open_mention_address (string address) {
            try {
                int contact_id = yield rpc.get_or_create_contact (address);
                if (contact_id <= 0) return;
                yield open_mention_contact (contact_id);
            } catch (Error e) {
                show_toast ("Could not open chat: " + e.message);
            }
        }

        private async void load_self_identity () {
            try {
                rpc.self_email = yield rpc.get_config ("addr", rpc.account_id);
            } catch (Error e) {
                rpc.self_email = null;
            }
            try {
                MessageRow.self_display_name =
                    yield rpc.get_config ("displayname", rpc.account_id);
            } catch (Error e) {
                MessageRow.self_display_name = null;
            }
            try {
                MessageRow.self_avatar_path =
                    yield rpc.get_config ("selfavatar", rpc.account_id);
            } catch (Error e) {
                MessageRow.self_avatar_path = null;
            }
            yield refresh_self_mention_keys ();
        }

        private void show_rpc_not_found () {
            /* Whenever a prebuilt binary exists for this architecture we offer a
               one-click download — regardless of the configured source — and the
               install switches the source to Auto so the downloaded binary is
               picked up. Custom choices still get their specific error text,
               but the download is the primary action. */
            bool can_download = RpcInstaller.can_auto_install () &&
                !SettingsManager.rpc_server_path_is_fixed ();

            string icon_name = "dialog-error-symbolic";
            string title = "RPC server not found";
            string description;
            if (settings.effective_rpc_server_source () == RpcServerSource.CUSTOM &&
                settings.effective_rpc_server_path ().length > 0) {
                description =
                    "Configured path is missing or not executable:\n" +
                    Markup.escape_text (settings.effective_rpc_server_path ()) +
                    (can_download ? "\n\nDownload the engine to use it instead." : "");
            } else if (can_download) {
                icon_name = "parla-welcome";
                title = "Welcome to Parla";
                description =
                    "Parla needs the Delta Chat engine to connect.\n" +
                    "Download it once to get started.";
            } else {
                title = "Delta Chat engine required";
                description =
                    "No prebuilt deltachat-rpc-server is available for this\n" +
                    "architecture. Install it manually (see docs/rpc-server.md)\n" +
                    "or choose a binary in Settings.";
            }

            Gtk.Widget child;
            if (can_download) {
                var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
                box.halign = Gtk.Align.CENTER;

                var dl = new Gtk.Button.with_label ("Download & start");
                dl.add_css_class ("suggested-action");
                dl.add_css_class ("pill");
                dl.halign = Gtk.Align.CENTER;
                dl.clicked.connect (() => { install_and_connect.begin (); });
                box.append (dl);

                var settings_link = new Gtk.Button.with_label ("Open Settings…");
                settings_link.add_css_class ("flat");
                settings_link.halign = Gtk.Align.CENTER;
                settings_link.clicked.connect (show_settings_dialog);
                box.append (settings_link);

                child = box;
            } else {
                var btn = new Gtk.Button.with_label ("Open Settings…");
                btn.add_css_class ("suggested-action");
                btn.add_css_class ("pill");
                btn.halign = Gtk.Align.CENTER;
                btn.clicked.connect (show_settings_dialog);
                child = btn;
                show_toast ("deltachat-rpc-server not found");
            }

            show_empty_status (icon_name, title, description, child);
        }

        /* One-click onboarding: download the managed server, then reconnect. */
        private async void install_and_connect () {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            box.halign = Gtk.Align.CENTER;
            var spinner = new Gtk.Spinner ();
            spinner.spinning = true;
            spinner.set_size_request (32, 32);
            box.append (spinner);
            var label = new Gtk.Label ("Downloading Delta Chat engine…");
            label.add_css_class ("dim-label");
            box.append (label);

            show_empty_status ("folder-download-symbolic", "Setting up Parla",
                "", box);

            var installer = new RpcInstaller ();
            installer.progress.connect ((received, total) => {
                if (total > 0) {
                    double pct = (double) received / (double) total * 100.0;
                    label.label =
                        "Downloading Delta Chat engine… %.0f%% (%.1f MB)".printf (
                            pct, total / 1048576.0);
                } else {
                    label.label = "Downloading Delta Chat engine… %.1f MB".printf (
                        received / 1048576.0);
                }
            });

            try {
                yield installer.download_latest ();
            } catch (Error e) {
                show_toast ("Download failed: " + e.message);
                show_rpc_not_found ();
                return;
            }

            /* The downloaded binary lives in the Auto search path, so make sure
               we resolve it on reconnect even if the source was Custom. */
            if (settings.rpc_server_source != RpcServerSource.AUTO) {
                settings.save_rpc_server_source (RpcServerSource.AUTO);
            }

            show_toast ("Delta Chat engine installed");
            yield reconnect_rpc_server ();
        }

        /**
         * Downloads the uBlock/AdGuard removeparam list configured in
         * Settings → Links and installs it as the active link cleaner.
         * Without `force` the cached copy is kept until it expires.
         * Returns null on success, otherwise a message for the user.
         */
        public async string? refresh_tracking_filter (bool force) {
            if (!settings.tracking_filter_enabled) return "Filter list disabled";
            string url = settings.tracking_filter_url;
            if (url.length == 0) return "No filter list URL configured";
            if (rpc == null || rpc.account_id <= 0)
                return "Not connected: the list is downloaded through the "
                       + "active account";
            if (!force) {
                var cached = RemoveParamFilter.active;
                if (cached != null && !cached.cache_is_stale ()) return null;
            }
            uint8[] body;
            string? mimetype;
            try {
                body = yield rpc.get_http_response (url, out mimetype);
            } catch (Error e) {
                warning ("tracking filter: download failed: %s", e.message);
                return "Download failed: " + e.message;
            }
            var sb = new StringBuilder.sized (body.length + 1);
            sb.append_len ((string) body, body.length);
            var filter = RemoveParamFilter.from_text (sb.str);
            if (filter == null)
                return "The downloaded file contains no $removeparam rules";
            if (!RemoveParamFilter.save_cached (sb.str))
                return "Could not save the filter list";
            RemoveParamFilter.active = filter;
            debug ("tracking filter: %d rules from %s", filter.rule_count, url);
            return null;
        }

        /* Quietly check GitHub for a newer managed server and offer to update. */
        private async void check_managed_update () {
            try {
                string? installed = yield RpcInstaller.installed_version ();
                if (installed == null) return;
                string tag = yield RpcInstaller.fetch_latest_tag ();
                string? latest = RpcInstaller.extract_version (tag);
                string? current = RpcInstaller.extract_version (installed);
                if (latest == null || current == null || latest == current) return;

                var toast = new Adw.Toast (
                    "Delta Chat engine update available: %s".printf (latest));
                toast.timeout = 8;
                toast.button_label = "Update";
                toast.button_clicked.connect (() => {
                    update_managed_server.begin ();
                });
                toast_overlay.add_toast (toast);
            } catch (Error e) {
                /* Update checks are best-effort; stay quiet on failure. */
            }
        }

        private async void update_managed_server () {
            show_toast ("Updating Delta Chat engine…");
            var installer = new RpcInstaller ();
            try {
                yield installer.download_latest ();
                show_toast ("Update installed");
                yield reconnect_rpc_server ();
            } catch (Error e) {
                show_toast ("Update failed: " + e.message);
            }
        }

        public async void reconnect_rpc_server () {
            if (reconnecting_rpc) return;
            reconnecting_rpc = true;

            var app = (Dc.Application) this.application;
            /* Close views while their old RPC object is still valid. */
            discard_all_views ();
            app.reset_rpc_client ();
            rpc = app.rpc;
            events = null;
            chat_menu = null;
            current_chat_id = 0;

            reset_chat_ui ();
            profile_unread_badge.visible = false;

            show_empty_status ("parla-welcome", "Connecting",
                "Starting Delta Chat engine…");
            set_connection_status (false, "Reconnecting…");

            yield try_connect ();
            reconnecting_rpc = false;
        }

        public void clear_chat_view () {
            current_chat_id = 0;
            mark_current_chat_row (null);
            content_title_label.label = "Select a chat";
            content_mute_icon.visible = false;
            show_empty_status ("parla-welcome", "Parla",
                "Select a chat to start messaging.");
        }

        public ConversationView? current_view () {
            if (current_chat_id <= 0) return null;
            return views.lookup (current_chat_id);
        }

        private ConversationView get_or_create_view (int chat_id,
                                                     ChatKind kind = ChatKind.UNKNOWN) {
            var v = views.lookup (chat_id);
            if (v != null) {
                touch_cached_view (chat_id);
                v.set_chat_kind (kind);
                return v;
            }
            v = new ConversationView (chat_id, this, rpc, settings, kind);
            views.insert (chat_id, v);
            content_stack.add_named (v, "chat_%d".printf (chat_id));
            touch_cached_view (chat_id);
            evict_cached_views (chat_id);
            return v;
        }

        private void touch_cached_view (int chat_id) {
            int[] next = {};
            foreach (int id in view_recency) {
                if (id != chat_id) next += id;
            }
            next += chat_id;
            view_recency = next;
        }

        private void forget_cached_view (int chat_id) {
            int[] next = {};
            foreach (int id in view_recency) {
                if (id != chat_id) next += id;
            }
            view_recency = next;
        }

        private void evict_cached_views (int keep_chat_id) {
            while (views.size () > MAX_CACHED_CONVERSATION_VIEWS) {
                int candidate = 0;
                foreach (int id in view_recency) {
                    if (id != keep_chat_id && id != current_chat_id) {
                        candidate = id;
                        break;
                    }
                }
                if (candidate <= 0) return;
                remove_cached_view (candidate);
            }
        }

        private void remove_cached_view (int chat_id) {
            var view = views.lookup (chat_id);
            if (view == null) {
                forget_cached_view (chat_id);
                return;
            }
            view.close ();
            content_stack.remove (view);
            views.remove (chat_id);
            forget_cached_view (chat_id);
        }

        public void request_messages_reload () {
            if (events != null) events.schedule_messages_reload ();
        }

        public void request_chat_messages_reload (int chat_id) {
            if (chat_id <= 0) return;
            var v = views.lookup (chat_id);
            if (v != null) v.reload_messages.begin ();
        }

        private void toggle_archived_view () {
            showing_archived = !showing_archived;
            search_entry.text = "";
            update_archived_toggle ();
            load_chats.begin ();
        }

        private void update_archived_toggle () {
            if (archived_toggle_btn == null) return;
            bool compact = settings.sidebar_mode == SidebarMode.COMPACT;
            archived_toggle_btn.visible = showing_archived || archived_count > 0;
            if (showing_archived) {
                archived_btn_content.icon_name = "go-previous-symbolic";
                archived_btn_content.label = compact ? "" : "Back to Chats";
                archived_toggle_btn.tooltip_text = "Back to Chats";
            } else {
                archived_btn_content.icon_name = "archive-symbolic";
                archived_btn_content.label = compact ? ""
                    : "Archived Chats (%d)".printf (archived_count);
                archived_toggle_btn.tooltip_text = "Show Archived Chats";
            }
        }

        public async void load_chats () {
            if (rpc.account_id <= 0) return;

            try {
                /* The main list drops core's special entries (the "archived
                   chats" pseudo-chat used to show up as an empty row). */
                var entries = yield rpc.get_chatlist_entries_for (
                    rpc.account_id, null,
                    showing_archived ? RpcClient.GCL_ARCHIVED_ONLY
                                     : RpcClient.GCL_NO_SPECIALS);
                if (entries == null) return;

                if (showing_archived) {
                    archived_count = (int) entries.get_length ();
                    if (archived_count == 0) {
                        /* Last chat left the archive: fall back to the
                           normal list instead of showing an empty one. */
                        showing_archived = false;
                        update_archived_toggle ();
                        yield load_chats ();
                        return;
                    }
                } else {
                    var archived = yield rpc.get_chatlist_entries_for (
                        rpc.account_id, null, RpcClient.GCL_ARCHIVED_ONLY);
                    archived_count = archived != null
                        ? (int) archived.get_length () : 0;
                }
                update_archived_toggle ();

                var items = yield rpc.get_chatlist_items_by_entries_for (
                    rpc.account_id, entries);

                int desired_chat_id = current_chat_id;
                bool keep_empty_selection = desired_chat_id <= 0;
                var shown_entry = find_chat_entry (chat_store, desired_chat_id);

                ChatEntry[] parsed_entries = {};
                int[] preview_msg_ids = {};
                for (uint i = 0; i < entries.get_length (); i++) {
                    int chat_id = (int) entries.get_int_element (i);
                    string id_str = chat_id.to_string ();

                    if (items != null && items.has_member (id_str)) {
                        var item = items.get_object_member (id_str);
                        var entry = RpcParsers.parse_chat_item (chat_id, item);
                        entry.has_mention = mentioned_chats.contains (chat_id);
                        /* The open chat keeps the preview it already shows
                           instead of echoing the draft being typed into it.
                           Every draft save would otherwise rewrite its row,
                           and screen readers read the changed row out on
                           each pause in typing. The draft shows up in the
                           list once another chat is opened. */
                        bool frozen = entry.is_draft && shown_entry != null
                                      && chat_id == desired_chat_id;
                        if (frozen) {
                            entry.summary_prefix = shown_entry.summary_prefix;
                            entry.last_message = shown_entry.last_message;
                            entry.last_message_id = shown_entry.last_message_id;
                        }
                        parsed_entries += entry;
                        if (entry.last_message_id > 0 && !frozen) {
                            preview_msg_ids += entry.last_message_id;
                        }
                    }
                }
                yield hydrate_chat_text_previews (parsed_entries,
                    preview_msg_ids);

                /* Nothing visible changed (typically a draft save or a
                   notice for the open chat): keep the rows, so focus, the
                   highlight and the accessibility tree stay untouched. */
                if (same_chat_rows (parsed_entries)) return;

                /* Rebuilding the rows destroys the one holding the keyboard
                   focus; remember which chat it was so the user can keep
                   arrowing through the list after the refresh. */
                int focused_chat_id = focused_chat_row_id ();

                chat_store.remove_all ();
                clear_listbox (chat_listbox);
                current_chat_row = null;
                chat_rows_day = today_stamp ();

                Gtk.ListBoxRow? reselect_row = null;
                Gtk.ListBoxRow? refocus_row = null;
                foreach (var entry in parsed_entries) {
                    chat_store.append (entry);

                    var row = new Gtk.ListBoxRow ();
                    var chat_row = new ChatRow (entry);
                    chat_row.set_compact (settings.sidebar_mode == SidebarMode.COMPACT);
                    chat_row.accept_file_drop.connect (() => can_attach_file_to_chat (chat_row.chat_id));
                    chat_row.file_dropped.connect ((path, name) => attach_file_to_chat (chat_row.chat_id, path, name));
                    chat_row.file_drop_failed.connect ((message) => show_toast ("Attach failed: " + message));
                    row.child = chat_row;
#if A11Y
                    row.update_property (Gtk.AccessibleProperty.LABEL,
                        ChatRow.accessible_summary (entry), -1);
#endif
                    chat_listbox.append (row);

                    if (entry.id == focused_chat_id) refocus_row = row;
                    if (entry.id == desired_chat_id) {
                        reselect_row = row;
                        /* Refresh header state that can change while the
                           chat stays open (rename, mute toggled). */
                        content_title_label.label = entry.name;
                        content_mute_icon.visible = entry.is_muted;
                    }
                }

                mark_current_chat_row (reselect_row);
                if (reselect_row == null && !keep_empty_selection) {
                    /* The open chat left the list (deleted, archived). */
                    clear_chat_view ();
                }
                if (refocus_row != null) refocus_row.grab_focus ();
            } catch (Error e) {
                show_toast ("Failed to load chats: " + e.message);
            }
        }

        private static int today_stamp () {
            var now = new DateTime.now_local ();
            return now.get_year () * 1000 + now.get_day_of_year ();
        }

        /* Whether the rows currently in the list already show exactly what
           `entries` describe, so load_chats can leave them alone. */
        private bool same_chat_rows (ChatEntry[] entries) {
            if (entries.length == 0) return false;
            if (chat_store.get_n_items () != entries.length) return false;
            if (chat_rows_day != today_stamp ()) return false;
            for (int i = 0; i < entries.length; i++) {
                var old = chat_store.get_item (i) as ChatEntry;
                if (old == null || !old.same_display (entries[i])) return false;
            }
            return true;
        }

        private async void hydrate_chat_text_previews (ChatEntry[] entries,
                                                       int[] msg_ids) {
            if (entries.length == 0 || msg_ids.length == 0) return;

            try {
                var map = yield rpc.get_messages_for (rpc.account_id, msg_ids);
                if (map == null) return;

                foreach (var entry in entries) {
                    if (entry.last_message_id <= 0) continue;
                    string key = entry.last_message_id.to_string ();
                    if (!map.has_member (key)) continue;

                    var msg = RpcParsers.parse_message (
                        map.get_object_member (key), rpc.self_email);
                    if (!plain_text_preview_message (msg)) continue;
                    entry.last_message = msg.text;
                }
            } catch (Error e) {
                warning ("hydrate_chat_text_previews: %s", e.message);
            }
        }

        private static bool plain_text_preview_message (Message msg) {
            if (msg.text == null || msg.text.strip ().length == 0) return false;
            if (msg.file_path != null && msg.file_path.length > 0) return false;
            if (msg.file_name != null && msg.file_name.length > 0) return false;
            if (msg.is_info) return false;

            if (msg.view_type == null || msg.view_type.length == 0) return true;
            string vt = msg.view_type.down ();
            return vt == "text" || vt == "unknown";
        }

        private bool filter_chats (Gtk.ListBoxRow row) {
            string query = search_entry.text.strip ().down ();
            if (query.length == 0) return true;

            var chat_row = row.child as ChatRow;
            if (chat_row == null) return true;

            var entry = find_chat_entry (chat_store, chat_row.chat_id);
            if (entry != null) {
                return entry.name.down ().contains (query);
            }
            return true;
        }

        private bool chat_list_has_focus () {
            var f = get_focus ();
            return f != null && (f == chat_listbox || f.is_ancestor (chat_listbox));
        }

        private bool can_attach_file_to_chat (int chat_id) {
            var entry = find_chat_entry (chat_store, chat_id);
            if (entry == null || entry.is_contact_request) return false;

            var view = views.lookup (chat_id);
            return view == null || view.can_accept_dropped_file ();
        }

        private void attach_file_to_chat (int chat_id, string path,
                                          string name) {
            if (!can_attach_file_to_chat (chat_id)) {
                show_toast ("Attach failed: cannot attach here");
                return;
            }
            if (!select_chat_by_id (chat_id)) {
                show_toast ("Attach failed: chat is unavailable");
                return;
            }

            var view = current_view ();
            if (view == null) {
                show_toast ("Attach failed: chat is unavailable");
                return;
            }
            view.attach_dropped_file (path, name);
        }

        private ChatRow? chat_row_at_point (double x, double y) {
            Gtk.Widget? widget = pick (x, y, Gtk.PickFlags.DEFAULT);
            while (widget != null && widget != this) {
                var chat_row = widget as ChatRow;
                if (chat_row != null) return chat_row;

                var list_row = widget as Gtk.ListBoxRow;
                if (list_row != null) {
                    chat_row = list_row.child as ChatRow;
                    if (chat_row != null) return chat_row;
                }
                widget = widget.get_parent ();
            }
            return null;
        }

        private Gtk.ListBoxRow? first_visible_chat_row () {
            int idx = 0;
            Gtk.ListBoxRow? row;
            while ((row = chat_listbox.get_row_at_index (idx)) != null) {
                if (filter_chats (row)) return row;
                idx++;
            }
            return null;
        }

        /* Highlight `row` as the open chat (null: none). Rows are not
           GTK-selected (see the chat_listbox setup), so the :selected look
           and the accessible state are applied by hand. */
        private void mark_current_chat_row (Gtk.ListBoxRow? row) {
            if (current_chat_row == row) return;
            if (current_chat_row != null) {
                current_chat_row.unset_state_flags (Gtk.StateFlags.SELECTED);
#if A11Y
                current_chat_row.update_state (
                    Gtk.AccessibleState.SELECTED, false, -1);
#endif
            }
            current_chat_row = row;
            if (row != null) {
                row.set_state_flags (Gtk.StateFlags.SELECTED, false);
#if A11Y
                row.update_state (Gtk.AccessibleState.SELECTED, true, -1);
#endif
            }
        }

        /* Chat id of the chat-list row holding the keyboard focus, or 0. */
        private int focused_chat_row_id () {
            for (var w = get_focus (); w != null; w = w.get_parent ()) {
                if (w == chat_listbox) return 0;
                if (w is Gtk.ListBoxRow) {
                    if (!w.is_ancestor (chat_listbox)) return 0;
                    var chat_row = ((Gtk.ListBoxRow) w).child as ChatRow;
                    return chat_row != null ? chat_row.chat_id : 0;
                }
            }
            return 0;
        }

        /* Open the chat behind `row`: called for Enter/click on the row and
           for every programmatic switch (shortcuts, search, quick switcher,
           notifications). Merely moving the keyboard focus through the list
           never gets here. */
        private void open_chat_row (Gtk.ListBoxRow row) {
            var chat_row = row.child as ChatRow;
            if (chat_row == null) return;

            int chat_id = chat_row.chat_id;
            mark_current_chat_row (row);

            /* Opening from the list itself (Enter on the focused row) keeps
               the focus there until the activation handler moves it; every
               other path lands the caret in the message entry. In collapsed
               mode opening always commits (the sidebar closes), so grab the
               entry there too. */
            bool focus_compose = split_view.collapsed || !chat_list_has_focus ();

            if (chat_id == current_chat_id) {
                if (split_view.collapsed) {
                    split_view.show_sidebar = false;
                }
                var v = current_view ();
                if (v != null) {
                    v.on_reselected (focus_compose);
                    if (this.is_active) v.flush_pending_seen ();
                }
                notice_chat.begin (chat_id);
                return;
            }

            var entry = find_chat_entry (chat_store, chat_id);
            var view = get_or_create_view (
                chat_id, entry != null ? entry.kind : ChatKind.UNKNOWN);
            current_chat_id = chat_id;

            if (entry != null) {
                content_title_label.label = entry.name;
            }
            content_mute_icon.visible = entry != null && entry.is_muted;
            /* Contact requests swap the compose box for an Accept/Block bar. */
            view.set_contact_request (entry != null && entry.is_contact_request);

            content_stack.visible_child_name = "chat_%d".printf (chat_id);
            view.on_activated (focus_compose);

            /* In narrow/mobile mode, hide the sidebar so the chat takes over */
            if (split_view.collapsed) {
                split_view.show_sidebar = false;
            }

            if (this.is_active) view.flush_pending_seen ();

            notice_chat.begin (current_chat_id);
        }

        private async void notice_chat (int chat_id) {
            clear_chat_mention (chat_id);
            try {
                yield rpc.marknoticed_chat (chat_id);
            } catch (Error e) {
                /* non-critical */
            }
            if (events != null) {
                events.clear_notifications_for_chat (rpc.account_id, chat_id);
            }
        }

        /* Drop the unseen-mention highlight for a chat the user is now reading,
           refreshing the sidebar so the tint/marker disappears. */
        private void clear_chat_mention (int chat_id) {
            if (mentioned_chats.remove (chat_id)) {
                request_reload_chats ();
            }
        }

        private void on_window_focused () {
            if (current_chat_id <= 0) return;
            /* In collapsed (mobile) mode with the sidebar shown the user is
               looking at the chat list, not the conversation. */
            if (split_view.collapsed && split_view.show_sidebar) return;
            var v = current_view ();
            if (v != null) v.flush_pending_seen ();
            notice_chat.begin (current_chat_id);
        }

        /* ================================================================
         *  Attachments (save / image viewer)
         * ================================================================ */

        public void show_image_list (string[] paths, int start_index) {
            image_viewer.show_list (paths, start_index);
        }

        public string? image_viewer_path () {
            return image_viewer.current_path;
        }

        /** Extends the open viewer's list; no-op unless it still shows
            `expected_path`. */
        public void replace_image_list (string[] paths, string expected_path) {
            if (image_viewer.current_path != expected_path) return;
            image_viewer.replace_list (paths);
        }

        private void show_gallery_dialog () {
            if (current_chat_id <= 0 || !can_show_rpc_modal ()) return;
            var entry = find_chat_entry (chat_store, current_chat_id);
            var dialog = new GalleryDialog (this, rpc, current_chat_id,
                                            entry != null ? entry.name : null);
            present_modal (dialog);
        }

        public void show_video (string path, string? name) {
            video_player.show (path, name);
        }

        public async void save_attachment (string src_path, string? name) {
            var dialog = new Gtk.FileDialog ();
            dialog.initial_name = name ?? Path.get_basename (src_path);
            try {
                var dest = yield dialog.save (this, null);
                if (dest == null) return;
                var src_file = File.new_for_path (src_path);
                yield src_file.copy_async (dest, FileCopyFlags.OVERWRITE,
                                           Priority.DEFAULT, null, null);
                show_toast ("File saved");
            } catch (Error e) {
                if (is_dialog_dismissal (e)) return;
                show_toast ("Save failed: " + e.message);
            }
        }

        /** One entry point for Webxdc attachments in conversations and the
            gallery. Unsupported builds and disabled settings deliberately
            omit Start App instead of offering an action that cannot work. */
        public async void prompt_webxdc_app (Gtk.Widget parent,
                                             RpcClient app_rpc,
                                             Message msg) {
            bool can_start = Webxdc.AVAILABLE && Webxdc.enabled ();
            string app_name = msg.display_file_name ("App");
            if (app_name.down ().has_suffix (".xdc")) {
                app_name = app_name.substring (0, app_name.length - 4);
            }

            string title;
            string body;
            if (!Webxdc.AVAILABLE) {
                title = "Cannot Start Webxdc App";
                body = ("This version of Parla was built without Webxdc "
                    + "support, so it cannot start “%s”. You can still "
                    + "download the .xdc file.").printf (app_name);
            } else if (!Webxdc.enabled ()) {
                title = "Webxdc Apps Are Disabled";
                body = ("Webxdc apps are turned off in Settings, so Parla "
                    + "cannot start “%s”. You can still download the .xdc "
                    + "file.").printf (app_name);
            } else {
                title = "Open Webxdc App?";
                body = ("Start “%s” in Parla, or download its .xdc file "
                    + "without opening it.").printf (app_name);
            }

            var dialog = new Adw.AlertDialog (title, body);
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("download", "Download File");
            if (can_start) {
                dialog.add_response ("start", "Start App");
                dialog.set_response_appearance (
                    "start", Adw.ResponseAppearance.SUGGESTED);
                dialog.default_response = "start";
            } else {
                dialog.set_response_appearance (
                    "download", Adw.ResponseAppearance.SUGGESTED);
                dialog.default_response = "download";
            }
            dialog.close_response = "cancel";

            string response = yield dialog.choose (parent, null);
            if (response == "cancel") return;

            var local_msg = yield ensure_webxdc_file (app_rpc, msg);
            if (local_msg == null) return;
            if (response == "start") {
                Webxdc.open (this, app_rpc, local_msg);
            } else if (response == "download") {
                yield save_attachment (local_msg.file_path,
                                       local_msg.file_name);
            }
        }

        /** Start (or re-present) a Webxdc instance from the Apps manager.
            The instance may live in another profile; switch first so the
            app window talks to the account its chat belongs to. */
        public async bool run_webxdc_instance (int acct_id, Message msg) {
            if (!Webxdc.AVAILABLE) {
                show_toast ("This build of Parla has no Webxdc support");
                return false;
            }
            if (!Webxdc.enabled ()) {
                show_toast ("Webxdc apps are disabled in Settings");
                return false;
            }
            if (acct_id != rpc.account_id
                    && !(yield switch_account (acct_id))) {
                return false;
            }
            var local_msg = yield ensure_webxdc_file (rpc, msg);
            if (local_msg == null) return false;
            Webxdc.open (this, rpc, local_msg);
            return true;
        }

        private async Message? ensure_webxdc_file (RpcClient app_rpc,
                                                    Message msg) {
            if (msg.has_local_file) return msg;
            if (msg.is_downloading_full_message) {
                show_toast ("The app file is still downloading");
                return null;
            }
            if (!msg.can_download_full_message) {
                show_toast ("The app file is not available for download");
                return null;
            }

            try {
                show_toast ("Downloading app…");
                yield app_rpc.download_full_message (msg.id);
                var downloaded = yield app_rpc.fetch_message (msg.id);
                if (downloaded != null && downloaded.has_local_file) {
                    return downloaded;
                }
                show_toast ("The app file has not finished downloading");
            } catch (Error e) {
                show_toast ("App download failed: " + e.message);
            }
            return null;
        }

        /* ================================================================
         *  Event Loop (delegates to EventHandler)
         * ================================================================ */

        public void request_reload_chats () {
            if (events != null) events.schedule_chats_reload ();
        }

        /* Queue a notification for a new message or reaction: batch rapid
           arrivals into one banner per chat and check the chat's mute state
           when the batch is flushed. Behavioral contract: docs/notifications.md */
        private void queue_chat_notification (int acct_id, int chat_id, int msg_id,
                                              int contact_id = 0,
                                              string? reaction = null) {
            if (acct_id <= 0 || chat_id <= 0 || events == null
                || !settings.notifications_enabled)
                return;
            /* The app is on screen and focused: the user already sees new
               activity in the app (chat list and account badges), so no
               desktop banner. Hidden, minimized or unfocused: notify. */
            if (this.visible && this.is_active) return;

            var p = new PendingNotification ();
            p.acct_id = acct_id;
            p.chat_id = chat_id;
            p.msg_id = msg_id;
            p.contact_id = contact_id;
            p.reaction = reaction;
            pending_notifications.add (p);

            if (notification_flush_timer > 0) return;
            notification_flush_timer = Timeout.add (400, () => {
                notification_flush_timer = 0;
                flush_chat_notifications.begin ();
                return Source.REMOVE;
            });
        }

        private async void flush_chat_notifications () {
            var items = pending_notifications;
            pending_notifications = new GenericArray<PendingNotification> ();
            if (events == null || !settings.notifications_enabled) return;

            int[] acct_ids = {};
            for (uint i = 0; i < items.length; i++) {
                int acct_id = items.get (i).acct_id;
                if (!has_int (acct_ids, acct_id)) acct_ids += acct_id;
            }

            foreach (int acct_id in acct_ids) {
                var acct_items = new GenericArray<PendingNotification> ();
                for (uint i = 0; i < items.length; i++) {
                    var item = items.get (i);
                    if (item.acct_id == acct_id) acct_items.add (item);
                }
                yield notify_account_items (acct_id, acct_items);
            }
        }

        private async void notify_account_items (int acct_id,
                GenericArray<PendingNotification> items) {
            int[] chat_ids = {};
            int messages = 0;
            for (uint i = 0; i < items.length; i++) {
                var item = items.get (i);
                if (item.reaction == null) messages++;
                if (!has_int (chat_ids, item.chat_id)) chat_ids += item.chat_id;
            }

            /* A storm across many chats (e.g. catching up after being
               offline) collapses into one account-wide group banner. */
            if (chat_ids.length > 3) {
                string title = yield prefix_background_account (acct_id,
                    "%d new messages".printf (messages));
                events.send_chat_notification (acct_id, 0, title,
                    "In %d chats".printf (chat_ids.length));
                return;
            }

            foreach (int chat_id in chat_ids) {
                var group = new GenericArray<PendingNotification> ();
                for (uint i = 0; i < items.length; i++) {
                    var item = items.get (i);
                    if (item.chat_id == chat_id) group.add (item);
                }
                yield notify_chat_group (acct_id, chat_id, group);
            }
        }

        private async void notify_chat_group (int acct_id, int chat_id,
                GenericArray<PendingNotification> group) {
            string? chat_name = null;
            try {
                var chat_obj = yield rpc.get_full_chat_by_id_for (acct_id, chat_id);
                if (chat_obj != null) {
                    /* Core emits IncomingMsg for muted chats too; official
                       clients drop those at notification time (mentions in
                       them are covered by the mention notification). */
                    if (json_bool (chat_obj, "isMuted")) return;
                    chat_name = json_str (chat_obj, "name");
                }
            } catch (Error e) { /* compose without chat info */ }

            int messages = 0;
            PendingNotification? msg_item = null;
            for (uint i = 0; i < group.length; i++) {
                if (group.get (i).reaction == null) {
                    messages++;
                    msg_item = group.get (i);
                }
            }

            bool show = settings.show_notification_contents;
            string title = chat_name ?? "New message";
            string body = messages == 0 ? "New reaction" : "New message";
            if (messages > 1) {
                body = "%d new messages".printf (messages);
            } else if (messages == 1 && show) {
                try {
                    var msg = yield rpc.fetch_message_for (acct_id,
                                                           msg_item.msg_id);
                    if (msg != null) {
                        string sender = msg.sender_name
                            ?? msg.sender_address ?? title;
                        title = (chat_name != null && chat_name.length > 0
                                 && chat_name != sender)
                            ? "%s (%s)".printf (sender, chat_name) : sender;
                        body = (msg.text != null && msg.text.length > 0)
                            ? msg.text
                            : (msg.file_name != null && msg.file_name.length > 0)
                            ? msg.file_name : "New message";
                    }
                } catch (Error e) { /* keep the generic body */ }
            } else if (messages == 0 && show) {
                /* Only reactions: announce the latest one. */
                var r = group.get (group.length - 1);
                string reactor = "";
                try {
                    var c = yield rpc.get_contact_for (acct_id, r.contact_id);
                    if (c != null) reactor = json_str (c, "displayName") ?? "";
                } catch (Error e) { /* name is optional */ }
                body = reactor.length > 0
                    ? "%s reacted %s".printf (reactor, r.reaction)
                    : "Reacted %s".printf (r.reaction);
            }

            title = yield prefix_background_account (acct_id, title);
            events.send_chat_notification (acct_id, chat_id, title, body);
        }

        /* Tag notifications from background accounts so the user can tell
           which profile they belong to. */
        private async string prefix_background_account (int acct_id, string title) {
            if (acct_id == rpc.account_id) return title;
            try {
                string? name = yield rpc.get_config ("displayname", acct_id);
                if (name == null || name.length == 0)
                    name = yield rpc.get_config ("addr", acct_id);
                if (name != null && name.length > 0)
                    return "[%s] %s".printf (name, title);
            } catch (Error e) { /* fall back to the plain title */ }
            return title;
        }

        private static bool has_int (int[] haystack, int needle) {
            foreach (int x in haystack) {
                if (x == needle) return true;
            }
            return false;
        }

        private async void on_incoming_msg (int acct_id, int chat_id, int msg_id) {
            check_mention.begin (acct_id, chat_id, msg_id);
            if (acct_id != rpc.account_id) {
                queue_chat_notification (acct_id, chat_id, msg_id);
                update_unread_indicators.begin ();
                return;
            }

            var view = views.lookup (chat_id);
            bool handled = false;
            if (view != null) {
                handled = yield view.handle_incoming_msg (msg_id);
            }
            if (view != null && !handled) {
                if (chat_id == current_chat_id) {
                    request_messages_reload ();
                }
            }
            queue_chat_notification (acct_id, chat_id, msg_id);
            request_reload_chats ();
        }

        private void on_chat_messages_changed (int acct_id, int chat_id) {
            if (acct_id != rpc.account_id) return;

            if (chat_id > 0) {
                var view = views.lookup (chat_id);
                if (view != null) view.mark_messages_stale ();
                if (chat_id == current_chat_id) request_messages_reload ();
                return;
            }

            mark_all_views_messages_stale ();
            request_messages_reload ();
        }

        /* ================================================================
         *  Actions
         * ================================================================ */

        private async void load_account_menu () {
            if (rpc == null || !rpc.is_connected) {
                account_menu_state = null;
                clear_listbox (account_menu_list);
                var row = new Adw.ActionRow ();
                row.title = "Not connected";
                row.subtitle = "Open Settings to configure the RPC server";
                account_menu_list.append (row);
                focus_current_account_menu_row_if_requested ();
                return;
            }

            int gen = ++account_menu_load_gen;
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node == null) return;
                var accounts = accounts_node.get_array ();

                /* Build the rows off-screen, then swap them in synchronously
                   and only when something visible changed, so the open menu
                   never flashes. */
                var state = new StringBuilder ();
                Adw.ActionRow[] rows = {};
                for (uint i = 0; i < accounts.get_length (); i++) {
                    var acct = accounts.get_object_element (i);
                    int id = (int) acct.get_int_member ("id");
                    rows += yield build_account_menu_row_for_id (
                        id, id == rpc.account_id, state);
                }
                if (gen != account_menu_load_gen) return; /* superseded */
                if (account_menu_state == state.str) {
                    focus_current_account_menu_row_if_requested ();
                    return;
                }
                account_menu_state = state.str;

                clear_listbox (account_menu_list);
                foreach (var row in rows) account_menu_list.append (row);
                if (rows.length == 0) {
                    var empty = new Adw.ActionRow ();
                    empty.title = "No accounts";
                    empty.subtitle = "Add an account to get started";
                    account_menu_list.append (empty);
                }
                account_menu_list.append (build_add_account_row ());
                focus_current_account_menu_row_if_requested ();
            } catch (Error e) {
                if (gen != account_menu_load_gen) return;
                account_menu_state = null;
                clear_listbox (account_menu_list);
                var err_row = new Adw.ActionRow ();
                err_row.use_markup = false;
                err_row.title = "Error loading accounts";
                err_row.subtitle = e.message;
                account_menu_list.append (err_row);
                focus_current_account_menu_row_if_requested ();
            }
        }

        private void focus_current_account_menu_row_if_requested () {
            if (!focus_current_account_on_menu_load) return;
            focus_current_account_on_menu_load = false;

            Idle.add (() => {
                focus_current_account_menu_row ();
                return Source.REMOVE;
            });
        }

        private void focus_current_account_menu_row () {
            Gtk.ListBoxRow? fallback = null;
            int current_account_id = rpc != null ? rpc.account_id : 0;
            int idx = 0;
            Gtk.ListBoxRow? row;

            while ((row = account_menu_list.get_row_at_index (idx)) != null) {
                if (fallback == null) fallback = row;

                var action_row = row as Adw.ActionRow;
                if (action_row != null &&
                    action_row.get_data<int> ("acct-id") == current_account_id) {
                    row.grab_focus ();
                    return;
                }
                idx++;
            }

            if (fallback != null) fallback.grab_focus ();
        }

        private Adw.ActionRow build_add_account_row () {
            var row = new Adw.ActionRow ();
            row.title = "Add Profile";
            row.activatable = true;
            row.set_data<int> ("acct-id", -1);

            var icon = new Gtk.Image.from_icon_name ("list-add-symbolic");
            icon.valign = Gtk.Align.CENTER;
            row.add_prefix (icon);

            return row;
        }

        private async Adw.ActionRow build_account_menu_row_for_id (int id,
                                                                   bool current,
                                                                   StringBuilder state) throws Error {
            bool configured = yield rpc.is_configured (id);

            string? email = null;
            string? display_name = null;
            string? avatar = null;
            int unread = 0;
            if (configured) {
                try {
                    email = yield rpc.get_config ("addr", id);
                    display_name = yield rpc.get_config ("displayname", id);
                    avatar = yield rpc.get_config ("selfavatar", id);
                    unread = yield rpc.get_fresh_msg_count (id);
                } catch (Error ce) { /* ignore */ }
            }
            state.append_printf ("%d|%d|%d|%s|%s|%s|%d\n", id,
                configured ? 1 : 0, current ? 1 : 0, email ?? "",
                display_name ?? "", avatar ?? "", unread);

            return build_account_menu_row (id, configured, current,
                email, display_name, avatar, unread);
        }

        private Adw.ActionRow build_account_menu_row (int id, bool configured,
                                                       bool current,
                                                       string? email,
                                                       string? display_name,
                                                       string? avatar,
                                                       int unread) {
            string title;
            if (display_name != null && display_name.length > 0) {
                title = display_name;
            } else if (configured) {
                title = email ?? "Account #%d".printf (id);
            } else {
                title = "Unconfigured account";
            }

            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = title;
            row.subtitle = email ?? "";
            row.activatable = configured && !current;
            row.set_data<int> ("acct-id", id);
            if (current) row.add_css_class ("current-account-row");

            var avatar_widget = new Adw.Avatar (32, title, true);
            avatar_widget.custom_image = load_avatar (avatar);

            if (unread > 0) {
                /* Red counter badge in the bottom-right corner of the avatar
                   for accounts with pending unread notifications. */
                var badge = new Gtk.Label (unread > 99 ? "99+" : unread.to_string ());
                badge.add_css_class ("account-unread-badge");
                badge.halign = Gtk.Align.END;
                badge.valign = Gtk.Align.END;

                var overlay = new Gtk.Overlay ();
                overlay.child = avatar_widget;
                overlay.add_overlay (badge);
                overlay.valign = Gtk.Align.CENTER;
                row.add_prefix (overlay);
            } else {
                row.add_prefix (avatar_widget);
            }

            var edit_btn = new Gtk.Button.from_icon_name ("preferences-system-symbolic");
            edit_btn.valign = Gtk.Align.CENTER;
            edit_btn.add_css_class ("flat");
            edit_btn.tooltip_text = "Edit profile";
            edit_btn.sensitive = configured;
            edit_btn.clicked.connect (() => {
                account_popover.popdown ();
                show_profile_for_account (id);
            });
            row.add_suffix (edit_btn);

            if (!configured) {
                var status = new Gtk.Label ("Not configured");
                status.add_css_class ("caption");
                status.add_css_class ("dim-label");
                status.valign = Gtk.Align.CENTER;
                row.add_suffix (status);
            }

            return row;
        }

        private void on_account_menu_row_activated (Gtk.ListBoxRow row) {
            var action_row = row as Adw.ActionRow;
            if (action_row == null) return;
            int acct_id = action_row.get_data<int> ("acct-id");
            if (acct_id == -1) {
                account_popover.popdown ();
                on_add_account ();
                return;
            }
            if (!action_row.activatable || acct_id <= 0 || acct_id == rpc.account_id) return;

            account_popover.popdown ();
            switch_account.begin (acct_id);
        }

        private const string[] ADD_PROFILE_METHODS = {
            "contact-new-symbolic", "Create new profile", "Pick a chatmail relay and create a new account",
            "phone-symbolic", "Add as secondary device", "Synchronize from another device on the same network",
            "mail-message-new-symbolic", "Use classic email address", "Sign in with an existing email account",
            "mail-attachment-symbolic", "Use invitation code", "Join via a dcaccount: link or QR code",
        };

        // Modal Adw.Dialog with a vertical box whose first child is a header
        // bar; the caller fills `box` and sets it as dialog content.
        private Adw.Dialog make_modal (string title, int width, out Gtk.Box box) {
            var dialog = new Adw.Dialog ();
            dialog.title = title;
            dialog.content_width = width;
            box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());
            return dialog;
        }

        private void on_add_account () {
            if (active_modal != null) return;

            Gtk.Box box;
            var dialog = make_modal ("Add Profile", 460, out box);

            var intro = new Gtk.Label ("Choose how you want to add an account.");
            intro.halign = Gtk.Align.START;
            intro.margin_start = intro.margin_end = 12;
            intro.margin_top = 12;
            intro.add_css_class ("dim-label");
            box.append (intro);

            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.margin_start = list.margin_end = 12;
            list.margin_top = 8;
            list.margin_bottom = 12;

            for (int i = 0; i + 2 < ADD_PROFILE_METHODS.length; i += 3) {
                list.append (build_add_method_row (ADD_PROFILE_METHODS[i],
                    ADD_PROFILE_METHODS[i + 1], ADD_PROFILE_METHODS[i + 2]));
            }

            list.row_activated.connect ((row) => {
                string method = row.get_data<string> ("add-method");
                dialog.close ();
                on_add_account_method_selected (method);
            });

            box.append (list);
            dialog.child = box;
            present_modal (dialog);
        }

        private Adw.ActionRow build_add_method_row (string icon_name,
                                                     string title,
                                                     string subtitle) {
            var row = new Adw.ActionRow ();
            row.title = title;
            row.subtitle = subtitle;
            row.activatable = true;
            row.set_data<string> ("add-method", title);

            var icon = new Gtk.Image.from_icon_name (icon_name);
            icon.valign = Gtk.Align.CENTER;
            row.add_prefix (icon);

            var chevron = new Gtk.Image.from_icon_name ("go-next-symbolic");
            chevron.valign = Gtk.Align.CENTER;
            chevron.add_css_class ("dim-label");
            row.add_suffix (chevron);

            return row;
        }

        private void on_add_account_method_selected (string method) {
            if (method == "Use classic email address") {
                show_classic_email_dialog ();
            } else if (method == "Add as secondary device") {
                show_secondary_device_dialog ();
            } else if (method == "Create new profile") {
                show_create_profile_dialog ();
            } else if (method == "Use invitation code") {
                show_invitation_code_profile_dialog ();
            }
        }

        private void show_create_profile_dialog () {
            if (!can_show_rpc_modal ()) return;

            var dialog = new CreateProfileDialog (rpc, events);
            dialog.account_created.connect ((new_id) => {
                after_profile_created.begin (new_id);
            });
            present_modal (dialog);
        }

        private async void after_profile_created (int new_id) {
            if (yield switch_account (new_id)) show_toast ("Profile created");
        }

        private void show_invitation_code_profile_dialog () {
            if (!can_show_rpc_modal ()) return;

            var dialog = new InvitationCodeProfileDialog (rpc, events);
            dialog.account_created.connect ((new_id, chat_id) => {
                after_invitation_profile_created.begin (new_id, chat_id);
            });
            present_modal (dialog);
        }

        private async void after_invitation_profile_created (int new_id,
                                                            int chat_id) {
            if (yield switch_account (new_id)) {
                if (chat_id > 0) {
                    yield load_chats ();
                    select_chat_by_id (chat_id);
                }
                show_toast (chat_id > 0
                    ? "Profile created and invitation accepted"
                    : "Profile created");
            }
        }

        private void show_secondary_device_dialog () {
            if (!can_show_rpc_modal ()) return;

            var dialog = new ReceiveBackupDialog (rpc, events);
            dialog.account_imported.connect ((new_id) => {
                after_secondary_device_imported.begin (new_id);
            });
            present_modal (dialog);
        }

        private async void after_secondary_device_imported (int new_id) {
            if (yield switch_account (new_id)) show_toast ("Profile imported");
        }

        private void show_classic_email_dialog () {
            if (!can_show_rpc_modal ()) return;

            var dialog = new ClassicEmailDialog (rpc, events);
            dialog.account_created.connect ((new_id) => {
                after_profile_created.begin (new_id);
            });
            present_modal (dialog);
        }

        public async void set_auto_download_limit (int bytes) {
            settings.save_auto_download_limit (bytes);
            if (!rpc.is_connected) return;
            try {
                yield apply_auto_download_limit ();
            } catch (Error e) {
                show_toast ("Unable to update attachment downloads: " + e.message);
            }
        }

        private async void apply_auto_download_limit () throws Error {
            var accounts_node = yield rpc.get_all_accounts ();
            if (accounts_node == null) return;
            var accounts = accounts_node.get_array ();
            string limit = settings.auto_download_limit.to_string ();
            for (uint i = 0; i < accounts.get_length (); i++) {
                var account = accounts.get_object_element (i);
                int id = (int) account.get_int_member ("id");
                if (id > 0) {
                    yield rpc.batch_set_config ("download_limit", limit, id);
                }
            }
        }

        public async bool switch_account (int acct_id) {
            if (acct_id <= 0 || acct_id == rpc.account_id) return false;

            try {
                yield rpc.select_account (acct_id);
                rpc.account_id = acct_id;
                /* IO stays running for every account, so switching only changes
                   which account is shown — the others keep fetching mail in the
                   background. Re-asserting all-accounts IO here is idempotent and
                   also covers accounts created during this session. */
                yield apply_auto_download_limit ();
                yield rpc.start_io_for_all_accounts ();
                yield reload_active_account ();
                return true;
            } catch (Error e) {
                show_error (this, e.message);
                return false;
            }
        }

        private void show_profile_for_account (int acct_id) {
            if (acct_id <= 0) return;

            bool edits_current_account = acct_id == rpc.account_id;
            var dialog = new ProfileDialog (rpc, settings, events, acct_id);
            dialog.profile_updated.connect (() => {
                if (edits_current_account) {
                    load_profile_avatar.begin ();
                }
            });
            dialog.account_deleted.connect ((deleted_id) => {
                after_profile_deleted.begin (deleted_id, edits_current_account);
            });
            dialog.present (this);
        }

        private async void after_profile_deleted (int deleted_id,
                                                  bool was_current_account) {
            bool switched_account = false;

            if (was_current_account) {
                switched_account = yield switch_to_first_configured_account (
                    deleted_id);
                if (!switched_account) {
                    rpc.account_id = 0;
                    yield reload_active_account ();
                }
            }

            yield update_unread_indicators ();
            show_toast (switched_account
                ? "Profile deleted; switched profile"
                : "Profile deleted");
        }

        private async bool switch_to_first_configured_account (int skip_id) {
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node == null) return false;

                var accounts = accounts_node.get_array ();
                for (uint i = 0; i < accounts.get_length (); i++) {
                    var acct = accounts.get_object_element (i);
                    int id = (int) acct.get_int_member ("id");
                    if (id <= 0 || id == skip_id) continue;

                    bool configured = false;
                    try {
                        configured = yield rpc.is_configured (id);
                    } catch (Error e) {
                        continue;
                    }
                    if (configured && yield switch_account (id)) {
                        return true;
                    }
                }
            } catch (Error e) {
                show_toast ("Failed to select another profile: " + e.message);
            }
            return false;
        }

        private async void load_profile_avatar () {
            if (rpc.account_id <= 0) {
                profile_unread_badge.visible = false;
                return;
            }

            try {
                string? name = yield rpc.get_config ("displayname", rpc.account_id);
                string? avatar = yield rpc.get_config ("selfavatar", rpc.account_id);

                MessageRow.self_avatar_path = avatar;
                profile_avatar.text = name ?? "";
                profile_avatar.custom_image = load_avatar (avatar);
            } catch (Error e) {
                /* ignore */
            }
            yield update_unread_indicators ();
        }

        /* Toggle the red circle on the header avatar and, while the avatar
           menu is open, refresh its per-account counters. The circle flags
           that *another* account has notification-worthy unread messages, so
           the user knows to open the account menu and switch — it stays put
           regardless of window focus and isn't cleared by reading the current
           account (whose own unread is already shown in the chat list). */
        private async void update_unread_indicators () {
            if (profile_unread_badge == null) return;
            bool other_unread = false;
            if (rpc != null && rpc.is_connected && rpc.account_id > 0) {
                try {
                    var accounts_node = yield rpc.get_all_accounts ();
                    if (accounts_node != null) {
                        var accounts = accounts_node.get_array ();
                        for (uint i = 0; i < accounts.get_length (); i++) {
                            var acct = accounts.get_object_element (i);
                            int id = (int) acct.get_int_member ("id");
                            if (id <= 0 || id == rpc.account_id) continue;
                            if ((yield rpc.get_fresh_msg_count (id)) > 0) {
                                other_unread = true;
                                break;
                            }
                        }
                    }
                } catch (Error e) {
                    return;
                }
            }
            profile_unread_badge.visible = other_unread;
            if (account_popover != null && account_popover.get_visible ()) {
                yield load_account_menu ();
            }
        }

        private void on_new_chat () {
            if (!can_show_account_modal ()) return;

            var picker = new ContactPickerDialog (rpc);
            picker.contact_picked.connect ((contact_id, email) => {
                create_chat_by_email.begin (email);
            });
            present_modal (picker);
        }

        private async void create_chat_by_email (string email) {
            if (rpc.account_id <= 0) return;

            try {
                int contact_id = yield rpc.get_or_create_contact (email);
                int chat_id = yield rpc.get_or_create_chat_by_contact (contact_id);

                yield load_chats ();
                select_chat_by_id (chat_id);

                show_toast ("Chat created with " + email);
            } catch (Error e) {
                show_toast ("Failed to create chat: " + e.message);
            }
        }

        private void on_new_group () {
            show_group_dialog (false);
        }

        private void on_new_channel () {
            show_group_dialog (true);
        }

        private void show_group_dialog (bool is_channel) {
            if (!can_show_account_modal ()) return;

            var dialog = new NewGroupDialog (rpc, is_channel);
            dialog.group_created.connect ((chat_id) => {
                after_group_created.begin (chat_id, is_channel);
            });
            present_modal (dialog);
        }

        private async void after_group_created (int chat_id, bool is_channel) {
            yield load_chats ();
            select_chat_by_id (chat_id);
            show_toast (is_channel ? "Channel created" : "Group created");
        }

        public void scroll_to_message (int msg_id) {
            var v = current_view ();
            if (v != null) v.scroll_to_message (msg_id);
        }

        /* Jump to a message in a specific chat (gallery "View in
           Conversation"). The gallery can be opened for a chat that is
           not the current one; selecting the already-current chat again
           would re-run on_reselected and scroll to the bottom, so only
           switch when needed. scroll_to_message survives the chat still
           loading: it parks the ID in pending_scroll_message_id and
           load_messages resumes it. */
        public void open_conversation_message (int chat_id, int msg_id) {
            if (current_chat_id != chat_id
                    && !select_chat_by_id (chat_id)) return;
            scroll_to_message (msg_id);
        }

        public async void open_media_message (int acct_id, int chat_id,
                                              int msg_id) {
            yield open_chat_from_notification (acct_id, chat_id);
            if (current_chat_id == chat_id) scroll_to_message (msg_id);
        }

        public void navigate_voice_playback (int direction) {
            var item = AudioPlayback.shared ().current_item;
            if (item == null || direction == 0) return;
            if (item.account_id != rpc.account_id) {
                navigate_voice_after_open.begin (
                    item.account_id, item.chat_id, item.message_id, direction);
                return;
            }
            var view = views.lookup (item.chat_id);
            if (view != null) {
                view.request_voice_navigation (direction);
            } else {
                navigate_voice_after_open.begin (
                    item.account_id, item.chat_id, item.message_id, direction);
            }
        }

        private async void navigate_voice_after_open (int acct_id, int chat_id,
                                                       int msg_id,
                                                       int direction) {
            yield open_media_message (acct_id, chat_id, msg_id);
            var item = AudioPlayback.shared ().current_item;
            if (item == null || item.account_id != acct_id
                    || item.chat_id != chat_id || item.message_id != msg_id)
                return;
            var view = views.lookup (chat_id);
            if (view != null) view.request_voice_navigation (direction);
        }

        /* Entry point for the "app.open-chat" action fired when the user
           clicks a message notification: bring the owning account forward
           (it may be a background one) and open the chat. */
        public async void open_chat_from_notification (int acct_id, int chat_id) {
            if (acct_id > 0 && acct_id != rpc.account_id) {
                if (!yield switch_account (acct_id)) return;
            }
            if (chat_id <= 0) return;
            if (!select_chat_by_id (chat_id)) {
                /* The chat may not be in the sidebar yet (fresh contact
                   request, stale list) — reload and try once more. */
                yield load_chats ();
                select_chat_by_id (chat_id);
            }
        }

        /* Main menu. Hand-built rather than a GLib.Menu-backed
           GtkPopoverMenu: GtkModelButton names itself through a
           presentational label, which GTK's AccessKit backend leaves to
           AccessKit to resolve, so NVDA read the menu as empty items
           (#57). The win.* actions stay: the accelerators bind to them. */
        private Gtk.Popover build_app_menu () {
            window_action ("new-chat").activate.connect (() => { on_new_chat (); });
            window_action ("new-group").activate.connect (() => { on_new_group (); });
            window_action ("new-channel").activate.connect (() => { on_new_channel (); });
            window_action ("use-invite-link").activate.connect (() => { show_use_invite_link_dialog (); });
            window_action ("refresh").activate.connect (() => { load_chats.begin (); });
            window_action ("settings").activate.connect (() => { show_settings_dialog (); });
            window_action ("stickers").activate.connect (() => { show_stickers_dialog (); });
            window_action ("webxdc-apps").activate.connect (() => { show_webxdc_apps_dialog (); });
            window_action ("shortcuts").activate.connect (() => { show_keyboard_shortcuts_dialog (); });
            window_action ("about").activate.connect (() => { show_about_dialog (); });
            window_action ("quit").activate.connect (() => { handle_primary_q (); });
            window_action ("font-increase").activate.connect (() => { adjust_font_size (1); });
            window_action ("font-decrease").activate.connect (() => { adjust_font_size (-1); });
            window_action ("font-reset").activate.connect (() => {
                settings.save_font_size (FONT_SIZE_SYSTEM);
            });

            var popover = new Gtk.Popover ();
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            box.add_css_class ("menu");
            popover.child = box;
            foreach (unowned AppMenuEntry e in APP_MENU) {
                if (e.label == null) {
                    box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
                    continue;
                }
                string action = "win." + e.action;
                var btn = new PopoverButton (popover, e.label, false, true,
                                             accel_label (action));
                btn.selected.connect (() => activate_action_variant (action, null));
                box.append (btn);
            }
            return popover;
        }

        private struct AppMenuEntry {
            public unowned string? label;
            public unowned string? action;
        }

        /* Main-menu rows in order; a null label is a separator. */
        private const AppMenuEntry[] APP_MENU = {
            { "New Chat", "new-chat" },
            { "New Group", "new-group" },
            { "New Channel", "new-channel" },
            { "Use Invite Link", "use-invite-link" },
            { null, null },
            { "Stickers", "stickers" },
            { "Apps", "webxdc-apps" },
            { null, null },
            { "Settings", "settings" },
            { "Shortcuts", "shortcuts" },
            { "About", "about" },
            { null, null },
            { "Quit", "quit" },
        };

        /* Display form of an action's first accelerator, or null. The
           window's application property is still unset while construct
           runs, hence the process-wide default. */
        private static string? accel_label (string action) {
            var app = GLib.Application.get_default () as Gtk.Application;
            var accels = app.get_accels_for_action (action);
            if (accels.length == 0) return null;
            uint key;
            Gdk.ModifierType mods;
            if (!Gtk.accelerator_parse (accels[0], out key, out mods)) return null;
            return Gtk.accelerator_get_label (key, mods);
        }

        private SimpleAction window_action (string name) {
            var action = new SimpleAction (name, null);
            add_action (action);
            return action;
        }

        private void show_about_dialog () {
            var about = new Adw.AboutDialog ();
            about.application_name = Parla.AppData.NAME;
            about.application_icon = Parla.AppData.ID;
            about.version = Parla.VERSION;
            about.developer_name = Parla.AppData.DEVELOPER;
            /* Avoid the same Vala strv constness mismatch as GTK's
               accelerator API; the GObject property owns a copied strv. */
            about.set ("developers", Parla.AppData.developers ());
            about.license_type = Gtk.License.GPL_3_0;
            about.website = Parla.AppData.WEBSITE;
            about.issue_url = Parla.AppData.ISSUE_URL;
            about.comments = Parla.AppData.COMMENTS;
            about.release_notes_version = Parla.VERSION;
            about.release_notes = Parla.AppData.release_notes ();
            about.present (this);
        }

        /* Entry point for invite links that arrive from outside the menu:
           a click on an "openpgp4fpr:" / "https://i.delta.chat/" link in a
           message, or the system handing us such a URI on the command line.
           Brings the window forward and opens the join dialog pre-filled; if
           no profile is connected yet (e.g. a cold start triggered by the
           link), the URI is parked and opened once try_connect finishes. */
        public void handle_invite_uri (string uri) {
            restore_from_tray ();

            if (rpc == null || rpc.account_id <= 0) {
                pending_invite_uri = uri;
                show_toast ("Invite link will open once a profile is ready");
                return;
            }
            show_use_invite_link_dialog (uri);
        }

        private void show_use_invite_link_dialog (string? prefill = null) {
            if (active_modal != null) return;
            if (rpc.account_id <= 0) {
                show_toast ("No active profile");
                return;
            }

            Gtk.Box box;
            var dialog = make_modal ("Use Invite Link", 460, out box);

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
            content.margin_start = 18;
            content.margin_end = 18;
            content.margin_top = 12;
            content.margin_bottom = 18;

            var label = new Gtk.Label ("Paste a Delta Chat invite link.");
            label.halign = Gtk.Align.START;
            label.xalign = 0;
            label.wrap = true;
            label.add_css_class ("dim-label");
            content.append (label);

            var entry = new Gtk.Entry ();
            entry.placeholder_text = "https://i.delta.chat/#...";
            entry.input_purpose = Gtk.InputPurpose.URL;
            entry.hexpand = true;
            content.append (entry);

            var status = new Gtk.Label ("");
            status.halign = Gtk.Align.START;
            status.xalign = 0;
            status.wrap = true;
            status.add_css_class ("dim-label");
            content.append (status);

            var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            actions.halign = Gtk.Align.END;
            actions.margin_top = 6;

            var cancel_btn = new Gtk.Button.with_label ("Cancel");
            cancel_btn.clicked.connect (() => { dialog.close (); });
            actions.append (cancel_btn);

            var add_btn = new Gtk.Button.with_label ("Add");
            add_btn.add_css_class ("suggested-action");
            add_btn.sensitive = false;
            add_btn.clicked.connect (() => {
                use_invite_link.begin (dialog, entry, status, add_btn);
            });
            actions.append (add_btn);
            content.append (actions);

            entry.changed.connect (() => {
                add_btn.sensitive = entry.text.strip ().length > 0;
                status.label = "";
            });
            entry.activate.connect (() => {
                if (add_btn.sensitive) {
                    use_invite_link.begin (dialog, entry, status, add_btn);
                }
            });

            box.append (content);
            dialog.child = box;
            present_modal (dialog);

            /* When the link came from a click or the system handler, drop it
               straight in so the user only has to confirm with "Add". */
            if (prefill != null && prefill.strip ().length > 0) {
                entry.text = prefill.strip ();
                add_btn.sensitive = true;
                add_btn.grab_focus ();
            } else {
                entry.grab_focus ();
            }
        }

        private async void use_invite_link (Adw.Dialog dialog,
                                            Gtk.Entry entry,
                                            Gtk.Label status,
                                            Gtk.Button add_btn) {
            string invite_link = entry.text.strip ();
            if (invite_link.length == 0) return;

            add_btn.sensitive = false;
            entry.sensitive = false;
            status.label = "Checking invite link…";

            try {
                var qr = yield rpc.check_qr (rpc.account_id, invite_link);
                if (qr == null || !qr.has_member ("kind")) {
                    status.label = "This is not a valid invite link.";
                    return;
                }

                string kind = qr.get_string_member ("kind");

                /* check_qr resolves a link relative to the current account.
                   Someone else's invite is an "ask*" kind we can join. Our own
                   invite comes back as withdraw* (token still active) or
                   revive* (token withdrawn) — see core/src/qr.rs. Those are not
                   errors: the link is ours to share, and a revive* simply means
                   it must be re-activated before others can use it. */
                switch (kind) {
                case "askVerifyContact":
                case "askVerifyGroup":
                case "askJoinBroadcast":
                    {
                        status.label = "Accepting invite link…";
                        int chat_id = yield rpc.secure_join (rpc.account_id, invite_link);
                        yield load_chats ();
                        select_chat_by_id (chat_id);
                        dialog.close ();
                        show_toast ("Invite link accepted");
                    }
                    break;

                case "reviveVerifyContact":
                case "reviveVerifyGroup":
                case "reviveJoinBroadcast":
                    /* Our own link, currently inactive — activate it so others
                       can join. */
                    status.label = "Activating your invite link…";
                    yield rpc.set_config_from_qr (rpc.account_id, invite_link);
                    status.label = "This is your own invite link. It is now active — "
                        + "share it with others so they can join.";
                    break;

                case "withdrawVerifyContact":
                case "withdrawVerifyGroup":
                case "withdrawJoinBroadcast":
                    /* Our own link, already active. Nothing to join — just tell
                       the user it is ready to share. */
                    status.label = "This is your own invite link and it is active. "
                        + "Share it with others so they can join.";
                    break;

                default:
                    status.label = "This is not a contact, group, or channel invite link.";
                    break;
                }
            } catch (Error e) {
                status.label = "Invite link failed: " + e.message;
            } finally {
                if (active_modal == dialog) {
                    entry.sensitive = true;
                    add_btn.sensitive = entry.text.strip ().length > 0;
                }
            }
        }

        private void show_stickers_dialog () {
            if (active_modal != null) return;
            present_modal (new StickerManagerDialog (this));
        }

        private void show_webxdc_apps_dialog () {
            if (!can_show_rpc_modal ()) return;
            present_modal (new WebxdcManagerDialog (this, rpc));
        }

        private void show_settings_dialog () {
            if (active_modal != null) return;

            var dialog = new SettingsDialog (this, rpc);
            dialog.closed.connect (() => {
                if (!rpc.is_connected &&
                    settings.effective_rpc_server_path ().length > 0) {
                    try_connect.begin ();
                }
            });
            present_modal (dialog);
        }

        public async void reload_active_account () {
            reset_chat_ui ();

            if (rpc.account_id <= 0) {
                clear_self_identity ();
                profile_avatar.text = "";
                profile_avatar.custom_image = null;
                profile_unread_badge.visible = false;
                show_empty_status ("avatar-default-symbolic",
                    "No Profile Loaded",
                    "Add or select a profile from the profile menu.");
                current_chat_id = 0;
                return;
            }

            show_empty_status ("parla-welcome", "Parla",
                "Select a chat to start messaging.");
            yield load_self_identity ();
            current_chat_id = 0;
            yield load_chats ();
            yield load_profile_avatar ();
            if (events != null && !events.is_listening) {
                events.start.begin ();
            }
        }

        private void discard_all_views () {
            var iter = HashTableIter<int, ConversationView> (views);
            int k;
            ConversationView v;
            while (iter.next (out k, out v)) {
                v.close ();
                content_stack.remove (v);
            }
            views.remove_all ();
            view_recency = {};
        }

        public override void dispose () {
            discard_all_views ();
            base.dispose ();
        }

        private void mark_all_views_messages_stale () {
            var iter = HashTableIter<int, ConversationView> (views);
            int k;
            ConversationView v;
            while (iter.next (out k, out v)) {
                v.mark_messages_stale ();
            }
        }

        private void toggle_sidebar_button () {
            if (split_view.collapsed) {
                toggle_collapsed_sidebar ();
            } else {
                toggle_sidebar_visibility ();
            }
        }

        private void toggle_collapsed_sidebar () {
            if (split_view.show_sidebar) {
                split_view.show_sidebar = false;
                return;
            }
            settings.save_sidebar_mode (SidebarMode.FULL);
            apply_sidebar_mode (true);
        }

        private void toggle_sidebar_visibility () {
            if (split_view.collapsed) {
                toggle_collapsed_sidebar ();
                return;
            }
            settings.save_sidebar_mode (
                settings.sidebar_mode == SidebarMode.HIDDEN
                    ? SidebarMode.FULL
                    : SidebarMode.HIDDEN);
            apply_sidebar_mode (true);
        }

        private void toggle_sidebar_width () {
            settings.save_sidebar_mode (
                settings.sidebar_mode == SidebarMode.COMPACT
                    ? SidebarMode.FULL
                    : SidebarMode.COMPACT);
            apply_sidebar_mode (true);
        }

        private void apply_sidebar_mode (bool update_visibility) {
            var mode = settings.sidebar_mode;
            sidebar_toggle_btn.icon_name = "sidebar-show-symbolic";
            if (mode == SidebarMode.COMPACT) {
                if (update_visibility) split_view.show_sidebar = true;
                split_view.sidebar_width_unit = Adw.LengthUnit.PX;
                split_view.min_sidebar_width = COMPACT_SIDEBAR_WIDTH;
                split_view.max_sidebar_width = COMPACT_SIDEBAR_WIDTH;
                split_view.sidebar_width_fraction = 0.0;
                sidebar_box.add_css_class ("sidebar-compact");
                search_entry.visible = false;
                sidebar_menu_button.visible = false;
                sidebar_title.visible = false;
                sidebar_title.title = "";
                set_compact_header_chrome (true);
                set_sidebar_toggle_tooltip (false);
            } else {
                /* FULL and HIDDEN share the expanded layout; they differ only
                   in whether the sidebar starts shown and the toggle's verb. */
                bool hidden = mode == SidebarMode.HIDDEN;
                if (update_visibility) split_view.show_sidebar = !hidden;
                split_view.sidebar_width_unit = Adw.LengthUnit.SP;
                split_view.min_sidebar_width = split_view.collapsed
                    ? COLLAPSED_SIDEBAR_MIN_WIDTH
                    : FULL_SIDEBAR_MIN_WIDTH;
                split_view.max_sidebar_width = split_view.collapsed
                    ? COLLAPSED_SIDEBAR_MAX_WIDTH
                    : FULL_SIDEBAR_MAX_WIDTH;
                split_view.sidebar_width_fraction = 0.32;
                sidebar_box.remove_css_class ("sidebar-compact");
                search_entry.visible = true;
                sidebar_menu_button.visible = true;
                sidebar_title.visible = true;
                sidebar_title.title = "Parla";
                set_compact_header_chrome (false);
                set_sidebar_toggle_tooltip (hidden);
            }
            apply_compact_to_rows (mode == SidebarMode.COMPACT);
            update_archived_toggle ();
        }

        private void set_sidebar_toggle_tooltip (bool hidden) {
            sidebar_toggle_btn.tooltip_text =
                (hidden ? "Show Sidebar (%s)" : "Hide Sidebar (%s)").printf (
                    Platform.primary_shortcut_text ("S"));
        }

        private void set_compact_header_chrome (bool compact) {
            if (!Platform.is_macos ()) return;
            sidebar_header.show_start_title_buttons = !compact;
            sidebar_header.show_end_title_buttons = !compact;
        }

        private void apply_compact_to_rows (bool compact) {
            int idx = 0;
            Gtk.ListBoxRow? row;
            while ((row = chat_listbox.get_row_at_index (idx)) != null) {
                var chat_row = row.child as ChatRow;
                if (chat_row != null) chat_row.set_compact (compact);
                idx++;
            }
        }

        private bool on_window_key_pressed (uint keyval, uint keycode,
                                            Gdk.ModifierType state) {
            /* Image viewer handles its own keys (nav keys move; any
             * other key closes). */
            if (image_viewer.visible) {
                return image_viewer.handle_key (keyval);
            }
            if (video_player.visible) {
                return video_player.handle_key (keyval);
            }

            /* Any non-Escape key (modifiers excepted) breaks a pending
               double-Escape. */
            if (keyval != Gdk.Key.Escape && !is_modifier_keyval (keyval)) {
                escape_armed = false;
            }

            /* Escape: first dismiss any transient UI (open dialog, then the
               in-conversation search). With nothing transient open, a single
               Escape just focuses the entry; a second consecutive Escape
               drops the active reply/edit/attachment mode. */
            if (keyval == Gdk.Key.Escape) {
                var v = current_view ();
                bool dismissed = false;
                for (var w = this.focus_widget; w != null; w = w.get_parent ()) {
                    if (w is Adw.Dialog) {
                        ((Adw.Dialog) w).close ();
                        dismissed = true;
                        break;
                    }
                }
                /* Focus can sit outside the dialog subtree (or nowhere at
                   all); close the presented modal anyway so Escape never
                   goes dead. close() still honours can_close, so dialogs
                   layering Escape (gallery: viewer → selection → close)
                   keep their ordering. */
                if (!dismissed && active_modal != null) {
                    active_modal.close ();
                    dismissed = true;
                }
                if (!dismissed && v != null && v.close_search_if_active ()) {
                    dismissed = true;
                }
                if (dismissed) {
                    escape_armed = false;
                } else if (v != null && v.has_active_compose_mode ()) {
                    /* With focus already in the entry the first Escape has
                       nothing else to do, so drop the reply/edit/attachment
                       right away; from anywhere else the first Escape only
                       focuses the entry and the second one cancels. */
                    if (escape_armed || v.compose_entry_has_focus ()) {
                        v.cancel_active_compose_mode ();
                        escape_armed = false;
                    } else {
                        escape_armed = true;
                    }
                } else {
                    escape_armed = false;
                }
                if (v != null) v.focus_entry ();
                return true;
            }

            /* Type-ahead: a printable key pressed while focus is not in a
               text field (or with nothing focused) is redirected to the
               message entry, so you can start typing without the mouse —
               e.g. click a message, type 'a', and 'a' lands in the entry. */
            if (is_typeahead_key (keyval, state) && !focus_in_text_or_overlay ()) {
                var v = current_view ();
                if (v != null) {
                    unichar uc = (unichar) Gdk.keyval_to_unicode (keyval);
                    if (uc != 0) {
                        v.type_into_entry (uc.to_string ());
                        return true;
                    }
                }
            }

            /* All other shortcuts require the platform primary modifier:
               Ctrl normally, Command on macOS. */
            if (!Platform.has_primary_modifier (state)) return false;

            uint lower_key = Gdk.keyval_to_lower (keyval);

            switch (lower_key) {
            case Gdk.Key.Page_Up:
            case Gdk.Key.KP_Page_Up:
                return focus_adjacent_chat (-1);
            case Gdk.Key.Page_Down:
            case Gdk.Key.KP_Page_Down:
                return focus_adjacent_chat (1);
            /* Ctrl+Tab / Ctrl+Shift+Tab are deliberately not handled here:
               GTK4 reserves them for moving the focus out of a widget that
               eats plain Tab (text views; the chat list has its own handler
               for this). Ctrl+Page_Up / Ctrl+Page_Down browse chat rows;
               Enter commits the focused chat (#57). */
            case Gdk.Key.a:
                if ((state & Gdk.ModifierType.SHIFT_MASK) == 0) return false;
                show_account_menu ();
                return true;
            case Gdk.Key.n:
                on_new_chat ();
                return true;
            case Gdk.Key.g:
                if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) {
                    on_new_channel ();
                } else {
                    on_new_group ();
                }
                return true;
            case Gdk.Key.comma:
                show_settings_dialog ();
                return true;
            case Gdk.Key.plus:
            case Gdk.Key.equal:
            case Gdk.Key.KP_Add:
            case Gdk.Key.KP_Equal:
                adjust_font_size (1);
                return true;
            case Gdk.Key.minus:
            case Gdk.Key.KP_Subtract:
                adjust_font_size (-1);
                return true;
            case Gdk.Key.@0:
            case Gdk.Key.KP_0:
                settings.save_font_size (FONT_SIZE_SYSTEM);
                return true;
            case Gdk.Key.f:
                if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) {
                    focus_contact_search ();
                } else {
                    toggle_message_search ();
                }
                return true;
            case Gdk.Key.k:
                show_quick_switch_dialog ();
                return true;
            case Gdk.Key.l:
                var v = current_view ();
                if (v == null) return false;
                v.focus_entry ();
                return true;
            case Gdk.Key.r:
                refresh_current_chat ();
                return true;
            case Gdk.Key.i:
                if (current_chat_id > 0 && chat_menu != null) {
                    chat_menu.show_info (current_chat_id);
                }
                return true;
            case Gdk.Key.m:
                show_gallery_dialog ();
                return true;
            case Gdk.Key.s:
                if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) {
                    toggle_sidebar_width ();
                } else {
                    toggle_sidebar_visibility ();
                }
                return true;
            case Gdk.Key.w:
                handle_primary_w ();
                return true;
            case Gdk.Key.q:
                handle_primary_q ();
                return true;
            }
            return false;
        }

        private void adjust_font_size (int delta) {
            int next_size = SettingsManager.clamp_font_size (
                settings.effective_font_size () + delta);
            settings.save_font_size (next_size);
        }

        private bool on_chat_scroll (Gtk.EventControllerScroll scroll,
                                     double dx, double dy) {
            if (!Platform.has_primary_modifier (
                    scroll.get_current_event_state ())) {
                return false;
            }
            if (dy == 0) return false;
            adjust_font_size (dy < 0 ? 1 : -1);
            return true;
        }

        /* A printable character (excluding space) with no Ctrl/Alt/Super/Meta
           held. Shift and CapsLock are allowed (capitals, shifted symbols).
           Space is excluded so it still activates a keyboard-focused button or
           chat row; navigation/control keys (arrows, Enter, Tab, Backspace,
           F-keys…) map to 0 or a control char via keyval_to_unicode, so they
           are excluded too. */
        private static bool is_typeahead_key (uint keyval, Gdk.ModifierType state) {
            var mods = state & (Gdk.ModifierType.CONTROL_MASK
                              | Gdk.ModifierType.ALT_MASK
                              | Gdk.ModifierType.SUPER_MASK
                              | Gdk.ModifierType.META_MASK);
            if (mods != 0) return false;
            uint uc = Gdk.keyval_to_unicode (keyval);
            return uc > 0x20 && uc != 0x7f;
        }

        /* Whether the focused widget should keep the key rather than have it
           redirected to the compose entry: any text field, or anything inside
           an open dialog or popover. */
        private static bool is_modifier_keyval (uint keyval) {
            switch (keyval) {
            case Gdk.Key.Shift_L:
            case Gdk.Key.Shift_R:
            case Gdk.Key.Control_L:
            case Gdk.Key.Control_R:
            case Gdk.Key.Alt_L:
            case Gdk.Key.Alt_R:
            case Gdk.Key.Meta_L:
            case Gdk.Key.Meta_R:
            case Gdk.Key.Super_L:
            case Gdk.Key.Super_R:
            case Gdk.Key.Caps_Lock:
                return true;
            default:
                return false;
            }
        }

        private bool focus_in_text_or_overlay () {
            for (var w = this.focus_widget; w != null; w = w.get_parent ()) {
                if (w is Gtk.Editable || w is Gtk.TextView) return true;
                if (w is Gtk.Popover || w is Adw.Dialog) return true;
            }
            return false;
        }

        private void focus_contact_search () {
            /* The entry is hidden in compact mode and the sidebar itself
               may be hidden (or collapsed away on narrow widths); make
               both visible before grabbing focus. */
            if (settings.sidebar_mode != SidebarMode.FULL) {
                settings.save_sidebar_mode (SidebarMode.FULL);
                apply_sidebar_mode (true);
            } else if (!split_view.show_sidebar) {
                split_view.show_sidebar = true;
            }
            search_entry.grab_focus ();
        }

        private void toggle_message_search () {
            var v = current_view ();
            if (v != null) v.toggle_search ();
        }

        private void refresh_current_chat () {
            request_reload_chats ();
            if (current_chat_id > 0) {
                request_messages_reload ();
            }
        }

        private void show_account_menu () {
            if (active_modal != null) return;

            focus_current_account_on_menu_load = true;
            if (account_popover.get_visible ()) {
                focus_current_account_menu_row_if_requested ();
                return;
            }

            account_menu_button.popup ();
        }

        /* Ctrl+Page Up/Down browse the chat list without committing to a
           chat. This is especially important for screen-reader users: moving
           through unread rows must not load their conversations or mark their
           messages as seen. Enter (or a click) activates the focused row.
           Prefer the keyboard-focused row as the next starting point, so
           repeated presses continue through the list while the open chat
           stays unchanged. */
        private bool focus_adjacent_chat (int delta) {
            Gtk.ListBoxRow[] visible_rows = {};
            int focused_chat_id = focused_chat_row_id ();
            int current_index = -1;
            Gtk.ListBoxRow? row;

            int index = 0;
            while ((row = chat_listbox.get_row_at_index (index)) != null) {
                index++;
                if (!filter_chats (row)) continue;
                var chat_row = row.child as ChatRow;
                if (chat_row == null) continue;
                visible_rows += row;
                int visible_index = visible_rows.length - 1;
                if (chat_row.chat_id == focused_chat_id) {
                    current_index = visible_index;
                } else if (focused_chat_id == 0
                           && chat_row.chat_id == current_chat_id) {
                    current_index = visible_index;
                }
            }

            if (visible_rows.length == 0) return false;
            if (visible_rows.length == 1) {
                visible_rows[0].grab_focus ();
                return true;
            }

            int target_index;
            if (current_index < 0) {
                target_index = delta > 0 ? 0 : visible_rows.length - 1;
            } else {
                target_index = current_index + delta;
                if (target_index < 0) {
                    target_index = visible_rows.length - 1;
                } else if (target_index >= visible_rows.length) {
                    target_index = 0;
                }
            }

            visible_rows[target_index].grab_focus ();
            return true;
        }

        private void show_quick_switch_dialog () {
            if (!can_show_account_modal ()) return;
            if (chat_store.get_n_items () == 0) return;

            var dialog = new QuickSwitchDialog (chat_store);
            dialog.chat_selected.connect ((chat_id) => {
                select_chat_by_id (chat_id);
            });
            present_modal (dialog);
            dialog.focus_entry ();
        }

        public bool current_chat_is_group () {
            var entry = find_chat_entry (chat_store, current_chat_id);
            return entry != null && entry.kind == ChatKind.GROUP;
        }

        public bool select_chat_by_id (int chat_id) {
            int idx = 0;
            Gtk.ListBoxRow? row;
            while ((row = chat_listbox.get_row_at_index (idx)) != null) {
                var chat_row = row.child as ChatRow;
                if (chat_row != null && chat_row.chat_id == chat_id) {
                    open_chat_row (row);
                    return true;
                }
                idx++;
            }
            return false;
        }

        private const string[] SHORTCUTS = {
            "New chat",              "<Primary>n",
            "New group",             "<Primary>g",
            "New channel",           "<Primary><Shift>g",
            "Open settings",         "<Primary>comma",
            "Increase font size",     "<Primary>plus",
            "Decrease font size",     "<Primary>minus",
            "Reset font size",        "<Primary>0",
            "Open chat info",        "<Primary>i",
            "Apps and media gallery","<Primary>m",
            "Search in conversation","<Primary>f",
            "Search contacts",       "<Primary><Shift>f",
            "Quick switch chat",     "<Primary>k",
            "Focus message entry",   "<Primary>l",
            "Account menu",          "<Primary><Shift>a",
            "Focus next chat",       "<Primary>Page_Down",
            "Focus previous chat",   "<Primary>Page_Up",
            "Refresh messages",      "<Primary>r",
            "Toggle sidebar",        "<Primary>s",
            "Compact sidebar",       "<Primary><Shift>s",
            "Focus message entry",   "Escape",
            "Cancel reply/edit/image", "Escape",
            "Close window",          "<Primary>w",
            "Quit application",      "<Primary>q",
        };

        private static string shortcut_accelerator (string accelerator) {
            return accelerator.replace ("<Primary>",
                Platform.primary_accelerator_prefix ());
        }

        private static string shortcut_label_text (string accelerator) {
            uint key;
            Gdk.ModifierType mods;
            var resolved = shortcut_accelerator (accelerator);
            if (!Gtk.accelerator_parse (resolved, out key, out mods)) {
                return resolved;
            }
            return Gtk.accelerator_get_label (key, mods);
        }

        private void show_keyboard_shortcuts_dialog () {
            if (active_modal != null) return;

            Gtk.Box box;
            var dialog = make_modal ("Shortcuts", 400, out box);
            dialog.content_height = 380;

            var scroller = new Gtk.ScrolledWindow ();
            scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroller.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            scroller.vexpand = true;
            scroller.hexpand = true;

            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.margin_start = list.margin_end = list.margin_top = list.margin_bottom = 12;

            for (int i = 0; i + 1 < SHORTCUTS.length; i += 2) {
                var row = new Adw.ActionRow ();
                row.title = SHORTCUTS[i];
                var lbl = new Gtk.Label (shortcut_label_text (SHORTCUTS[i + 1]));
                lbl.valign = Gtk.Align.CENTER;
                lbl.add_css_class ("dim-label");
                row.add_suffix (lbl);
                list.append (row);
            }

            var wheel_row = new Adw.ActionRow ();
            wheel_row.title = "Change font size";
            var wheel_lbl = new Gtk.Label (
                Platform.primary_shortcut_text ("Mouse Wheel"));
            wheel_lbl.valign = Gtk.Align.CENTER;
            wheel_lbl.add_css_class ("dim-label");
            wheel_row.add_suffix (wheel_lbl);
            list.append (wheel_row);

            /* The emoji picker opens on a typed "::" rather than a key
               accelerator, so it gets a plain-text suffix. */
            var emoji_row = new Adw.ActionRow ();
            emoji_row.title = "Emoji picker";
            var emoji_lbl = new Gtk.Label ("::");
            emoji_lbl.valign = Gtk.Align.CENTER;
            emoji_lbl.add_css_class ("dim-label");
            emoji_row.add_suffix (emoji_lbl);
            list.append (emoji_row);

            scroller.child = list;
            box.append (scroller);
            dialog.child = box;
            present_modal (dialog);
        }

        /* Toast with a single action button, e.g. "Chat archived" + Mute. */
        public Adw.Toast show_action_toast (string message,
                                            string button_label) {
            var toast = new Adw.Toast (message);
            toast.timeout = 6;
            toast.button_label = button_label;
            var modal_toasts = active_modal != null
                ? active_modal.child as Adw.ToastOverlay : null;
            (modal_toasts ?? toast_overlay).add_toast (toast);
            return toast;
        }

        public void show_toast (string message) {
            var toast = new Adw.Toast (message);
            toast.timeout = 4;
            /* The main overlay is invisible under a modal dialog; route
               into the dialog's own overlay when it has one (dialogs
               wanting local toasts make an Adw.ToastOverlay their child,
               like GalleryDialog). */
            var modal_toasts = active_modal != null
                ? active_modal.child as Adw.ToastOverlay : null;
            (modal_toasts ?? toast_overlay).add_toast (toast);
        }

        private Gtk.Revealer build_connection_banner () {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.add_css_class ("connection-banner");

            var icon = new Gtk.Image.from_icon_name ("network-offline-symbolic");
            icon.pixel_size = 14;
            box.append (icon);

            connection_banner_label = new Gtk.Label ("Not connected");
            connection_banner_label.add_css_class ("connection-banner-label");
            box.append (connection_banner_label);

            connection_banner = new Gtk.Revealer ();
            connection_banner.child = box;
            connection_banner.reveal_child = false;
            connection_banner.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
            connection_banner.transition_duration = 200;
            connection_banner.halign = Gtk.Align.CENTER;
            connection_banner.valign = Gtk.Align.START;
            connection_banner.margin_top = 8;
            connection_banner.can_target = false;   /* clicks pass through */
            return connection_banner;
        }

        public void set_connection_status (bool connected, string? reason = null) {
            if (connection_banner == null) return;
            if (connected) {
                connection_banner.reveal_child = false;
            } else {
                connection_banner_label.label = reason ?? "Not connected";
                connection_banner.reveal_child = true;
            }
        }

    }
}
