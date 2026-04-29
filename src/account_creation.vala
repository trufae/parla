namespace Dc {

    /**
     * Account-creation flows. Hosts the dialog(s) that turn the four
     * "Add Account" entry points into concrete RPC calls.
     *
     * Currently implemented:
     *   - Create new profile (CreateProfileDialog) — chatmail relay
     *   - Add as secondary device (ReceiveBackupDialog)
     *   - Use invitation code (InvitationCodeProfileDialog)
     *
     * Stubs for future work:
     *   - Use classic email address (lives in window.vala for now)
     */

    /**
     * Creates a fresh chatmail profile on the relay chosen by the user.
     * Server-side picks an address, returns credentials, and the rpc
     * server configures the account end-to-end. ConfigureProgress events
     * drive the progress bar.
     */
    public class CreateProfileDialog : Adw.Dialog {

        public signal void account_created (int new_account_id);

        private RpcClient rpc;
        private EventHandler events;

        private Gtk.Stack stack;
        private Gtk.Entry name_entry;
        private RelayPicker relay_picker;
        private Gtk.Button create_btn;
        private Gtk.ProgressBar progress_bar;
        private Gtk.Label progress_label;
        private Gtk.Label status_label;

        private int new_account_id = 0;
        private bool create_running = false;
        private bool create_finished = false;
        private ulong progress_handler_id = 0;

        public CreateProfileDialog (RpcClient rpc, EventHandler events) {
            this.rpc = rpc;
            this.events = events;

            this.title = "Create New Profile";
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
                "Pick a chatmail relay or enter a custom server. The server will assign you an email " +
                "address and password automatically — encryption keys are " +
                "generated on this device.");
            intro.wrap = true;
            intro.xalign = 0;
            intro.add_css_class ("dim-label");
            content.append (intro);

            var name_label = new Gtk.Label ("Display Name");
            name_label.add_css_class ("heading");
            name_label.xalign = 0;
            content.append (name_label);

            name_entry = new Gtk.Entry ();
            name_entry.placeholder_text = "Your name";
            name_entry.activates_default = true;
            content.append (name_entry);

            var relay_label = new Gtk.Label ("Server");
            relay_label.add_css_class ("heading");
            relay_label.xalign = 0;
            content.append (relay_label);

            relay_picker = new RelayPicker ();
            content.append (relay_picker);

            var hint = new Gtk.Label (null);
            hint.use_markup = true;
            hint.xalign = 0;
            hint.wrap = true;
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            hint.label = "See <a href=\"https://chatmail.at/relays\">" +
                "chatmail.at/relays</a> for the full list.";
            content.append (hint);

            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row.halign = Gtk.Align.END;
            row.margin_top = 6;

            create_btn = new Gtk.Button.with_label ("Create Profile");
            create_btn.add_css_class ("suggested-action");
            create_btn.clicked.connect (() => { do_create.begin (); });
            row.append (create_btn);
            this.default_widget = create_btn;
            content.append (row);

            return content;
        }

        private Gtk.Widget build_progress_page () {
            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = content.margin_end = 18;
            content.margin_top = 12;
            content.margin_bottom = 18;
            content.valign = Gtk.Align.CENTER;

            status_label = new Gtk.Label ("Contacting server…");
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
            cancel_btn.clicked.connect (cancel_create);
            actions.append (cancel_btn);
            content.append (actions);

            return content;
        }

        /* ---- Flow ---- */

        private async void do_create () {
            if (create_running) return;

            string display_name = name_entry.text.strip ();
            string domain = relay_picker.get_selected_domain ();
            string qr_link = relay_picker.get_chatmail_qr ();

            create_running = true;
            stack.visible_child_name = "progress";
            status_label.label = "Creating profile on %s…".printf (domain);

            progress_handler_id = events.configure_progress.connect (
                on_configure_progress);

            try {
                new_account_id = yield rpc.add_account ();
            } catch (Error e) {
                cleanup_signal ();
                create_running = false;
                show_error (this, "Failed to create account: " + e.message);
                this.close ();
                return;
            }

            if (display_name.length > 0) {
                try {
                    yield rpc.batch_set_config ("displayname", display_name,
                                                  new_account_id);
                } catch (Error e) {
                    /* non-fatal — just continue */
                }
            }

            try {
                yield rpc.add_transport_from_qr (new_account_id, qr_link);
            } catch (Error e) {
                cleanup_signal ();
                create_running = false;
                int aid = new_account_id;
                new_account_id = 0;
                if (aid > 0) {
                    try { yield rpc.remove_account (aid); }
                    catch (Error re) { /* ignore */ }
                }
                show_error (this, "Profile creation failed: " + e.message);
                this.close ();
                return;
            }

            cleanup_signal ();
            create_finished = true;
            create_running = false;
            int created = new_account_id;
            new_account_id = 0;
            account_created (created);
            this.close ();
        }

        private void on_configure_progress (int ctx, int progress,
                                              string? comment) {
            if (ctx != new_account_id) return;
            if (progress == 0) {
                status_label.label = comment ?? "Failed";
                return;
            }
            double frac = ((double) progress) / 1000.0;
            if (frac > 1.0) frac = 1.0;
            progress_bar.fraction = frac;
            progress_label.label = "%d %%".printf ((int) (frac * 100));
            if (comment != null && comment.length > 0) {
                status_label.label = comment;
            } else if (progress >= 1000) {
                status_label.label = "Finishing…";
            }
        }

        private void cleanup_signal () {
            if (progress_handler_id != 0) {
                events.disconnect (progress_handler_id);
                progress_handler_id = 0;
            }
        }

        private void cancel_create () {
            if (!create_running) {
                this.close ();
                return;
            }
            if (new_account_id > 0) {
                rpc.stop_ongoing_process.begin (new_account_id, (obj, res) => {
                    try { rpc.stop_ongoing_process.end (res); }
                    catch (Error e) { /* ignore */ }
                });
            }
        }

        private void on_dialog_closed () {
            cleanup_signal ();
            if (!create_finished && new_account_id > 0) {
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

    /**
     * Creates a profile from a pasted Delta Chat invitation/account link.
     *
     * DCACCOUNT/DCLOGIN links configure the new profile directly using the
     * linked server credentials. Secure-join invitation links first create a
     * default chatmail profile and then accept the invite on the new profile,
     * matching Delta Chat Desktop's instant-onboarding flow.
     */
    public class InvitationCodeProfileDialog : Adw.Dialog {

        public signal void account_created (int new_account_id, int chat_id);

        private RpcClient rpc;
        private EventHandler events;

        private Gtk.Stack stack;
        private Gtk.Entry invite_entry;
        private Gtk.Button start_btn;
        private Gtk.ProgressBar progress_bar;
        private Gtk.Label progress_label;
        private Gtk.Label status_label;

        private int new_account_id = 0;
        private bool create_running = false;
        private bool create_finished = false;
        private ulong progress_handler_id = 0;

        public InvitationCodeProfileDialog (RpcClient rpc, EventHandler events) {
            this.rpc = rpc;
            this.events = events;

            this.title = "Use Invitation Code";
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

        private Gtk.Widget build_input_page () {
            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = content.margin_end = 18;
            content.margin_top = 12;
            content.margin_bottom = 18;

            var intro = new Gtk.Label (
                "Paste a Delta Chat account or invitation link. Account links " +
                "use the linked server; contact and group invites create a new " +
                "chatmail profile first.");
            intro.wrap = true;
            intro.xalign = 0;
            intro.add_css_class ("dim-label");
            content.append (intro);

            invite_entry = new Gtk.Entry ();
            invite_entry.placeholder_text = "dcaccount:example.org or https://i.delta.chat/#...";
            invite_entry.input_purpose = Gtk.InputPurpose.URL;
            invite_entry.hexpand = true;
            invite_entry.activates_default = true;
            invite_entry.changed.connect (update_start_sensitivity);
            content.append (invite_entry);

            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row.halign = Gtk.Align.END;

            var paste_btn = new Gtk.Button.with_label ("Paste from Clipboard");
            paste_btn.clicked.connect (paste_from_clipboard);
            row.append (paste_btn);

            start_btn = new Gtk.Button.with_label ("Create Profile");
            start_btn.add_css_class ("suggested-action");
            start_btn.sensitive = false;
            start_btn.clicked.connect (() => { start_create.begin (); });
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

            status_label = new Gtk.Label ("Checking invitation…");
            status_label.xalign = 0;
            status_label.wrap = true;
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
            cancel_btn.clicked.connect (cancel_create);
            actions.append (cancel_btn);
            content.append (actions);

            return content;
        }

        private void update_start_sensitivity () {
            start_btn.sensitive = invite_entry.text.strip ().length > 0;
        }

        private void paste_from_clipboard () {
            var display = this.get_display ();
            if (display == null) return;
            var clipboard = display.get_clipboard ();
            clipboard.read_text_async.begin (null, (obj, res) => {
                try {
                    string? text = clipboard.read_text_async.end (res);
                    if (text != null) {
                        invite_entry.text = text.strip ();
                        invite_entry.grab_focus_without_selecting ();
                    }
                } catch (Error e) {
                    /* no clipboard text */
                }
            });
        }

        private async void start_create () {
            if (create_running) return;

            string invite_link = invite_entry.text.strip ();
            if (invite_link.length == 0) return;

            create_running = true;
            stack.visible_child_name = "progress";
            status_label.label = "Checking invitation…";

            progress_handler_id = events.configure_progress.connect (
                on_configure_progress);

            try {
                new_account_id = yield rpc.add_account ();
            } catch (Error e) {
                cleanup_signal ();
                create_running = false;
                show_error (this, "Failed to create account: " + e.message);
                this.close ();
                return;
            }

            Json.Object? qr = null;
            try {
                qr = yield rpc.check_qr (new_account_id, invite_link);
            } catch (Error e) {
                yield fail_new_account ("Invitation code failed: " + e.message);
                return;
            }

            if (qr == null || !qr.has_member ("kind")) {
                yield fail_new_account ("This is not a valid Delta Chat invitation code.");
                return;
            }

            string kind = qr.get_string_member ("kind");
            int chat_id = 0;

            if (kind == "account" || kind == "login") {
                status_label.label = "Creating profile…";
                try {
                    yield rpc.add_transport_from_qr (new_account_id, invite_link);
                } catch (Error e) {
                    yield fail_new_account ("Profile creation failed: " + e.message);
                    return;
                }
            } else if (kind == "askVerifyContact" ||
                       kind == "askVerifyGroup" ||
                       kind == "askJoinBroadcast") {
                status_label.label = "Creating profile…";
                try {
                    yield rpc.add_transport_from_qr (
                        new_account_id,
                        build_chatmail_qr (CHATMAIL_RELAYS[0].domain));
                    status_label.label = "Accepting invitation…";
                    chat_id = yield rpc.secure_join (new_account_id, invite_link);
                } catch (Error e) {
                    yield fail_new_account ("Invitation failed: " + e.message);
                    return;
                }
            } else {
                yield fail_new_account (
                    "This code cannot be used to create a profile.");
                return;
            }

            cleanup_signal ();
            create_finished = true;
            create_running = false;
            int created = new_account_id;
            new_account_id = 0;
            account_created (created, chat_id);
            this.close ();
        }

        private async void fail_new_account (string message) {
            cleanup_signal ();
            create_running = false;
            if (new_account_id > 0) {
                int aid = new_account_id;
                new_account_id = 0;
                try {
                    yield rpc.stop_ongoing_process (aid);
                } catch (Error e) { /* ignore */ }
                try {
                    yield rpc.remove_account (aid);
                } catch (Error e) { /* ignore */ }
            }
            show_error (this, message);
            this.close ();
        }

        private void on_configure_progress (int ctx, int progress,
                                              string? comment) {
            if (ctx != new_account_id) return;
            if (progress == 0) {
                status_label.label = comment ?? "Failed";
                return;
            }
            double frac = ((double) progress) / 1000.0;
            if (frac > 1.0) frac = 1.0;
            progress_bar.fraction = frac;
            progress_label.label = "%d %%".printf ((int) (frac * 100));
            if (comment != null && comment.length > 0) {
                status_label.label = comment;
            } else if (progress >= 1000) {
                status_label.label = "Finishing…";
            }
        }

        private void cleanup_signal () {
            if (progress_handler_id != 0) {
                events.disconnect (progress_handler_id);
                progress_handler_id = 0;
            }
        }

        private void cancel_create () {
            if (!create_running) {
                this.close ();
                return;
            }
            if (new_account_id > 0) {
                rpc.stop_ongoing_process.begin (new_account_id, (obj, res) => {
                    try { rpc.stop_ongoing_process.end (res); }
                    catch (Error e) { /* ignore */ }
                });
            }
        }

        private void on_dialog_closed () {
            cleanup_signal ();
            if (!create_finished && new_account_id > 0) {
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
