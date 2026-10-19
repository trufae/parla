namespace Dc {
    public enum BackupAction { CREATE, VERIFY, RESTORE }

    public class BackupDialog : Adw.Dialog {
        private unowned Window window;
        private BackupAction action;
        private SafeStore.Backups backups = new SafeStore.Backups ();
        private Cancellable cancel = new Cancellable ();
        private Adw.PasswordEntryRow password;
        private Adw.PasswordEntryRow confirmation;
        private Gtk.Button choose;
        private Gtk.Button run;
        private Gtk.Button cancel_button;
        private Gtk.Button use_restored;
        private Gtk.Label status;
        private Gtk.ProgressBar progress;
        private string? archive_path;
        private string? restored_path;
        private bool running;
        private bool window_held;

        public BackupDialog (Window window, BackupAction action) {
            this.window = window;
            this.action = action;
            title = action == BackupAction.CREATE ? _("Create Encrypted Backup") :
                action == BackupAction.VERIFY ? _("Check Encrypted Backup") : _("Restore Encrypted Backup");
            content_width = 540;
            var toolbar = new Adw.ToolbarView ();
            toolbar.add_top_bar (new Adw.HeaderBar ());
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
            box.margin_start = box.margin_end = 24;
            box.margin_top = 12; box.margin_bottom = 24;
            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 650;
            scroll.child = box;
            toolbar.content = scroll;
            child = toolbar;
            var explanation = new Gtk.Label (action == BackupAction.CREATE
                ? _("Save all accounts, messages, and attachments in a password-protected ZIP. Messaging pauses while the backup is made. Use a long, unique password and keep it somewhere safe: it cannot be recovered.")
                : action == BackupAction.VERIFY
                ? _("Check the password and every file in a Parla backup without changing your accounts.")
                : _("Restore a Parla backup into a new folder. Your current accounts stay in place. The restored folder contains readable account data; choose a private location on your computer."));
            explanation.wrap = true; explanation.xalign = 0;
            box.append (explanation);
            choose = new Gtk.Button.with_label (action == BackupAction.CREATE ? _("Choose Where to Save…") : _("Choose Backup…"));
            choose.clicked.connect (() => { choose_archive.begin (); });
            box.append (choose);
            var group = new Adw.PreferencesGroup ();
            password = new Adw.PasswordEntryRow (); password.title = _("Backup password");
            confirmation = new Adw.PasswordEntryRow (); confirmation.title = _("Repeat password");
            group.add (password);
            if (action == BackupAction.CREATE) group.add (confirmation);
            box.append (group);
            status = new Gtk.Label (""); status.wrap = true; status.xalign = 0; status.selectable = true;
            status.set_size_request (-1, 60);
            box.append (status);
            progress = new Gtk.ProgressBar (); progress.visible = false;
            box.append (progress);
            run = new Gtk.Button.with_label (action == BackupAction.CREATE ? _("Create Backup") : action == BackupAction.VERIFY ? _("Check Backup") : _("Restore to New Folder…"));
            run.add_css_class ("suggested-action");
            run.clicked.connect (() => { execute.begin (); }); box.append (run);
            use_restored = new Gtk.Button.with_label (_("Use Restored Accounts"));
            use_restored.visible = false;
            use_restored.clicked.connect (() => { activate_restored.begin (); }); box.append (use_restored);
            cancel_button = new Gtk.Button.with_label (_("Close"));
            cancel_button.clicked.connect (() => { if (running) cancel.cancel (); else close (); });
            box.append (cancel_button);
            backups.progress.connect ((phase, completed, total) => {
                if (!running) return;
                status.label = phase == "scan" ? _("Reading account files…") : phase == "encrypt" ? _("Encrypting backup…") : phase == "restore" ? _("Restoring files…") : _("Checking every backup file…");
                if (total > 0) progress.fraction = (double) completed / total;
                else progress.pulse ();
            });
        }

        private async void choose_archive () {
            var picker = new Gtk.FileDialog ();
            picker.title = action == BackupAction.CREATE ? _("Save Encrypted Backup") : _("Open Encrypted Backup");
            var filter = new Gtk.FileFilter (); filter.name = _("ZIP backups"); filter.add_pattern ("*.zip");
            var filters = new GLib.ListStore (typeof (Gtk.FileFilter)); filters.append (filter);
            picker.filters = filters; picker.default_filter = filter;
            if (action == BackupAction.CREATE) picker.initial_name = "parla-backup-" + new DateTime.now_local ().format ("%Y%m%d-%H%M%S") + ".zip";
            try {
                File file;
                if (action == BackupAction.CREATE) file = yield picker.save (window, null);
                else file = yield picker.open (window, null);
                archive_path = file.get_path ();
                if (archive_path == null) throw new IOError.NOT_SUPPORTED (_("Choose a local file or a connected USB drive"));
                choose.label = Path.get_basename (archive_path);
                choose.tooltip_text = archive_path;
                status.label = archive_path;
            } catch (Error e) { if (!is_dialog_dismissal (e)) status.label = e.message; }
        }

        private void set_running (bool active) {
            running = active; can_close = !active;
            run.sensitive = !active; choose.sensitive = !active;
            password.sensitive = !active; confirmation.sensitive = !active;
            use_restored.sensitive = !active;
            cancel_button.label = active ? _("Cancel") : _("Close");
            progress.visible = active;
            if (active) { cancel = new Cancellable (); progress.fraction = 0; }
        }

        private async void execute () {
            if (running) return;
            if (archive_path == null) { status.label = _("Choose a backup file first"); return; }
            if (password.text.length == 0) { status.label = _("Enter the backup password"); return; }
            if (action == BackupAction.CREATE && password.text != confirmation.text) { status.label = _("The passwords do not match"); return; }
            string? destination = null;
            if (action == BackupAction.RESTORE) {
                try {
                    var picker = new Gtk.FileDialog (); picker.title = _("Choose Where to Create the Restored Folder");
                    var parent = yield picker.select_folder (window, null);
                    string? path = parent.get_path ();
                    if (path == null) throw new IOError.NOT_SUPPORTED (_("Choose a local folder"));
                    destination = Path.build_filename (path, "parla-restored-" + new DateTime.now_local ().format ("%Y%m%d-%H%M%S") + "-" + Uuid.string_random ().substring (0, 8));
                    yield backups.validate_restore_destination (window.settings.effective_accounts_path (), destination);
                } catch (Error e) { if (!is_dialog_dismissal (e)) status.label = e.message; return; }
            }
            var secret = new SafeStore.SecretValue (password.text);
            password.text = ""; confirmation.text = "";
            set_running (true);
            use_restored.visible = false;
            status.label = _("Preparing account storage…");
            try {
                SafeStore.BackupInfo info;
                if (action == BackupAction.CREATE) info = yield window.create_account_backup (backups, archive_path, secret, cancel);
                else {
                    window.hold_backup_task (); window_held = true;
                    if (action == BackupAction.VERIFY) info = yield backups.verify (archive_path, secret, cancel);
                    else info = yield backups.restore (archive_path, destination, secret, cancel);
                }
                string detail = _("%u files · %s · Created %s").printf (info.files, format_size (info.bytes), info.created_at);
                if (action == BackupAction.CREATE) {
                    status.label = _("Backup saved and verified. Safely eject your USB drive before unplugging it.") + "\n" + archive_path + "\n" + detail;
                } else if (action == BackupAction.VERIFY) {
                    status.label = _("Password and all backup files verified. Your current accounts were not changed.") + "\n" + detail;
                } else {
                    restored_path = info.restored_path;
                    AccountBackup.validate_layout (restored_path);
                    use_restored.visible = true;
                    status.label = _("Files restored and verified. Use the button below to check them with Chatmail Core and switch to this copy. Your previous accounts folder will be kept.") + "\n" + restored_path + "\n" + detail;
                }
            } catch (Error e) {
                status.label = (e is IOError.CANCELLED) ? _("Operation cancelled. Your current accounts were not changed.") : e.message;
                if (restored_path != null) status.label += "\n" + _("Restored files were kept at:") + "\n" + restored_path;
            } finally {
                secret.clear ();
                if (window_held) { window.release_backup_task (); window_held = false; }
                set_running (false);
            }
        }

        private async void activate_restored () {
            if (restored_path == null || running) return;
            set_running (true); cancel_button.sensitive = false;
            status.label = _("Checking restored accounts with Chatmail Core…");
            string previous_path = window.settings.effective_accounts_path ();
            try {
                yield window.use_restored_accounts (restored_path);
                status.label = _("Parla is now using the restored accounts. Your previous folder has been kept. To return to it, select it in Settings → Advanced → Profile Storage Folder.") + "\n" + previous_path;
                use_restored.visible = false;
            } catch (Error e) { status.label = e.message + "\n" + restored_path; }
            finally { set_running (false); cancel_button.sensitive = true; }
        }
    }
}
