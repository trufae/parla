#include "webxdc_sandbox.h"
#import <Cocoa/Cocoa.h>

static void log_message (const gchar *domain, GLogLevelFlags level,
    const gchar *message, gpointer data)
{
    (void)domain; (void)level; (void)data;
    NSLog (@"Webxdc: %s", message);
}

void parla_webxdc_helper_init (gboolean internet)
{
    (void)internet;
    g_log_set_default_handler (log_message, NULL);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    // Cocoa owns the main thread; drain a bounded amount of GLib work on it.
    [NSTimer scheduledTimerWithTimeInterval:0.005 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        for (int i = 0; i < 64 && g_main_context_pending (NULL); i++)
            g_main_context_iteration (NULL, FALSE);
    }];
}
void parla_webxdc_helper_run (void) { [NSApp run]; }
void parla_webxdc_helper_quit (void) {
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
        context:nil subtype:0 data1:0 data2:0] atStart:NO];
}
