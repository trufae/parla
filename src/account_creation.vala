namespace Dc {

    /**
     * Account-creation flows. Hosts the dialog(s) that turn the four
     * "Add Account" entry points into concrete RPC calls.
     *
     * Currently implemented:
     *   - Add as secondary device (ReceiveBackupDialog)
     *
     * Stubs for future work:
     *   - Create new profile (chatmail relay)
     *   - Use classic email address (lives in window.vala for now)
     *   - Use invitation code
     */

    /**
     * Imports a profile from another device using the dcbackup token shown
     * by the source device. The user pastes the token into the entry; we
     * call get_backup() and stream ImexProgress to a progress bar. Cancel
     * stops the ongoing process and removes the half-imported account.
     *
     * On success the new account_id is reported via account_imported.
     */
    public class ReceiveBackupDialog : Adw.Dialog {

        public signal void account_imported (int new_account_id);

        private RpcClient rpc;
        private EventHandler events;

        private Gtk.Stack stack;
        private Gtk.Entry url_entry;
        private Gtk.Button start_btn;
        private Gtk.ProgressBar progress_bar;
        private Gtk.Label progress_label;
        private Gtk.Label status_label;

        private int new_account_id = 0;
        private bool import_running = false;
        private bool import_finished = false;
        private ulong progress_handler_id = 0;

        public ReceiveBackupDialog (RpcClient rpc, EventHandler events) {
            this.rpc = rpc;
            this.events = events;

            this.title = "Add as Secondary Device";
            this.content_width = 480;
            this.can_close = true;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

            stack = new Gtk.Stack ();
            stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            stack.transition_duration = 180;
            stack.vexpand = true;

            stack.add_named (build_input_page (), "input");
            stack.add_named (build_progress_page (), "progress");

            box.append (stack);
            this.child = box;

            install_escape_close (this);
            this.closed.connect (on_dialog_closed);
        }

        /* ---- UI ---- */

        private Gtk.Widget build_input_page () {
            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = content.margin_end = 18;
            content.margin_top = 12;
            content.margin_bottom = 18;

            var intro = new Gtk.Label (
                "On your existing device, open Settings → " +
                "“Add Second Device” and copy the setup code shown there. " +
                "Paste it below.");
            intro.wrap = true;
            intro.xalign = 0;
            intro.add_css_class ("dim-label");
            content.append (intro);

            url_entry = new Gtk.Entry ();
            url_entry.placeholder_text = "DCBACKUP2:…";
            url_entry.hexpand = true;
            url_entry.activates_default = true;
            url_entry.changed.connect (update_start_sensitivity);
            content.append (url_entry);

            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row.halign = Gtk.Align.END;

            var paste_btn = new Gtk.Button.with_label ("Paste from Clipboard");
            paste_btn.clicked.connect (paste_from_clipboard);
            row.append (paste_btn);

            start_btn = new Gtk.Button.with_label ("Start Import");
            start_btn.add_css_class ("suggested-action");
            start_btn.sensitive = false;
            start_btn.clicked.connect (() => { start_import.begin (); });
            row.append (start_btn);

            this.default_widget = start_btn;
            content.append (row);

            return content;
        }

        private Gtk.Widget build_progress_page () {
            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = content.margin_end = 18;
            content.margin_top = 12;
            content.margin_bottom = 18;
            content.valign = Gtk.Align.CENTER;

            status_label = new Gtk.Label ("Connecting…");
            status_label.xalign = 0;
            content.append (status_label);

            progress_bar = new Gtk.ProgressBar ();
            progress_bar.fraction = 0.0;
            progress_bar.show_text = false;
            content.append (progress_bar);

            progress_label = new Gtk.Label ("0 %");
            progress_label.xalign = 0;
            progress_label.add_css_class ("dim-label");
            content.append (progress_label);

            var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            actions.halign = Gtk.Align.END;
            actions.margin_top = 6;
            var cancel_btn = new Gtk.Button.with_label ("Cancel");
            cancel_btn.add_css_class ("destructive-action");
            cancel_btn.clicked.connect (cancel_import);
            actions.append (cancel_btn);
            content.append (actions);

            return content;
        }

        /* ---- Helpers ---- */

        private void update_start_sensitivity () {
            string t = url_entry.text.strip ();
            start_btn.sensitive = t.length > 0;
        }

        private void paste_from_clipboard () {
            var display = this.get_display ();
            if (display == null) return;
            var clipboard = display.get_clipboard ();
            clipboard.read_text_async.begin (null, (obj, res) => {
                try {
                    string? text = clipboard.read_text_async.end (res);
                    if (text != null) {
                        url_entry.text = text.strip ();
                        url_entry.grab_focus_without_selecting ();
                    }
                } catch (Error e) {
                    /* no clipboard text */
                }
            });
        }

        private void show_progress (string msg) {
            status_label.label = msg;
        }

        /* ---- Import flow ---- */

        private async void start_import () {
            if (import_running) return;

            string qr = url_entry.text.strip ();
            if (qr.length == 0) return;

            import_running = true;
            stack.visible_child_name = "progress";

            /* Subscribe to ImexProgress for the new account */
            progress_handler_id = events.imex_progress.connect (on_imex_progress);

            try {
                new_account_id = yield rpc.add_account ();
            } catch (Error e) {
                cleanup_signal ();
                import_running = false;
                show_error (this, "Failed to create account: " + e.message);
                this.close ();
                return;
            }

            try {
                yield rpc.get_backup (new_account_id, qr);
            } catch (Error e) {
                cleanup_signal ();
                import_running = false;
                /* Drop the half-imported account so the user can retry */
                if (new_account_id > 0) {
                    try {
                        yield rpc.remove_account (new_account_id);
                    } catch (Error re) { /* ignore */ }
                    new_account_id = 0;
                }
                show_error (this, "Import failed: " + e.message);
                this.close ();
                return;
            }

            /* Success */
            cleanup_signal ();
            import_finished = true;
            import_running = false;
            int imported = new_account_id;
            new_account_id = 0; /* prevent cleanup from removing it */
            account_imported (imported);
            this.close ();
        }

        private void on_imex_progress (int ctx, int progress) {
            if (ctx != new_account_id) return;
            /* progress: 0=error, 1-999=permille, 1000=done */
            if (progress == 0) {
                show_progress ("Failed");
                return;
            }
            double frac = ((double) progress) / 1000.0;
            if (frac > 1.0) frac = 1.0;
            progress_bar.fraction = frac;
            progress_label.label = "%d %%".printf ((int) (frac * 100));
            if (progress >= 1000) {
                show_progress ("Finishing…");
            } else {
                show_progress (frac > 0.0 ? "Transferring…" : "Connecting…");
            }
        }

        private void cleanup_signal () {
            if (progress_handler_id != 0) {
                events.disconnect (progress_handler_id);
                progress_handler_id = 0;
            }
        }

        private void cancel_import () {
            if (!import_running) {
                this.close ();
                return;
            }
            if (new_account_id > 0) {
                rpc.stop_ongoing_process.begin (new_account_id, (obj, res) => {
                    try {
                        rpc.stop_ongoing_process.end (res);
                    } catch (Error e) { /* ignore */ }
                });
            }
            /* The pending get_backup() will return with an error and
               the cleanup path in start_import() will remove the account. */
        }

        private void on_dialog_closed () {
            cleanup_signal ();
            /* If user dismissed mid-flight without success, clean up. */
            if (!import_finished && new_account_id > 0) {
                int aid = new_account_id;
                new_account_id = 0;
                rpc.stop_ongoing_process.begin (aid, (obj, res) => {
                    try { rpc.stop_ongoing_process.end (res); } catch (Error e) {}
                    rpc.remove_account.begin (aid, (obj2, res2) => {
                        try { rpc.remove_account.end (res2); } catch (Error e) {}
                    });
                });
            }
        }
    }
}
