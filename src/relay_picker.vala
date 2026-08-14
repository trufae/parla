namespace Dc {

    /**
     * Curated list of public chatmail relays derived from the human-readable
     * directory at https://chatmail.at/relays. The first entry is always the
     * default. Locations follow the form "City, Country" or a language hint
     * if the operators only document the audience.
     */
    public struct ChatmailRelay {
        public unowned string domain;
        public unowned string location;
    }

    public const ChatmailRelay[] CHATMAIL_RELAYS = {
        { "nine.testrun.org",                "Default" },
        { "mehl.cloud",                      "German" },
        { "mailchat.pl",                     "Poland" },
        { "chatmail.woodpeckersnest.space",  "Italy" },
        { "chatmail.culturanerd.it",         "Italy" },
        { "chat.adminforge.de",              "Falkenstein, Germany" },
        { "chika.aangat.lahat.computer",     "Santa Clara, USA" },
        { "tarpit.fun",                      "Nuremberg, Germany" },
        { "d.gaufr.es",                      "Roubaix, France" },
        { "chtml.ca",                        "Quebec, Canada" },
        { "chatmail.au",                     "Melbourne, Australia" },
        { "e2ee.wang",                       "Johannesburg, South Africa" },
        { "chat.privittytech.com",           "Bangalore, India" },
        { "e2ee.im",                         "Orastie, Romania" },
        { "chatmail.email",                  "Warsaw, Poland" },
        { "danneskjold.de",                  "Helsinki, Finland" },
        { "chat.in-the.eu",                  "Falkenstein, Germany" },
        { "chat.nuvon.app",                  "Prague, Czechia" },
        { "nibblehole.com",                  "Zug, Switzerland" },
        { "chat.zashm.org",                  "Lviv, Ukraine" },
        { "chat.sus.fr",                     "Iceland/Japan/Kenya/South Africa" },
        { "delta.thelab.uno",                "Gravelines, France" },
        { "chat.vim.wtf",                    "Frankfurt, Germany" },
        { "uninterest.ing",                  "Elk Grove Village, USA" },
        { "sweetfern.net",                   "Ashburn, USA" },
        { "delta.disobey.net",               "Roon, Netherlands" }
    };

    /**
     * Builds the canonical chatmail account QR link for a relay domain.
     * The DCACCOUNT scheme expects an HTTPS URL pointing at the relay's
     * /new endpoint.
     */
    public static string build_chatmail_qr (string domain) {
        return "DCACCOUNT:https://%s/new".printf (domain);
    }

    /**
     * Reusable widget that lets the user pick a chatmail relay from the
     * curated list or type a custom server name. Used both during account
     * creation and when adding extra transports to an existing profile.
     */
    public class RelayPicker : Gtk.Box {

        private Gtk.DropDown dropdown;
        private Gtk.StringList model;
        private Gtk.Entry custom_entry;
        private GenericArray<string> domains;
        private RpcClient? rpc = null;
        private Gtk.Button? discover_btn = null;
        private bool discovered = false;

        /* Pass an RpcClient to include the built-in "Discover from Contacts"
           button; omit it for a plain relay list. */
        public RelayPicker (RpcClient? rpc = null) {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 8);
            this.rpc = rpc;

            domains = new GenericArray<string> ();
            model = new Gtk.StringList (null);
            for (int i = 0; i < CHATMAIL_RELAYS.length; i++) {
                model.append ("%s (%s)".printf (
                    CHATMAIL_RELAYS[i].domain,
                    CHATMAIL_RELAYS[i].location));
                domains.add (CHATMAIL_RELAYS[i].domain);
            }
            dropdown = new Gtk.DropDown (model, null);
            dropdown.selected = 0;
            dropdown.hexpand = true;

            custom_entry = new Gtk.Entry ();
            custom_entry.placeholder_text = "Custom server name";
            custom_entry.activates_default = true;
            custom_entry.hexpand = true;
            custom_entry.changed.connect (() => {
                dropdown.sensitive = custom_entry.text.strip ().length == 0;
            });

            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row.append (dropdown);
            row.append (custom_entry);
            this.append (row);

            if (rpc != null) {
                discover_btn = new Gtk.Button.with_label ("Discover from Contacts");
                discover_btn.halign = Gtk.Align.START;
                discover_btn.add_css_class ("flat");
                discover_btn.tooltip_text =
                    "Scan contacts on your other profiles and add the relays they use.";
                discover_btn.clicked.connect (() => { run_discover.begin (); });
                this.append (discover_btn);
            }
        }

        /* Drives the built-in Discover button: scans once, then reports the
           outcome in the button label and leaves it disabled. */
        private async void run_discover () {
            if (rpc == null || discovered) return;
            discover_btn.sensitive = false;
            string original = discover_btn.label;
            discover_btn.label = "Scanning…";

            int added = 0;
            try {
                added = yield discover_from_contacts (rpc);
            } catch (Error e) {
                discover_btn.label = original;
                discover_btn.sensitive = true;
                show_error (this, "Failed to scan contacts: " + e.message);
                return;
            }

            discovered = true;
            discover_btn.label = added > 0
                ? "Found %d new".printf (added)
                : "No new relays";
        }

        public string get_selected_domain () {
            string custom = custom_entry.text.strip ();
            if (custom.length > 0) return custom;

            int idx = (int) dropdown.selected;
            if (idx < 0 || idx >= (int) domains.length) idx = 0;
            return domains[idx];
        }

        public string get_chatmail_qr () {
            return build_chatmail_qr (get_selected_domain ());
        }

        /**
         * Append a domain entry to the dropdown if it isn't already present.
         * `note` is shown in parentheses after the domain.
         * Returns true when a new entry was added.
         */
        public bool add_domain (string domain, string note) {
            if (domain.length == 0) return false;
            for (int i = 0; i < (int) domains.length; i++) {
                if (domains[i] == domain) return false;
            }
            model.append ("%s (%s)".printf (domain, note));
            domains.add (domain);
            return true;
        }

        /**
         * Scan known contacts across every configured account (purely local,
         * no network round-trips), pull the domain out of each address, and
         * append the unique ones to the dropdown. Returns how many new
         * domains were added.
         */
        public async int discover_from_contacts (RpcClient rpc) throws Error {
            var counts = new HashTable<string, int> (str_hash, str_equal);

            var accounts_node = yield rpc.get_all_accounts ();
            if (accounts_node != null
                && accounts_node.get_node_type () == Json.NodeType.ARRAY) {
                var accounts = accounts_node.get_array ();
                for (uint a = 0; a < accounts.get_length (); a++) {
                    var acct = accounts.get_object_element (a);
                    if (acct == null) continue;
                    int aid = (int) acct.get_int_member ("id");
                    if (aid <= 0) continue;
                    yield collect_contact_domains (rpc, aid, counts);
                }
            }

            int added = 0;
            counts.foreach ((domain, count) => {
                string note = count == 1
                    ? "1 contact"
                    : "%d contacts".printf (count);
                if (add_domain (domain, note)) added++;
            });
            return added;
        }

        private async void collect_contact_domains (RpcClient rpc, int aid,
                                                    HashTable<string, int> counts) throws Error {
            var ids = yield rpc.get_contact_ids_for (aid, null);
            if (ids == null) return;
            for (uint i = 0; i < ids.get_length (); i++) {
                int cid = (int) ids.get_int_element (i);
                if (cid <= 1) continue; /* skip self / special ids */
                var obj = yield rpc.get_contact_for (aid, cid);
                if (obj == null) continue;
                string addr = json_str (obj, "address") ?? "";
                int at = addr.index_of_char ('@');
                if (at <= 0 || at >= addr.length - 1) continue;
                string domain = addr.substring (at + 1).down ().strip ();
                if (domain.length == 0) continue;
                int prev = counts.lookup (domain);
                counts.insert (domain, prev + 1);
            }
        }

    }

    /**
     * Lists all transports configured for an account and lets the user
     * remove existing ones (with a confirmation prompt) or add a new one
     * by picking a relay from the curated list.
     */
    public class RelaysDialog : Adw.Dialog {

        private RpcClient rpc;
        private EventHandler events;
        private int account_id;
        private Gtk.ListBox list_box;
        private Gtk.Stack list_stack;
        private Gtk.Label empty_label;
        private RelayPicker picker;
        private Gtk.Button add_btn;
        private bool busy = false;

        public RelaysDialog (RpcClient rpc, EventHandler events, int acct_id) {
            this.rpc = rpc;
            this.events = events;
            this.account_id = acct_id;
            this.title = "Relays";
            this.content_width = 480;
            this.content_height = 520;
            this.can_close = true;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.append (new Adw.HeaderBar ());

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = 18;
            content.margin_end = 18;
            content.margin_top = 12;
            content.margin_bottom = 18;
            content.vexpand = true;

            var intro = new Gtk.Label (
                "Transports configured for this profile. " +
                "Add more relays to receive messages on additional addresses.");
            intro.wrap = true;
            intro.xalign = 0;
            intro.add_css_class ("dim-label");
            content.append (intro);

            list_box = new Gtk.ListBox ();
            list_box.selection_mode = Gtk.SelectionMode.NONE;
            list_box.add_css_class ("boxed-list");

            empty_label = new Gtk.Label ("No transports configured.");
            empty_label.add_css_class ("dim-label");
            empty_label.margin_top = 24;
            empty_label.margin_bottom = 24;

            list_stack = new Gtk.Stack ();
            list_stack.add_named (list_box, "list");
            list_stack.add_named (empty_label, "empty");

            var scroll = new Gtk.ScrolledWindow ();
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = list_stack;
            content.append (scroll);

            var add_label = new Gtk.Label ("Add Relay");
            add_label.add_css_class ("heading");
            add_label.xalign = 0;
            content.append (add_label);

            picker = new RelayPicker (rpc);
            content.append (picker);

            var add_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            add_row.halign = Gtk.Align.END;
            add_btn = new Gtk.Button.with_label ("Add Relay");
            add_btn.add_css_class ("suggested-action");
            add_btn.clicked.connect (() => { do_add_relay.begin (); });
            add_row.append (add_btn);
            content.append (add_row);

            box.append (content);
            this.child = box;

            install_escape_close (this);
            refresh_list.begin ();
        }

        private async void refresh_list () {
            clear_listbox (list_box);

            Json.Node? result = null;
            try {
                result = yield rpc.list_transports (account_id);
            } catch (Error e) {
                show_error (this, "Failed to load transports: " + e.message);
                list_stack.visible_child_name = "empty";
                return;
            }

            if (result == null || result.get_node_type () != Json.NodeType.ARRAY) {
                list_stack.visible_child_name = "empty";
                return;
            }

            var arr = result.get_array ();
            if (arr.get_length () == 0) {
                list_stack.visible_child_name = "empty";
                return;
            }

            for (uint i = 0; i < arr.get_length (); i++) {
                var node = arr.get_element (i);
                if (node == null || node.get_node_type () != Json.NodeType.OBJECT)
                    continue;
                var obj = node.get_object ();
                string addr = json_str (obj, "addr") ?? "";
                if (addr.length == 0) continue;
                list_box.append (build_relay_row (addr,
                    EnteredLoginParams.from_json (obj)));
            }
            list_stack.visible_child_name = "list";
        }

        private Gtk.Widget build_relay_row (string addr,
                                            EnteredLoginParams params) {
            var row = new Adw.ActionRow ();
            row.title = addr;

            var edit_btn = new Gtk.Button.from_icon_name (
                "document-edit-symbolic");
            edit_btn.add_css_class ("flat");
            edit_btn.valign = Gtk.Align.CENTER;
            edit_btn.tooltip_text = "Edit password and server settings";
            edit_btn.clicked.connect (() => {
                show_edit_transport_dialog (params);
            });
            row.add_suffix (edit_btn);

            var trash_btn = new Gtk.Button.from_icon_name ("user-trash-symbolic");
            trash_btn.add_css_class ("flat");
            trash_btn.valign = Gtk.Align.CENTER;
            trash_btn.tooltip_text = "Remove this relay";
            trash_btn.clicked.connect (() => {
                confirm_delete_relay.begin (addr);
            });
            row.add_suffix (trash_btn);

            return row;
        }

        private void show_edit_transport_dialog (EnteredLoginParams params) {
            var dialog = new ClassicEmailDialog.for_edit (rpc, events,
                account_id, params);
            dialog.transport_updated.connect (() => {
                refresh_list.begin ();
            });
            dialog.present (this);
        }

        private async void confirm_delete_relay (string addr) {
            if (yield confirm_action (this, "Remove Relay",
                "Remove transport \"%s\"? The profile will no longer receive messages on this address.".printf (addr),
                "remove", "Remove"))
                do_delete_relay.begin (addr);
        }

        private async void do_delete_relay (string addr) {
            if (busy) return;
            busy = true;
            try {
                yield rpc.delete_transport (account_id, addr);
            } catch (Error e) {
                show_error (this, "Failed to remove relay: " + e.message);
                busy = false;
                return;
            }
            busy = false;
            yield refresh_list ();
        }

        private async void do_add_relay () {
            if (busy) return;
            busy = true;
            add_btn.sensitive = false;
            string qr = picker.get_chatmail_qr ();
            try {
                yield rpc.add_transport_from_qr (account_id, qr);
            } catch (Error e) {
                show_error (this, "Failed to add relay: " + e.message);
                add_btn.sensitive = true;
                busy = false;
                return;
            }
            add_btn.sensitive = true;
            busy = false;
            yield refresh_list ();
        }

    }
}
