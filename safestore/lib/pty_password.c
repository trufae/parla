#include <gio/gio.h>
#include <glib.h>
#include <string.h>
#include "pty_password.h"

#if !defined(G_OS_WIN32) && !defined(SAFESTORE_NO_PTY)
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <termios.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#endif

struct _SafeStoreSecretMemory {
    gint references;
    gchar *value;
    gsize allocation_size;
    gboolean memory_locked;
};

SafeStoreSecretMemory *
safestore_secret_memory_new (const gchar *value)
{
    SafeStoreSecretMemory *self = g_new0 (SafeStoreSecretMemory, 1);
    self->references = 1;
    gsize length = strlen (value);
    self->allocation_size = length + 1;
    self->value = g_malloc (self->allocation_size);
    memcpy (self->value, value, self->allocation_size);
#if !defined(G_OS_WIN32) && !defined(SAFESTORE_NO_PTY)
    self->memory_locked = mlock (self->value, self->allocation_size) == 0;
#endif
    return self;
}

SafeStoreSecretMemory *
safestore_secret_memory_ref (SafeStoreSecretMemory *self)
{
    g_atomic_int_inc (&self->references);
    return self;
}

void
safestore_secret_memory_unref (SafeStoreSecretMemory *self)
{
    if (g_atomic_int_dec_and_test (&self->references)) {
        safestore_secret_memory_clear (self);
        g_free (self);
    }
}

const gchar *
safestore_secret_memory_peek (SafeStoreSecretMemory *self)
{
    g_return_val_if_fail (self != NULL, "");
    return self->value != NULL ? self->value : "";
}

void
safestore_secret_memory_clear (SafeStoreSecretMemory *self)
{
    g_return_if_fail (self != NULL);
    if (self->value == NULL) return;
    volatile guint8 *cursor = (volatile guint8 *) self->value;
    for (gsize index = 0; index < self->allocation_size; index++) {
        cursor[index] = 0;
    }
#if !defined(G_OS_WIN32) && !defined(SAFESTORE_NO_PTY)
    if (self->memory_locked) munlock (self->value, self->allocation_size);
#endif
    g_free (self->value);
    self->value = NULL;
    self->allocation_size = 0;
    self->memory_locked = FALSE;
}

int
safestore_acquire_accounts_guard (const gchar *lock_path,
                                  GError **error)
{
#if defined(G_OS_WIN32) || defined(SAFESTORE_NO_PTY)
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                         "ZIP account locking is unavailable on this platform");
    return -1;
#else
    int descriptor = open (lock_path, O_RDWR | O_CLOEXEC);
    if (descriptor < 0 && errno == ENOENT) return -1;
    if (descriptor < 0) {
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno),
                     "could not open Delta Chat account lock: %s",
                     g_strerror (errno));
        return -1;
    }
    if (flock (descriptor, LOCK_EX | LOCK_NB) != 0) {
        int saved_errno = errno;
        close (descriptor);
        g_set_error_literal (
            error, G_IO_ERROR, G_IO_ERROR_BUSY,
            saved_errno == EWOULDBLOCK || saved_errno == EAGAIN
                ? "Delta Chat is still using the accounts; close Parla before locking"
                : "could not lock the Delta Chat accounts");
        return -1;
    }
    return descriptor;
#endif
}

void
safestore_release_accounts_guard (int descriptor)
{
#if !defined(G_OS_WIN32) && !defined(SAFESTORE_NO_PTY)
    if (descriptor >= 0) {
        flock (descriptor, LOCK_UN);
        close (descriptor);
    }
#endif
}

/*
 * Info-ZIP deliberately reads encryption passwords from a terminal.  This
 * helper gives it a private controlling pseudo-terminal, waits until echo is
 * disabled and the English "password:" prompt appears, and only then writes
 * the secret.  The secret is never placed in argv or the environment.
 */
gboolean
safestore_run_pty_password (gchar **argv,
                            const gchar *cwd,
                            const gchar *password,
                            gboolean confirm,
                            gchar **output,
                            GError **error)
{
#if defined(G_OS_WIN32) || defined(SAFESTORE_NO_PTY)
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                         "private ZIP password channel is unavailable on this platform");
    return FALSE;
#else
    int master = -1;
    gchar *program = g_find_program_in_path (argv[0]);
    if (program == NULL) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                     "executable was not found: %s", argv[0]);
        return FALSE;
    }
    gchar **environment = g_get_environ ();
    environment = g_environ_setenv (environment, "LC_ALL", "C", TRUE);
    pid_t child = forkpty (&master, NULL, NULL, NULL);
    if (child < 0) {
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno),
                     "could not create private password terminal: %s",
                     g_strerror (errno));
        g_free (program);
        g_strfreev (environment);
        return FALSE;
    }
    if (child == 0) {
        if (chdir (cwd) != 0) _exit (126);
        execve (program, argv, environment);
        _exit (127);
    }
    g_free (program);
    g_strfreev (environment);

    GString *text = g_string_new (NULL);
    guint prompts = 0;
    guint required = confirm ? 2 : 1;
    gboolean ok = TRUE;
    gint64 prompt_deadline = g_get_monotonic_time () + 30 * G_TIME_SPAN_SECOND;
    char buffer[4096];

    while (TRUE) {
        int timeout = prompts < required ? 250 : -1;
        struct pollfd item = { master, POLLIN | POLLHUP, 0 };
        int polled = poll (&item, 1, timeout);
        if (polled < 0 && errno == EINTR) continue;
        if (polled < 0) {
            ok = FALSE;
            g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno),
                         "could not read ZIP password terminal: %s",
                         g_strerror (errno));
            break;
        }
        if (polled == 0) {
            if (prompts < required
                    && g_get_monotonic_time () > prompt_deadline) {
                ok = FALSE;
                g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                                     "ZIP did not request a password");
                break;
            }
        }

        // A prompt can arrive before echo is disabled. Recheck it on timeout.
        ssize_t count = polled > 0 ? read (master, buffer, sizeof buffer) : 0;
        if (count > 0 || polled == 0) {
            if (count > 0) g_string_append_len (text, buffer, count);
            gchar *lower = g_ascii_strdown (text->str, text->len);
            gboolean rejected = strstr (lower, "reenter:") != NULL
                || strstr (lower, "incorrect password") != NULL;
            guint found = 0;
            const gchar *cursor = lower;
            while ((cursor = strstr (cursor, "password:")) != NULL) {
                found++;
                cursor += strlen ("password:");
            }
            if (rejected) {
                g_free (lower);
                ok = FALSE;
                g_set_error_literal (error, G_IO_ERROR,
                                     G_IO_ERROR_PERMISSION_DENIED,
                                     "ZIP password was rejected");
                break;
            }
            g_free (lower);
            while (prompts < found && prompts < required) {
                struct termios attributes;
                if (tcgetattr (master, &attributes) != 0
                        || (attributes.c_lflag & ECHO) != 0) {
                    break;
                }
                gsize length = strlen (password);
                if (write (master, password, length) != (ssize_t) length
                        || write (master, "\n", 1) != 1) {
                    ok = FALSE;
                    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                                         "could not send the ZIP password");
                    break;
                }
                prompts++;
            }
            if (!ok) break;
            if (found > required) {
                ok = FALSE;
                g_set_error_literal (error, G_IO_ERROR,
                                     G_IO_ERROR_PERMISSION_DENIED,
                                     "ZIP password was rejected");
                break;
            }
            continue;
        }
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count == 0 || errno == EIO) break;
        ok = FALSE;
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno),
                     "could not read ZIP output: %s", g_strerror (errno));
        break;
    }

    if (!ok) kill (child, SIGTERM);
    close (master);
    int status = 0;
    while (waitpid (child, &status, 0) < 0 && errno == EINTR) {}

    /* Defense in depth in case a nonconforming program echoed its input. */
    if (password[0] != '\0') {
        gchar **parts = g_strsplit (text->str, password, -1);
        gchar *redacted = g_strjoinv ("[password redacted]", parts);
        g_strfreev (parts);
        g_string_assign (text, redacted);
        g_free (redacted);
    }
    if (output != NULL) *output = g_string_free (text, FALSE);
    else g_string_free (text, TRUE);

    if (!ok) return FALSE;
    if (!WIFEXITED (status) || WEXITSTATUS (status) != 0) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                     "ZIP process exited with status %d",
                     WIFEXITED (status) ? WEXITSTATUS (status) : 1);
        return FALSE;
    }
    if (prompts < required) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                             "ZIP process did not complete password entry");
        return FALSE;
    }
    return TRUE;
#endif
}
