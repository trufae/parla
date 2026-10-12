namespace Dc {

    public static bool is_phosh_session () {
        foreach (var variable in new string[] {
            "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION"
        }) {
            var value = Environment.get_variable (variable);
            if (value == null) continue;
            foreach (var desktop in value.split (":")) {
                if (desktop.ascii_casecmp ("phosh") == 0) return true;
            }
        }
        return false;
    }

    /* Capture before child labels/buttons, but only claim in the menu
       handler once the hold succeeds. GTK cancels on release or movement.
       Binding the phase makes the preference take effect on existing views
       and cancels a pending hold when it is switched off. */
    public static Gtk.GestureLongPress context_menu_long_press (
            Gtk.Widget widget, SettingsManager settings) {
        var gesture = new Gtk.GestureLongPress ();
        gesture.button = Gdk.BUTTON_PRIMARY;
        settings.bind_property ("long-press-context-menu", gesture,
            "propagation-phase", BindingFlags.SYNC_CREATE,
            (binding, from_value, ref to_value) => {
                if (!from_value.get_boolean ()) {
                    var target = binding.dup_target () as Gtk.EventController;
                    if (target != null) target.reset ();
                }
                to_value.set_enum (from_value.get_boolean ()
                    ? Gtk.PropagationPhase.CAPTURE : Gtk.PropagationPhase.NONE);
                return true;
            });
        widget.add_controller (gesture);
        return gesture;
    }
}
