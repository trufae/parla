#include <gio/gio.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include "pty_password.h"

static const gchar *executable;
static const gchar *password = "disposable terminal password";

static int delayed_prompt (int prompts)
{
    struct termios attributes;
    char reply[128];
    if (tcgetattr (STDIN_FILENO, &attributes) != 0) return 1;
    for (int index = 0; index < prompts; index++) {
        attributes.c_lflag |= ECHO;
        if (tcsetattr (STDIN_FILENO, TCSANOW, &attributes) != 0) return 1;
        fputs ("password:", stdout);
        fflush (stdout);
        // Force the parent to see the prompt while echo is still enabled.
        g_usleep (100000);
        attributes.c_lflag &= ~ECHO;
        if (tcsetattr (STDIN_FILENO, TCSANOW, &attributes) != 0) return 1;
        if (fgets (reply, sizeof reply, stdin) == NULL
                || g_strcmp0 (g_strchomp (reply), password) != 0) return 1;
    }
    return 0;
}

static void test_delayed_echo (void)
{
    for (int prompts = 1; prompts <= 2; prompts++) {
        gchar *argv[] = { (gchar *) executable, "--child",
                         prompts == 2 ? "2" : "1", NULL };
        GError *error = NULL;
        gchar *output = NULL;
        gboolean ok = safestore_run_pty_password (
            argv, ".", password, prompts == 2, &output, &error);
        g_assert_no_error (error);
        g_assert_true (ok);
        // Redaction would also reveal that input was sent with echo enabled.
        g_assert_null (strstr (output, "[password redacted]"));
        g_free (output);
    }
}

int main (int argc, char **argv)
{
    if (argc == 3 && g_str_equal (argv[1], "--child"))
        return delayed_prompt (g_str_equal (argv[2], "2") ? 2 : 1);
    executable = argv[0];
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/pty-password/delayed-echo", test_delayed_echo);
    return g_test_run ();
}
