namespace Dc {
    /* GtkLabel starts selecting on the first movement, before the parent
       scroller's drag threshold. Touch swipes must belong to the scroller;
       keep mouse/keyboard selection, link taps and long-press menus intact. */
    public void make_label_selectable (Gtk.Label label) {
        label.selectable = true;
        var controllers = label.observe_controllers ();
        for (uint i = 0; i < controllers.get_n_items (); i++) {
            var gesture = controllers.get_item (i) as Gtk.GestureDrag;
            if (gesture == null) continue;
            unowned var drag = gesture;
            gesture.begin.connect ((sequence) => {
                var event = drag.get_last_event (sequence);
                if (event == null) return;
                var device = event.get_device ();
                if (event.get_event_type () != Gdk.EventType.TOUCH_BEGIN &&
                        (device == null || device.source != Gdk.InputSource.TOUCHSCREEN))
                    return;
                drag.set_state (Gtk.EventSequenceState.DENIED);
                // Stop the default handler from starting text selection.
                Signal.stop_emission_by_name (drag, "begin");
            });
        }
    }
}
