namespace Dc {

    /**
     * Dialog to manage local sticker packs: a pack selector with a [+]
     * button to create packs, the pack's stickers with their associated
     * emoji, and a destructive button to delete the whole pack. Stickers
     * are added from the message context menu ("Add Sticker…").
     */
    public class StickerManagerDialog : Adw.Dialog {

        private const int THUMB_SIZE = 96;

        private unowned Window app_window;
        private Gtk.DropDown pack_dropdown;
        private Gtk.FlowBox sticker_grid;
        private Gtk.Label placeholder;
        private Gtk.Button rename_pack_btn;
        private Gtk.Button delete_pack_btn;
        private string[] packs = {};
        private bool syncing_packs = false;

        public StickerManagerDialog (Window window) {
            this.app_window = window;
            this.title = "Stickers";
            this.content_width = 420;
            this.content_height = 520;

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var header = new Adw.HeaderBar ();
            header.show_end_title_buttons = true;
            box.append (header);

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content.margin_start = 16;
            content.margin_end = 16;
            content.margin_top = 12;
            content.margin_bottom = 16;

            /* [+] to create a pack, the pack selector, [-] to delete it */
            var pack_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            var add_pack_btn = new Gtk.Button.from_icon_name (
                "list-add-symbolic");
            add_pack_btn.tooltip_text = "Create a new sticker pack";
            add_pack_btn.clicked.connect (() => {
                prompt_new_pack.begin (this, (obj, res) => {
                    var pack = prompt_new_pack.end (res);
                    if (pack != null) add_session_pack (pack);
                });
            });
            pack_row.append (add_pack_btn);

            pack_dropdown = new Gtk.DropDown.from_strings ({});
            pack_dropdown.hexpand = true;
            pack_dropdown.notify["selected"].connect (() => {
                if (!syncing_packs) reload_stickers ();
            });
            pack_row.append (pack_dropdown);

            rename_pack_btn = new Gtk.Button.from_icon_name (
                "document-edit-symbolic");
            rename_pack_btn.tooltip_text = "Rename the selected pack";
            rename_pack_btn.clicked.connect (on_rename_pack);
            pack_row.append (rename_pack_btn);

            delete_pack_btn = new Gtk.Button.from_icon_name (
                "list-remove-symbolic");
            delete_pack_btn.tooltip_text =
                "Delete the selected pack and all of its stickers";
            delete_pack_btn.clicked.connect (() => { on_delete_pack.begin (); });
            pack_row.append (delete_pack_btn);
            content.append (pack_row);

            /* Sticker list */
            placeholder = new Gtk.Label ("");
            placeholder.add_css_class ("dim-label");
            placeholder.wrap = true;
            placeholder.justify = Gtk.Justification.CENTER;
            placeholder.margin_top = 24;
            placeholder.margin_bottom = 24;
            placeholder.margin_start = 12;
            placeholder.margin_end = 12;

            sticker_grid = new Gtk.FlowBox ();
            sticker_grid.selection_mode = Gtk.SelectionMode.NONE;
            sticker_grid.min_children_per_line = 3;
            sticker_grid.max_children_per_line = 3;
            sticker_grid.homogeneous = true;
            sticker_grid.column_spacing = 8;
            sticker_grid.row_spacing = 8;
            sticker_grid.valign = Gtk.Align.START;

            /* FlowBox has no ListBox-style placeholder, so keep the label
               beside it and toggle its visibility */
            var grid_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            grid_box.append (placeholder);
            grid_box.append (sticker_grid);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.child = grid_box;
            content.append (scroll);

            box.append (content);
            this.child = box;

            reload_packs (null);
        }

        /* ---- pack picker prompts (also used from the message menu) ---- */

        public static async string? prompt_new_pack (Gtk.Widget parent) {
            var d = new Adw.AlertDialog ("New Sticker Pack",
                "Name for the new sticker pack.");
            d.add_response ("cancel", "Cancel");
            d.add_response ("create", "Create");
            d.set_response_appearance ("create",
                Adw.ResponseAppearance.SUGGESTED);
            d.default_response = "create";
            d.close_response = "cancel";

            var entry = new Gtk.Entry ();
            entry.placeholder_text = "Pack name";
            entry.activates_default = true;
            d.extra_child = entry;

            string response = yield d.choose (parent, null);
            if (response != "create") return null;
            return StickerStore.sanitize_pack_name (entry.text);
        }

        /** Ask for the destination pack (existing or new) and copy the
            sticker file into it. */
        public static void prompt_add_sticker (Window window,
                                               string file_path) {
            string[] packs = StickerStore.list_packs ();

            var d = new Adw.AlertDialog ("Add Sticker",
                "Choose the sticker pack to add this sticker to.");
            d.add_response ("cancel", "Cancel");
            d.add_response ("add", "Add");
            d.set_response_appearance ("add",
                Adw.ResponseAppearance.SUGGESTED);
            d.default_response = "add";
            d.close_response = "cancel";

            string[] choices = packs;
            choices += "New pack…";
            var dropdown = new Gtk.DropDown.from_strings (choices);
            dropdown.selected = 0;

            var entry = new Gtk.Entry ();
            entry.placeholder_text = "New pack name";
            entry.activates_default = true;
            entry.visible = packs.length == 0;
            dropdown.notify["selected"].connect (() => {
                entry.visible = dropdown.selected == packs.length;
            });

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            box.append (dropdown);
            box.append (entry);
            d.extra_child = box;

            d.response.connect ((r) => {
                if (r != "add") return;
                string? pack;
                if (dropdown.selected < packs.length) {
                    pack = packs[dropdown.selected];
                } else {
                    pack = StickerStore.sanitize_pack_name (entry.text);
                    if (pack == null) {
                        window.show_toast (
                            "Enter a name for the new sticker pack");
                        return;
                    }
                }
                try {
                    window.show_toast (
                        StickerStore.add_sticker (pack, file_path)
                            ? "Sticker added to \"%s\"".printf (pack)
                            : "Sticker is already in \"%s\"".printf (pack));
                } catch (Error e) {
                    show_error (window, "Could not add sticker: " + e.message);
                }
            });
            d.present (window);
        }

        /* ---- pack and sticker lists ---- */

        private void reload_packs (string? select_pack) {
            show_packs (StickerStore.list_packs (), select_pack);
        }

        /* Packs exist on disk only through their stickers' file names, so a
           freshly created pack lives in the dropdown alone until its first
           sticker arrives. */
        private void add_session_pack (string pack) {
            bool known = false;
            foreach (string existing in packs) {
                if (existing == pack) known = true;
            }
            if (!known) packs += pack;
            show_packs (packs, pack);
        }

        private void show_packs (string[] new_packs, string? select_pack) {
            string? want = select_pack ?? selected_pack ();
            packs = new_packs;

            syncing_packs = true;
            pack_dropdown.model = new Gtk.StringList (packs);
            for (uint i = 0; i < packs.length; i++) {
                if (packs[i] == want) {
                    pack_dropdown.selected = i;
                    break;
                }
            }
            syncing_packs = false;

            pack_dropdown.sensitive = packs.length > 0;
            rename_pack_btn.sensitive = packs.length > 0;
            delete_pack_btn.sensitive = packs.length > 0;
            reload_stickers ();
        }

        private string? selected_pack () {
            uint sel = pack_dropdown.selected;
            return packs.length > 0 && sel < packs.length ? packs[sel] : null;
        }

        private void reload_stickers () {
            Gtk.FlowBoxChild? child;
            while ((child = sticker_grid.get_child_at_index (0)) != null) {
                sticker_grid.remove (child);
            }

            string? pack = selected_pack ();
            if (pack == null) {
                placeholder.label =
                    "No sticker packs yet.\nPress + to create one.";
                placeholder.visible = true;
                return;
            }
            var stickers = StickerStore.list_stickers (pack);
            placeholder.label = "This pack has no stickers yet.\n" +
                "Right-click a sticker in a conversation and choose " +
                "\"Add Sticker…\".";
            placeholder.visible = stickers.length == 0;
            foreach (Sticker sticker in stickers) {
                sticker_grid.append (build_sticker_card (sticker));
            }
        }

        private Gtk.Widget build_sticker_card (Sticker sticker) {
            var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
            card.add_css_class ("card");

            var thumb = sticker_thumbnail (
                StickerStore.sticker_path (sticker.file_name),
                int.max (1, app_window.get_scale_factor ()), THUMB_SIZE);
            thumb.halign = Gtk.Align.CENTER;
            thumb.margin_top = 8;
            thumb.margin_start = 8;
            thumb.margin_end = 8;
            card.append (thumb);

            /* Tapping the emoji opens the picker to change it */
            var emoji_btn = new Gtk.Button ();
            emoji_btn.halign = Gtk.Align.CENTER;
            emoji_btn.margin_bottom = 6;
            emoji_btn.add_css_class ("flat");
            emoji_btn.tooltip_text = "Emoji associated with this sticker";
            if (sticker.emoji.length > 0) emoji_btn.label = sticker.emoji;
            else emoji_btn.icon_name = "face-smile-symbolic";
            emoji_btn.clicked.connect (() => {
                pick_emoji (sticker, emoji_btn);
            });
            card.append (emoji_btn);

            /* Right-click: copy path, move to another pack or delete */
            var click = new Gtk.GestureClick ();
            click.button = Gdk.BUTTON_SECONDARY;
            click.pressed.connect ((n, x, y) => {
                show_sticker_menu (sticker, card, x, y);
            });
            card.add_controller (click);
            return card;
        }

        private void pick_emoji (Sticker sticker, Gtk.Button btn) {
            var chooser = create_emoji_chooser ();
            if (chooser == null) {
                app_window.show_toast ("Emoji picker unavailable");
                return;
            }
            chooser.emoji_picked.connect ((emoji) => {
                try {
                    /* set_emoji renames the file and updates the Sticker
                       object, so the row stays valid as-is */
                    StickerStore.set_emoji (sticker, emoji);
                    btn.label = emoji;
                } catch (Error e) {
                    show_error (this, "Could not set emoji: " + e.message);
                }
            });
            chooser.set_parent (btn);
            unparent_on_close (chooser);
            chooser.popup ();
        }

        private void show_sticker_menu (Sticker sticker,
                                        Gtk.Widget parent,
                                        double x, double y) {
            Gtk.Box vbox;
            var popover = popover_menu (parent, x, y, out vbox);

            var copy_btn = new PopoverButton (popover, "Copy File Path");
            copy_btn.selected.connect (() => {
                this.get_clipboard ().set_text (
                    StickerStore.sticker_path (sticker.file_name));
                app_window.show_toast ("File path copied");
            });
            vbox.append (copy_btn);
            vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            bool has_move_targets = false;
            foreach (string other in packs) {
                if (other == sticker.pack) continue;
                has_move_targets = true;
                string dest = other;
                var move_btn = new PopoverButton (popover,
                    "Move to \"%s\"".printf (dest));
                move_btn.selected.connect (() => {
                    try {
                        app_window.show_toast (
                            StickerStore.move_sticker (sticker, dest)
                                ? "Sticker moved to \"%s\"".printf (dest)
                                : "Sticker is already in \"%s\"".printf (dest));
                    } catch (Error e) {
                        show_error (this,
                            "Could not move sticker: " + e.message);
                    }
                    reload_stickers ();
                });
                vbox.append (move_btn);
            }
            if (has_move_targets) {
                vbox.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            }

            var delete_btn = new PopoverButton (popover, "Delete…", true);
            delete_btn.selected.connect (() =>
                confirm_delete_sticker.begin (sticker));
            vbox.append (delete_btn);

            popover.popup ();
        }

        private async void confirm_delete_sticker (Sticker sticker) {
            if (yield confirm_action (this, "Delete Sticker?",
                    "Delete this sticker from \"%s\"? This cannot be undone."
                        .printf (sticker.pack),
                    "delete", "Delete")) {
                StickerStore.delete_sticker (sticker);
                reload_stickers ();
            }
        }

        private void on_rename_pack () {
            string? pack = selected_pack ();
            if (pack == null) return;
            var d = new Adw.AlertDialog ("Rename Sticker Pack",
                "New name for the pack \"%s\".".printf (pack));
            d.add_response ("cancel", "Cancel");
            d.add_response ("rename", "Rename");
            d.set_response_appearance ("rename",
                Adw.ResponseAppearance.SUGGESTED);
            d.default_response = "rename";
            d.close_response = "cancel";

            var entry = new Gtk.Entry ();
            entry.text = pack;
            entry.activates_default = true;
            d.extra_child = entry;

            d.response.connect ((r) => {
                if (r != "rename") return;
                string? new_pack = StickerStore.sanitize_pack_name (entry.text);
                if (new_pack == null || new_pack == pack) return;
                try {
                    StickerStore.rename_pack (pack, new_pack);
                } catch (Error e) {
                    show_error (this, "Could not rename pack: " + e.message);
                    return;
                }
                /* Rewrite the in-memory list instead of rescanning the disk
                   so still-empty session packs survive, deduping in case the
                   rename merged two packs */
                string[] updated = {};
                foreach (string existing in packs) {
                    string name = existing == pack ? new_pack : existing;
                    bool seen = false;
                    foreach (string prev in updated) {
                        if (prev == name) seen = true;
                    }
                    if (!seen) updated += name;
                }
                show_packs (updated, new_pack);
            });
            d.present (this);
        }

        private async void on_delete_pack () {
            string? pack = selected_pack ();
            if (pack == null) return;
            if (yield confirm_action (this, "Delete Sticker Pack?",
                "Delete the pack \"%s\" and all of its stickers? This cannot be undone."
                    .printf (pack),
                "delete", "Delete Pack")) {
                StickerStore.delete_pack (pack);
                reload_packs (null);
            }
        }
    }
}
