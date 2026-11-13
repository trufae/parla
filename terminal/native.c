#include "native.h"
#include <gio/gio.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

struct ParlaTty {
    struct termios saved;
    struct sigaction winch;
    int pipefd[2];
};

static ParlaTty *active;
static volatile sig_atomic_t resize_writer = -1;

static void resized (int signum) {
    (void) signum;
    int saved_errno = errno;
    char byte = 1;
    if (resize_writer >= 0) {
        ssize_t ignored = write (resize_writer, &byte, 1);
        (void) ignored;
    }
    errno = saved_errno;
}

static gboolean write_all (const char *text) {
    size_t size = strlen (text);
    while (size) {
        ssize_t n = write (STDOUT_FILENO, text, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return FALSE;
        text += n;
        size -= n;
    }
    return TRUE;
}

static void restore_at_exit (void) {
    if (active) parla_tty_free (active);
}

void parla_tty_free (ParlaTty *tty) {
    if (!tty) return;
    resize_writer = -1;
    sigaction (SIGWINCH, &tty->winch, NULL);
    tcsetattr (STDIN_FILENO, TCSANOW, &tty->saved);
    write_all ("\033[0m\033[?7h\033[?25h\033[?1000l\033[?1006l\033[?2004l\033[?1049l");
    close (tty->pipefd[0]);
    close (tty->pipefd[1]);
    active = NULL;
    g_free (tty);
}

ParlaTty *parla_tty_open (GError **error) {
    const char *term = g_getenv ("TERM");
    if (active || !isatty (STDIN_FILENO) || !isatty (STDOUT_FILENO) ||
        !term || !strcmp (term, "dumb")) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
            "The terminal UI needs an interactive ANSI terminal (TERM must not be dumb)");
        return NULL;
    }
    ParlaTty *tty = g_new0 (ParlaTty, 1);
    if (tcgetattr (STDIN_FILENO, &tty->saved) < 0) goto fail;
    if (pipe (tty->pipefd) < 0) goto fail;
    for (int i = 0; i < 2; i++) {
        if (fcntl (tty->pipefd[i], F_SETFL, O_NONBLOCK) < 0 ||
            fcntl (tty->pipefd[i], F_SETFD, FD_CLOEXEC) < 0) goto fail_pipe;
    }
    struct sigaction action = {0};
    action.sa_handler = resized;
    sigemptyset (&action.sa_mask);
    if (sigaction (SIGWINCH, &action, &tty->winch) < 0) goto fail_pipe;
    struct termios raw = tty->saved;
    cfmakeraw (&raw);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr (STDIN_FILENO, TCSANOW, &raw) < 0) {
        sigaction (SIGWINCH, &tty->winch, NULL);
        goto fail_pipe;
    }
    active = tty;
    resize_writer = tty->pipefd[1];
    static gboolean registered;
    if (!registered) { atexit (restore_at_exit); registered = TRUE; }
    if (!write_all ("\033[?1049h\033[?2004h\033[?1000h\033[?1006h\033[?7l")) {
        int saved_errno = errno;
        parla_tty_free (tty);
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (saved_errno), "%s", g_strerror (saved_errno));
        return NULL;
    }
    return tty;
fail_pipe:
    {
        int saved_errno = errno;
        close (tty->pipefd[0]); close (tty->pipefd[1]);
        errno = saved_errno;
    }
fail:
    g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "%s", g_strerror (errno));
    g_free (tty);
    return NULL;
}

int parla_tty_resize_fd (ParlaTty *tty) { return tty->pipefd[0]; }

void parla_tty_size (ParlaTty *tty, int *width, int *height) {
    char bytes[128];
    while (read (tty->pipefd[0], bytes, sizeof bytes) > 0) {}
    struct winsize size = {0};
    if (ioctl (STDOUT_FILENO, TIOCGWINSZ, &size) < 0) memset (&size, 0, sizeof size);
    *width = CLAMP (size.ws_col ? size.ws_col : 80, 1, 1000);
    *height = CLAMP (size.ws_row ? size.ws_row : 24, 1, 500);
}

gboolean parla_tty_write (ParlaTty *tty, const char *text, GError **error) {
    (void) tty;
    if (write_all (text)) return TRUE;
    g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "%s", g_strerror (errno));
    return FALSE;
}
