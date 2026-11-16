#include "webxdc_view.h"
#include <adwaita.h>
#include <webkit/webkit.h>

typedef struct {
    GtkWindow *window;
    WebKitWebView *view;
    GHashTable *tasks;
    ParlaWebxdcBlobFn blob;
    ParlaWebxdcMsgFn message;
    ParlaWebxdcClosedFn closed;
    gpointer data;
    gboolean internet, wasm, minimized;
} View;

static void resource (WebKitURISchemeRequest *request, gpointer data)
{
    View *v = data;
    if (!g_str_has_prefix (webkit_uri_scheme_request_get_uri (request), "webxdc://app/")) {
        GError *error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "Invalid app origin");
        webkit_uri_scheme_request_finish_error (request, error);
        g_error_free (error);
        return;
    }
    g_hash_table_add (v->tasks, g_object_ref (request));
    v->blob (webkit_uri_scheme_request_get_path (request), request, v->data);
}

static void message (WebKitUserContentManager *manager, JSCValue *value, gpointer data)
{
    (void)manager;
    View *v = data;
    char *json = jsc_value_to_string (value);
    v->message (json, v->data);
    g_free (json);
}

static gboolean policy (WebKitWebView *view, WebKitPolicyDecision *decision,
    WebKitPolicyDecisionType type, gpointer data)
{
    (void)view; (void)data;
    if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        webkit_policy_decision_ignore (decision);
        return TRUE;
    }
    if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
        WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action (
            WEBKIT_NAVIGATION_POLICY_DECISION (decision));
        const char *uri = webkit_uri_request_get_uri (webkit_navigation_action_get_request (action));
        if (!g_str_has_prefix (uri, "webxdc://app/")) {
            webkit_policy_decision_ignore (decision);
            return TRUE;
        }
    }
    return FALSE;
}

static gboolean permission (WebKitWebView *view, WebKitPermissionRequest *request, gpointer data)
{
    (void)view; (void)data;
    webkit_permission_request_deny (request);
    return TRUE;
}

static void download (WebKitNetworkSession *session, WebKitDownload *item, gpointer data)
{
    (void)session; (void)data;
    webkit_download_cancel (item);
}

static gboolean closed (GtkWindow *window, gpointer data)
{
    (void)window;
    View *v = data;
    v->closed (v->data);
    return TRUE;
}

gpointer parla_webxdc_open (const char *title, ParlaWebxdcBlobFn blob,
    ParlaWebxdcMsgFn msg, ParlaWebxdcClosedFn close, gboolean internet,
    gboolean wasm, gboolean webgl, gboolean developer, gpointer data)
{
    gboolean engine_wasm;
    if (!jsc_options_get_boolean ("useWasm", &engine_wasm) || engine_wasm != wasm)
        g_error ("WebKitGTK cannot enforce the requested Wasm policy");
    View *v = g_new0 (View, 1);
    v->blob = blob; v->message = msg; v->closed = close; v->data = data;
    v->internet = internet; v->wasm = wasm;
    v->tasks = g_hash_table_new_full (g_direct_hash, g_direct_equal, g_object_unref, NULL);
    WebKitWebContext *context = webkit_web_context_new ();
    webkit_web_context_register_uri_scheme (context, "webxdc", resource, v, NULL);
    webkit_security_manager_register_uri_scheme_as_secure (
        webkit_web_context_get_security_manager (context), "webxdc");
    WebKitNetworkSession *session = webkit_network_session_new_ephemeral ();
    g_signal_connect (session, "download-started", G_CALLBACK (download), NULL);
    if (!internet) {
        WebKitNetworkProxySettings *proxy = webkit_network_proxy_settings_new ("socks5://127.0.0.1:1", NULL);
        webkit_network_session_set_proxy_settings (session, WEBKIT_NETWORK_PROXY_MODE_CUSTOM, proxy);
        webkit_network_proxy_settings_free (proxy);
    }
    WebKitUserContentManager *manager = webkit_user_content_manager_new ();
    webkit_user_content_manager_register_script_message_handler (manager, "webxdc", NULL);
    g_signal_connect (manager, "script-message-received::webxdc", G_CALLBACK (message), v);
    v->view = g_object_new (WEBKIT_TYPE_WEB_VIEW, "web-context", context,
        "network-session", session, "user-content-manager", manager, NULL);
    g_object_unref (context); g_object_unref (session); g_object_unref (manager);
    WebKitSettings *settings = webkit_web_view_get_settings (v->view);
    g_object_set (settings, "enable-developer-extras", developer,
        "allow-modal-dialogs", FALSE, "javascript-can-open-windows-automatically", FALSE,
        "enable-webrtc", internet, "enable-webgl", webgl,
        "hardware-acceleration-policy", WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER, NULL);
    g_signal_connect (v->view, "decide-policy", G_CALLBACK (policy), v);
    g_signal_connect (v->view, "permission-request", G_CALLBACK (permission), v);
    v->window = GTK_WINDOW (adw_window_new ());
    g_object_ref_sink (v->window);
    gtk_window_set_title (v->window, title);
    gtk_window_set_default_size (v->window, 420, 640);
    AdwToolbarView *toolbar = ADW_TOOLBAR_VIEW (adw_toolbar_view_new ());
    adw_toolbar_view_add_top_bar (toolbar, adw_header_bar_new ());
    adw_toolbar_view_set_content (toolbar, GTK_WIDGET (v->view));
    adw_window_set_content (ADW_WINDOW (v->window), GTK_WIDGET (toolbar));
    g_signal_connect (v->window, "close-request", G_CALLBACK (closed), v);
    if (developer) webkit_web_inspector_show (webkit_web_view_get_inspector (v->view));
    return v;
}

void parla_webxdc_load (gpointer handle, const char *uri) { webkit_web_view_load_uri (((View *)handle)->view, uri); }
void parla_webxdc_eval_js (gpointer handle, const char *js) {
    webkit_web_view_evaluate_javascript (((View *)handle)->view, js, -1, NULL, NULL, NULL, NULL, NULL);
}
void parla_webxdc_set_title (gpointer handle, const char *title) { gtk_window_set_title (((View *)handle)->window, title); }
void parla_webxdc_present (gpointer handle) { gtk_window_present (((View *)handle)->window); }
void parla_webxdc_minimize (gpointer handle) {
    View *v = handle;
    v->minimized = !v->minimized;
    if (v->minimized) gtk_window_minimize (v->window);
    else gtk_window_present (v->window);
}
void parla_webxdc_set_visible (gpointer handle, gboolean visible) { gtk_widget_set_visible (GTK_WIDGET (((View *)handle)->window), visible); }
void parla_webxdc_set_acceleration (gpointer handle, gboolean enabled) {
    webkit_settings_set_hardware_acceleration_policy (webkit_web_view_get_settings (((View *)handle)->view),
        enabled ? WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS : WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
}
void parla_webxdc_finish_task (gpointer handle, gpointer task, const guint8 *data, gint length, const char *mime)
{
    View *v = handle;
    if (!g_hash_table_contains (v->tasks, task)) return;
    GBytes *bytes = g_bytes_new (data, length);
    GInputStream *stream = g_memory_input_stream_new_from_bytes (bytes);
    WebKitURISchemeResponse *response = webkit_uri_scheme_response_new (stream, length);
    webkit_uri_scheme_response_set_content_type (response, mime);
    {
        SoupMessageHeaders *headers = soup_message_headers_new (SOUP_MESSAGE_HEADERS_RESPONSE);
        soup_message_headers_append (headers, "Content-Security-Policy",
            parla_webxdc_csp (v->internet, v->wasm));
        webkit_uri_scheme_response_set_http_headers (response, headers);
    }
    webkit_uri_scheme_request_finish_with_response (task, response);
    g_object_unref (response); g_object_unref (stream); g_bytes_unref (bytes);
    g_hash_table_remove (v->tasks, task);
}
void parla_webxdc_fail_task (gpointer handle, gpointer task)
{
    View *v = handle;
    if (!g_hash_table_contains (v->tasks, task)) return;
    GError *error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "Webxdc resource unavailable");
    webkit_uri_scheme_request_finish_error (task, error);
    g_error_free (error);
    g_hash_table_remove (v->tasks, task);
}
void parla_webxdc_close (gpointer handle) { closed (NULL, handle); }
void parla_webxdc_free (gpointer handle)
{
    View *v = handle;
    gtk_window_destroy (v->window);
    g_object_unref (v->window);
    g_hash_table_unref (v->tasks);
    g_free (v);
}
