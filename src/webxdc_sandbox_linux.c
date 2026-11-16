#include "webxdc_sandbox.h"
#include <gio/gunixsocketaddress.h>
#include <unistd.h>

static void add (GPtrArray *args, const char *value) { g_ptr_array_add (args, g_strdup (value)); }
static void bind_ro (GPtrArray *args, const char *path)
{
    if (!g_file_test (path, G_FILE_TEST_EXISTS)) return;
    add (args, "--ro-bind"); add (args, path); add (args, path);
}

gpointer parla_webxdc_sandbox_launch (const char *helper, gboolean internet, gboolean acceleration, gboolean wasm,
    GInputStream **input, GOutputStream **output, GError **error)
{
    *input = NULL; *output = NULL;
    const char *display = g_getenv ("WAYLAND_DISPLAY");
    if (!display || !*display) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
            "Sandboxed Webxdc requires a Wayland session. Direct X11 access would expose other applications.");
        return NULL;
    }
    /* Forward one connected Wayland descriptor, never the session bus,
     * X11 socket, runtime directory, or parent's environment. */
    g_autofree char *socket_path = g_path_is_absolute (display) ? g_strdup (display)
        : g_build_filename (g_get_user_runtime_dir (), display, NULL);
    g_autoptr(GSocket) socket = g_socket_new (G_SOCKET_FAMILY_UNIX, G_SOCKET_TYPE_STREAM, 0, error);
    g_autoptr(GSocketAddress) address = g_unix_socket_address_new (socket_path);
    if (!socket || !g_socket_connect (socket, address, NULL, error)) return NULL;
    int display_fd = dup (g_socket_get_fd (socket));
    if (display_fd < 0) {
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Cannot forward Wayland: %s", g_strerror (errno));
        return NULL;
    }
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new (
        G_SUBPROCESS_FLAGS_STDIN_PIPE | G_SUBPROCESS_FLAGS_STDOUT_PIPE);
    g_subprocess_launcher_take_fd (launcher, display_fd, 3);
    g_autoptr(GPtrArray) args = g_ptr_array_new_with_free_func (g_free);
    gboolean flatpak = g_file_test ("/.flatpak-info", G_FILE_TEST_EXISTS);
    if (flatpak) {
        add (args, "/usr/bin/flatpak-spawn");
        add (args, "--sandbox"); add (args, "--watch-bus"); add (args, "--clear-env");
        add (args, "--forward-fd=3"); add (args, "--directory=/");
        if (!internet) add (args, "--no-network");
        if (acceleration) add (args, "--sandbox-flag=share-gpu");
        add (args, "--env=WAYLAND_SOCKET=3"); add (args, "--env=GDK_BACKEND=wayland");
        add (args, "--env=GTK_A11Y=none"); add (args, "--env=GIO_USE_VFS=local");
        add (args, "--env=PATH=/app/bin:/usr/bin");
        add (args, wasm ? "--env=JSC_useWasm=true" : "--env=JSC_useWasm=false");
        if (!acceleration) add (args, "--env=GSK_RENDERER=cairo");
        add (args, helper);
    } else {
        if (!g_file_test ("/usr/bin/bwrap", G_FILE_TEST_IS_EXECUTABLE)) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                "Sandboxed Webxdc requires bubblewrap (/usr/bin/bwrap).");
            return NULL;
        }
        add (args, "/usr/bin/bwrap");
        const char *base[] = { "--unshare-all", "--die-with-parent", "--new-session",
            "--cap-drop", "ALL", "--clearenv",
            "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
            "--dir", "/home/webxdc", "--dir", "/run/webxdc", "--chdir", "/", NULL };
        for (int i = 0; base[i]; i++) add (args, base[i]);
        if (internet) add (args, "--share-net");
        const char *paths[] = { "/usr", "/bin", "/lib", "/lib64", "/sys", "/etc/ld.so.cache",
            "/etc/fonts", "/etc/ssl/certs", "/etc/localtime", NULL };
        for (int i = 0; paths[i]; i++) bind_ro (args, paths[i]);
        if (acceleration && g_file_test ("/dev/dri", G_FILE_TEST_IS_DIR)) {
            add (args, "--dev-bind"); add (args, "/dev/dri"); add (args, "/dev/dri");
        }
        if (internet) { bind_ro (args, "/etc/resolv.conf"); bind_ro (args, "/etc/hosts"); }
        add (args, "--ro-bind"); add (args, helper); add (args, "/app/parla-webxdc");
        const char *env[] = { "HOME", "/home/webxdc", "XDG_RUNTIME_DIR", "/run/webxdc",
            "PATH", "/usr/bin:/bin", "WAYLAND_SOCKET", "3", "GDK_BACKEND", "wayland",
            "GTK_A11Y", "none", "GIO_USE_VFS", "local", "LANG", "C.UTF-8", NULL };
        for (int i = 0; env[i]; i += 2) { add (args, "--setenv"); add (args, env[i]); add (args, env[i + 1]); }
        // Some WebKitGTK versions do not enforce Wasm through CSP. JSC's
        // engine option also covers workers and is fixed before exec.
        add (args, "--setenv"); add (args, "JSC_useWasm"); add (args, wasm ? "true" : "false");
        if (!acceleration) { add (args, "--setenv"); add (args, "GSK_RENDERER"); add (args, "cairo"); }
        add (args, "--"); add (args, "/app/parla-webxdc");
    }
    add (args, internet ? "online" : "offline");
    g_ptr_array_add (args, NULL);
    GSubprocess *process = g_subprocess_launcher_spawnv (launcher, (const char * const *)args->pdata, error);
    if (!process) return NULL;
    *input = g_object_ref (g_subprocess_get_stdout_pipe (process));
    *output = g_object_ref (g_subprocess_get_stdin_pipe (process));
    return process;
}

void parla_webxdc_sandbox_stop (gpointer process)
{
    /* Do not depend on a compromised helper honoring SIGTERM. Killing the
     * launcher tears down bubblewrap's PID namespace; Flatpak's --watch-bus
     * ties the child to the launcher's portal connection. */
    g_subprocess_force_exit (process);
    g_subprocess_wait_async (process, NULL, NULL, NULL);
    g_object_unref (process);
}
