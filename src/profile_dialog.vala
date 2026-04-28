namespace Dc {

    public class ProfileDialog : Adw.Dialog {

        private RpcClient rpc;
        private int account_id;
        private Adw.Avatar avatar_widget;
        private Gtk.Entry name_entry;
        private Gtk.Entry status_entry;
        private Gtk.Label email_label;
        private string? avatar_path = null;
        private bool avatar_changed = false;

        public signal void profile_updated ();
        public signal void account_deleted (int acct_id);

        public ProfileDialog (RpcClient rpc, int acct_id = 0) {
            this.rpc = rpc;
            this.account_id = acct_id > 0 ? acct_id : rpc.account_id;
            this.title = "My Profile";
            this.content_width = 360;
            this.content_height = 420;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            var save_btn = new Gtk.Button.with_label ("Save");
            save_btn.add_css_class ("suggested-action");
            save_btn.clicked.connect (() => {
                do_save.begin ();
            });
            header.pack_end (save_btn);
            box.append (header);

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = 16;
            content.margin_end = 16;
            content.margin_top = 12;
            content.margin_bottom = 16;

            /* Avatar */
            avatar_widget = new Adw.Avatar (96, "", true);
            avatar_widget.halign = Gtk.Align.CENTER;
            content.append (avatar_widget);

            var avatar_btn = new Gtk.Button.with_label ("Change Avatar");
            avatar_btn.halign = Gtk.Align.CENTER;
            avatar_btn.add_css_class ("flat");
            avatar_btn.clicked.connect (() => {
                pick_avatar.begin ();
            });
            content.append (avatar_btn);

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            /* Display name */
            var name_lbl = new Gtk.Label ("Display Name");
            name_lbl.add_css_class ("heading");
            name_lbl.halign = Gtk.Align.START;
            content.append (name_lbl);

            name_entry = new Gtk.Entry ();
            name_entry.placeholder_text = "Your name";
            name_entry.changed.connect (() => {
                avatar_widget.text = name_entry.text.length > 0
                    ? name_entry.text : "";
            });
            content.append (name_entry);

            /* Status */
            var status_lbl = new Gtk.Label ("Status");
            status_lbl.add_css_class ("heading");
            status_lbl.halign = Gtk.Align.START;
            content.append (status_lbl);

            status_entry = new Gtk.Entry ();
            status_entry.placeholder_text = "Your status message";
            content.append (status_entry);

            /* Email (read-only) */
            var email_lbl = new Gtk.Label ("Email");
            email_lbl.add_css_class ("heading");
            email_lbl.halign = Gtk.Align.START;
            content.append (email_lbl);

            email_label = new Gtk.Label ("");
            email_label.halign = Gtk.Align.START;
            email_label.add_css_class ("dim-label");
            email_label.selectable = true;
            content.append (email_label);

            content.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var second_device_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            second_device_box.margin_top = 4;

            var second_device_btn = new Gtk.Button.with_label ("Add Second Device");
            second_device_btn.tooltip_text = "Show a setup QR code for another device";
            second_device_btn.clicked.connect (show_second_device_dialog);
            second_device_box.append (second_device_btn);

            var second_device_label = new Gtk.Label ("Transfer to another device");
            second_device_label.add_css_class ("dim-label");
            second_device_label.valign = Gtk.Align.CENTER;
            second_device_label.wrap = true;
            second_device_label.xalign = 0;
            second_device_label.hexpand = true;
            second_device_box.append (second_device_label);

            content.append (second_device_box);

            var delete_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            delete_box.margin_top = 4;

            var delete_btn = new Gtk.Button.with_label ("Delete Profile");
            delete_btn.add_css_class ("destructive-action");
            delete_btn.tooltip_text = "Delete local profile data";
            delete_btn.clicked.connect (confirm_delete_account);
            delete_box.append (delete_btn);

            var delete_label = new Gtk.Label ("Delete local profile data");
            delete_label.add_css_class ("dim-label");
            delete_label.valign = Gtk.Align.CENTER;
            delete_label.wrap = true;
            delete_label.xalign = 0;
            delete_label.hexpand = true;
            delete_box.append (delete_label);

            content.append (delete_box);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = content;
            box.append (scroll);

            this.child = box;

            load_profile.begin ();
        }

        private async void load_profile () {
            try {
                string? name = yield rpc.get_config ("displayname", account_id);
                string? status = yield rpc.get_config ("selfstatus", account_id);
                string? email = yield rpc.get_config ("addr", account_id);
                string? avatar = yield rpc.get_config ("selfavatar", account_id);

                if (name != null) {
                    name_entry.text = name;
                    avatar_widget.text = name;
                }
                if (status != null) status_entry.text = status;
                if (email != null) email_label.label = email;
                if (avatar != null && avatar.length > 0 &&
                    FileUtils.test (avatar, FileTest.EXISTS)) {
                    avatar_path = avatar;
                }
                avatar_widget.custom_image = load_avatar (avatar);
            } catch (Error e) {
                /* ignore */
            }
        }

        private async void do_save () {
            try {
                yield rpc.batch_set_config ("displayname", name_entry.text.strip (), account_id);
                yield rpc.batch_set_config ("selfstatus", status_entry.text.strip (), account_id);
                if (avatar_changed && avatar_path != null) {
                    yield rpc.batch_set_config ("selfavatar", avatar_path, account_id);
                }
                profile_updated ();
                this.close ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private void show_second_device_dialog () {
            var dialog = new SecondDeviceDialog (rpc, account_id);
            dialog.present (this);
        }

        private void confirm_delete_account () {
            string label = email_label.label.strip ();
            if (label.length == 0) {
                label = name_entry.text.strip ();
            }
            if (label.length == 0) {
                label = "this account";
            }

            confirm_action (this, "Delete Account",
                "Delete \"%s\"? This will remove all local data for this account.".printf (label),
                "delete", "Delete", () => { do_delete_account.begin (); });
        }

        private async void do_delete_account () {
            try {
                yield rpc.remove_account (account_id);
                if (rpc.account_id == account_id) {
                    rpc.account_id = 0;
                }
                account_deleted (account_id);
                this.close ();
            } catch (Error e) {
                show_error (this, e.message);
            }
        }

        private async void pick_avatar () {
            string? path = yield pick_image_file (
                (Gtk.Window) this.get_root (), "Select Avatar");
            if (path != null) {
                avatar_path = path;
                avatar_changed = true;
                avatar_widget.custom_image = load_avatar (path);
            }
        }
    }

    public class SecondDeviceDialog : Adw.Dialog {

        private RpcClient rpc;
        private int account_id;
        private Gtk.Label status_label;
        private Gtk.Picture qr_picture;
        private Gtk.TextView qr_text_view;
        private Gtk.ScrolledWindow qr_text_scroll;
        private Gtk.Button copy_btn;
        private string? qr_text = null;
        private bool closing = false;
        private bool provider_running = false;

        public SecondDeviceDialog (RpcClient rpc, int acct_id) {
            this.rpc = rpc;
            this.account_id = acct_id;
            this.title = "Add Second Device";
            this.content_width = 480;
            this.content_height = 560;
            this.can_close = true;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = 18;
            content.margin_end = 18;
            content.margin_top = 12;
            content.margin_bottom = 18;

            status_label = new Gtk.Label ("Preparing account…");
            status_label.wrap = true;
            status_label.xalign = 0;
            content.append (status_label);

            qr_picture = new Gtk.Picture ();
            qr_picture.content_fit = Gtk.ContentFit.CONTAIN;
            qr_picture.can_shrink = true;
            qr_picture.halign = Gtk.Align.CENTER;
            qr_picture.set_size_request (280, 280);
            qr_picture.visible = false;
            content.append (qr_picture);

            qr_text_view = new Gtk.TextView ();
            qr_text_view.editable = false;
            qr_text_view.cursor_visible = false;
            qr_text_view.monospace = true;
            qr_text_view.wrap_mode = Gtk.WrapMode.CHAR;

            qr_text_scroll = new Gtk.ScrolledWindow ();
            qr_text_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            qr_text_scroll.min_content_height = 96;
            qr_text_scroll.child = qr_text_view;
            qr_text_scroll.visible = false;
            content.append (qr_text_scroll);

            var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            actions.halign = Gtk.Align.END;
            actions.margin_top = 6;

            copy_btn = new Gtk.Button.with_label ("Copy Text");
            copy_btn.sensitive = false;
            copy_btn.clicked.connect (copy_qr_text);
            actions.append (copy_btn);

            var close_btn = new Gtk.Button.with_label ("Close");
            close_btn.clicked.connect (() => { this.close (); });
            actions.append (close_btn);
            content.append (actions);

            box.append (content);
            this.child = box;

            install_escape_close (this);
            this.closed.connect (on_closed);
            start_transfer.begin ();
        }

        private async void start_transfer () {
            provider_running = true;
            rpc.provide_backup.begin (account_id, (obj, res) => {
                provider_running = false;
                try {
                    rpc.provide_backup.end (res);
                    if (!closing) this.close ();
                } catch (Error e) {
                    if (!closing) show_transfer_error (e.message);
                }
            });

            try {
                string text = yield rpc.get_backup_qr (account_id);
                string svg = yield rpc.create_qr_svg (text);
                if (!closing) show_qr (text, svg);
            } catch (Error e) {
                if (!closing) {
                    show_transfer_error (e.message);
                    stop_provider ();
                }
            }
        }

        private void show_qr (string text, string svg) {
            qr_text = text;
            status_label.label = "Scan this QR code with the second device, or copy the text below.";
            qr_text_view.buffer.text = text;
            qr_text_scroll.visible = true;
            copy_btn.sensitive = true;

            try {
                var bytes = new Bytes (svg.data);
                qr_picture.paintable = Gdk.Texture.from_bytes (bytes);
                qr_picture.visible = true;
            } catch (Error e) {
                status_label.label = "QR text is ready, but the image could not be rendered: " + e.message;
            }
        }

        private void show_transfer_error (string message) {
            status_label.label = "Second-device setup failed: " + message;
            copy_btn.sensitive = false;
        }

        private void copy_qr_text () {
            if (qr_text == null || qr_text.length == 0) return;
            this.get_display ().get_clipboard ().set_text (qr_text);
        }

        private void on_closed () {
            closing = true;
            stop_provider ();
        }

        private void stop_provider () {
            if (provider_running) {
                rpc.stop_ongoing_process.begin (account_id, (obj, res) => {
                    try { rpc.stop_ongoing_process.end (res); }
                    catch (Error e) { /* ignore */ }
                });
            }
        }
    }
}
