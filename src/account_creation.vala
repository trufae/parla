namespace Dc {

    /* New cores choose a fast initial relay and manage additional ones.
       Keep single-relay setup for engines predating init_transports (2.61). */
    public static async void initialize_profile_transports (
            RpcClient rpc, int account_id, string? qr) throws Error {
        try {
            yield rpc.init_transports (account_id, qr);
            return;
        } catch (Error e) {
            string message = e.message.down ();
            if (!("method not found" in message || "procedure not found" in message
                  || "unknown method" in message)) throw e;
        }
        if (qr != null) {
            var code = yield rpc.check_qr (account_id, qr);
            string? kind = code != null ? json_str (code, "kind") : null;
            if (kind == "account" || kind == "login") {
                yield rpc.add_transport_from_qr (account_id, qr);
                return;
            }
            if (kind != "askVerifyContact" && kind != "askVerifyGroup"
                && kind != "askJoinBroadcast")
                throw new IOError.INVALID_ARGUMENT ("This code cannot create a profile");
        }
        yield rpc.add_transport_from_qr (account_id,
            build_chatmail_qr (CHATMAIL_RELAYS[0].domain));
    }

    private static Gtk.Box account_setup_content () {
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.margin_start = content.margin_end = 18;
        content.margin_top = 12;
        content.margin_bottom = 18;
        return content;
    }

    private static Gtk.Label account_setup_intro (string text) {
        var intro = new Gtk.Label (text);
        intro.wrap = true;
        intro.xalign = 0;
        intro.add_css_class ("dim-label");
        return intro;
    }

    private static Gtk.Label account_setup_heading (string text) {
        var label = new Gtk.Label (text);
        label.add_css_class ("heading");
        label.xalign = 0;
        return label;
    }

    private static Gtk.Box account_setup_action_row (bool with_margin = true) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        row.halign = Gtk.Align.END;
        if (with_margin) row.margin_top = 6;
        return row;
    }

    private static Gtk.Stack account_setup_stack (Gtk.Widget input_page,
                                                   Gtk.Widget progress_page) {
        var stack = new Gtk.Stack ();
        stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        stack.transition_duration = 180;
        stack.vexpand = true;
        stack.add_named (input_page, "input");
        stack.add_named (progress_page, "progress");
        return stack;
    }

    private static Gtk.Box account_setup_shell (Gtk.Stack stack) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.append (new Adw.HeaderBar ());
        box.append (stack);
        return box;
    }

    private static Gtk.Stack account_setup_dialog (Adw.Dialog dialog,
                                                    string title,
                                                    Gtk.Widget input_page,
                                                    Gtk.Widget progress_page) {
        dialog.title = title;
        dialog.content_width = 480;
        dialog.can_close = true;
        var stack = account_setup_stack (input_page, progress_page);
        dialog.child = account_setup_shell (stack);
        install_escape_close (dialog);
        return stack;
    }

    private static Gtk.Button account_setup_action (Gtk.Box content,
                                                    string label,
                                                    bool with_margin = true) {
        var row = account_setup_action_row (with_margin);
        var button = new Gtk.Button.with_label (label);
        button.add_css_class ("suggested-action");
        row.append (button);
        content.append (row);
        return button;
    }

    private static Gtk.Entry account_setup_entry (string placeholder,
                                                  bool hexpand = false,
                                                  Gtk.InputPurpose purpose =
                                                      Gtk.InputPurpose.FREE_FORM) {
        var entry = new Gtk.Entry ();
        entry.placeholder_text = placeholder;
        entry.input_purpose = purpose;
        entry.hexpand = hexpand;
        entry.activates_default = true;
        return entry;
    }

    private static void disconnect_progress_handler (EventHandler events,
                                                     ref ulong handler_id) {
        if (handler_id == 0) return;
        events.disconnect (handler_id);
        handler_id = 0;
    }

    private static void stop_ongoing_account (RpcClient rpc, int account_id) {
        if (account_id <= 0) return;
        rpc.stop_ongoing_process.begin (account_id, (obj, res) => {
            try { rpc.stop_ongoing_process.end (res); }
            catch (Error e) { /* ignore */ }
        });
    }

    private static async void cleanup_pending_account (RpcClient rpc,
                                                       int account_id,
                                                       bool stop_first) {
        if (account_id <= 0) return;
        if (stop_first) {
            try { yield rpc.stop_ongoing_process (account_id); }
            catch (Error e) { /* ignore */ }
        }
        try { yield rpc.remove_account (account_id); }
        catch (Error e) { /* ignore */ }
    }

    private static void cleanup_unfinished_account (RpcClient rpc,
                                                    ref int account_id,
                                                    bool finished) {
        if (finished || account_id <= 0) return;
        int aid = account_id;
        account_id = 0;
        cleanup_pending_account.begin (rpc, aid, true);
    }

    private static bool close_if_idle (Adw.Dialog dialog, bool running) {
        if (running) return false;
        dialog.close ();
        return true;
    }

    private class AccountProgressPage : Gtk.Box {
        private Gtk.ProgressBar progress_bar;
        private Gtk.Label progress_label;
        private Gtk.Label status_label;

        public signal void cancel_requested ();

        public AccountProgressPage (string initial_status,
                                    bool wrap_status = false) {
            Object (
                orientation: Gtk.Orientation.VERTICAL,
                spacing: 12
            );
            margin_start = margin_end = 18;
            margin_top = 12;
            margin_bottom = 18;
            valign = Gtk.Align.CENTER;

            status_label = new Gtk.Label (initial_status);
            status_label.xalign = 0;
            status_label.wrap = wrap_status;
            append (status_label);

            progress_bar = new Gtk.ProgressBar ();
            progress_bar.fraction = 0.0;
            progress_bar.show_text = false;
            append (progress_bar);

            progress_label = new Gtk.Label ("0 %");
            progress_label.xalign = 0;
            progress_label.add_css_class ("dim-label");
            append (progress_label);

            var actions = account_setup_action_row ();
            var cancel_btn = new Gtk.Button.with_label ("Cancel");
            cancel_btn.add_css_class ("destructive-action");
            cancel_btn.clicked.connect (() => { cancel_requested (); });
            actions.append (cancel_btn);
            append (actions);
        }

        public void set_status (string status) {
            status_label.label = status;
        }

        public void set_permille (int progress, string? comment = null,
                                  string? active_status = null) {
            if (progress == 0) {
                set_status (comment ?? "Failed");
                return;
            }

            double fraction = ((double) progress) / 1000.0;
            if (fraction > 1.0) fraction = 1.0;
            progress_bar.fraction = fraction;
            progress_label.label = "%d %%".printf ((int) (fraction * 100));

            if (comment != null && comment.length > 0) {
                set_status (comment);
            } else if (progress >= 1000) {
                set_status ("Finishing…");
            } else if (active_status != null) {
                set_status (active_status);
            }
        }
    }

    public class CreateProfileDialog : Adw.Dialog {

        public signal void account_created (int new_account_id);

        private RpcClient rpc;
        private EventHandler events;

        private Gtk.Stack stack;
        private Gtk.Entry name_entry;
        private RelayPicker relay_picker;
        private Gtk.Button create_btn;
        private AccountProgressPage progress_page;

        private int new_account_id = 0;
        private bool create_running = false;
        private bool create_finished = false;
        private bool cancelled = false;
        private ulong progress_handler_id = 0;

        public CreateProfileDialog (RpcClient rpc, EventHandler events) {
            this.rpc = rpc;
            this.events = events;

            stack = account_setup_dialog (this, "Create New Profile",
                build_input_page (), build_progress_page ());
            this.closed.connect (on_dialog_closed);
        }

        private Gtk.Widget build_input_page () {
            var content = account_setup_content ();
            content.append (account_setup_intro (
                "Let Parla choose fast chatmail relays, or select a server. " +
                "Your profile is created automatically, with encryption keys " +
                "generated on this device."));

            content.append (account_setup_heading ("Display Name"));

            name_entry = account_setup_entry ("Your name");
            content.append (name_entry);

            content.append (account_setup_heading ("Server"));

            relay_picker = new RelayPicker (rpc, true);
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

            create_btn = account_setup_action (content, "Create Profile");
            create_btn.clicked.connect (() => { do_create.begin (); });
            this.default_widget = create_btn;

            return content;
        }

        private Gtk.Widget build_progress_page () {
            progress_page = new AccountProgressPage ("Contacting server…");
            progress_page.cancel_requested.connect (cancel_create);
            return progress_page;
        }

        private async void do_create () {
            if (create_running) return;

            string display_name = name_entry.text.strip ();
            string domain = relay_picker.get_selected_domain ();
            string? qr_link = relay_picker.get_chatmail_qr ();

            create_running = true;
            stack.visible_child_name = "progress";
            progress_page.set_status (qr_link == null ? "Finding a fast relay…"
                : "Creating profile on %s…".printf (domain));

            progress_handler_id = events.configure_progress.connect (
                on_configure_progress);

            try {
                new_account_id = yield rpc.add_account ();
            } catch (Error e) {
                cleanup_signal ();
                create_running = false;
                if (!cancelled) {
                    show_error (this, "Failed to create account: " + e.message);
                    this.close ();
                }
                return;
            }

            if (cancelled) {
                cleanup_signal ();
                create_running = false;
                return;
            }

            if (display_name.length > 0) {
                try {
                    yield rpc.batch_set_config ("displayname", display_name,
                                                  new_account_id);
                } catch (Error e) { /* ignore */ }
            }

            if (cancelled) {
                cleanup_signal ();
                create_running = false;
                return;
            }

            try {
                yield initialize_profile_transports (rpc, new_account_id, qr_link);
            } catch (Error e) {
                cleanup_signal ();
                create_running = false;
                if (cancelled) return;
                int aid = new_account_id;
                new_account_id = 0;
                yield cleanup_pending_account (rpc, aid, false);
                show_error (this, "Profile creation failed: " + e.message);
                this.close ();
                return;
            }

            cleanup_signal ();
            create_running = false;
            if (cancelled) return;
            create_finished = true;
            int created = new_account_id;
            new_account_id = 0;
            account_created (created);
            this.close ();
        }

        private void on_configure_progress (int ctx, int progress,
                                              string? comment) {
            if (ctx != new_account_id) return;
            progress_page.set_permille (progress, comment);
        }

        private void cleanup_signal () {
            disconnect_progress_handler (events, ref progress_handler_id);
        }

        private void cancel_create () {
            if (!create_running) {
                this.close ();
                return;
            }
            cancelled = true;
            this.close ();
        }

        private void on_dialog_closed () {
            cleanup_signal ();
            cleanup_unfinished_account (rpc, ref new_account_id, create_finished);
        }
    }

    public class InvitationCodeProfileDialog : Adw.Dialog {

        public signal void account_created (int new_account_id, int chat_id);

        private RpcClient rpc;
        private EventHandler events;

        private Gtk.Stack stack;
        private Gtk.Entry invite_entry;
        private Gtk.Button start_btn;
        private AccountProgressPage progress_page;

        private int new_account_id = 0;
        private bool create_running = false;
        private bool create_finished = false;
        private ulong progress_handler_id = 0;

        public InvitationCodeProfileDialog (RpcClient rpc, EventHandler events) {
            this.rpc = rpc;
            this.events = events;

            stack = account_setup_dialog (this, "Use Invitation Code",
                build_input_page (), build_progress_page ());
            this.closed.connect (on_dialog_closed);
        }

        private Gtk.Widget build_input_page () {
            var content = account_setup_content ();
            content.append (account_setup_intro (
                "Paste a Delta Chat account or invitation link. Account links " +
                "use the linked server; contact and group invites create a new " +
                "chatmail profile first."));

            invite_entry = account_setup_entry (
                "dcaccount:example.org or https://i.delta.chat/#...",
                true, Gtk.InputPurpose.URL);
            invite_entry.changed.connect (update_start_sensitivity);
            content.append (invite_entry);

            start_btn = account_setup_action (content, "Create Profile", false);
            start_btn.clicked.connect (() => { start_create.begin (); });
            start_btn.sensitive = false;

            this.default_widget = start_btn;

            return content;
        }

        private Gtk.Widget build_progress_page () {
            progress_page = new AccountProgressPage ("Checking invitation…", true);
            progress_page.cancel_requested.connect (cancel_create);
            return progress_page;
        }

        private void update_start_sensitivity () {
            start_btn.sensitive = invite_entry.text.strip ().length > 0;
        }

        private async void start_create () {
            if (create_running) return;

            string invite_link = invite_entry.text.strip ();
            if (invite_link.length == 0) return;

            create_running = true;
            stack.visible_child_name = "progress";
            progress_page.set_status ("Checking invitation…");

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
                progress_page.set_status ("Creating profile…");
                try {
                    yield initialize_profile_transports (rpc, new_account_id, invite_link);
                } catch (Error e) {
                    yield fail_new_account ("Profile creation failed: " + e.message);
                    return;
                }
            } else if (kind == "askVerifyContact" ||
                       kind == "askVerifyGroup" ||
                       kind == "askJoinBroadcast") {
                progress_page.set_status ("Creating profile…");
                try {
                    yield initialize_profile_transports (rpc, new_account_id, invite_link);
                    progress_page.set_status ("Accepting invitation…");
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
                yield cleanup_pending_account (rpc, aid, true);
            }
            show_error (this, message);
            this.close ();
        }

        private void on_configure_progress (int ctx, int progress,
                                              string? comment) {
            if (ctx != new_account_id) return;
            progress_page.set_permille (progress, comment);
        }

        private void cleanup_signal () {
            disconnect_progress_handler (events, ref progress_handler_id);
        }

        private void cancel_create () {
            if (close_if_idle (this, create_running)) return;
            stop_ongoing_account (rpc, new_account_id);
        }

        private void on_dialog_closed () {
            cleanup_signal ();
            cleanup_unfinished_account (rpc, ref new_account_id, create_finished);
        }
    }

    public class ReceiveBackupDialog : Adw.Dialog {

        public signal void account_imported (int new_account_id);

        private RpcClient rpc;
        private EventHandler events;

        private Gtk.Stack stack;
        private Gtk.Entry url_entry;
        private Gtk.Button start_btn;
        private AccountProgressPage progress_page;

        private int new_account_id = 0;
        private bool import_running = false;
        private bool import_finished = false;
        private ulong progress_handler_id = 0;

        public ReceiveBackupDialog (RpcClient rpc, EventHandler events) {
            this.rpc = rpc;
            this.events = events;

            stack = account_setup_dialog (this, "Add as Secondary Device",
                build_input_page (), build_progress_page ());
            this.closed.connect (on_dialog_closed);
        }

        private Gtk.Widget build_input_page () {
            var content = account_setup_content ();
            content.append (account_setup_intro (
                "On your existing device, open Settings → " +
                "“Add Second Device” and copy the setup code shown there. " +
                "Paste it below."));

            url_entry = account_setup_entry ("DCBACKUP2:…", true);
            url_entry.changed.connect (update_start_sensitivity);
            content.append (url_entry);

            start_btn = account_setup_action (content, "Start Import", false);
            start_btn.clicked.connect (() => { start_import.begin (); });
            start_btn.sensitive = false;

            this.default_widget = start_btn;

            return content;
        }

        private Gtk.Widget build_progress_page () {
            progress_page = new AccountProgressPage ("Connecting…");
            progress_page.cancel_requested.connect (cancel_import);
            return progress_page;
        }

        private void update_start_sensitivity () {
            start_btn.sensitive = url_entry.text.strip ().length > 0;
        }

        private async void start_import () {
            if (import_running) return;

            string qr = url_entry.text.strip ();
            if (qr.length == 0) return;

            import_running = true;
            stack.visible_child_name = "progress";

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
                if (new_account_id > 0) {
                    yield cleanup_pending_account (rpc, new_account_id, false);
                    new_account_id = 0;
                }
                show_error (this, "Import failed: " + e.message);
                this.close ();
                return;
            }

            cleanup_signal ();
            import_finished = true;
            import_running = false;
            int imported = new_account_id;
            new_account_id = 0;
            account_imported (imported);
            this.close ();
        }

        private void on_imex_progress (int ctx, int progress) {
            if (ctx != new_account_id) return;
            progress_page.set_permille (progress, null, "Transferring…");
        }

        private void cleanup_signal () {
            disconnect_progress_handler (events, ref progress_handler_id);
        }

        private void cancel_import () {
            if (close_if_idle (this, import_running)) return;
            stop_ongoing_account (rpc, new_account_id);
        }

        private void on_dialog_closed () {
            cleanup_signal ();
            cleanup_unfinished_account (rpc, ref new_account_id, import_finished);
        }
    }
}
