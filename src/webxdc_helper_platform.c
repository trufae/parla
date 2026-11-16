#include "webxdc_sandbox.h"
#ifdef _WIN32
#include <windows.h>
#include <gio/gwin32inputstream.h>
#include <gio/gwin32outputstream.h>
#else
#include <signal.h>
#include <gio/gunixinputstream.h>
#include <gio/gunixoutputstream.h>
#endif
#ifdef __linux__
#include <adwaita.h>
#include <seccomp.h>
#include <sys/socket.h>
#include <errno.h>
#include <stdlib.h>
#endif

void parla_webxdc_helper_stdio (GInputStream **input, GOutputStream **output)
{
#ifdef _WIN32
    *input = g_win32_input_stream_new (GetStdHandle (STD_INPUT_HANDLE), FALSE);
    *output = g_win32_output_stream_new (GetStdHandle (STD_OUTPUT_HANDLE), FALSE);
#else
    signal (SIGPIPE, SIG_IGN);
    *input = g_unix_input_stream_new (0, FALSE);
    *output = g_unix_output_stream_new (1, FALSE);
#endif
}

#ifndef __APPLE__
static GMainLoop *loop;
#ifdef _WIN32
static gboolean pump (gpointer data)
{
    (void)data;
    MSG msg;
    while (PeekMessageW (&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage (&msg);
        DispatchMessageW (&msg);
    }
    return G_SOURCE_CONTINUE;
}
#endif
void parla_webxdc_helper_init (gboolean internet)
{
#ifdef __linux__
    scmp_filter_ctx filter = seccomp_init (SCMP_ACT_ALLOW);
    if (!filter) exit (1);
    const char *blocked[] = { "ptrace", "process_vm_readv", "process_vm_writev",
        "keyctl", "add_key", "request_key", "bpf", "perf_event_open", "userfaultfd",
        "io_uring_setup", "io_uring_enter", "io_uring_register", NULL };
    for (int i = 0; blocked[i]; i++) {
        int syscall = seccomp_syscall_resolve_name (blocked[i]);
        if (syscall != __NR_SCMP_ERROR && seccomp_rule_add (filter, SCMP_ACT_ERRNO (EPERM), syscall, 0) < 0) exit (1);
    }
    if (!internet) {
        if (seccomp_rule_add (filter, SCMP_ACT_ERRNO (EPERM), SCMP_SYS (socket), 1,
                SCMP_A0 (SCMP_CMP_EQ, AF_INET)) < 0 ||
            seccomp_rule_add (filter, SCMP_ACT_ERRNO (EPERM), SCMP_SYS (socket), 1,
                SCMP_A0 (SCMP_CMP_EQ, AF_INET6)) < 0) exit (1);
    }
    if (seccomp_load (filter) < 0) exit (1);
    seccomp_release (filter);
    adw_init ();
#else
    (void)internet;
    g_timeout_add (10, pump, NULL);
#endif
    loop = g_main_loop_new (NULL, FALSE);
}
void parla_webxdc_helper_run (void) { g_main_loop_run (loop); }
void parla_webxdc_helper_quit (void) { g_main_loop_quit (loop); }
#endif
