namespace Dc {

    public class ProfileDialog : Adw.Dialog {

        private RpcClient rpc;
        private int acct_id;
        private Adw.Avatar avatar_widget;
        private Gtk.Entry name_entry;
        private Gtk.Entry status_entry;
        private Gtk.Label email_label;
        private string? avatar_path = null;
        private bool avatar_changed = false;

        public signal void profile_updated ();

        public ProfileDialog (RpcClient rpc, int acct_id) {
            this.rpc = rpc;
            this.acct_id = acct_id;
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
                string? name = yield rpc.get_config (acct_id, "displayname");
                string? status = yield rpc.get_config (acct_id, "selfstatus");
                string? email = yield rpc.get_config (acct_id, "addr");
                string? avatar = yield rpc.get_config (acct_id, "selfavatar");

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
                yield rpc.batch_set_config (acct_id,
                    "displayname", name_entry.text.strip ());
                yield rpc.batch_set_config (acct_id,
                    "selfstatus", status_entry.text.strip ());
                if (avatar_changed && avatar_path != null) {
                    yield rpc.batch_set_config (acct_id,
                        "selfavatar", avatar_path);
                }
                profile_updated ();
                this.close ();
            } catch (Error e) {
                var err = new Adw.AlertDialog ("Error", e.message);
                err.add_response ("ok", "OK");
                err.present (this);
            }
        }

        private async void pick_avatar () {
            var chooser = new Gtk.FileDialog ();
            chooser.title = "Select Avatar";

            var filter = new Gtk.FileFilter ();
            filter.add_mime_type ("image/*");
            filter.name = "Images";
            var filters = new ListStore (typeof (Gtk.FileFilter));
            filters.append (filter);
            chooser.filters = filters;

            try {
                var file = yield chooser.open ((Gtk.Window) this.get_root (), null);
                if (file != null) {
                    avatar_path = file.get_path ();
                    avatar_changed = true;
                    avatar_widget.custom_image = load_avatar (avatar_path);
                }
            } catch (Error e) {
                /* cancelled */
            }
        }
    }
}
