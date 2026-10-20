namespace Dc {
    /** Android fallback for GTK's touch selection bubble. Keep Paste available
        even when advertised clipboard formats are empty; read the system
        clipboard only in response to the user's Paste action. */
    public class TouchTextMenu : Object {
        public static void install (Gtk.Widget root) {
            var gesture = new Gtk.GestureLongPress ();
            gesture.touch_only = true;
            gesture.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            unowned var hold = gesture;
            unowned var owner = root;
            gesture.pressed.connect ((x, y) => {
                var target = find_target (owner.pick (x, y, Gtk.PickFlags.DEFAULT));
                if (target == null) return;
                // Cancel GTK's competing magnifier/bubble before presenting.
                hold.set_state (Gtk.EventSequenceState.CLAIMED);
                target.grab_focus ();
                show (target);
            });
            root.add_controller (gesture);
        }

        public static Gtk.Widget? find_target (Gtk.Widget? widget) {
            for (var current = widget; current != null; current = current.parent) {
                if (current is Gtk.Popover) return null;
                if (current is Gtk.Text || current is Gtk.TextView)
                    return current;
            }
            return null;
        }

        public static Gtk.Popover show (Gtk.Widget target) {
            bool editable;
            bool selected;
            bool can_copy;
            bool has_text;
            var text = target as Gtk.Text;
            if (text != null) {
                int start, end;
                editable = text.editable;
                selected = text.get_selection_bounds (out start, out end);
                can_copy = text.visibility;
                has_text = text.text.length > 0;
            } else {
                var view = (Gtk.TextView) target;
                editable = view.editable;
                selected = view.buffer.has_selection;
                can_copy = true;
                has_text = view.buffer.get_char_count () > 0;
            }

            Gtk.Box box;
            var menu = popover_menu (target, target.get_width () / 2.0,
                target.get_height (), out box);
            append_action (box, menu, target, _("Cut"), "clipboard.cut",
                editable && selected && can_copy);
            append_action (box, menu, target, _("Copy"), "clipboard.copy",
                selected && can_copy);
            append_action (box, menu, target, _("Paste"), "paste-clipboard", editable);
            append_action (box, menu, target, _("Select All"), "selection.select-all", has_text);
            menu.popup ();
            return menu;
        }

        private static void append_action (Gtk.Box box, Gtk.Popover menu,
                                           Gtk.Widget target, string label,
                                           string action, bool enabled) {
            var button = new Gtk.Button.with_label (label);
            button.add_css_class ("flat");
            button.sensitive = enabled;
            button.focus_on_click = false;
            unowned var editor = target;
            unowned var popover = menu;
            button.clicked.connect (() => {
                popover.popdown ();
                if (action == "paste-clipboard") {
                    // Bypass the format-gated action, preserving the native
                    // signal and ComposeBar's existing paste handler.
                    Signal.emit_by_name (editor, "paste-clipboard");
                } else {
                    editor.activate_action (action, null);
                }
            });
            box.append (button);
        }
    }
}
