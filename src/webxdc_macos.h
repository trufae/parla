#pragma once

#include <glib.h>

/*
 * macOS view layer for the experimental Webxdc runner: an NSWindow with a
 * WKWebView from the system WebKit.framework, so no WebKitGTK is needed
 * on macOS. All Cocoa logic lives in webxdc_macos.m behind these plain C
 * entry points; the Vala side (webxdc.vala, #if MACOS section) supplies
 * the app content and the security policy stays engine-level. By default a
 * WKContentRuleList blocks every load outside the webxdc: scheme; an explicit
 * unsafe setting can omit that list. The website data store is always
 * non-persistent.
 *
 * Every callback is dispatched to the GTK main loop with g_idle_add, so
 * handlers may safely touch GTK/Vala state. Each blob request is answered
 * exactly once with finish_task or fail_task; the shim keeps the task
 * alive (even after WebKit cancels it) until that answer or free.
 */

typedef void (*ParlaWebxdcBlobFn)   (const char *path, gpointer task,
                                     gpointer user_data);
typedef void (*ParlaWebxdcMsgFn)    (const char *json, gpointer user_data);
typedef void (*ParlaWebxdcClosedFn) (gpointer user_data);

/* Create the window (not yet loading anything) and return an opaque
 * handle. blob fires for every webxdc: resource request, message for
 * every window.webkit.messageHandlers.webxdc.postMessage, closed once
 * when the window goes away (the handle must then be released with
 * parla_webxdc_free and never used again). */
gpointer parla_webxdc_open (const char          *title,
                            ParlaWebxdcBlobFn    blob,
                            ParlaWebxdcMsgFn     message,
                            ParlaWebxdcClosedFn  closed,
                            gboolean             allow_internet,
                            gboolean             allow_wasm,
                            gboolean             allow_webgl,
                            gboolean             developer_tools,
                            gpointer             user_data);

void parla_webxdc_load (gpointer handle, const char *uri);
void parla_webxdc_finish_task (gpointer handle, gpointer task,
                               const guint8 *data, gint data_length,
                               const char *mime);
void parla_webxdc_fail_task (gpointer handle, gpointer task);
void parla_webxdc_eval_js (gpointer handle, const char *js);
void parla_webxdc_set_title (gpointer handle, const char *title);
void parla_webxdc_present (gpointer handle);
void parla_webxdc_minimize (gpointer handle);   /* toggles: restores if minimized */
void parla_webxdc_set_visible (gpointer handle, gboolean visible);
void parla_webxdc_close (gpointer handle);
void parla_webxdc_free (gpointer handle);
