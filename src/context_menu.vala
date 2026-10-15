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

    /** Attach once to a widget and handle requested to open its menu.
        Coordinates are relative to that widget. Return true when a menu
        opens, or false to leave the event to GTK (e.g. selected text).
        Both gestures capture before child labels/buttons; only a handled
        request claims the sequence and suppresses child activation. */
    public class ContextMenuGestures : Object {
        public signal bool requested (double x, double y, bool long_press);

        public ContextMenuGestures (Gtk.Widget widget, SettingsManager settings) {
            var click = new Gtk.GestureClick ();
            click.button = Gdk.BUTTON_SECONDARY;
            click.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            // The widget owns the controllers. Keeping the captured pointers
            // unowned avoids controller -> closure -> controller cycles.
            unowned var right_click = click;
            click.pressed.connect ((n, x, y) => {
                right_click.set_state (requested (x, y, false)
                    ? Gtk.EventSequenceState.CLAIMED : Gtk.EventSequenceState.DENIED);
            });
            widget.add_controller (click);

            var gesture = new Gtk.GestureLongPress ();
            gesture.button = Gdk.BUTTON_PRIMARY;
            // One preference covers both touch and primary-button holds,
            // including accessibility use on machines without a touchscreen.
            gesture.touch_only = false;
            unowned var hold = gesture;
            gesture.pressed.connect ((x, y) => {
                hold.set_state (requested (x, y, true)
                    ? Gtk.EventSequenceState.CLAIMED : Gtk.EventSequenceState.DENIED);
            });
            // Apply changes to existing widgets and cancel pending holds
            // when disabled. GTK cancels on release or pointer movement.
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
        }
    }
}
