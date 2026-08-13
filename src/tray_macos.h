#pragma once

#include <glib.h>

/*
 * macOS menu-bar ("tray") counterpart of the freedesktop
 * StatusNotifierItem in tray_icon.vala. All Cocoa/objc logic lives in
 * tray_macos.m; the Vala side (tray_macos.vala) only sees these plain C
 * entry points. Every callback is dispatched to the GTK main loop with
 * g_idle_add, so handlers may safely touch GTK state.
 */

typedef void (*ParlaMacosTrayAction) (gpointer user_data);
typedef void (*ParlaMacosTrayToggle) (gboolean enabled, gpointer user_data);

/* Wire the callbacks; must be called once, from the main thread, before
 * any other tray call. window_toggle backs the Show/Hide menu item;
 * window_show fires when the user re-launches or docks-click the app
 * while the window is hidden. */
void parla_macos_tray_init (ParlaMacosTrayAction window_toggle,
                            ParlaMacosTrayAction window_show,
                            ParlaMacosTrayAction quit,
                            ParlaMacosTrayToggle notifications_toggle,
                            gpointer             user_data);

gboolean parla_macos_tray_show (void);
void parla_macos_tray_hide (void);

/* Keep the menu labels/checkmark in sync with the app state. */
void parla_macos_tray_set_window_visible (gboolean visible);
void parla_macos_tray_set_notifications_enabled (gboolean enabled);
