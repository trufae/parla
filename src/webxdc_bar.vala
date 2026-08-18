namespace Dc {

    /** Per-chat topbar (like the pinned-messages bar) listing the Webxdc
        apps currently RUNNING from this chat — an app that is not running
        has no row, and with nothing running the bar stays hidden. Starting
        an app happens from its message card; this bar controls the open
        window. Each row shows the app with minimize and stop buttons, and
        a right-click menu carries the rest: view in conversation, forward,
        save to disk, pin/unpin the message and stop. Window behavior (independent vs
        follow-chat) is a global choice in Settings → Webxdc Apps. The
        window state itself lives in Dc.Webxdc; this bar is only a view
        over it, kept in sync through Webxdc.Monitor. */
    public class WebxdcAppsBar : Object {

        public Gtk.Revealer revealer { get; private set; }

        public signal void scroll_requested (int msg_id);
        public signal void forward_requested (int msg_id);
        public signal void save_requested (int msg_id);

        private unowned RpcClient? rpc = null;
        private unowned PinnedMessagesManager? pinned = null;
        private Gtk.Box bar_content;
        private int chat_id = 0;
        private uint load_generation = 0;
        private ulong monitor_handler = 0;
        private bool closed = false;

        public WebxdcAppsBar () {
            bar_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            bar_content.add_css_class ("webxdc-bar");
            revealer = new Gtk.Revealer ();
            revealer.child = bar_content;
            revealer.reveal_child = false;
            revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
            /* A collapsed SLIDE_DOWN revealer still reports its child's
               full width, and these rows are wide (name plus controls).
               An invisible child measures zero; drop it out of
               measurement whenever the bar is hidden. */
            bar_content.visible = false;
            revealer.notify["child-revealed"].connect (() => {
                if (!revealer.reveal_child && !revealer.child_revealed) {
                    revealer.child.visible = false;
                }
            });

            /* Any start/stop can alter which rows exist, so rebuild from
               the runner's current state. */
            monitor_handler = connect_monitor (this);
        }

        private static ulong connect_monitor (WebxdcAppsBar target) {
            WeakRef bar_ref = WeakRef (target);
            return Webxdc.Monitor.get_default ().changed.connect ((msg_id) => {
                var bar = bar_ref.get () as WebxdcAppsBar;
                if (bar != null && !bar.closed)
                    bar.load_for_chat.begin (bar.chat_id);
            });
        }

        public void set_rpc (RpcClient r) { this.rpc = r; }

        public void set_pinned (PinnedMessagesManager p) { this.pinned = p; }

        public async void load_for_chat (int chat_id) {
            if (closed) return;
            this.chat_id = chat_id;
            uint generation = ++load_generation;
            if (chat_id <= 0 || !Webxdc.AVAILABLE || rpc == null) {
                hide_bar ();
                return;
            }

            int[] app_ids = Webxdc.running_apps (rpc.account_id, chat_id);
            if (app_ids.length == 0) {
                hide_bar ();
                return;
            }

            var next_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            next_content.add_css_class ("webxdc-bar");

            foreach (int app_id in app_ids) {
                var info = yield Webxdc.card_info (app_id);
                if (closed || generation != load_generation) return;
                if (!Webxdc.is_running (app_id)) continue;
                next_content.append (build_row (app_id, info));
            }
            if (next_content.get_first_child () == null) {
                hide_bar ();
                return;
            }

            bar_content = next_content;
            revealer.child = bar_content;
            bar_content.visible = true;
            revealer.reveal_child = true;
        }

        private void hide_bar () {
            revealer.reveal_child = false;
        }

        private Gtk.Widget build_row (int msg_id, Webxdc.CardInfo info) {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            box.margin_start = 8;
            box.margin_end = 8;
            box.margin_top = 3;
            box.margin_bottom = 3;

            var icon = new Gtk.Image ();
            icon.pixel_size = 20;
            if (info.icon != null) icon.paintable = info.icon;
            else icon.icon_name = "application-x-executable-symbolic";

            var name_lbl = new Gtk.Label (info.name ?? "Webxdc app");
            name_lbl.halign = Gtk.Align.START;
            name_lbl.ellipsize = Pango.EllipsizeMode.END;
            name_lbl.max_width_chars = 30;

            /* The name area raises the app window; jumping to the message
               lives in the context menu as "View in conversation". */
            var name_btn = new Gtk.Button ();
            name_btn.add_css_class ("flat");
            name_btn.hexpand = true;
            var name_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            name_box.append (icon);
            name_box.append (name_lbl);
            name_btn.child = name_box;
            name_btn.tooltip_text = "Raise app window";
            name_btn.clicked.connect (() => { Webxdc.present_app (msg_id); });
            box.append (name_btn);

            var minimize = bar_button ("window-minimize-symbolic",
                                       "Minimize or restore app window");
            minimize.clicked.connect (() => {
                Webxdc.minimize_app (msg_id);
            });
            box.append (minimize);

            var stop = bar_button ("media-playback-stop-symbolic",
                                   "Stop app");
            stop.clicked.connect (() => {
                Webxdc.stop_app (msg_id);
            });
            box.append (stop);

            var context = new Gtk.GestureClick ();
            context.button = Gdk.BUTTON_SECONDARY;
            context.pressed.connect ((n_press, x, y) => {
                show_context_menu (box, msg_id, x, y);
            });
            box.add_controller (context);

            return box;
        }

        private void show_context_menu (Gtk.Widget parent, int msg_id,
                                        double x, double y) {
            Gtk.Box vbox;
            var popover = popover_menu (parent, x, y, out vbox);

            var view_btn = new PopoverButton (popover,
                                              "View in conversation");
            view_btn.selected.connect (() => { scroll_requested (msg_id); });
            vbox.append (view_btn);

            var forward_btn = new PopoverButton (popover, "Forward…");
            forward_btn.selected.connect (() => {
                forward_requested (msg_id);
            });
            vbox.append (forward_btn);

            var save_btn = new PopoverButton (popover, "Save to disk…");
            save_btn.selected.connect (() => { save_requested (msg_id); });
            vbox.append (save_btn);

            if (pinned != null) {
                var pin_btn = new PopoverButton (popover,
                    pinned.is_pinned (msg_id) ? "Unpin" : "Pin");
                pin_btn.selected.connect (() => {
                    pinned.toggle_pin.begin (msg_id);
                });
                vbox.append (pin_btn);
            }

            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var stop_btn = new PopoverButton (popover, "Stop app", true);
            stop_btn.selected.connect (() => { Webxdc.stop_app (msg_id); });
            vbox.append (stop_btn);

            popover.popup ();
        }

        public void close () {
            if (closed) return;
            closed = true;
            load_generation++;
            chat_id = 0;
            if (monitor_handler != 0) {
                Webxdc.Monitor.get_default ().disconnect (monitor_handler);
                monitor_handler = 0;
            }
            rpc = null;
            pinned = null;
            hide_bar ();
        }

        public override void dispose () {
            close ();
            base.dispose ();
        }

        private static Gtk.Button bar_button (string icon_name,
                                              string tooltip) {
            var button = new Gtk.Button.from_icon_name (icon_name);
            button.add_css_class ("flat");
            button.valign = Gtk.Align.CENTER;
            button.tooltip_text = tooltip;
            return button;
        }
    }
}
