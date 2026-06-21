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
        private Gtk.SearchEntry search_entry;
        private Gtk.Box sidebar_box;
        private Gtk.Button sidebar_toggle_btn;
        private Gtk.MenuButton sidebar_menu_button;
        private Adw.WindowTitle sidebar_title;

        /* Chat list */
        private Gtk.ListBox chat_listbox;
        public GLib.ListStore chat_store { get; private set; }

        /* Per-chat cached views */
        private HashTable<int, ConversationView> views;

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

        /* State */
        private unowned RpcClient rpc;
        private int _current_chat_id = 0;
        private bool suppress_reselect_scroll = false;
        public int current_chat_id {
            get { return _current_chat_id; }
            private set {
                _current_chat_id = value;
                if (events != null) events.active_chat_id = value;
            }
        }

        /* Extracted managers */
        public SettingsManager settings;
        private ImageViewer image_viewer;
        private VideoPlayer video_player;
        private EventHandler events;
        private ChatContextMenu chat_menu;
        private ChatSwitcher chat_switcher;
        private bool reconnecting_rpc = false;
        private uint unread_notification_timer = 0;
        private int[] pending_unread_notification_accounts = {};
        private int applied_media_font_size = -1;

        private const double FULL_SIDEBAR_MIN_WIDTH = 260;
        private const double FULL_SIDEBAR_MAX_WIDTH = 340;
        private const double COLLAPSED_SIDEBAR_MIN_WIDTH = 220;
        private const double COLLAPSED_SIDEBAR_MAX_WIDTH = 10000;
        private const double COMPACT_SIDEBAR_WIDTH = 48;

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

        private void present_modal (Adw.Dialog dialog) {
            active_modal = dialog;
            dialog.closed.connect (() => {
                active_modal = null;
                /* Return focus to the compose entry so in-conversation
                   shortcuts work immediately after dismissing a modal. */
                var v = current_view ();
                if (v != null) v.focus_entry ();
            });
            dialog.present (this);
        }

        private void reset_chat_ui () {
            discard_all_views ();
            chat_store.remove_all ();
            clear_listbox (chat_listbox);
            search_entry.text = "";
            content_title_label.label = "Select a chat";
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

        private TrayIcon? tray = null;
        private bool held_in_background = false;
        private NativeFileDropTarget? native_file_drop_target;

        /* Set after an Escape that had nothing transient to dismiss while a
           compose mode is active; a second consecutive Escape then drops the
           reply/edit/attachment. Any other key clears it. */
        private bool escape_armed = false;

        public Window (Dc.Application app) {
            Object (
                application: app,
                default_width: 920,
                default_height: 640,
                width_request: 300,
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
            apply_current_appearance ();

            settings.appearance_changed.connect (() => {
                MessageRow.style = settings.message_style;
                apply_current_appearance ();
                rebuild_current_chat_view ();
            });
            settings.font_changed.connect (() => {
                int previous_size = applied_media_font_size;
                apply_current_appearance ();
                if (applied_media_font_size != previous_size) {
                    var v = current_view ();
                    if (v != null) v.queue_resize ();
                }
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
            applied_media_font_size = settings.font_size;
            MessageRow.set_media_scale (
                settings.font_size,
                SettingsManager.system_font_size ());
            app.apply_accent_color (settings.accent_color);
            app.apply_background (
                settings.background_mode, settings.background_color);
            app.apply_font (
                settings.font_family,
                settings.font_attribute,
                settings.font_size);
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
            /* No tray on macOS (see sync_tray) — hiding the window with the
               app held would leave it running with no way back and crashes
               the GTK macOS backend, so always do a normal close there. */
            if (Platform.is_macos ()) return false;
            if (!settings.minimize_to_tray && !settings.notifications_enabled)
                return false;
            this.set_visible (false);
            if (!held_in_background) {
                this.application.hold ();
                held_in_background = true;
            }
            return true;
        }

        private void handle_native_file_drop (string path) {
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
            /* StatusNotifierItem is a freedesktop/D-Bus protocol with no
               watcher on macOS — the icon can never show up there. */
            if (Platform.is_macos ()) return;
            if (tray == null && settings.minimize_to_tray) {
                var conn = this.application.get_dbus_connection ();
                if (conn == null) return;
                tray = new TrayIcon (conn);
                tray.show_requested.connect (restore_from_tray);
                tray.quit_requested.connect (() => {
                    release_background_hold ();
                    this.application.quit ();
                });
                tray.notifications_toggle_requested.connect ((enabled) => {
                    set_notifications_enabled (enabled);
                });
            }
            if (tray == null) return;
            tray.set_notifications_enabled (settings.notifications_enabled);
            if (settings.minimize_to_tray) tray.show ();
            else { tray.hide (); restore_from_tray (); }
        }

        public void restore_from_tray () {
            release_background_hold ();
            this.present ();
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
            account_menu_button.popover = account_popover;
            sidebar_header.pack_start (account_menu_button);

            /* Hamburger menu button on the right */
            sidebar_menu_button = new Gtk.MenuButton ();
            sidebar_menu_button.icon_name = "open-menu-symbolic";
            sidebar_menu_button.tooltip_text = "Main Menu";
            sidebar_menu_button.add_css_class ("flat");
            sidebar_menu_button.menu_model = build_app_menu ();
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
            sidebar_box.append (search_entry);

            /* Chat list */
            var chat_scroll = new Gtk.ScrolledWindow ();
            chat_scroll.vexpand = true;
            chat_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            chat_listbox = new Gtk.ListBox ();
            chat_listbox.selection_mode = Gtk.SelectionMode.SINGLE;
            chat_listbox.add_css_class ("navigation-sidebar");
            chat_listbox.set_filter_func (filter_chats);
            chat_listbox.row_selected.connect (on_chat_selected);
            /* row_selected does not fire when tapping the already-selected
               chat, so that tap would otherwise do nothing in collapsed
               (mobile) mode. Close the sidebar to return to the conversation.
               For different-chat taps row_selected runs first and has already
               closed the sidebar, so this is a no-op. */
            chat_listbox.row_activated.connect ((row) => {
                if (split_view.collapsed && split_view.show_sidebar) {
                    split_view.show_sidebar = false;
                    var v = current_view ();
                    if (v != null && this.is_active) v.flush_pending_seen ();
                }
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

            chat_scroll.child = chat_listbox;
            sidebar_box.append (chat_scroll);

            /* ---- Content area ---- */
            var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            content_header = new Adw.HeaderBar ();
            content_title_label = new Gtk.Label ("Select a chat");
            content_title_label.add_css_class ("heading");
            content_title_label.ellipsize = Pango.EllipsizeMode.END;
            content_header.title_widget = content_title_label;

            /* Sidebar visibility button. On collapsed/mobile widths this
               opens the sidebar as the full-width overlay instead of compact. */
            sidebar_toggle_btn = new Gtk.Button.from_icon_name ("sidebar-show-symbolic");
            sidebar_toggle_btn.add_css_class ("flat");
            sidebar_toggle_btn.clicked.connect (() => { toggle_sidebar_button (); });
            content_header.pack_start (sidebar_toggle_btn);

            /* Search/filter button on the right side */
            var search_btn = new Gtk.Button.from_icon_name ("edit-find-symbolic");
            search_btn.tooltip_text = "Search in conversation (%s)".printf (
                Platform.primary_shortcut_text ("F"));
            search_btn.clicked.connect (() => { toggle_message_search (); });
            content_header.pack_end (search_btn);

            content_box.append (content_header);

            /* Stack: empty status + one child per chat view (added lazily) */
            content_stack = new Gtk.Stack ();
            content_stack.vexpand = true;

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
            var breakpoint = new Adw.Breakpoint (
                Adw.BreakpointCondition.parse ("max-width: 600px"));
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

            apply_sidebar_mode (true);

            chat_switcher = new ChatSwitcher (
                this, chat_listbox, chat_store, sidebar_box, split_view);

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

            var scroll_ctrl = new Gtk.EventControllerScroll (
                Gtk.EventControllerScrollFlags.VERTICAL |
                Gtk.EventControllerScrollFlags.DISCRETE);
            scroll_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            scroll_ctrl.scroll.connect (on_window_scroll);
            ((Gtk.Widget) this).add_controller (scroll_ctrl);
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
            string accounts_path = Path.build_filename (data_dir, "accounts");

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

            /* Create event handler and message actions now that rpc is ready */
            events = new EventHandler (rpc);
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
            events.account_unread_changed.connect ((acct_id) => {
                update_unread_indicators.begin ();
                queue_unread_notification_refresh (acct_id);
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
            content_stack.visible_child_name = "empty";
        }

        public ConversationView? current_view () {
            if (current_chat_id <= 0) return null;
            return views.lookup (current_chat_id);
        }

        private ConversationView get_or_create_view (int chat_id,
                                                     ChatKind kind = ChatKind.UNKNOWN) {
            var v = views.lookup (chat_id);
            if (v != null) {
                v.set_chat_kind (kind);
                return v;
            }
            v = new ConversationView (chat_id, this, rpc, settings, kind);
            views.insert (chat_id, v);
            content_stack.add_named (v, "chat_%d".printf (chat_id));
            return v;
        }

        public void request_messages_reload () {
            if (events != null) events.schedule_messages_reload ();
        }

        public async void load_chats () {
            if (rpc.account_id <= 0) return;

            try {
                var entries = yield rpc.get_chatlist_entries_for (rpc.account_id);
                if (entries == null) return;

                var items = yield rpc.get_chatlist_items_by_entries_for (
                    rpc.account_id, entries);

                chat_store.remove_all ();
                clear_listbox (chat_listbox);

                Gtk.ListBoxRow? reselect_row = null;
                for (uint i = 0; i < entries.get_length (); i++) {
                    int chat_id = (int) entries.get_int_element (i);
                    string id_str = chat_id.to_string ();

                    if (items != null && items.has_member (id_str)) {
                        var item = items.get_object_member (id_str);
                        var entry = RpcParsers.parse_chat_item (chat_id, item);
                        chat_store.append (entry);

                        var row = new Gtk.ListBoxRow ();
                        var chat_row = new ChatRow (entry);
                        chat_row.set_compact (settings.sidebar_mode == SidebarMode.COMPACT);
                        row.child = chat_row;
                        chat_listbox.append (row);

                        if (chat_id == current_chat_id) {
                            reselect_row = row;
                        }
                    }
                }

                if (reselect_row != null) {
                    suppress_reselect_scroll = true;
                    chat_listbox.select_row (reselect_row);
                    suppress_reselect_scroll = false;
                }
            } catch (Error e) {
                show_toast ("Failed to load chats: " + e.message);
            }
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

        private void on_chat_selected (Gtk.ListBoxRow? row) {
            if (row == null) return;

            var chat_row = row.child as ChatRow;
            if (chat_row == null) return;

            int chat_id = chat_row.chat_id;

            if (chat_id == current_chat_id) {
                if (suppress_reselect_scroll) return;
                if (split_view.collapsed) {
                    split_view.show_sidebar = false;
                }
                var v = current_view ();
                if (v != null) {
                    v.on_reselected ();
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
            /* Contact requests swap the compose box for an Accept/Block bar. */
            view.set_contact_request (entry != null && entry.is_contact_request);

            content_stack.visible_child_name = "chat_%d".printf (chat_id);
            view.on_activated ();
            if (this.is_active) view.flush_pending_seen ();

            notice_chat.begin (current_chat_id);

            /* In narrow/mobile mode, hide the sidebar so the chat takes over */
            if (split_view.collapsed) {
                split_view.show_sidebar = false;
            }
        }

        private async void notice_chat (int chat_id) {
            try {
                yield rpc.marknoticed_chat (chat_id);
            } catch (Error e) {
                /* non-critical */
            }
            if (events != null) {
                events.clear_notifications_for_chat (rpc.account_id, chat_id);
            }
            queue_unread_notification_refresh (rpc.account_id);
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
                if (e is IOError.CANCELLED) return;
                show_toast ("Save failed: " + e.message);
            }
        }

        /* ================================================================
         *  Event Loop (delegates to EventHandler)
         * ================================================================ */

        public void request_reload_chats () {
            if (events != null) events.schedule_chats_reload ();
        }

        private void queue_unread_notification_refresh (int acct_id) {
            if (acct_id <= 0 || events == null || !settings.notifications_enabled)
                return;

            foreach (int pending in pending_unread_notification_accounts) {
                if (pending == acct_id) return;
            }
            pending_unread_notification_accounts += acct_id;

            if (unread_notification_timer > 0) return;
            unread_notification_timer = Timeout.add (400, () => {
                unread_notification_timer = 0;
                int[] accounts = pending_unread_notification_accounts;
                pending_unread_notification_accounts = {};

                foreach (int id in accounts) {
                    if (events == null || !settings.notifications_enabled) break;
                    bool allow_send = id != rpc.account_id
                        || !this.get_visible ()
                        || !this.is_active;
                    events.refresh_unread_notification.begin (id, allow_send);
                }
                return Source.REMOVE;
            });
        }

        private async void on_incoming_msg (int acct_id, int chat_id, int msg_id) {
            if (acct_id != rpc.account_id) {
                queue_unread_notification_refresh (acct_id);
                update_unread_indicators.begin ();
                return;
            }

            var view = views.lookup (chat_id);
            if (view != null) {
                yield view.handle_incoming_msg (msg_id);
            }
            queue_unread_notification_refresh (acct_id);
            request_reload_chats ();
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

        private void on_add_account () {
            if (active_modal != null) return;

            var dialog = new Adw.Dialog ();
            dialog.title = "Add Profile";
            dialog.content_width = 460;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

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
            var dialog = new Adw.AlertDialog (
                "Use classic email address",
                "Enter your email and password."
            );

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            var email_entry = new Gtk.Entry ();
            email_entry.placeholder_text = "user@example.com";
            email_entry.input_purpose = Gtk.InputPurpose.EMAIL;
            box.append (email_entry);

            var pass_entry = new Gtk.PasswordEntry ();
            pass_entry.placeholder_text = "Password";
            pass_entry.show_peek_icon = true;
            box.append (pass_entry);

            dialog.extra_child = box;

            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("add", "Add");
            dialog.set_response_appearance ("add", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "add";

            pass_entry.activate.connect (() => {
                dialog.response ("add");
            });

            dialog.response.connect ((resp) => {
                if (resp == "add") {
                    string email = email_entry.text.strip ();
                    string password = pass_entry.text;
                    if (email.length > 0 && email.contains ("@") && password.length > 0) {
                        do_add_account.begin (email, password);
                    }
                }
            });

            dialog.present (this);
        }

        private async void do_add_account (string email, string password) {
            try {
                int acct_id = yield rpc.add_account ();
                yield rpc.add_or_update_transport (acct_id, email, password);
                yield rpc.select_account (acct_id);
                /* Pick up IO for the freshly added account (and keep the rest
                   running too). */
                yield rpc.start_io_for_all_accounts ();
                rpc.account_id = acct_id;
                yield reload_active_account ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        public async bool switch_account (int acct_id) {
            if (acct_id <= 0 || acct_id == rpc.account_id) return false;

            try {
                /* IO stays running for every account, so switching only changes
                   which account is shown — the others keep fetching mail in the
                   background. Re-asserting all-accounts IO here is idempotent and
                   also covers accounts created during this session. */
                yield rpc.start_io_for_all_accounts ();
                yield rpc.select_account (acct_id);
                rpc.account_id = acct_id;
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
            var dialog = new ProfileDialog (rpc, settings, acct_id);
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

        private GLib.MenuModel build_app_menu () {
            window_action ("new-chat").activate.connect (() => { on_new_chat (); });
            window_action ("new-group").activate.connect (() => { on_new_group (); });
            window_action ("new-channel").activate.connect (() => { on_new_channel (); });
            window_action ("use-invite-link").activate.connect (() => { show_use_invite_link_dialog (); });
            window_action ("refresh").activate.connect (() => { load_chats.begin (); });
            window_action ("settings").activate.connect (() => { show_settings_dialog (); });
            window_action ("shortcuts").activate.connect (() => { show_keyboard_shortcuts_dialog (); });
            window_action ("about").activate.connect (() => { show_about_dialog (); });
            window_action ("quit").activate.connect (() => { this.application.quit (); });
            window_action ("font-increase").activate.connect (() => { adjust_font_size (1); });
            window_action ("font-decrease").activate.connect (() => { adjust_font_size (-1); });
            window_action ("font-reset").activate.connect (() => {
                settings.save_font_size (FONT_SIZE_SYSTEM);
            });

            var s1 = new GLib.Menu ();
            s1.append ("New Chat", "win.new-chat");
            s1.append ("New Group", "win.new-group");
            s1.append ("New Channel", "win.new-channel");
            s1.append ("Use Invite Link", "win.use-invite-link");
            var s2 = new GLib.Menu ();
            s2.append ("Settings", "win.settings");
            var s3 = new GLib.Menu ();
            s3.append ("Shortcuts", "win.shortcuts");
            s3.append ("About", "win.about");
            var s4 = new GLib.Menu ();
            s4.append ("Quit", "win.quit");

            var menu = new GLib.Menu ();
            menu.append_section (null, s1);
            menu.append_section (null, s2);
            menu.append_section (null, s3);
            menu.append_section (null, s4);
            return menu;
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
            about.developers = Parla.AppData.developers ();
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

            var dialog = new Adw.Dialog ();
            dialog.title = "Use Invite Link";
            dialog.content_width = 460;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

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
                content_stack.remove (v);
            }
            views.remove_all ();
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
            switch (mode) {
            case SidebarMode.FULL:
                if (update_visibility) split_view.show_sidebar = true;
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
                sidebar_toggle_btn.icon_name = "sidebar-show-symbolic";
                sidebar_toggle_btn.tooltip_text = "Hide Sidebar (%s)".printf (
                    Platform.primary_shortcut_text ("S"));
                break;
            case SidebarMode.COMPACT:
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
                sidebar_toggle_btn.icon_name = "sidebar-show-symbolic";
                sidebar_toggle_btn.tooltip_text = "Hide Sidebar (%s)".printf (
                    Platform.primary_shortcut_text ("S"));
                break;
            case SidebarMode.HIDDEN:
                if (update_visibility) split_view.show_sidebar = false;
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
                sidebar_toggle_btn.icon_name = "sidebar-show-symbolic";
                sidebar_toggle_btn.tooltip_text = "Show Sidebar (%s)".printf (
                    Platform.primary_shortcut_text ("S"));
                break;
            }
            apply_compact_to_rows (mode == SidebarMode.COMPACT);
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

            if (chat_switcher.handle_key (keyval, state)) return true;

            /* All other shortcuts require the platform primary modifier:
               Ctrl normally, Command on macOS. */
            if (!Platform.has_primary_modifier (state)) return false;

            uint lower_key = Gdk.keyval_to_lower (keyval);
#if PARLA_MACOS_CLIPBOARD_WORKAROUND
            if (lower_key == Gdk.Key.v && paste_macos_text_into_focus ())
                return true;
#endif

            switch (lower_key) {
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
                toggle_message_search ();
                return true;
            case Gdk.Key.k:
                show_quick_switch_dialog ();
                return true;
            case Gdk.Key.r:
                refresh_current_chat ();
                return true;
            case Gdk.Key.s:
                if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) {
                    toggle_sidebar_width ();
                } else {
                    toggle_sidebar_visibility ();
                }
                return true;
            case Gdk.Key.w:
                this.close ();
                return true;
            case Gdk.Key.q:
                this.application.quit ();
                return true;
            }
            return false;
        }

        private void adjust_font_size (int delta) {
            int next_size = SettingsManager.clamp_font_size (
                settings.effective_font_size () + delta);
            settings.save_font_size (next_size);
        }

        private bool on_window_scroll (Gtk.EventControllerScroll scroll,
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

        internal bool shortcuts_modal_open () {
            return active_modal != null;
        }

        internal Gtk.Widget? shortcuts_focus_widget () {
            return focus_widget ?? get_focus ();
        }

        internal bool shortcuts_filter_chat_row (Gtk.ListBoxRow row) {
            return filter_chats (row);
        }

#if PARLA_MACOS_CLIPBOARD_WORKAROUND
        private bool paste_macos_text_into_focus () {
            if (!Platform.is_macos ()) return false;

            var focus = this.focus_widget;
            if (focus == null || is_inside_compose_bar (focus)) return false;

            string? text = null;
            for (var w = focus; w != null; w = w.get_parent ()) {
                var editable = w as Gtk.Editable;
                if (editable != null && editable.get_editable ()) {
                    text = text ?? Platform.read_macos_pasteboard_text ();
                    if (text == null || text.length == 0) return false;

                    editable.delete_selection ();
                    int position = editable.get_position ();
                    editable.do_insert_text (text, text.length, ref position);
                    editable.set_position (position);
                    return true;
                }

                var text_view = w as Gtk.TextView;
                if (text_view != null && text_view.editable) {
                    text = text ?? Platform.read_macos_pasteboard_text ();
                    if (text == null || text.length == 0) return false;

                    text_view.buffer.delete_selection (true, text_view.editable);
                    text_view.buffer.insert_at_cursor (text, text.length);
                    return true;
                }
            }
            return false;
        }

        private static bool is_inside_compose_bar (Gtk.Widget widget) {
            for (var w = widget; w != null; w = w.get_parent ()) {
                if (w is ComposeBar) return true;
            }
            return false;
        }
#endif

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

        public bool select_chat_by_id (int chat_id) {
            int idx = 0;
            Gtk.ListBoxRow? row;
            while ((row = chat_listbox.get_row_at_index (idx)) != null) {
                var chat_row = row.child as ChatRow;
                if (chat_row != null && chat_row.chat_id == chat_id) {
                    chat_listbox.select_row (row);
                    on_chat_selected (row);
                    return true;
                }
                idx++;
            }
            return false;
        }

        private const string[] SHORTCUTS_BEFORE_CHAT_SWITCHER = {
            "New chat",              "<Primary>n",
            "New group",             "<Primary>g",
            "New channel",           "<Primary><Shift>g",
            "Open settings",         "<Primary>comma",
            "Increase font size",     "<Primary>plus",
            "Decrease font size",     "<Primary>minus",
            "Reset font size",        "<Primary>0",
            "Search in conversation","<Primary>f",
            "Quick switch chat",     "<Primary>k",
            "Account menu",          "<Primary><Shift>a",
        };

        private const string[] SHORTCUTS_AFTER_CHAT_SWITCHER = {
            "Refresh messages",      "<Primary>r",
            "Toggle sidebar",        "<Primary>s",
            "Compact sidebar",       "<Primary><Shift>s",
            "Focus message entry",   "Escape",
            "Cancel reply/edit/image", "Escape",
            "Close window",          "<Primary>w",
            "Quit application",      "<Primary>q",
        };

        private void append_shortcut_rows (Gtk.ListBox list, string[] pairs) {
            for (int i = 0; i + 1 < pairs.length; i += 2) {
                var row = new Adw.ActionRow ();
                row.title = pairs[i];
                var lbl = new Gtk.Label (shortcut_label_text (pairs[i + 1]));
                lbl.valign = Gtk.Align.CENTER;
                lbl.add_css_class ("dim-label");
                row.add_suffix (lbl);
                list.append (row);
            }
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

        private void show_keyboard_shortcuts_dialog () {
            if (active_modal != null) return;

            var dialog = new Adw.Dialog ();
            dialog.title = "Shortcuts";
            dialog.content_width = 400;
            dialog.content_height = 380;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

            var scroller = new Gtk.ScrolledWindow ();
            scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroller.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            scroller.vexpand = true;
            scroller.hexpand = true;

            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.margin_start = list.margin_end = list.margin_top = list.margin_bottom = 12;

            append_shortcut_rows (list, SHORTCUTS_BEFORE_CHAT_SWITCHER);
            chat_switcher.append_shortcut_rows (list);
            append_shortcut_rows (list, SHORTCUTS_AFTER_CHAT_SWITCHER);

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

        public void show_toast (string message) {
            var toast = new Adw.Toast (message);
            toast.timeout = 4;
            toast_overlay.add_toast (toast);
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
