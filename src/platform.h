#pragma once

#include <glib.h>

typedef struct _GtkWidget GtkWidget;

typedef void (*ParlaMacosFileDropCallback) (const gchar *path,
                                            gdouble      x,
                                            gdouble      y,
                                            gpointer     user_data);

gchar *parla_get_executable_path (void);
gboolean parla_platform_is_macos (void);
void parla_setup_macos_bundle_environment (void);
void parla_macos_install_file_drop_handler (GtkWidget                  *widget,
                                            ParlaMacosFileDropCallback  callback,
                                            gpointer                    user_data);

#ifdef _WIN32
#include <gio/gio.h>

/*
 * GLib's g_spawn on win32 goes through the CRT spawn functions, which do
 * not set STARTF_USESTDHANDLES: a console child of a GUI parent then gets
 * a fresh console window and reads/writes that console instead of the
 * pipes. This CreateProcessW wrapper wires the std handles explicitly and
 * passes CREATE_NO_WINDOW so no console flashes up.
 */
gboolean parla_win32_spawn (const gchar * const  *argv,
                            const gchar          *cwd,
                            const gchar          *env_name,
                            const gchar          *env_value,
                            gboolean              with_stdin,
                            void                **process_out,
                            GOutputStream       **stdin_out,
                            GInputStream        **stdout_out,
                            GInputStream        **stderr_out,
                            GError              **error);

/* Wait up to timeout_ms; returns the exit code or -1 on timeout/failure. */
gint parla_win32_process_wait_sync (void *process, guint timeout_ms);
void parla_win32_process_terminate (void *process);
void parla_win32_process_free (void *process);
#endif
