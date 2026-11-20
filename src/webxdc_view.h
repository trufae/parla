#pragma once
#include <glib.h>

G_BEGIN_DECLS
/* These belong to native window chrome, outside the app's web content. */
#define PARLA_WEBXDC_SANDBOX_ICON "🛡️"
static inline const char *parla_webxdc_sandbox_tooltip (void) {
    return g_dgettext ("parla", "Sandboxed app. Runs separately with restricted access to your files.");
}
static inline char *parla_webxdc_window_title (const char *title) {
    return g_strconcat (PARLA_WEBXDC_SANDBOX_ICON " ", title, NULL);
}

/* Private native-view ABI, linked only into the sandboxed helper. Resource
 * task pointers and engine callbacks never cross the process boundary. */
typedef void (*ParlaWebxdcBlobFn)   (const char *path, gpointer task,
                                     gpointer user_data);
typedef void (*ParlaWebxdcMsgFn)    (const char *json, gpointer user_data);
typedef void (*ParlaWebxdcClosedFn) (gpointer user_data);

/* One response policy for all engines, including worker scripts. Offline
 * pages may fetch archive resources but cannot open URL-backed transports.
 * Enabling Wasm permits its compilation without also enabling JS eval. */
static inline const char *parla_webxdc_csp (gboolean internet, gboolean wasm) {
#define LOCAL_SOURCES "'self' webxdc: data: blob: "
#define OFFLINE_POLICY "default-src " LOCAL_SOURCES "; style-src " LOCAL_SOURCES "'unsafe-inline'; " \
    "connect-src " LOCAL_SOURCES "; form-action 'none'; object-src 'none'; base-uri 'self'; "
#define SCRIPTS "script-src " LOCAL_SOURCES "'unsafe-inline' "
    if (internet) return wasm ? SCRIPTS "http: https: 'wasm-unsafe-eval'" : SCRIPTS "http: https:";
    return wasm ? OFFLINE_POLICY SCRIPTS "'wasm-unsafe-eval'" : OFFLINE_POLICY SCRIPTS;
#undef SCRIPTS
#undef OFFLINE_POLICY
#undef LOCAL_SOURCES
}

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

#if defined(_WIN32) || defined(__APPLE__)
static inline void parla_webxdc_set_acceleration (gpointer handle, gboolean enabled) {
    (void)handle; (void)enabled;
}
#else
void parla_webxdc_set_acceleration (gpointer handle, gboolean enabled);
#endif
G_END_DECLS
