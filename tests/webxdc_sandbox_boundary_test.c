#include "webxdc_sandbox.h"
#include <glib/gstdio.h>

int main (int argc, char **argv)
{
    if (argc == 3 && g_str_equal (argv[2], "--expect-denied")) {
        GError *failure = NULL;
        GInputStream *input;
        GOutputStream *output;
        gpointer process = parla_webxdc_sandbox_launch (argv[1], FALSE, FALSE, FALSE, &input, &output, &failure);
        g_assert_null (process);
        g_assert_error (failure, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED);
        g_clear_error (&failure);
        g_print ("Invalid sandbox entitlement rejected before launch: PASS\n");
        return 0;
    }
    if (argc != 2) return 2;
    GError *error = NULL;
    char *dir = g_dir_make_tmp ("parla-sandbox-boundary-XXXXXX", &error);
    g_assert_no_error (error);
    char *path = g_build_filename (dir, "account-secret", NULL);
    g_file_set_contents (path, "test-only", -1, &error);
    g_assert_no_error (error);
    GSocketListener *listener = g_socket_listener_new ();
    guint16 port = g_socket_listener_add_any_inet_port (listener, NULL, &error);
    g_assert_no_error (error);
    // Prove the destination is reachable outside the sandbox.
    GSocketClient *client = g_socket_client_new ();
    GSocketConnection *control = g_socket_client_connect_to_host (client, "127.0.0.1", port, NULL, &error);
    g_assert_no_error (error);
    g_object_unref (control); g_object_unref (client);
    g_setenv ("PARLA_SANDBOX_SENTINEL", "must-not-leak", TRUE);
    GInputStream *input;
    GOutputStream *output;
    gpointer process = parla_webxdc_sandbox_launch (argv[1], FALSE, FALSE, FALSE, &input, &output, &error);
    g_assert_no_error (error);
    g_assert_nonnull (process);
    char *request = g_strdup_printf ("%s\n%u\n", path, port);
    g_output_stream_write_all (output, request, strlen (request), NULL, NULL, &error);
    g_assert_no_error (error);
    GDataInputStream *reader = g_data_input_stream_new (input);
    char *reply = g_data_input_stream_read_line (reader, NULL, NULL, &error);
    g_assert_no_error (error);
#ifdef __APPLE__
    // WKWebView requires network.client, including in offline mode.
    g_assert_cmpstr (reply, ==, "read=0 network=1 env=0");
#else
    g_assert_cmpstr (reply, ==, "read=0 network=0 env=0");
#endif
    parla_webxdc_sandbox_stop (process);
    // Closing must terminate even the probe that ignores SIGTERM and never
    // voluntarily exits. The Python runner bounds this wait with a timeout.
    char extra;
    g_assert_cmpint (g_input_stream_read (input, &extra, 1, NULL, &error), ==, 0);
    g_assert_no_error (error);
    g_object_unref (reader); g_object_unref (input); g_object_unref (output);
    g_object_unref (listener);
    g_unlink (path); g_rmdir (dir);
    g_free (path); g_free (dir); g_free (request); g_free (reply);
    g_print ("Native sandbox boundary checks: PASS\n");
    return 0;
}
