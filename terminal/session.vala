namespace Parla.Terminal {
    /** Owns raw mode and the alternate screen. Call close() before releasing
     * the session; no polling or periodic repaint source runs while idle. */
    public class Session : Object {
        public signal void closed ();
        public signal void failed (string message);
        private Tty? tty;
        private View view;
        private Renderer renderer = new Renderer ();
        private Input input = new Input ();
        private uint input_source;
        private uint resize_source;
        private uint refresh_source;
        private uint escape_source;
        private uint int_source;
        private uint term_source;
        private uint hup_source;
        private ulong invalidated_handler;
        private ulong redraw_handler;
        private int width = 80;
        private int height = 24;

        public Session (View view) throws Error {
            tty = new Tty ();
            tty.size (out width, out height);
            input.key.connect ((key, text) => this.view.handle_key (key, text));
            input.mouse.connect ((event) => this.view.handle_mouse (event));
            set_view (view);
            var channel = new IOChannel.unix_new (0);
            input_source = channel.add_watch (IOCondition.IN | IOCondition.HUP | IOCondition.ERR, (source, condition) => {
                if ((condition & (IOCondition.HUP | IOCondition.ERR)) != 0) {
                    input_source = 0; close (); return Source.REMOVE;
                }
                uint8[] bytes = new uint8[4096];
                ssize_t count = Posix.read (0, bytes, bytes.length);
                if (count > 0) input.feed (bytes[:count]);
                else if (count == 0 || Posix.errno != Posix.EINTR) {
                    input_source = 0; close (); return Source.REMOVE;
                }
                if (tty == null) return Source.REMOVE;
                if (escape_source != 0) { Source.remove (escape_source); escape_source = 0; }
                if (input.waiting_escape) escape_source = Timeout.add (40, () => {
                    escape_source = 0; input.flush_escape (); return Source.REMOVE;
                });
                return Source.CONTINUE;
            });
            channel = new IOChannel.unix_new (tty.resize_fd ());
            resize_source = channel.add_watch (IOCondition.IN, () => {
                if (tty != null) { tty.size (out width, out height); schedule (); }
                return Source.CONTINUE;
            });
            int_source = Unix.signal_add (Posix.Signal.INT, () => { int_source = 0; close (); return Source.REMOVE; });
            term_source = Unix.signal_add (Posix.Signal.TERM, () => { term_source = 0; close (); return Source.REMOVE; });
            hup_source = Unix.signal_add (Posix.Signal.HUP, () => { hup_source = 0; close (); return Source.REMOVE; });
            schedule ();
        }

        /** Swap account/workspace views without leaving raw mode or losing drafts. */
        public void set_view (View view) {
            if (this.view != null) {
                this.view.disconnect (invalidated_handler);
                this.view.disconnect (redraw_handler);
            }
            this.view = view;
            invalidated_handler = view.invalidated.connect (schedule);
            redraw_handler = view.redraw_requested.connect (() => { renderer.invalidate (); schedule (); });
            schedule ();
        }

        public void use_theme (Theme theme) { renderer.use_theme (theme); schedule (); }

        private void schedule () {
            if (tty == null || refresh_source != 0) return;
            // Coalesce bursts and cap interactive redraws at roughly 60 Hz.
            refresh_source = Timeout.add (16, () => {
                refresh_source = 0;
                if (tty != null) {
                    var frame = view.draw (width, height);
                    string update = renderer.render (frame);
                    if (update != "") {
                        try { tty.write ("\033[?25l" + update + (frame.cursor_visible ? "\033[?25h" : "")); }
                        catch (Error e) { close (); failed (e.message); }
                    }
                }
                return Source.REMOVE;
            });
        }

        public void close () {
            if (tty == null) return;
            foreach (uint id in new uint[] { input_source, resize_source, refresh_source,
                escape_source, int_source, term_source, hup_source })
                if (id != 0) Source.remove (id);
            input_source = resize_source = refresh_source = escape_source = 0;
            int_source = term_source = hup_source = 0;
            view.disconnect (invalidated_handler);
            view.disconnect (redraw_handler);
            tty = null;
            closed ();
        }

        ~Session () { close (); }
    }
}
