namespace Dc {

    /* A modal popover's grab interrupts the editor's IM context even when
       its menu button has focus_on_click=false. Preserve focus on every
       platform so virtual keyboards do not hide/reopen when a picker opens.
       Replace the grab's outside-click/Escape dismissal. */
    internal void preserve_picker_focus (Gtk.MenuButton button) {
        unowned Gtk.MenuButton anchor = button;
        unowned Gtk.Popover popover = button.get_popover ();
        popover.autohide = false;
        /* GtkEmojiChooser also explicitly focuses its search entry in map().
           Block that initial grab, then allow normal taps and Tab navigation. */
        popover.can_focus = false;
        weak Gtk.Widget? root = null;
        Gtk.GestureClick? click = null;
        Gtk.EventControllerKey? keys = null;
        popover.map.connect (() => {
            popover.can_focus = true;
            root = anchor.get_root () as Gtk.Widget;
            if (root == null) return;
            click = new Gtk.GestureClick ();
            click.button = 0;
            click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            click.pressed.connect ((n, x, y) => {
                if (root == null) return;
                /* Popovers have their own native surfaces, including the
                   emoji skin-tone submenu; root.pick() cannot pick those. */
                var event = click.get_current_event ();
                var native = event == null ? null
                    : Gtk.Native.get_for_surface (event.get_surface ()) as Gtk.Widget;
                if (native != null && (native == popover || native.is_ancestor (popover)))
                    return;
                var target = root.pick (x, y, Gtk.PickFlags.DEFAULT);
                if (target == null || (target != anchor && !target.is_ancestor (anchor))) {
                    click.set_state (Gtk.EventSequenceState.CLAIMED);
                    popover.popdown ();
                }
            });
            keys = new Gtk.EventControllerKey ();
            keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            keys.propagation_limit = Gtk.PropagationLimit.NONE;
            keys.key_pressed.connect ((keyval, keycode, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                /* Let a nested chooser dismiss itself first. */
                var focus = ((Gtk.Root) root).get_focus ();
                if (focus != null && focus.get_native () != popover
                    && focus.is_ancestor (popover)) return false;
                bool return_to_button = focus != null && focus.is_ancestor (popover);
                popover.popdown ();
                if (return_to_button) anchor.grab_focus ();
                return true;
            });
            root.add_controller (click);
            root.add_controller (keys);
            /* Keyboard activation starts on the menu button, not an editor.
               Move into the picker in that case, preserving Tab/Enter use. */
            var focus = ((Gtk.Root) root).get_focus ();
            if (focus != null && (focus == anchor || focus.is_ancestor (anchor)))
                popover.child_focus (Gtk.DirectionType.TAB_FORWARD);
        });
        popover.unmap.connect (() => {
            popover.can_focus = false;
            if (root != null) {
                root.remove_controller (click);
                root.remove_controller (keys);
            }
            click = null;
            keys = null;
            root = null;
        });
    }

    public bool gtk_emoji_chooser_available () {
        var source = SettingsSchemaSource.get_default ();
        if (source == null) return false;

        var schema = source.lookup ("org.gtk.gtk4.Settings.EmojiChooser", true);
        if (schema != null) return true;

        schema = source.lookup ("org.gtk.Settings.EmojiChooser", true);
        return schema != null;
    }

    public Gtk.EmojiChooser? create_emoji_chooser () {
        if (!gtk_emoji_chooser_available ()) return null;
        return new Gtk.EmojiChooser ();
    }
}
