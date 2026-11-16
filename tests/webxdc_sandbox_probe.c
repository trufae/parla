/* Installed only in a temporary test bundle, never in the product. Attempts
 * native access after a successful sandbox launch, independently of browser
 * request interception or JavaScript settings. */
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#ifndef _WIN32
#include <signal.h>
#endif

int main (void)
{
#ifndef _WIN32
    // A compromised helper need not cooperate with graceful termination.
    signal (SIGTERM, SIG_IGN);
#endif
    char path[4096], port[16];
    if (!fgets (path, sizeof (path), stdin) || !fgets (port, sizeof (port), stdin)) return 2;
    g_strchomp (path);
    gchar *contents = NULL;
    gboolean readable = g_file_get_contents (path, &contents, NULL, NULL);
    g_free (contents);
    GSocketClient *client = g_socket_client_new ();
    g_socket_client_set_timeout (client, 2);
    GSocketConnection *connection = g_socket_client_connect_to_host (client, "127.0.0.1", atoi (port), NULL, NULL);
    printf ("read=%d network=%d env=%d\n", readable, connection != NULL,
        g_getenv ("PARLA_SANDBOX_SENTINEL") != NULL);
    if (connection) g_object_unref (connection);
    g_object_unref (client);
    fflush (stdout);
    g_main_loop_run (g_main_loop_new (NULL, FALSE));
    return 0;
}
