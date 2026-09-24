namespace Dc {

    /**
     * "Apps" manager: every Webxdc app found in any chat of any profile,
     * collected in one place. The list page shows each app with its icon,
     * the people who used it and a favorite star; activating an app pushes
     * an appstore-like detail page with the icon, description, author,
     * first-seen date, the users' avatars and the chats it ran in. From
     * there the app can be started ("Run" continues an existing chat or
     * shares it into a fresh one via the contact list) or saved to disk.
     * Favorites persist in a keyfile next to settings.ini and sort first.
     */
    public class WebxdcManagerDialog : Adw.Dialog {

        private class AppInstance : Object {
            public int account_id = 0;
            public string account_label = "";
            public Message msg;
            public string chat_name = "";
            public string? chat_avatar = null;
        }

        private class AppUser : Object {
            public string key = "";
            public string name = "";
            public string? avatar_path = null;
        }

        private class AppEntry : Object {
            public string key = "";
            public string name = "";
            public Gdk.Texture? icon = null;
            public string? summary = null;
            public string? document = null;
            public string? source_code_url = null;
            public bool internet_access = false;
            public string author = "";
            public int64 created = 0;
            public bool favorite = false;
            public GenericArray<AppInstance> instances =
                new GenericArray<AppInstance> ();
            public GenericArray<AppUser> users = new GenericArray<AppUser> ();
        }

        private unowned Window app_window;
        private RpcClient rpc;

        private Adw.NavigationView nav;
        private Gtk.SearchEntry search_entry;
        private Gtk.ListBox app_list;
        private Gtk.Stack stack;
        private Adw.StatusPage empty_page;
        private GenericArray<AppEntry> apps = new GenericArray<AppEntry> ();
        private GenericSet<string> favorites;
        private uint load_generation = 0;

        public WebxdcManagerDialog (Window window, RpcClient rpc) {
            this.app_window = window;
            this.rpc = rpc;
            this.title = "Apps";
            this.content_width = 560;
            this.content_height = 620;
            favorites = load_favorites ();

            search_entry = new Gtk.SearchEntry ();
            search_entry.placeholder_text = "Search apps…";
            search_entry.hexpand = true;
            search_entry.search_changed.connect (() => { rebuild_list (); });

            app_list = new Gtk.ListBox ();
            app_list.selection_mode = Gtk.SelectionMode.NONE;
            app_list.add_css_class ("boxed-list");
            app_list.valign = Gtk.Align.START;

            var list_scroll = new Gtk.ScrolledWindow ();
            list_scroll.vexpand = true;
            list_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            list_scroll.child = app_list;

            var spinner = new Gtk.Spinner ();
            spinner.spinning = true;
            spinner.width_request = 32;
            spinner.height_request = 32;
            spinner.halign = Gtk.Align.CENTER;
            spinner.valign = Gtk.Align.CENTER;

            empty_page = new Adw.StatusPage ();
            empty_page.icon_name = "application-x-executable-symbolic";
            empty_page.title = "No Apps Yet";
            empty_page.description = "Webxdc apps shared in any chat of "
                + "any profile will appear here";

            stack = new Gtk.Stack ();
            stack.vexpand = true;
            stack.add_named (spinner, "loading");
            stack.add_named (empty_page, "empty");
            stack.add_named (list_scroll, "list");
            stack.visible_child_name = "loading";

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            content.margin_start = 12;
            content.margin_end = 12;
            content.margin_top = 8;
            content.margin_bottom = 12;
            content.append (search_entry);
            content.append (stack);

            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (new Adw.HeaderBar ());
            toolbar.content = content;

            nav = new Adw.NavigationView ();
            nav.add (new Adw.NavigationPage (toolbar, "Apps"));
            this.child = nav;

            install_escape_close (this);

            reload.begin ();
        }

        /* ================================================================
         *  Data collection
         * ================================================================ */

        private async void reload () {
            uint gen = ++load_generation;
            stack.visible_child_name = "loading";

            var found = new GenericArray<AppEntry> ();
            var by_key = new HashTable<string, AppEntry> (str_hash, str_equal);
            try {
                var accounts_node = yield rpc.get_all_accounts ();
                if (accounts_node == null) return;
                var accounts = accounts_node.get_array ();
                for (uint i = 0; i < accounts.get_length (); i++) {
                    var acct = accounts.get_object_element (i);
                    if (json_str (acct, "kind") != "Configured") continue;
                    yield collect_account_apps (acct, by_key, found);
                    if (gen != load_generation) return;
                }
            } catch (Error e) {
                warning ("webxdc manager: %s", e.message);
            }
            if (gen != load_generation) return;

            for (uint i = 0; i < found.length; i++) {
                var entry = found[i];
                entry.favorite = favorites.contains (entry.key);
                entry.instances.sort ((a, b) =>
                    (int) (b.msg.timestamp - a.msg.timestamp).clamp (-1, 1));
            }
            apps = found;
            rebuild_list ();
        }

        /** All Webxdc instances of one profile, merged into the app map.
            Failures stay local to the profile so one broken account does
            not empty the whole list. */
        private async void collect_account_apps (Json.Object acct,
                                                 HashTable<string, AppEntry> by_key,
                                                 GenericArray<AppEntry> found) {
            int acct_id = (int) json_int (acct, "id");
            if (acct_id <= 0) return;
            string? self_addr = json_str (acct, "addr");
            string account_label = json_str (acct, "displayName")
                ?? self_addr ?? "Profile %d".printf (acct_id);

            int[] msg_ids;
            Json.Object? map;
            try {
                msg_ids = yield account_chat_media (acct_id);
                if (msg_ids.length == 0) return;
                map = yield rpc.get_messages_for (acct_id, msg_ids);
            } catch (Error e) {
                warning ("webxdc manager account %d: %s", acct_id, e.message);
                return;
            }
            if (map == null) return;

            var chat_names = new HashTable<int, string> (direct_hash,
                                                         direct_equal);
            var chat_avatars = new HashTable<int, string> (direct_hash,
                                                           direct_equal);
            foreach (int msg_id in msg_ids) {
                string mkey = msg_id.to_string ();
                if (!map.has_member (mkey)) continue;
                var node = map.get_member (mkey);
                if (node == null ||
                    node.get_node_type () != Json.NodeType.OBJECT) continue;
                var obj = node.get_object ();
                if (json_str (obj, "kind") != "message") continue;
                var msg = RpcParsers.parse_message (obj, self_addr);
                if (!msg.is_webxdc ()) continue;

                Json.Object? info = null;
                try {
                    var res = yield rpc.call ("get_webxdc_info",
                        Params.begin ().add_int (acct_id)
                            .add_int (msg.id).build ());
                    info = res.get_object ();
                } catch (Error e) {
                    debug ("webxdc info %d/%d: %s", acct_id, msg.id,
                           e.message);
                }

                string name = info != null
                    ? (json_str (info, "name") ?? "") : "";
                if (name.length == 0) {
                    name = msg.display_file_name ("App");
                    if (name.down ().has_suffix (".xdc")) {
                        name = name.substring (0, name.length - 4);
                    }
                }

                string key = name.down ();
                var entry = by_key.lookup (key);
                if (entry == null) {
                    entry = new AppEntry ();
                    entry.key = key;
                    entry.name = name;
                    by_key.insert (key, entry);
                    found.add (entry);
                }
                if (info != null) {
                    yield merge_info (entry, acct_id, msg.id, info);
                }
                if (entry.created == 0 || (msg.timestamp > 0
                        && msg.timestamp < entry.created)) {
                    entry.created = msg.timestamp;
                    entry.author = sender_label (msg);
                }

                var inst = new AppInstance ();
                inst.account_id = acct_id;
                inst.account_label = account_label;
                inst.msg = msg;
                yield lookup_chat (acct_id, msg.chat_id, chat_names,
                                   chat_avatars);
                inst.chat_name = chat_names.lookup (msg.chat_id)
                    ?? "Chat %d".printf (msg.chat_id);
                inst.chat_avatar = chat_avatars.lookup (msg.chat_id);
                entry.instances.add (inst);

                add_user (entry, acct_id, msg);
            }
        }

        /** Webxdc message ids in any chat of the account, newest last. */
        private async int[] account_chat_media (int acct_id) throws Error {
            var result = yield rpc.call ("get_chat_media", Params.begin ()
                .add_int (acct_id)
                .add_null ()            /* chatId: all chats */
                .add_string ("Webxdc")
                .add_null ()
                .add_null ()
                .build ());
            if (result == null ||
                result.get_node_type () != Json.NodeType.ARRAY) return {};
            var arr = result.get_array ();
            int[] ids = new int[arr.get_length ()];
            for (uint i = 0; i < arr.get_length (); i++) {
                ids[i] = (int) arr.get_int_element (i);
            }
            return ids;
        }

        /** Manifest metadata and icon, filled from the first instance that
            provides each piece. */
        private async void merge_info (AppEntry entry, int acct_id,
                                       int msg_id, Json.Object info) {
            if (entry.summary == null) {
                var summary = json_str (info, "summary");
                if (summary != null && summary.length > 0) {
                    entry.summary = summary;
                }
            }
            if (entry.document == null) {
                var document = json_str (info, "document");
                if (document != null && document.length > 0) {
                    entry.document = document;
                }
            }
            if (entry.source_code_url == null) {
                var url = json_str (info, "sourceCodeUrl");
                if (url != null && url.length > 0) {
                    entry.source_code_url = url;
                }
            }
            if (json_bool (info, "internetAccess")) {
                entry.internet_access = true;
            }
            if (entry.icon != null) return;
            var icon_name = json_str (info, "icon");
            if (icon_name == null || icon_name.length == 0) return;
            try {
                var blob = yield rpc.call ("get_webxdc_blob", Params.begin ()
                    .add_int (acct_id).add_int (msg_id)
                    .add_string (icon_name).build ());
                entry.icon = Gdk.Texture.from_bytes (
                    new Bytes (decode_rpc_blob (blob.get_string ())));
            } catch (Error e) {
                debug ("webxdc icon %d/%d: %s", acct_id, msg_id, e.message);
            }
        }

        private async void lookup_chat (int acct_id, int chat_id,
                                        HashTable<int, string> names,
                                        HashTable<int, string> avatars) {
            if (names.lookup (chat_id) != null) return;
            try {
                var chat = yield rpc.get_full_chat_by_id_for (acct_id,
                                                              chat_id);
                if (chat == null) return;
                var name = json_str (chat, "name");
                if (name != null && name.length > 0) {
                    names.insert (chat_id, name);
                }
                var avatar = json_str (chat, "profileImage");
                if (avatar != null && avatar.length > 0) {
                    avatars.insert (chat_id, avatar);
                }
            } catch (Error e) {
                debug ("webxdc chat %d/%d: %s", acct_id, chat_id, e.message);
            }
        }

        private static string sender_label (Message msg) {
            if (msg.is_outgoing) return "Me";
            return msg.sender_name ?? msg.sender_address ?? "Unknown";
        }

        private void add_user (AppEntry entry, int acct_id, Message msg) {
            string key = "%d:%d".printf (acct_id, msg.sender_contact_id);
            for (uint i = 0; i < entry.users.length; i++) {
                if (entry.users[i].key == key) return;
            }
            var user = new AppUser ();
            user.key = key;
            user.name = sender_label (msg);
            user.avatar_path = msg.sender_avatar_path;
            entry.users.add (user);
        }

        /* ================================================================
         *  Favorites
         * ================================================================ */

        private static string favorites_path () {
            return Path.build_filename (Environment.get_user_config_dir (),
                                        "parla", "webxdc-favorites.ini");
        }

        private static GenericSet<string> load_favorites () {
            var set = new GenericSet<string> (str_hash, str_equal);
            var kf = new KeyFile ();
            try {
                kf.load_from_file (favorites_path (), KeyFileFlags.NONE);
                foreach (string key in kf.get_string_list ("Favorites",
                                                           "apps")) {
                    if (key.length > 0) set.add (key);
                }
            } catch (Error e) { /* no favorites yet */ }
            return set;
        }

        private void save_favorites () {
            string[] keys = {};
            favorites.foreach ((key) => { keys += key; });
            var kf = new KeyFile ();
            kf.set_string_list ("Favorites", "apps", keys);
            try {
                DirUtils.create_with_parents (
                    Path.get_dirname (favorites_path ()), 0700);
                kf.save_to_file (favorites_path ());
            } catch (Error e) {
                warning ("webxdc favorites: %s", e.message);
            }
        }

        private void set_favorite (AppEntry entry, bool favorite) {
            entry.favorite = favorite;
            if (favorite) favorites.add (entry.key);
            else favorites.remove (entry.key);
            save_favorites ();
            /* Resort from an idle: the toggle emitting this lives in a row
               the rebuild is about to destroy. */
            Idle.add (() => {
                rebuild_list ();
                return Source.REMOVE;
            });
        }

        private static Gtk.ToggleButton star_button (AppEntry entry) {
            var star = new Gtk.ToggleButton ();
            star.add_css_class ("flat");
            star.valign = Gtk.Align.CENTER;
            star.active = entry.favorite;
            star.icon_name = entry.favorite
                ? "starred-symbolic" : "non-starred-symbolic";
            star.tooltip_text = entry.favorite
                ? "Remove from favorites" : "Add to favorites";
            return star;
        }

        /* ================================================================
         *  Apps list page
         * ================================================================ */

        private void rebuild_list () {
            clear_listbox (app_list);
            apps.sort ((a, b) => {
                if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
                return a.name.collate (b.name);
            });

            string q = search_entry.text.strip ().down ();
            uint shown = 0;
            for (uint i = 0; i < apps.length; i++) {
                var entry = apps[i];
                if (q.length > 0 && !entry.name.down ().contains (q)
                        && !entry.author.down ().contains (q)) continue;
                app_list.append (build_app_row (entry));
                shown++;
            }

            if (apps.length == 0) {
                stack.visible_child_name = "empty";
            } else {
                stack.visible_child_name = "list";
                if (shown == 0) {
                    var none = new Gtk.Label ("No apps match the search");
                    none.add_css_class ("dim-label");
                    none.margin_top = 12;
                    none.margin_bottom = 12;
                    app_list.append (none);
                }
            }
        }

        private Gtk.Widget build_app_row (AppEntry entry) {
            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = entry.name;
            row.subtitle = "%s · %s".printf (entry.author,
                count_label (entry.instances.length, "chat"));
            row.activatable = true;
            row.add_prefix (app_icon (entry, 40));

            row.add_suffix (users_cluster (entry, 20, 3));

            var star = star_button (entry);
            star.toggled.connect (() => {
                set_favorite (entry, star.active);
            });
            row.add_suffix (star);

            var chevron = new Gtk.Image.from_icon_name ("go-next-symbolic");
            chevron.add_css_class ("dim-label");
            row.add_suffix (chevron);

            row.activated.connect (() => { push_details (entry); });
            return row;
        }

        private Gtk.Widget app_icon (AppEntry entry, int size) {
            var icon = new Gtk.Image ();
            icon.pixel_size = size;
            if (entry.icon != null) icon.paintable = entry.icon;
            else icon.icon_name = "application-x-executable-symbolic";
            return icon;
        }

        /** Small stacked preview of the people who used the app. */
        private Gtk.Widget users_cluster (AppEntry entry, int size, int max) {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            box.valign = Gtk.Align.CENTER;
            uint shown = uint.min (entry.users.length, max);
            for (uint i = 0; i < shown; i++) {
                var user = entry.users[i];
                var avatar = new Adw.Avatar (size, user.name, true);
                avatar.custom_image = load_avatar (user.avatar_path);
                avatar.tooltip_text = user.name;
                box.append (avatar);
            }
            if (entry.users.length > max) {
                var more = new Gtk.Label (
                    "+%u".printf (entry.users.length - max));
                more.add_css_class ("dim-label");
                more.add_css_class ("caption");
                box.append (more);
            }
            return box;
        }

        private static string count_label (uint n, string noun) {
            return n == 1 ? "1 %s".printf (noun)
                          : "%u %ss".printf (n, noun);
        }

        /* ================================================================
         *  App detail page (appstore-like)
         * ================================================================ */

        private void push_details (AppEntry entry) {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_top = 12;
            box.margin_bottom = 20;

            /* Icon + name + author + first-seen date, store-front style. */
            var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 16);
            head.append (app_icon (entry, 96));

            var meta = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            meta.valign = Gtk.Align.CENTER;
            meta.hexpand = true;
            var name_lbl = new Gtk.Label (entry.name);
            name_lbl.add_css_class ("title-1");
            name_lbl.halign = Gtk.Align.START;
            name_lbl.wrap = true;
            name_lbl.xalign = 0;
            meta.append (name_lbl);
            meta.append (detail_line ("Shared by %s".printf (entry.author)));
            if (entry.created > 0) {
                meta.append (detail_line ("First seen %s".printf (
                    format_date_time (entry.created))));
            }
            if (entry.internet_access) {
                meta.append (detail_line ("Requests internet access"));
            }
            head.append (meta);

            var star = star_button (entry);
            star.valign = Gtk.Align.START;
            star.toggled.connect (() => {
                set_favorite (entry, star.active);
                star.icon_name = star.active
                    ? "starred-symbolic" : "non-starred-symbolic";
            });
            head.append (star);
            box.append (head);

            /* Actions: Run continues an existing chat or picks a contact;
               the rest mirror the message-card options. */
            var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            var run_btn = new Gtk.Button.with_label ("Run");
            run_btn.add_css_class ("suggested-action");
            run_btn.add_css_class ("pill");
            run_btn.clicked.connect (() => { show_run_menu (run_btn, entry); });
            actions.append (run_btn);

            var chat_btn = new Gtk.Button.with_label ("New Chat…");
            chat_btn.add_css_class ("pill");
            chat_btn.tooltip_text =
                "Share and start this app in a chat with a contact";
            chat_btn.clicked.connect (() => { pick_contact_and_send (entry); });
            actions.append (chat_btn);

            var save_btn = new Gtk.Button.with_label ("Save to Disk…");
            save_btn.add_css_class ("pill");
            save_btn.clicked.connect (() => { save_app.begin (entry); });
            actions.append (save_btn);
            box.append (actions);

            /* Description block from the manifest data core exposes. */
            var about = new Gtk.ListBox ();
            about.selection_mode = Gtk.SelectionMode.NONE;
            about.add_css_class ("boxed-list");
            if (entry.summary != null) {
                about.append (info_row ("Description", entry.summary));
            }
            if (entry.document != null) {
                about.append (info_row ("Document", entry.document));
            }
            if (entry.source_code_url != null) {
                var url_row = info_row ("Source Code", entry.source_code_url);
                url_row.activatable = true;
                url_row.activated.connect (() => {
                    open_url (entry.source_code_url);
                });
                var open_img = new Gtk.Image.from_icon_name (
                    "adw-external-link-symbolic");
                open_img.add_css_class ("dim-label");
                url_row.add_suffix (open_img);
                about.append (url_row);
            }
            var used_row = info_row ("Used by",
                count_label (entry.users.length, "person"));
            used_row.add_suffix (users_cluster (entry, 24, 6));
            about.append (used_row);
            box.append (section ("About", about));

            /* Every chat the app ran in, with a per-chat run button. */
            var chats = new Gtk.ListBox ();
            chats.selection_mode = Gtk.SelectionMode.NONE;
            chats.add_css_class ("boxed-list");
            for (uint i = 0; i < entry.instances.length; i++) {
                chats.append (build_instance_row (entry.instances[i]));
            }
            box.append (section ("Chats", chats));

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = box;

            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (new Adw.HeaderBar ());
            toolbar.content = scroll;
            nav.push (new Adw.NavigationPage (toolbar, entry.name));
        }

        private static Gtk.Widget detail_line (string text) {
            var lbl = new Gtk.Label (text);
            lbl.add_css_class ("dim-label");
            lbl.halign = Gtk.Align.START;
            lbl.wrap = true;
            lbl.xalign = 0;
            return lbl;
        }

        private static Adw.ActionRow info_row (string title, string subtitle) {
            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = title;
            row.subtitle = subtitle;
            return row;
        }

        private static Gtk.Widget section (string heading, Gtk.Widget child) {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
            var lbl = new Gtk.Label (heading);
            lbl.add_css_class ("heading");
            lbl.add_css_class ("dim-label");
            lbl.halign = Gtk.Align.START;
            box.append (lbl);
            box.append (child);
            return box;
        }

        private Gtk.Widget build_instance_row (AppInstance inst) {
            var row = new Adw.ActionRow ();
            row.use_markup = false;
            row.title = inst.chat_name;
            row.subtitle = "%s · %s".printf (inst.account_label,
                format_date_time (inst.msg.timestamp));
            row.add_prefix (presence_avatar (32, inst.chat_name,
                                             inst.chat_avatar, false));

            if (Webxdc.is_running (inst.msg.id)
                    && inst.account_id == rpc.account_id) {
                var running = new Gtk.Label ("Running");
                running.add_css_class ("caption");
                running.add_css_class ("accent");
                running.valign = Gtk.Align.CENTER;
                row.add_suffix (running);
            }

            var run = new Gtk.Button.from_icon_name (
                "media-playback-start-symbolic");
            run.add_css_class ("flat");
            run.valign = Gtk.Align.CENTER;
            run.tooltip_text = "Run in this chat";
            run.clicked.connect (() => { launch (inst); });
            row.add_suffix (run);

            row.activatable = true;
            row.activated.connect (() => { launch (inst); });
            return row;
        }

        /* ================================================================
         *  Actions
         * ================================================================ */

        /** Run: continue the app where it already ran, or start it in a
            fresh chat with a contact. A single known chat starts directly;
            several offer the choice. */
        private void show_run_menu (Gtk.Widget anchor, AppEntry entry) {
            if (entry.instances.length == 1) {
                launch (entry.instances[0]);
                return;
            }
            Gtk.Box vbox;
            var popover = popover_menu (anchor,
                anchor.get_width () / 2, anchor.get_height (), out vbox);
            for (uint i = 0; i < entry.instances.length; i++) {
                var inst = entry.instances[i];
                var btn = new PopoverButton (popover, "%s — %s".printf (
                    inst.chat_name, inst.account_label));
                btn.selected.connect (() => { launch (inst); });
                vbox.append (btn);
            }
            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            var fresh = new PopoverButton (popover, "Start in a new chat…");
            fresh.selected.connect (() => { pick_contact_and_send (entry); });
            vbox.append (fresh);
            popover.popup ();
        }

        /** The app window lives outside this dialog; close before starting
            so a possible profile switch is not blocked by the open modal. */
        private void launch (AppInstance inst) {
            this.close ();
            app_window.run_webxdc_instance.begin (inst.account_id, inst.msg);
        }

        private AppInstance? local_instance (AppEntry entry) {
            /* Prefer the active profile: sending and running then need no
               profile switch. */
            for (uint i = 0; i < entry.instances.length; i++) {
                var inst = entry.instances[i];
                if (inst.account_id == rpc.account_id
                        && inst.msg.has_local_file) return inst;
            }
            for (uint i = 0; i < entry.instances.length; i++) {
                if (entry.instances[i].msg.has_local_file) {
                    return entry.instances[i];
                }
            }
            return null;
        }

        private async void save_app (AppEntry entry) {
            var inst = local_instance (entry);
            if (inst == null) {
                app_window.show_toast (
                    "The app file has not been downloaded yet");
                return;
            }
            yield app_window.save_attachment (inst.msg.file_path,
                                              inst.msg.file_name);
        }

        private void pick_contact_and_send (AppEntry entry) {
            var inst = local_instance (entry);
            if (inst == null) {
                app_window.show_toast (
                    "The app file has not been downloaded yet");
                return;
            }
            var picker = new ContactPickerDialog (rpc, null,
                "Start App With…");
            picker.contact_picked.connect ((contact_id, email) => {
                send_and_run.begin (inst, contact_id, email);
            });
            picker.present (this);
        }

        /** Share the .xdc into a (possibly new) 1:1 chat of the active
            profile and start it there. */
        private async void send_and_run (AppInstance inst, int contact_id,
                                         string email) {
            try {
                if (contact_id == 0) {
                    contact_id = yield rpc.get_or_create_contact (email);
                }
                int chat_id = yield rpc.get_or_create_chat_by_contact (
                    contact_id);
                int msg_id = yield rpc.send_msg (chat_id, null,
                    inst.msg.file_path, inst.msg.file_name, 0, "Webxdc");
                if (msg_id <= 0) {
                    app_window.show_toast ("Could not share the app");
                    return;
                }
                app_window.show_toast ("App shared into the chat");
                var sent = yield rpc.fetch_message (msg_id);
                if (sent != null) {
                    this.close ();
                    yield app_window.run_webxdc_instance (rpc.account_id,
                                                          sent);
                    return;
                }
                yield reload ();
            } catch (Error e) {
                show_error (this, "Could not share the app: " + e.message);
            }
        }

        private void open_url (string url) {
            var launcher = new Gtk.UriLauncher (url);
            launcher.launch.begin (app_window, null, (obj, res) => {
                try {
                    launcher.launch.end (res);
                } catch (Error e) {
                    app_window.show_toast ("Could not open link: "
                                           + e.message);
                }
            });
        }
    }
}
