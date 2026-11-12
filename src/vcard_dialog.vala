namespace Dc {

    public class VcardDialog : Adw.Dialog {
        private Window window;
        private RpcClient rpc;
        private int account_id;
        private VcardDocument document;
        private Gtk.Button import_button;
        private Gtk.Box cards;
        private bool closed_dialog = false;

        public VcardDialog (Window window, RpcClient rpc, int account_id,
                            VcardDocument document) {
            this.window = window;
            this.rpc = rpc;
            this.account_id = account_id;
            this.document = document;
            title = _("Contact Card");
            content_width = 420;
            content_height = 400;
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());
            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            cards = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
            cards.margin_start = cards.margin_end = 18;
            cards.margin_top = cards.margin_bottom = 18;
            for (uint i = 0; i < document.contacts.length; i++)
                cards.append (new VcardPreview (document.contacts[i]));
            scroll.child = cards;
            box.append (scroll);
            var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            actions.halign = Gtk.Align.CENTER;
            actions.margin_start = actions.margin_end = 12;
            actions.margin_top = actions.margin_bottom = 12;
            var save = new Gtk.Button.with_label (_("Save As…"));
            save.clicked.connect (() => save_file.begin ());
            actions.append (save);
            var share = new Gtk.Button.with_label (_("Share…"));
            share.clicked.connect (share_file);
            actions.append (share);
            import_button = new Gtk.Button.with_label (document.contacts.length == 1
                ? _("Start Chat") : _("Import Contacts"));
            // A standard vCard need not have an email address. Only importing
            // a chat contact requires one; viewing, saving and sharing do not.
            import_button.visible = document.has_email_contacts;
            import_button.add_css_class ("suggested-action");
            import_button.clicked.connect (() => import_contacts.begin ());
            actions.append (import_button);
            box.append (actions);
            child = box;
            install_escape_close (this);
            closed.connect (() => { closed_dialog = true; });
        }

        public static async void open_file (Window window, RpcClient rpc,
                                            int account_id, File file) {
            try {
                var doc = yield VcardDocument.load (rpc, file);
                if (rpc.account_id != account_id) return;
                new VcardDialog (window, rpc, account_id, doc).present (window);
            } catch (Error e) {
                window.show_toast (_("Could not open contact file: ") + e.message);
            }
        }

        public static async void show_contact (Window window, RpcClient rpc,
                                               int account_id, int contact_id) {
            try {
                var text = yield rpc.make_vcard (account_id, { contact_id });
                var doc = yield VcardDocument.from_contents (rpc, text);
                if (rpc.account_id != account_id) return;
                new VcardDialog (window, rpc, account_id, doc).present (window);
            } catch (Error e) {
                window.show_toast (_("Could not share contact: ") + e.message);
            }
        }

        private async void import_contacts () {
            if (!document.has_email_contacts) return;
            import_button.sensitive = false;
            try {
                var ids = yield rpc.import_vcard_contents (account_id, document.contents);
                if (closed_dialog) return;
                if (ids == null || ids.get_length () == 0)
                    throw new IOError.INVALID_DATA (_("No contacts could be imported."));
                if (document.contacts.length == 1) {
                    yield open_contact ((int) ids.get_int_element (0));
                    return;
                }
                import_button.label = _("Imported");
                for (uint i = 0; i < ids.get_length (); i++) {
                    int id = (int) ids.get_int_element (i);
                    var obj = yield rpc.get_contact_for (account_id, id);
                    if (closed_dialog) return;
                    if (obj == null) continue;
                    var contact = RpcParsers.parse_contact (id, obj);
                    var button = new Gtk.Button.with_label (_("Chat with %s").printf (
                        contact.display_name.length > 0 ? contact.display_name : contact.address));
                    button.clicked.connect (() => open_contact.begin (id));
                    cards.append (button);
                }
            } catch (Error e) {
                if (!closed_dialog) {
                    import_button.sensitive = true;
                    show_error (this, _("Could not import contacts: ") + e.message);
                }
            }
        }

        private async void open_contact (int id) {
            try {
                int chat_id = yield rpc.get_or_create_chat_by_contact_for (account_id, id);
                if (closed_dialog) return;
                close ();
                yield window.open_chat_from_notification (account_id, chat_id);
            } catch (Error e) {
                if (!closed_dialog) {
                    import_button.sensitive = true;
                    show_error (this, _("Could not start chat: ") + e.message);
                }
            }
        }

        private async void save_file () {
            var dialog = new Gtk.FileDialog ();
            dialog.title = _("Save Contact Card");
            dialog.initial_name = document.filename;
            try {
                var file = yield dialog.save (window, null);
                yield file.replace_contents_async (document.contents.data, null, false,
                    FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
                if (!is_dialog_dismissal (e) && !closed_dialog) show_error (this, e.message);
            }
        }

        private void share_file () {
            var picker = new ContactPickerDialog (rpc, window.chat_store, _("Share Contact To"), true);
            picker.chat_picked.connect ((chat_id) => {
                send_file.begin (picker.selected_account_id, chat_id, 0, "");
            });
            picker.contact_picked.connect ((id, email) => {
                send_file.begin (picker.selected_account_id, 0, id, email);
            });
            picker.present (this);
        }

        private async void send_file (int destination_account, int chat_id, int contact_id, string email) {
            string? path = null;
            try {
                if (chat_id <= 0) {
                    int id = contact_id > 0 ? contact_id
                        : yield rpc.get_or_create_contact_for (destination_account, email);
                    chat_id = yield rpc.get_or_create_chat_by_contact_for (destination_account, id);
                }
                path = document.write_temp ();
                yield rpc.send_msg_for (destination_account, chat_id, "", path, document.filename, 0, "Vcard");
                window.request_reload_chats ();
                if (rpc.account_id == destination_account) window.request_chat_messages_reload (chat_id);
                window.show_toast (_("Contact shared"));
            } catch (Error e) {
                window.show_toast (_("Could not share contact: ") + e.message);
            } finally {
                if (path != null) FileUtils.unlink (path);
            }
        }
    }
}
