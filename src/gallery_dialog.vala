namespace Dc {

    /** Implemented by both gallery cell flavours (grid thumbnails and
        list rows) so GalleryDialog drives them through a single list
        item factory (see GalleryDialog.make_cell_factory). */
    private interface GalleryCell : Gtk.Widget {
        public abstract Message? msg { get; set; }
        public abstract void bind (Message m);
        public abstract void unbind ();
    }

    /**
     * Per-chat media overview mirroring the official Delta Chat gallery:
     * tabs for Apps, Images, Video, Audio and Files. Message ids come from
     * the get_chat_media JSON-RPC call — a metadata-only database query,
     * so nothing is downloaded to build the lists. Core returns the ids
     * oldest first; we display newest first like the official client.
     *
     * Images and videos open in the same fullscreen viewers used by the
     * conversation (ImageViewer / VideoPlayer), overlaid on the dialog.
     */
    public class GalleryDialog : Adw.Dialog {

        /* Keep three responsive cells within the narrow dialog floor. */
        private const int CELL_MIN = 76;
        private const int CELL_MAX = 512;
        private const int FETCH_CHUNK = 50;

        /* Ctrl+wheel thumbnail zoom, expressed as the grids' column cap:
           fewer columns means larger cells. Never implemented by raising
           the cells' minimum width — that pins the grid minimum past the
           dialog's fixed natural width and trips min > natural warnings.
           Static so the zoom persists across gallery openings within the
           session. */
        private const int ZOOM_COLUMNS_MAX = 12;
        private static int zoom_columns = ZOOM_COLUMNS_MAX;

        /* Sticker gallery membership follows the semantic Sticker viewtype
           (see Message.is_sticker_file), regardless of the file encoding. */
        private enum MediaFilter { ALL, STICKERS_ONLY, NO_STICKERS }

        private unowned Window app_window;
        private unowned RpcClient rpc;
        private int chat_id;

        /* Dialog this gallery was presented on top of (Chat Info). "View
           in Conversation" must close the whole stack, not just the
           gallery, or the leftover dialog re-scrolls the chat when the
           user closes it later. */
        public unowned Adw.Dialog? presenter_dialog = null;

        private Adw.ViewStack view_stack;
        private Adw.ToastOverlay toasts;
        private Gtk.Button save_all_btn;
        private Gtk.MenuButton more_btn;
        private Gtk.Popover more_popover;
        private HashTable<string, Gtk.Button> more_items =
            new HashTable<string, Gtk.Button> (str_hash, str_equal);
        private ImageViewer viewer;
        private VideoPlayer player;

        private Gtk.Box switcher_bar;
        private Gtk.Box selection_bar;
        private Gtk.Revealer selection_revealer;
        private Gtk.Label selection_label;
        private Gtk.Button forward_sel_btn;
        private Gtk.Button save_sel_btn;
        private Gtk.Button delete_sel_btn;

        /* Multi-selection mode, entered via "Select…" in an item's context
           menu. Cells watch selection_changed to refresh their checkmarks
           (they are recycled, so they cannot bind once). */
        public bool selection_mode { get; private set; default = false; }
        public signal void selection_changed ();
        private HashTable<int, bool> selected_ids =
            new HashTable<int, bool> (direct_hash, direct_equal);

        private GalleryTab[] tabs = {};
        private Gtk.GridView[] media_grids = {};
        private bool is_open = true;

        private HashTable<string, Gdk.Texture> thumb_cache =
            new HashTable<string, Gdk.Texture> (str_hash, str_equal);
        private ThreadPool<ThumbRequest>? thumb_pool = null;

        private class GalleryTab : Object {
            public string key;
            public string title;
            public string icon_name;
            /* Up to three core viewtypes queried via get_chat_media. */
            public string[] types;
            public MediaFilter filter;
            public string empty_title;
            public string empty_description;
            /* "…" is substituted with the item kind in save-all texts. */
            public string kind_plural;
            /* Overflow tabs live in the "More" menu. */
            public bool overflow;
            public GLib.ListStore store = new GLib.ListStore (typeof (Message));
            public Gtk.Stack stack;
            public bool load_started = false;
        }

        private class ThumbRequest {
            public string path;
            public int size;
            public Source resume_source;
            public Gdk.Texture? result = null;
        }

        public GalleryDialog (Window window, RpcClient rpc, int chat_id,
                              string? chat_name) {
            this.app_window = window;
            this.rpc = rpc;
            this.chat_id = chat_id;

            title = "Apps and Media";
            content_width = 860;
            content_height = 600;
            /* Do not force the dialog beyond small window bounds. */
            width_request = 280;
            height_request = 200;

            try {
                thumb_pool = new ThreadPool<ThumbRequest>.with_owned_data ((req) => {
                    try {
                        req.result = texture_from_pixbuf (
                            scaled_frame_from_file (req.path, req.size));
                    } catch (Error e) {
                        /* Broken image: the placeholder icon remains. */
                    }
                    req.resume_source.attach (MainContext.default ());
                }, 2, false);
            } catch (Error e) {
                warning ("gallery thumb pool: %s", e.message);
            }

            tabs = {
                new GalleryTab () {
                    key = "images", title = "Images",
                    icon_name = "image-x-generic-symbolic",
                    types = { "Gif", "Image" },
                    filter = MediaFilter.NO_STICKERS,
                    empty_title = "No Images",
                    empty_description = "Images shared in this chat will appear here",
                    kind_plural = "images"
                },
                new GalleryTab () {
                    key = "stickers", title = "Stickers",
                    icon_name = "sticker-symbolic",
                    types = { "Sticker" },
                    filter = MediaFilter.STICKERS_ONLY,
                    empty_title = "No Stickers",
                    empty_description = "Stickers shared in this chat will appear here",
                    kind_plural = "stickers",
                    overflow = true
                },
                new GalleryTab () {
                    key = "video", title = "Video",
                    icon_name = "video-x-generic-symbolic",
                    types = { "Video" },
                    empty_title = "No Videos",
                    empty_description = "Videos shared in this chat will appear here",
                    kind_plural = "videos"
                },
                new GalleryTab () {
                    key = "audio", title = "Audio",
                    icon_name = "audio-x-generic-symbolic",
                    types = { "Audio", "Voice" },
                    empty_title = "No Audio",
                    empty_description = "Audio files and voice messages will appear here",
                    kind_plural = "audio files"
                },
                new GalleryTab () {
                    key = "files", title = "Files",
                    icon_name = "text-x-generic-symbolic",
                    types = { "File" },
                    empty_title = "No Files",
                    empty_description = "Documents and other files shared in this chat will appear here",
                    kind_plural = "files",
                    overflow = true
                },
                new GalleryTab () {
                    key = "links", title = "Links",
                    icon_name = "web-browser-symbolic",
                    types = {},
                    empty_title = "No Links",
                    empty_description = "Links shared in this chat will appear here",
                    kind_plural = "links",
                    overflow = true
                },
                new GalleryTab () {
                    key = "apps", title = "Apps",
                    icon_name = "application-x-executable-symbolic",
                    types = { "Webxdc" },
                    empty_title = "No Apps",
                    empty_description = "Delta Chat apps shared in this chat will appear here",
                    kind_plural = "apps",
                    overflow = true
                },
            };

            view_stack = new Adw.ViewStack ();
            foreach (var tab in tabs) {
                build_tab_page (tab);
                var page = view_stack.add_titled (tab.stack, tab.key,
                                                  tab.title);
                page.icon_name = tab.icon_name;
                tab.store.items_changed.connect (() => {
                    update_tab_badge (tab);
                    if (view_stack.visible_child_name == tab.key)
                        update_save_all_button ();
                });
            }

            var header = new Adw.HeaderBar ();
            header.title_widget = new Adw.WindowTitle ("Apps and Media",
                chat_name ?? "");

            save_all_btn = new Gtk.Button.from_icon_name ("document-save-symbolic");
            save_all_btn.sensitive = false;
            save_all_btn.clicked.connect (() => { on_save_all_clicked (); });
            header.pack_start (save_all_btn);

            /* Keep primary sections in the bar and the rest in "More". */
            var switcher = new Adw.ViewSwitcher ();
            switcher.stack = view_stack;
            switcher.policy = Adw.ViewSwitcherPolicy.NARROW;

            /* Hand-built popover rather than a GLib.Menu-backed
               GtkPopoverMenu: GtkModelButton labels itself through a
               presentational child that GTK's AccessKit backend leaves
               unresolved, so NVDA reads the menu as empty items (#57).
               The rows carry a radio role and a checked state; the active
               overflow section is synced from the stack in
               sync_more_button, not here. */
            more_popover = new Gtk.Popover ();
            more_popover.has_arrow = false;
            var more_list = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            more_list.add_css_class ("menu");
            foreach (var tab in tabs) {
                if (!tab.overflow) continue;
                view_stack.get_page (tab.stack).visible = false;
                var item = build_more_item (tab.key, tab.title);
                more_list.append (item);
                more_items.set (tab.key, item);
            }
            more_popover.child = more_list;

            var more_icon = new Gtk.Image.from_icon_name ("view-more-symbolic");
            var more_label = new Gtk.Label ("More");
            more_label.add_css_class ("caption");
            var more_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
            more_box.valign = Gtk.Align.CENTER;
            more_box.append (more_icon);
            more_box.append (more_label);

            more_btn = new Gtk.MenuButton ();
            more_btn.child = more_box;
            /* GTK 4.22 widened the setter to GtkWidget*; the property is
               stable across the Vala 0.56 pointer signature. */
            more_btn.set ("popover", more_popover);
            more_btn.direction = Gtk.ArrowType.UP;
            more_btn.add_css_class ("flat");
            more_btn.add_css_class ("gallery-more");

            switcher_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            switcher_bar.halign = Gtk.Align.CENTER;
            /* Strips the buttons' spare padding and minimum width (see
               application.vala) so the whole bar fits narrow windows. */
            switcher_bar.add_css_class ("gallery-tabs");
            switcher_bar.append (switcher);
            switcher_bar.append (more_btn);

            /* Two rows so the bar fits the narrow dialog floor: Cancel and
               the count on top, the actions sharing the width below. */
            var cancel_selection = new Gtk.Button.with_label ("Cancel");
            cancel_selection.clicked.connect (() => { exit_selection_mode (); });

            selection_label = new Gtk.Label ("");

            var selection_top = new Gtk.CenterBox ();
            selection_top.start_widget = cancel_selection;
            selection_top.center_widget = selection_label;

            forward_sel_btn = new Gtk.Button.with_label ("Forward…");
            forward_sel_btn.add_css_class ("suggested-action");
            forward_sel_btn.clicked.connect (() => { forward_selection (); });

            save_sel_btn = new Gtk.Button.with_label ("Save…");
            save_sel_btn.clicked.connect (() => { save_selection (); });

            delete_sel_btn = new Gtk.Button.with_label ("Delete…");
            delete_sel_btn.add_css_class ("destructive-action");
            delete_sel_btn.clicked.connect (() => { delete_selection (); });

            var selection_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            selection_actions.homogeneous = true;
            selection_actions.append (delete_sel_btn);
            selection_actions.append (save_sel_btn);
            selection_actions.append (forward_sel_btn);

            selection_bar = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
            selection_bar.add_css_class ("toolbar");
            selection_bar.append (selection_top);
            selection_bar.append (selection_actions);

            /* Hide the bar after its animation so it does not constrain width. */
            selection_bar.visible = false;
            selection_revealer = new Gtk.Revealer ();
            selection_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
            selection_revealer.child = selection_bar;
            selection_revealer.notify["child-revealed"].connect (() => {
                if (!selection_revealer.reveal_child &&
                    !selection_revealer.child_revealed) {
                    selection_bar.visible = false;
                }
            });

            var toolbar_view = new Adw.ToolbarView ();
            toolbar_view.add_top_bar (header);
            toolbar_view.add_bottom_bar (switcher_bar);
            toolbar_view.add_bottom_bar (selection_revealer);
            toolbar_view.content = view_stack;

            /* Same fullscreen viewers the conversation uses, overlaid on the
               dialog (the window-level ones would be hidden behind it). */
            viewer = new ImageViewer ();
            viewer.set_window (window);
            player = new VideoPlayer ();
            player.set_window (window);

            var media_overlay = new Gtk.Overlay ();
            media_overlay.child = toolbar_view;
            media_overlay.add_overlay (viewer.widget);
            media_overlay.add_overlay (player.widget);

            /* The overlay being the dialog's direct child also makes
               Window.show_toast route toasts here while we are modal. */
            toasts = new Adw.ToastOverlay ();
            toasts.child = media_overlay;
            child = toasts;

            /* Route keys to the fullscreen viewers while they are open, so
               arrows navigate and Escape closes the viewer, not the dialog. */
            var kc = new Gtk.EventControllerKey ();
            kc.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            kc.key_pressed.connect ((kv, code, state) => {
                if (viewer.visible) return viewer.handle_key (kv);
                if (player.visible) return player.handle_key (kv);
                return false;
            });
            ((Gtk.Widget) this).add_controller (kc);

            /* Ctrl+wheel resizes the grid thumbnails (the window's font
               zoom is scoped to the chat area and never sees events over
               this dialog). Claimed even on the list tabs so the wheel
               with the modifier held does nothing surprising there. */
            var zoom_ctrl = new Gtk.EventControllerScroll (
                Gtk.EventControllerScrollFlags.VERTICAL |
                Gtk.EventControllerScrollFlags.DISCRETE);
            zoom_ctrl.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            zoom_ctrl.scroll.connect ((dx, dy) => {
                if (!Platform.has_primary_modifier (
                        zoom_ctrl.get_current_event_state ())) {
                    return false;
                }
                if (dy == 0) return false;
                adjust_thumb_zoom (dy < 0 ? 1 : -1);
                return true;
            });
            ((Gtk.Widget) this).add_controller (zoom_ctrl);

            /* The dialog's own Escape shortcut fires at the window root,
               before the controller above — block it while a viewer is up
               (can_close) and dismiss the viewer from close_attempt. */
            viewer.widget.notify["visible"].connect (() => {
                update_can_close ();
            });
            player.widget.notify["visible"].connect (() => {
                update_can_close ();
            });
            close_attempt.connect (() => {
                if (viewer.visible) {
                    viewer.hide ();
                } else if (player.visible) {
                    player.hide ();
                } else if (selection_mode) {
                    exit_selection_mode ();
                } else {
                    force_close ();
                }
            });

            closed.connect (() => {
                is_open = false;
                var playback = AudioPlayback.shared ();
                if (playback_was_started &&
                    playback.current_message_id > 0) {
                    playback.stop ();
                }
            });

            view_stack.notify["visible-child-name"].connect (() => {
                var tab = current_tab ();
                if (tab != null) load_tab.begin (tab);
                update_save_all_button ();
                sync_more_button ();
            });

            /* Images is the most useful default section in Parla. */
            view_stack.visible_child_name = "images";
            update_save_all_button ();
            sync_more_button ();
            load_tab.begin (find_tab ("images"));
        }

        /* One "More" menu row: a flat, radio-roled button with a leading
           checkmark (opacity-toggled by sync_more_button) and a real
           label, so a screen reader announces its name and checked state. */
        private Gtk.Button build_more_item (string key, string title) {
            var check = new Gtk.Image.from_icon_name ("object-select-symbolic");
            check.opacity = 0;
            var label = new Gtk.Label (title);
            label.xalign = 0;
            label.hexpand = true;
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            row.append (check);
            row.append (label);
            var item = (Gtk.Button) Object.new (typeof (Gtk.Button),
                "accessible-role", Gtk.AccessibleRole.MENU_ITEM_RADIO);
            item.child = row;
            item.add_css_class ("flat");
            item.set_data ("gallery-check", check);
#if A11Y
            item.update_property (Gtk.AccessibleProperty.LABEL, title, -1);
#endif
            item.clicked.connect (() => {
                more_popover.popdown ();
                view_stack.visible_child_name = key;
            });
            return item;
        }

        /* Highlight "More" while an overflow section is active. */
        private void sync_more_button () {
            var key = view_stack.visible_child_name ?? "";
            more_items.foreach ((item_key, item) => {
                bool active = item_key == key;
                item.get_data<Gtk.Image> ("gallery-check").opacity =
                    active ? 1 : 0;
#if A11Y
                item.update_state (Gtk.AccessibleState.CHECKED, active, -1);
#endif
            });
            var tab = find_tab (key);
            if (tab != null && tab.overflow) {
                more_btn.add_css_class ("gallery-more-active");
            } else {
                more_btn.remove_css_class ("gallery-more-active");
            }
        }

        private bool playback_was_started = false;

        /* Escape first dismisses a fullscreen viewer, then leaves selection
           mode, and only then closes the dialog. */
        private void update_can_close () {
            can_close = !viewer.visible && !player.visible && !selection_mode;
        }

        /* ================================================================
         *  Multi-selection
         * ================================================================ */

        public bool is_selected (int msg_id) {
            return selected_ids.contains (msg_id);
        }

        private void enter_selection_mode (int msg_id) {
            selection_mode = true;
            selected_ids.replace (msg_id, true);
            update_selection_ui ();
        }

        private void exit_selection_mode () {
            if (!selection_mode) return;
            selection_mode = false;
            selected_ids.remove_all ();
            update_selection_ui ();
        }

        private void toggle_selected (Message m) {
            if (selected_ids.contains (m.id)) selected_ids.remove (m.id);
            else selected_ids.replace (m.id, true);
            update_selection_ui ();
        }

        private void update_selection_ui () {
            uint count = selected_ids.size ();
            /* Show the bar before starting its reveal animation. The tab
               bar swaps out for the duration of the selection so the two
               bars never stack (and its width never constrains a narrow
               dialog while selecting). */
            if (selection_mode) selection_bar.visible = true;
            switcher_bar.visible = !selection_mode;
            selection_revealer.reveal_child = selection_mode;
            selection_label.label = "%u selected".printf (count);
            forward_sel_btn.sensitive = count > 0;
            save_sel_btn.sensitive = count > 0;
            delete_sel_btn.sensitive = count > 0;
            update_can_close ();
            selection_changed ();
        }

        /** Selected messages in per-tab store order (newest first), so bulk
            actions keep a stable, predictable ordering. */
        private Message[] selected_messages () {
            Message[] result = {};
            foreach (var tab in tabs) {
                for (uint i = 0; i < tab.store.get_n_items (); i++) {
                    var m = (Message) tab.store.get_item (i);
                    if (m != null && selected_ids.contains (m.id)) result += m;
                }
            }
            return result;
        }

        private void forward_selection () {
            var msgs = selected_messages ();
            if (msgs.length == 0) return;
            int[] ids = {};
            foreach (var m in msgs) ids += m.id;
            /* Leave selection mode only once a destination is picked, so
               cancelling the picker keeps the selection intact. */
            var picker = MessageActions.forward_with_picker (
                app_window, rpc, ids);
            if (picker == null) return;
            picker.chat_picked.connect ((chat_id) => {
                exit_selection_mode ();
            });
            picker.contact_picked.connect ((contact_id, email) => {
                exit_selection_mode ();
            });
        }

        private void save_selection () {
            /* Leave selection mode only once a folder is picked, so
               cancelling the chooser keeps the selection intact. */
            choose_folder_then_save (selected_messages (), true);
        }

        private void delete_selection () {
            var msgs = selected_messages ();
            if (msgs.length == 0) return;
            int[] ids = {};
            bool all_outgoing = true;
            foreach (var m in msgs) {
                ids += m.id;
                if (!m.is_outgoing) all_outgoing = false;
            }
            confirm_delete_ids.begin (ids, all_outgoing);
        }

        /** Confirmation shared by the selection bar and the item context
            menu. Only fully-outgoing selections offer Delete for Everyone. */
        private async void confirm_delete_ids (owned int[] ids,
                                               bool all_outgoing) {
            string title = ids.length == 1
                ? "Delete Message?" : "Delete Messages?";
            string what = ids.length == 1
                ? "this message" : "these %d messages".printf (ids.length);
            string body = all_outgoing
                ? "Delete %s from your device only, or from all participants? This cannot be undone.".printf (what)
                : "Delete %s from your device? This cannot be undone.".printf (what);
            var choice = yield confirm_delete_options (
                this, title, body, all_outgoing);
            if (choice == DeleteChoice.FOR_ME)
                delete_messages_ui.begin (ids, false);
            else if (choice == DeleteChoice.FOR_EVERYONE)
                delete_messages_ui.begin (ids, true);
        }

        /* ================================================================
         *  Tab pages
         * ================================================================ */

        private void build_tab_page (GalleryTab tab) {
            tab.stack = new Gtk.Stack ();
            tab.stack.transition_type = Gtk.StackTransitionType.CROSSFADE;

            var spinner = new Gtk.Spinner ();
            spinner.spinning = true;
            spinner.width_request = 32;
            spinner.height_request = 32;
            spinner.halign = Gtk.Align.CENTER;
            spinner.valign = Gtk.Align.CENTER;
            tab.stack.add_named (spinner, "loading");

            var empty = new Adw.StatusPage ();
            empty.icon_name = tab.icon_name;
            empty.title = tab.empty_title;
            empty.description = tab.empty_description;
            empty.add_css_class ("compact");
            tab.stack.add_named (empty, "empty");

            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.hexpand = true;
            scroll.vexpand = true;
            if (tab.key == "images" || tab.key == "stickers"
                || tab.key == "video") {
                scroll.child = build_media_grid (tab);
            } else {
                scroll.child = build_row_list (tab);
            }
            tab.stack.add_named (scroll, "content");

            tab.stack.visible_child_name = "loading";
        }

        private GalleryTab? find_tab (string key) {
            foreach (var tab in tabs) {
                if (tab.key == key) return tab;
            }
            return null;
        }

        private GalleryTab? current_tab () {
            var key = view_stack.visible_child_name;
            return key != null ? find_tab (key) : null;
        }

        private void update_tab_badge (GalleryTab tab) {
            view_stack.get_page (tab.stack).badge_number =
                tab.store.get_n_items ();
        }

        /* ================================================================
         *  Loading
         * ================================================================ */

        private async void load_tab (GalleryTab? tab) {
            if (tab == null || tab.load_started) return;
            tab.load_started = true;
            try {
                int[] ids;
                if (tab.key == "links") {
                    /* Links live in the message text, which get_chat_media
                       cannot match on; walk the chat's whole message list
                       and let append_messages keep the ones with a URL. */
                    ids = {};
                    var arr = yield rpc.get_message_ids_for (rpc.account_id,
                                                             chat_id);
                    if (arr != null) {
                        for (uint i = 0; i < arr.get_length (); i++)
                            ids += (int) arr.get_int_element (i);
                    }
                } else {
                    ids = yield rpc.get_chat_media (chat_id, tab.types);
                }
                if (!is_open) return;

                /* Newest first, like the official client. */
                for (int i = 0, j = ids.length - 1; i < j; i++, j--) {
                    int t = ids[i]; ids[i] = ids[j]; ids[j] = t;
                }

                for (int off = 0; off < ids.length; off += FETCH_CHUNK) {
                    int len = int.min (FETCH_CHUNK, ids.length - off);
                    var msgs = yield rpc.get_parsed_messages (
                        ids[off : off + len]);
                    if (!is_open) return;
                    append_messages (tab, msgs);
                    if (tab.store.get_n_items () > 0)
                        tab.stack.visible_child_name = "content";
                }
            } catch (Error e) {
                if (!is_open) return;
                toast ("Could not load media: " + e.message);
            }
            if (tab.store.get_n_items () == 0)
                tab.stack.visible_child_name = "empty";
        }

        private void append_messages (GalleryTab tab, Message[] msgs) {
            Object[] batch = {};
            foreach (var msg in msgs) {
                if (tab.key == "links") {
                    if (msg.is_info) continue;
                    string t = msg.text ?? "";
                    if (t.index_of ("://") < 0
                        || LinkCleaner.find_urls (t).length == 0) continue;
                    batch += msg;
                    continue;
                }
                if (!msg.has_file) continue;
                if (tab.filter == MediaFilter.STICKERS_ONLY
                    && !msg.is_sticker_file ()) continue;
                if (tab.filter == MediaFilter.NO_STICKERS
                    && msg.is_sticker_file ()) continue;
                batch += msg;
            }
            /* One splice per chunk avoids a per-row relayout storm. */
            if (batch.length > 0)
                tab.store.splice (tab.store.get_n_items (), 0, batch);
        }

        /* ================================================================
         *  Image / video grid
         * ================================================================ */

        /* One wheel notch removes or adds a grid column; GridView divides
           the width among the remaining columns, so the cells grow or
           shrink. The zoom floor is the grids' min_columns (GridView packs
           as many CELL_MIN columns as fit up to max_columns, so only the
           cap can force fewer). The step starts from the columns the
           current width actually fits (the width may cap them below
           zoom_columns), so the first notch always reacts. */
        private void adjust_thumb_zoom (int direction) {
            int avail = view_stack.get_width ();
            if (avail <= 0 || media_grids.length == 0) return;
            int min_cols = int.max (1, (int) media_grids[0].min_columns);
            int minw, nat, mb, nb;
            media_grids[0].measure (Gtk.Orientation.HORIZONTAL, -1,
                                    out minw, out nat, out mb, out nb);
            /* minw is min_cols cells plus the grid's padding/spacing. */
            int overhead = int.max (0, minw - min_cols * CELL_MIN);
            int fit = int.max (min_cols, (avail - overhead) / CELL_MIN);
            int cols = int.min (zoom_columns, fit);
            cols = (cols - direction).clamp (min_cols, ZOOM_COLUMNS_MAX);
            if (cols == zoom_columns) return;
            zoom_columns = cols;
            foreach (var g in media_grids) g.max_columns = cols;
        }

        private static Gtk.SignalListItemFactory make_cell_factory () {
            var factory = new Gtk.SignalListItemFactory ();
            factory.bind.connect ((obj) => {
                var item = (Gtk.ListItem) obj;
                ((GalleryCell) item.child).bind ((Message) item.item);
            });
            factory.unbind.connect ((obj) => {
                var item = (Gtk.ListItem) obj;
                ((GalleryCell) item.child).unbind ();
            });
            return factory;
        }

        private Gtk.GridView build_media_grid (GalleryTab tab) {
            bool is_video = tab.key == "video";
            /* Stickers are transparent cut-outs: show them whole instead
               of cover-cropping like photos. */
            bool contain = tab.key == "stickers";
            var factory = make_cell_factory ();
            factory.setup.connect ((obj) => {
                ((Gtk.ListItem) obj).child = new MediaCell (
                    this, is_video, contain);
            });

            var grid = new Gtk.GridView (new Gtk.NoSelection (tab.store),
                                         factory);
            grid.single_click_activate = true;
            /* min_columns is the Ctrl+wheel zoom-in floor (1 = a single
               huge thumbnail); the max_columns cap is the zoom level. */
            grid.min_columns = 1;
            grid.max_columns = zoom_columns;
            grid.add_css_class ("gallery-grid");
            media_grids += grid;
            grid.activate.connect ((pos) => {
                on_media_activated (tab, pos);
            });
            install_menu_key (grid);
            return grid;
        }

        private class MediaCell : Gtk.Box, GalleryCell {
            public Message? msg { get; set; }

            private unowned GalleryDialog dialog;
            private bool is_video;
            private Gtk.Picture picture;
            private Gtk.Image placeholder;
            private Gtk.Box? play_badge = null;
            private Gtk.CheckButton check;
            private int generation = 0;

            public MediaCell (GalleryDialog dialog, bool is_video,
                              bool contain = false) {
                Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
                this.dialog = dialog;
                this.is_video = is_video;

                picture = new Gtk.Picture ();
                picture.content_fit = contain
                    ? Gtk.ContentFit.CONTAIN : Gtk.ContentFit.COVER;
                picture.can_shrink = true;
                picture.halign = Gtk.Align.FILL;
                picture.valign = Gtk.Align.FILL;

                var overlay = new Gtk.Overlay ();
                overlay.child = picture;

                placeholder = new Gtk.Image.from_icon_name (
                    is_video ? "video-x-generic-symbolic"
                             : "image-x-generic-symbolic");
                placeholder.pixel_size = 28;
                placeholder.halign = Gtk.Align.CENTER;
                placeholder.valign = Gtk.Align.CENTER;
                placeholder.add_css_class ("dim-label");
                overlay.add_overlay (placeholder);

                if (is_video) {
                    play_badge = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                    play_badge.add_css_class ("message-video-play");
                    play_badge.halign = Gtk.Align.CENTER;
                    play_badge.valign = Gtk.Align.CENTER;
                    play_badge.can_target = false;
                    var play = new Gtk.Image.from_icon_name (
                        "media-playback-start-symbolic");
                    play.pixel_size = 18;
                    play_badge.append (play);
                    play_badge.visible = false;
                    overlay.add_overlay (play_badge);
                }

                /* Selection checkmark; the cell click toggles, so the
                   check itself must not swallow the press. */
                check = new Gtk.CheckButton ();
                check.add_css_class ("selection-mode");
                check.can_target = false;
                check.halign = Gtk.Align.END;
                check.valign = Gtk.Align.START;
                check.margin_top = 6;
                check.margin_end = 6;
                check.visible = false;
                overlay.add_overlay (check);

                /* Keep allocated thumbnails square and prevent crushed cells. */
                var frame = new ScaledPreviewFrame (CELL_MAX, CELL_MAX,
                                                    "gallery-thumb");
                frame.set_size_request (CELL_MIN, -1);
                if (contain) frame.add_css_class ("gallery-thumb-checker");
                frame.child = overlay;
                append (frame);

                add_context_menu_gestures (this, dialog);
                /* Cells live exactly as long as the dialog, so the
                   handler needs no per-bind bookkeeping. */
                dialog.selection_changed.connect (() => {
                    update_selection_visuals ();
                });
            }

            public void bind (Message m) {
                msg = m;
                generation++;
                picture.paintable = null;
                placeholder.visible = true;
                if (play_badge != null) play_badge.visible = false;
                tooltip_text = m.display_file_name ();
                update_selection_visuals ();

                if (!m.has_local_file) {
                    placeholder.icon_name = "image-missing-symbolic";
                    return;
                }
                placeholder.icon_name = is_video
                    ? "video-x-generic-symbolic" : "image-x-generic-symbolic";

                /* WebM (video stickers included) can't become a pixbuf;
                   a paused MediaFile shows the first frame. Deliberately
                   NOT muted: GtkMediaStream.muted poisons the per-app
                   PipeWire mute that WirePlumber then restores onto voice
                   playback, and a paused stream is silent anyway. */
                if (is_video || m.is_video_sticker_file ()) {
                    var media = Gtk.MediaFile.for_filename (m.file_path);
                    media.pause ();
                    picture.paintable = media;
                    placeholder.visible = false;
                    if (play_badge != null) play_badge.visible = true;
                    return;
                }

                int gen = generation;
                dialog.load_thumb.begin (m.file_path, (o, res) => {
                    var tex = dialog.load_thumb.end (res);
                    if (gen != generation || tex == null) return;
                    picture.paintable = tex;
                    placeholder.visible = false;
                });
            }

            public void unbind () {
                msg = null;
                generation++;
                picture.paintable = null;
            }

            private void update_selection_visuals () {
                check.visible = dialog.selection_mode;
                check.active = msg != null && dialog.is_selected (msg.id);
            }
        }

        private async Gdk.Texture? load_thumb (string path) {
            var cached = thumb_cache.lookup (path);
            if (cached != null) return cached;
            if (thumb_pool == null) return null;

            var req = new ThumbRequest ();
            req.path = path;
            /* 2x for crisp rendering on hidpi displays. */
            req.size = CELL_MIN * 2;
            req.resume_source = new IdleSource ();
            req.resume_source.set_callback (load_thumb.callback);
            try {
                thumb_pool.add (req);
            } catch (Error e) {
                return null;
            }
            yield;
            if (req.result != null) thumb_cache.insert (path, req.result);
            return req.result;
        }

        /** False (with a toast) when the attachment is not downloaded. */
        private bool ensure_local_file (Message m) {
            if (m.has_local_file) return true;
            toast ("File not available");
            return false;
        }

        private void on_media_activated (GalleryTab tab, uint pos) {
            var m = (Message) tab.store.get_item (pos);
            if (m == null) return;
            if (selection_mode) {
                toggle_selected (m);
                return;
            }
            if (!ensure_local_file (m)) return;
            /* WebM stickers cannot become a Gdk.Texture; play them like
               videos instead. */
            if (tab.key == "video" || m.is_video_sticker_file ()) {
                player.show (m.file_path, m.file_name);
                return;
            }
            /* Fullscreen viewer navigating the gallery's own image list,
               mirroring how the conversation view collects its paths. */
            string[] paths = {};
            int start = 0;
            for (uint i = 0; i < tab.store.get_n_items (); i++) {
                var it = (Message) tab.store.get_item (i);
                if (it == null || !it.has_local_file
                    || it.is_video_sticker_file ()) continue;
                if (it.id == m.id) start = paths.length;
                paths += it.file_path;
            }
            viewer.show_list (paths, start);
        }

        /* ================================================================
         *  Apps / audio / files lists
         * ================================================================ */

        private Gtk.ListView build_row_list (GalleryTab tab) {
            var factory = make_cell_factory ();
            factory.setup.connect ((obj) => {
                ((Gtk.ListItem) obj).child = new GalleryRow (this, tab.key);
            });

            var list = new Gtk.ListView (new Gtk.NoSelection (tab.store),
                                         factory);
            list.single_click_activate = true;
            list.add_css_class ("gallery-list");
            list.activate.connect ((pos) => {
                var m = (Message) tab.store.get_item (pos);
                if (m != null) on_row_activated (tab, m);
            });
            install_menu_key (list);
            return list;
        }

        private class GalleryRow : Gtk.Box, GalleryCell {
            public Message? msg { get; set; }

            private unowned GalleryDialog dialog;
            private string tab_key;
            private Gtk.CheckButton check;
            private Gtk.Image icon;
            private Gtk.Label title_label;
            private Gtk.Label subtitle_label;
            private Gtk.Button? play_btn = null;
            /* Links tab only: thumbnail of a picture attached to the
               same message, shown in place of the generic icon. */
            private Gtk.Picture? thumb = null;
            private int generation = 0;
            /* AudioPlayback outlives the dialog, so unlike the dialog's
               own selection_changed these must disconnect on unbind. */
            private ulong playing_handler = 0;
            private ulong current_handler = 0;

            public GalleryRow (GalleryDialog dialog, string tab_key) {
                Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 12);
                this.dialog = dialog;
                this.tab_key = tab_key;
                add_css_class ("gallery-row");
                margin_start = 12;
                margin_end = 12;
                margin_top = 8;
                margin_bottom = 8;

                /* The row click toggles selection, so the check itself
                   must not swallow the press. */
                check = new Gtk.CheckButton ();
                check.valign = Gtk.Align.CENTER;
                check.can_target = false;
                check.visible = false;
                append (check);

                icon = new Gtk.Image ();
                icon.pixel_size = 24;
                append (icon);

                var text_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
                text_box.hexpand = true;
                text_box.valign = Gtk.Align.CENTER;

                title_label = new Gtk.Label ("");
                title_label.xalign = 0;
                title_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
                text_box.append (title_label);

                subtitle_label = new Gtk.Label ("");
                subtitle_label.xalign = 0;
                subtitle_label.ellipsize = Pango.EllipsizeMode.END;
                subtitle_label.add_css_class ("dim-label");
                subtitle_label.add_css_class ("caption");
                text_box.append (subtitle_label);
                append (text_box);

                if (tab_key == "links") {
                    /* Attached picture, right-aligned after the text. */
                    thumb = new Gtk.Picture ();
                    thumb.content_fit = Gtk.ContentFit.COVER;
                    thumb.set_size_request (48, 48);
                    thumb.overflow = Gtk.Overflow.HIDDEN;
                    thumb.add_css_class ("gallery-thumb");
                    thumb.halign = Gtk.Align.END;
                    thumb.valign = Gtk.Align.CENTER;
                    thumb.visible = false;
                    append (thumb);
                }

                if (tab_key == "audio") {
                    play_btn = new Gtk.Button.from_icon_name (
                        "media-playback-start-symbolic");
                    play_btn.add_css_class ("circular");
                    play_btn.add_css_class ("flat");
                    play_btn.valign = Gtk.Align.CENTER;
                    play_btn.tooltip_text = "Play";
                    play_btn.clicked.connect (() => {
                        if (msg != null) dialog.toggle_audio (msg);
                    });
                    append (play_btn);
                }

                add_context_menu_gestures (this, dialog);
                dialog.selection_changed.connect (() => {
                    update_selection_visuals ();
                });
            }

            public void bind (Message m) {
                msg = m;
                generation++;
                update_selection_visuals ();

                string sender = m.is_outgoing ? "You"
                    : (m.override_sender_name ?? m.sender_name ?? "");
                string when = format_date_time (m.timestamp);
                string meta = sender.length > 0
                    ? "%s · %s".printf (sender, when) : when;

                switch (tab_key) {
                case "audio":
                    bool voice = m.view_type != null
                        && m.view_type.down () == "voice";
                    icon.icon_name = voice
                        ? "audio-input-microphone-symbolic"
                        : "audio-x-generic-symbolic";
                    title_label.label = voice
                        ? "Voice message" : m.display_file_name ("Audio");
                    subtitle_label.label = meta;
                    var playback = AudioPlayback.shared ();
                    playing_handler = playback.notify["playing"].connect (
                        () => { update_play_icon (); });
                    current_handler = playback.notify["current-message-id"]
                        .connect (() => { update_play_icon (); });
                    update_play_icon ();
                    play_btn.sensitive = m.has_local_file;
                    break;
                case "apps":
                    icon.icon_name = "application-x-executable-symbolic";
                    title_label.label = app_display_name (m);
                    subtitle_label.label = meta;
                    break;
                case "links":
                    var links = LinkCleaner.find_urls (m.text ?? "");
                    string link = links.length > 0 ? links[0] : "";
                    title_label.label = links.length > 1
                        ? "%s (+%d more)".printf (link, links.length - 1)
                        : link;
                    tooltip_text = link;
                    subtitle_label.label = meta;
                    icon.icon_name = "web-browser-symbolic";
                    bool has_pic = m.has_local_file && m.is_image_file ();
                    thumb.visible = has_pic;
                    thumb.paintable = null;
                    if (has_pic) {
                        int gen = generation;
                        dialog.load_thumb.begin (m.file_path, (o, res) => {
                            var tex = dialog.load_thumb.end (res);
                            if (gen != generation || tex == null) return;
                            thumb.paintable = tex;
                        });
                    }
                    break;
                default:
                    icon.gicon = file_type_icon (m);
                    title_label.label = m.display_file_name ();
                    subtitle_label.label = m.file_bytes > 0
                        ? "%s · %s".printf (
                            GLib.format_size (m.file_bytes), meta)
                        : meta;
                    break;
                }
            }

            public void unbind () {
                generation++;
                if (thumb != null) thumb.paintable = null;
                var playback = AudioPlayback.shared ();
                if (playing_handler != 0) {
                    playback.disconnect (playing_handler);
                    playing_handler = 0;
                }
                if (current_handler != 0) {
                    playback.disconnect (current_handler);
                    current_handler = 0;
                }
                msg = null;
            }

            private void update_selection_visuals () {
                check.visible = dialog.selection_mode;
                check.active = msg != null && dialog.is_selected (msg.id);
            }

            private void update_play_icon () {
                if (play_btn == null || msg == null) return;
                var playback = AudioPlayback.shared ();
                bool this_playing = playback.current_message_id == msg.id
                    && playback.playing;
                play_btn.icon_name = this_playing
                    ? "media-playback-pause-symbolic"
                    : "media-playback-start-symbolic";
                play_btn.tooltip_text = this_playing ? "Pause" : "Play";
            }

            private static GLib.Icon file_type_icon (Message m) {
                string mime = m.file_mime ?? "";
                if (mime.length == 0 && m.file_name != null) {
                    bool uncertain;
                    mime = GLib.ContentType.guess (m.file_name, null,
                                                   out uncertain);
                }
                if (mime.length > 0) {
                    return GLib.ContentType.get_icon (mime);
                }
                return new GLib.ThemedIcon ("text-x-generic-symbolic");
            }

            private static string app_display_name (Message m) {
                string name = m.display_file_name ("App");
                if (name.down ().has_suffix (".xdc")) {
                    name = name[0 : name.length - 4];
                }
                return name;
            }
        }

        private void on_row_activated (GalleryTab tab, Message m) {
            if (selection_mode) {
                toggle_selected (m);
                return;
            }
            switch (tab.key) {
            case "audio":
                toggle_audio (m);
                break;
            case "files":
                open_file (m);
                break;
            case "apps":
                app_window.prompt_webxdc_app.begin (this, rpc, m);
                break;
            case "links":
                var links = LinkCleaner.find_urls (m.text ?? "");
                if (links.length > 0) open_link (links[0]);
                break;
            }
        }

        private void open_link (string url) {
            var launcher = new Gtk.UriLauncher (url);
            launcher.launch.begin (app_window, null, (o, res) => {
                try {
                    launcher.launch.end (res);
                } catch (Error e) {
                    if (!is_dialog_dismissal (e))
                        toast ("Could not open link: " + e.message);
                }
            });
        }

        private void toggle_audio (Message m) {
            if (!ensure_local_file (m)) return;
            var playback = AudioPlayback.shared ();
            if (playback.current_message_id == m.id) {
                playback.toggle ();
            } else {
                playback.play_message (m, rpc.account_id);
                playback_was_started = true;
            }
        }

        private void open_file (Message m) {
            if (!ensure_local_file (m)) return;
            var launcher = new Gtk.FileLauncher (
                File.new_for_path (m.file_path));
            launcher.launch.begin (app_window, null, (o, res) => {
                try {
                    launcher.launch.end (res);
                } catch (Error e) {
                    if (!is_dialog_dismissal (e))
                        toast ("Could not open file: " + e.message);
                }
            });
        }

        /* ================================================================
         *  Context menu
         * ================================================================ */

        /** Right click and touch long-press open the item context menu.
            The message is read at event time because cells are recycled
            and rebound to different messages. */
        private static void add_context_menu_gestures (GalleryCell cell,
                                                       GalleryDialog dialog) {
            var widget = (Gtk.Widget) cell;
            var right_click = new Gtk.GestureClick ();
            right_click.button = 3;
            right_click.pressed.connect ((n, x, y) => {
                if (cell.msg != null)
                    dialog.show_item_menu (widget, cell.msg, x, y);
            });
            widget.add_controller (right_click);

            var long_press = new Gtk.GestureLongPress ();
            long_press.touch_only = true;
            long_press.pressed.connect ((x, y) => {
                if (cell.msg != null)
                    dialog.show_item_menu (widget, cell.msg, x, y);
            });
            widget.add_controller (long_press);
        }

        /** Menu / Shift+F10 on a grid or list opens the context menu for
            the focused cell. The controller sits on the view because the
            focusable widget is GTK's internal list item, not our cell. */
        private void install_menu_key (Gtk.Widget view) {
            var keys = new Gtk.EventControllerKey ();
            keys.key_pressed.connect ((kv, code, state) => {
                bool menu_key = kv == Gdk.Key.Menu
                    || (kv == Gdk.Key.F10
                        && (state & Gdk.ModifierType.SHIFT_MASK) != 0);
                if (!menu_key) return false;

                var item = view.get_focus_child ();
                var cell = item != null
                    ? item.get_first_child () as GalleryCell : null;
                if (cell == null || cell.msg == null) return false;

                var widget = (Gtk.Widget) cell;
                show_item_menu (widget, cell.msg,
                                widget.get_width () / 2.0,
                                widget.get_height () / 2.0);
                return true;
            });
            view.add_controller (keys);
        }

        private void show_item_menu (Gtk.Widget parent, Message m,
                                     double x, double y) {
            Gtk.Box vbox;
            var popover = popover_menu (parent, x, y, out vbox);

            var cur = current_tab ();
            if (cur != null && cur.key == "links") {
                var links = LinkCleaner.find_urls (m.text ?? "");
                if (links.length > 0) {
                    string link0 = links[0];
                    var open_btn = new PopoverButton (popover, "Open Link");
                    open_btn.selected.connect (() => open_link (link0));
                    vbox.append (open_btn);
                    var copy_btn = new PopoverButton (popover, "Copy Link");
                    copy_btn.selected.connect (() => {
                        get_clipboard ().set_text (link0);
                        toast ("Link copied");
                    });
                    vbox.append (copy_btn);
                }
            }

            if (m.has_local_file) {
                string fpath = m.file_path;
                string? fname = m.file_name;
                var save_btn = new PopoverButton (popover, "Save As…");
                save_btn.selected.connect (() =>
                    app_window.save_attachment.begin (fpath, fname));
                vbox.append (save_btn);
            }

            int msg_id = m.id;
            var forward_btn = new PopoverButton (popover, "Forward…");
            forward_btn.selected.connect (() =>
                MessageActions.forward_with_picker (
                    app_window, rpc, new int[] { msg_id }));
            vbox.append (forward_btn);

            var select_btn = new PopoverButton (popover, "Select…");
            select_btn.selected.connect (() => enter_selection_mode (msg_id));
            vbox.append (select_btn);

            var view_btn = new PopoverButton (
                popover, "View in Conversation");
            view_btn.selected.connect (() => {
                /* Each closing dialog restores the window focus it saved
                   when presented, and such a focus shift can scroll the
                   chat. Close the stack bottom-up through the closed
                   signals and jump only once the last one is gone, so
                   nothing runs after the jump to drag the viewport away. */
                int target_chat = chat_id;
                var presenter = presenter_dialog;
                closed.connect (() => {
                    if (presenter != null) {
                        presenter.closed.connect (() => {
                            app_window.open_conversation_message (
                                target_chat, msg_id);
                        });
                        presenter.close ();
                    } else {
                        app_window.open_conversation_message (
                            target_chat, msg_id);
                    }
                });
                close ();
            });
            vbox.append (view_btn);

            /* Collect sticker attachments into a local pack */
            if (m.is_sticker_file () && m.has_local_file) {
                string spath = m.file_path;
                var sticker_btn = new PopoverButton (popover, "Add Sticker…");
                sticker_btn.selected.connect (() =>
                    StickerManagerDialog.prompt_add_sticker (app_window, spath));
                vbox.append (sticker_btn);
            }

            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            bool is_outgoing = m.is_outgoing;
            var delete_btn = new PopoverButton (popover, "Delete…", true);
            delete_btn.selected.connect (() =>
                confirm_delete_ids.begin ({ msg_id }, is_outgoing));
            vbox.append (delete_btn);

            popover.popup ();
        }

        private async void delete_messages_ui (owned int[] ids, bool for_all) {
            try {
                if (for_all) {
                    yield rpc.delete_messages_for_all (ids);
                } else {
                    yield rpc.delete_messages (ids);
                }
                var deleted = new HashTable<int, bool> (direct_hash,
                                                        direct_equal);
                foreach (int msg_id in ids) {
                    deleted.replace (msg_id, true);
                    selected_ids.remove (msg_id);
                }
                foreach (var tab in tabs) {
                    for (int i = (int) tab.store.get_n_items () - 1;
                         i >= 0; i--) {
                        var m = (Message) tab.store.get_item (i);
                        if (m != null && deleted.contains (m.id))
                            tab.store.remove (i);
                    }
                    if (tab.load_started && tab.store.get_n_items () == 0)
                        tab.stack.visible_child_name = "empty";
                }
                app_window.request_chat_messages_reload (chat_id);
                toast (ids.length == 1 ? "Message deleted"
                       : "%d messages deleted".printf (ids.length));
            } catch (Error e) {
                toast ("Delete failed: " + e.message);
            }
            if (selection_mode && selected_ids.size () == 0)
                exit_selection_mode ();
            else if (selection_mode)
                update_selection_ui ();
        }

        /* ================================================================
         *  Save all
         * ================================================================ */

        private void update_save_all_button () {
            var tab = current_tab ();
            /* Links are text, not files — nothing "Save all" could save. */
            bool has_items = tab != null && tab.key != "links"
                && tab.store.get_n_items () > 0;
            save_all_btn.sensitive = has_items;
            save_all_btn.tooltip_text = tab != null
                ? "Save all %s to a folder…".printf (tab.kind_plural)
                : "Save all to a folder…";
        }

        private void on_save_all_clicked () {
            var tab = current_tab ();
            if (tab == null) return;
            Message[] msgs = {};
            for (uint i = 0; i < tab.store.get_n_items (); i++) {
                var m = (Message) tab.store.get_item (i);
                if (m != null) msgs += m;
            }
            choose_folder_then_save (msgs);
        }

        /** Shared by "save all" and the selection bar's "Save…"; items
            without a downloaded file are only counted as skipped.
            exit_selection runs only when a folder was actually chosen. */
        private void choose_folder_then_save (owned Message[] msgs,
                                              bool exit_selection = false) {
            Message[] items = {};
            int skipped = 0;
            foreach (var m in msgs) {
                if (m.has_local_file) items += m;
                else skipped++;
            }
            if (items.length == 0) {
                toast ("No downloaded files to save");
                return;
            }
            var chooser = new Gtk.FileDialog ();
            chooser.title = "Select Folder";
            chooser.select_folder.begin (app_window, null, (o, res) => {
                try {
                    var folder = chooser.select_folder.end (res);
                    if (folder == null) return;
                    if (exit_selection) exit_selection_mode ();
                    save_files_to_folder.begin (items, skipped, folder);
                } catch (Error e) {
                    if (!is_dialog_dismissal (e))
                        toast ("Folder selection failed: " + e.message);
                }
            });
        }

        private async void save_files_to_folder (owned Message[] items,
                                                 int skipped, File folder) {
            var progress = new Gtk.ProgressBar ();
            progress.hexpand = true;

            var file_label = new Gtk.Label ("");
            file_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            file_label.add_css_class ("dim-label");
            file_label.add_css_class ("caption");

            var pbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            pbox.append (progress);
            pbox.append (file_label);

            var alert = new Adw.AlertDialog ("Saving Files", null);
            alert.extra_child = pbox;
            alert.add_response ("cancel", "Cancel");
            alert.close_response = "cancel";

            var cancellable = new Cancellable ();
            bool finished = false;
            alert.response.connect ((r) => {
                if (!finished) cancellable.cancel ();
            });
            alert.present (this);

            int saved = 0;
            int failed = 0;
            for (int i = 0; i < items.length; i++) {
                if (cancellable.is_cancelled ()) break;
                var m = items[i];
                string name = m.display_file_name (
                    Path.get_basename (m.file_path));
                progress.fraction = (double) i / items.length;
                progress.text = "%d of %d".printf (i + 1, items.length);
                progress.show_text = true;
                file_label.label = name;
                try {
                    var src = File.new_for_path (m.file_path);
                    var dest = SaveFolder.unique_destination (folder, name);
                    yield src.copy_async (dest, FileCopyFlags.NONE,
                                          Priority.DEFAULT, cancellable, null);
                    saved++;
                } catch (Error e) {
                    if (e is IOError.CANCELLED) break;
                    failed++;
                }
            }

            finished = true;
            alert.force_close ();
            if (!is_open) return;

            string summary;
            if (cancellable.is_cancelled ()) {
                summary = "Saving cancelled — %d file%s saved".printf (
                    saved, saved == 1 ? "" : "s");
            } else {
                summary = "Saved %d file%s".printf (saved,
                    saved == 1 ? "" : "s");
                if (failed > 0) summary += ", %d failed".printf (failed);
                if (skipped > 0) summary += ", %d not downloaded".printf (skipped);
            }
            toast (summary);
        }

        private void toast (string text) {
            toasts.add_toast (new Adw.Toast (text));
        }
    }
}
