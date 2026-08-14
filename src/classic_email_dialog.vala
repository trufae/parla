namespace Dc {

    /**
     * Sign in with a classic email account, or edit the transport settings
     * of an existing one. Mirrors the official client's login form: address
     * and password up front, plus an "Advanced Settings" section for manual
     * IMAP/SMTP server configuration when autoconfiguration is not enough.
     */
    public class ClassicEmailDialog : Adw.Dialog {

        public signal void account_created (int new_account_id);
        public signal void transport_updated ();

        private RpcClient rpc;
        private EventHandler events;

        /* When > 0, the dialog edits this account's transport instead of
           creating a new profile. */
        private int edit_account_id = 0;
        private EnteredLoginParams? initial = null;

        private Gtk.Stack stack;
        private Gtk.Entry email_entry;
        private Gtk.PasswordEntry pass_entry;
        private Gtk.Expander advanced_expander;
        private Gtk.Grid adv_grid;
        private int adv_row = 0;
        private Gtk.Entry imap_user_entry;
        private Gtk.Entry imap_server_entry;
        private Gtk.Entry imap_port_entry;
        private Gtk.DropDown imap_security_dd;
        private Gtk.Entry smtp_user_entry;
        private Gtk.PasswordEntry smtp_pass_entry;
        private Gtk.Entry smtp_server_entry;
        private Gtk.Entry smtp_port_entry;
        private Gtk.DropDown smtp_security_dd;
        private Gtk.DropDown cert_checks_dd;
        private Gtk.Button submit_btn;
        private AccountProgressPage progress_page;

        private int new_account_id = 0;
        private int target_account_id = 0;
        private bool configure_running = false;
        private bool configure_finished = false;
        private bool cancelled = false;
        private ulong progress_handler_id = 0;

        public ClassicEmailDialog (RpcClient rpc, EventHandler events) {
            this.rpc = rpc;
            this.events = events;
            setup ("Use Classic Email Address");
        }

        public ClassicEmailDialog.for_edit (RpcClient rpc, EventHandler events,
                                            int account_id,
                                            EnteredLoginParams current) {
            this.rpc = rpc;
            this.events = events;
            this.edit_account_id = account_id;
            this.initial = current;
            setup ("Edit Transport");
        }

        private void setup (string title) {
            stack = account_setup_dialog (this, title,
                build_input_page (), build_progress_page ());
            this.closed.connect (on_dialog_closed);
        }

        private Gtk.Widget build_input_page () {
            var content = account_setup_content ();
            content.append (account_setup_intro (edit_account_id > 0
                ? "Change the login and server settings for this transport. " +
                  "Fields left on “Automatic” are configured automatically."
                : "Sign in with an existing email account. For most providers " +
                  "the address and password are enough — servers are " +
                  "configured automatically. If your provider needs custom " +
                  "IMAP/SMTP servers, set them under Advanced Settings."));

            email_entry = account_setup_entry ("user@example.com", true,
                Gtk.InputPurpose.EMAIL);
            content.append (email_entry);

            pass_entry = new Gtk.PasswordEntry ();
            pass_entry.placeholder_text = "Password";
            pass_entry.show_peek_icon = true;
            pass_entry.activates_default = true;
            content.append (pass_entry);

            advanced_expander = new Gtk.Expander ("Advanced Settings");
            advanced_expander.child = build_advanced_grid ();
            /* The dialog does not re-measure on its own once mapped, so ask
               for more room while the advanced section is open (clamped to
               the window; the page scrolls for the remainder). */
            advanced_expander.notify["expanded"].connect (() => {
                this.content_height = advanced_expander.expanded ? 680 : -1;
            });
            content.append (advanced_expander);

            var hint = new Gtk.Label (
                "Sometimes IMAP needs to be enabled in the web interface of " +
                "your provider first.");
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            content.append (hint);

            submit_btn = account_setup_action (content,
                edit_account_id > 0 ? "Save & Reconnect" : "Sign In", false);
            submit_btn.clicked.connect (() => { do_configure.begin (); });
            this.default_widget = submit_btn;

            apply_initial_values ();

            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.vexpand = true;
            scroll.child = content;
            return scroll;
        }

        private Gtk.Widget build_advanced_grid () {
            adv_grid = new Gtk.Grid ();
            adv_grid.column_spacing = 12;
            adv_grid.row_spacing = 8;
            adv_grid.margin_top = 8;
            adv_grid.margin_start = 6;

            adv_heading ("Inbox (IMAP)");
            imap_user_entry = adv_entry ("Automatic");
            adv_field ("Login name", imap_user_entry);
            imap_server_entry = adv_entry ("Automatic");
            adv_field ("Server", imap_server_entry);
            imap_port_entry = adv_port_entry ();
            adv_field ("Port", imap_port_entry);
            imap_security_dd = security_dropdown ();
            adv_field ("Security", imap_security_dd);

            adv_heading ("Outbox (SMTP)");
            smtp_user_entry = adv_entry ("Same as IMAP");
            adv_field ("Login name", smtp_user_entry);
            smtp_pass_entry = new Gtk.PasswordEntry ();
            smtp_pass_entry.placeholder_text = "Same as IMAP";
            smtp_pass_entry.show_peek_icon = true;
            adv_field ("Password", smtp_pass_entry);
            smtp_server_entry = adv_entry ("Automatic");
            adv_field ("Server", smtp_server_entry);
            smtp_port_entry = adv_port_entry ();
            adv_field ("Port", smtp_port_entry);
            smtp_security_dd = security_dropdown ();
            adv_field ("Security", smtp_security_dd);

            adv_heading ("Certificates");
            cert_checks_dd = new Gtk.DropDown.from_strings ({
                "Automatic", "Strict", "Accept invalid certificates" });
            adv_field ("Validation", cert_checks_dd);

            return adv_grid;
        }

        private void adv_heading (string text) {
            var label = account_setup_heading (text);
            if (adv_row > 0) label.margin_top = 8;
            adv_grid.attach (label, 0, adv_row++, 2, 1);
        }

        private void adv_field (string label_text, Gtk.Widget widget) {
            var label = new Gtk.Label (label_text);
            label.xalign = 0;
            label.add_css_class ("dim-label");
            adv_grid.attach (label, 0, adv_row, 1, 1);
            widget.hexpand = true;
            adv_grid.attach (widget, 1, adv_row++, 1, 1);
        }

        private static Gtk.Entry adv_entry (string placeholder) {
            return account_setup_entry (placeholder, true);
        }

        private static Gtk.Entry adv_port_entry () {
            var entry = account_setup_entry ("Automatic", true,
                Gtk.InputPurpose.DIGITS);
            entry.max_length = 5;
            return entry;
        }

        private static Gtk.DropDown security_dropdown () {
            return new Gtk.DropDown.from_strings ({
                "Automatic", "SSL/TLS", "STARTTLS", "Plain (no encryption)" });
        }

        private static string? security_value (Gtk.DropDown dd) {
            switch (dd.selected) {
                case 1: return "ssl";
                case 2: return "starttls";
                case 3: return "plain";
                default: return null;
            }
        }

        private static uint security_index (string? v) {
            switch (v) {
                case "ssl": return 1;
                case "starttls": return 2;
                case "plain": return 3;
                default: return 0;
            }
        }

        private void apply_initial_values () {
            if (initial == null) return;
            email_entry.text = initial.addr;
            /* Changing the address of an existing transport would add a new
               one instead of updating it, so lock it (like the official
               client's edit form does). */
            email_entry.editable = false;
            email_entry.sensitive = false;
            pass_entry.text = initial.password;
            imap_user_entry.text = initial.imap_user ?? "";
            imap_server_entry.text = initial.imap_server ?? "";
            if (initial.imap_port > 0)
                imap_port_entry.text = initial.imap_port.to_string ();
            imap_security_dd.selected = security_index (initial.imap_security);
            smtp_user_entry.text = initial.smtp_user ?? "";
            smtp_pass_entry.text = initial.smtp_password ?? "";
            smtp_server_entry.text = initial.smtp_server ?? "";
            if (initial.smtp_port > 0)
                smtp_port_entry.text = initial.smtp_port.to_string ();
            smtp_security_dd.selected = security_index (initial.smtp_security);
            cert_checks_dd.selected =
                initial.certificate_checks == "strict" ? 1 :
                initial.certificate_checks == "acceptInvalidCertificates" ? 2 : 0;
            advanced_expander.expanded = has_advanced_values ();
        }

        private bool has_advanced_values () {
            return initial != null &&
                (initial.imap_user != null || initial.imap_server != null ||
                 initial.imap_port > 0 || initial.imap_security != null ||
                 initial.smtp_user != null || initial.smtp_password != null ||
                 initial.smtp_server != null || initial.smtp_port > 0 ||
                 initial.smtp_security != null ||
                 initial.certificate_checks != null);
        }

        private static string? opt_text (Gtk.Entry entry) {
            string t = entry.text.strip ();
            return t.length > 0 ? t : null;
        }

        /* Returns 0 for "automatic" (empty), -1 for invalid input. */
        private static int port_value (Gtk.Entry entry) {
            string t = entry.text.strip ();
            if (t.length == 0) return 0;
            int v = int.parse (t);
            return (v > 0 && v <= 65535) ? v : -1;
        }

        private EnteredLoginParams? collect_params () {
            var p = new EnteredLoginParams ();
            p.addr = email_entry.text.strip ();
            p.password = pass_entry.text;
            if (p.addr.length == 0 || !p.addr.contains ("@")) {
                show_error (this, "Please enter a valid email address.");
                return null;
            }
            if (p.password.length == 0) {
                show_error (this, "Please enter your password.");
                return null;
            }
            p.imap_user = opt_text (imap_user_entry);
            p.imap_server = opt_text (imap_server_entry);
            p.imap_port = port_value (imap_port_entry);
            p.imap_security = security_value (imap_security_dd);
            p.smtp_user = opt_text (smtp_user_entry);
            p.smtp_password = smtp_pass_entry.text.length > 0
                ? smtp_pass_entry.text : null;
            p.smtp_server = opt_text (smtp_server_entry);
            p.smtp_port = port_value (smtp_port_entry);
            p.smtp_security = security_value (smtp_security_dd);
            if (p.imap_port < 0 || p.smtp_port < 0) {
                show_error (this, "Ports must be numbers between 1 and 65535.");
                return null;
            }
            switch (cert_checks_dd.selected) {
                case 1: p.certificate_checks = "strict"; break;
                case 2: p.certificate_checks = "acceptInvalidCertificates"; break;
                default: p.certificate_checks = null; break;
            }
            return p;
        }

        private Gtk.Widget build_progress_page () {
            progress_page = new AccountProgressPage ("Connecting…", true);
            progress_page.cancel_requested.connect (cancel_configure);
            return progress_page;
        }

        private async void do_configure () {
            if (configure_running) return;

            var params = collect_params ();
            if (params == null) return;

            configure_running = true;
            stack.visible_child_name = "progress";
            progress_page.set_status ("Configuring %s…".printf (params.addr));

            progress_handler_id = events.configure_progress.connect (
                on_configure_progress);

            if (edit_account_id > 0) {
                target_account_id = edit_account_id;
            } else {
                try {
                    new_account_id = yield rpc.add_account ();
                } catch (Error e) {
                    cleanup_signal ();
                    configure_running = false;
                    if (!cancelled) {
                        show_error (this, "Failed to create account: " + e.message);
                        stack.visible_child_name = "input";
                    }
                    return;
                }
                target_account_id = new_account_id;
            }

            if (cancelled) {
                cleanup_signal ();
                configure_running = false;
                return;
            }

            try {
                yield rpc.add_or_update_transport (target_account_id, params);
            } catch (Error e) {
                cleanup_signal ();
                configure_running = false;
                if (cancelled) return;
                if (new_account_id > 0) {
                    int aid = new_account_id;
                    new_account_id = 0;
                    yield cleanup_pending_account (rpc, aid, false);
                }
                /* Keep the dialog open so the entered settings survive a
                   failed attempt (wrong password, typo in a server, …). */
                show_error (this, "Configuration failed: " + e.message);
                stack.visible_child_name = "input";
                return;
            }

            cleanup_signal ();
            configure_running = false;
            if (cancelled) return;
            configure_finished = true;
            if (edit_account_id > 0) {
                transport_updated ();
            } else {
                int created = new_account_id;
                new_account_id = 0;
                account_created (created);
            }
            this.close ();
        }

        private void on_configure_progress (int ctx, int progress,
                                              string? comment) {
            if (ctx != target_account_id) return;
            progress_page.set_permille (progress, comment, "Configuring…");
        }

        private void cleanup_signal () {
            disconnect_progress_handler (events, ref progress_handler_id);
        }

        private void cancel_configure () {
            if (close_if_idle (this, configure_running)) return;
            cancelled = true;
            stop_ongoing_account (rpc, target_account_id);
            this.close ();
        }

        private void on_dialog_closed () {
            cleanup_signal ();
            cleanup_unfinished_account (rpc, ref new_account_id,
                                        configure_finished);
        }
    }
}
