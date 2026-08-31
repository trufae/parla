#pragma once

#include <glib.h>

G_BEGIN_DECLS

/* Windows-only Edge WebView2 bridge for the experimental Webxdc runner. */
typedef void (*ParlaWebxdcWinBlobFn) (const char *path,
                                      gpointer    task,
                                      gpointer    user_data);
typedef void (*ParlaWebxdcWinMsgFn) (const char *json, gpointer user_data);
typedef void (*ParlaWebxdcWinClosedFn) (gpointer user_data);

gpointer parla_webxdc_win_open (
    const char               *title,
    ParlaWebxdcWinBlobFn      blob,
    ParlaWebxdcWinMsgFn       message,
    ParlaWebxdcWinClosedFn    closed,
    gboolean                  allow_internet,
    gboolean                  allow_wasm,
    gboolean                  allow_webgl,
    gboolean                  developer_tools,
    gpointer                  user_data);

void parla_webxdc_win_load (gpointer handle, const char *uri);
void parla_webxdc_win_finish_task (gpointer handle, gpointer task,
                                   const guint8 *data, gint data_length,
                                   const char *mime);
void parla_webxdc_win_fail_task (gpointer handle, gpointer task);
void parla_webxdc_win_eval_js (gpointer handle, const char *js);
void parla_webxdc_win_set_title (gpointer handle, const char *title);
void parla_webxdc_win_present (gpointer handle);
void parla_webxdc_win_minimize (gpointer handle);
void parla_webxdc_win_set_visible (gpointer handle, gboolean visible);
void parla_webxdc_win_close (gpointer handle);
void parla_webxdc_win_free (gpointer handle);

G_END_DECLS
