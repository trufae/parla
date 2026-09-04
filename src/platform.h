#pragma once

#include <glib.h>

typedef struct _GtkWidget GtkWidget;

typedef void (*ParlaMacosFileDropCallback) (const gchar *path,
                                            gdouble      x,
                                            gdouble      y,
                                            gpointer     user_data);

typedef void (*ParlaAudioFinishedCallback) (gboolean completed,
                                            gpointer user_data);

gchar *parla_get_executable_path (void);
gboolean parla_platform_is_macos (void);
void parla_setup_macos_bundle_environment (void);
void parla_macos_install_file_drop_handler (GtkWidget                  *widget,
                                            ParlaMacosFileDropCallback  callback,
                                            gpointer                    user_data);

/*
 * Rate-aware audio playback. macOS implements this with AVAudioEngine; other
 * platforms use GstPlay when its runtime library is available. The opaque
 * handle is owned by the caller and must be released with
 * parla_audio_backend_free(). Times use GLib/GTK's microsecond convention.
 */
gboolean parla_audio_backend_supported (void);
gpointer parla_audio_backend_new (const gchar                *path,
                                  ParlaAudioFinishedCallback  callback,
                                  gpointer                    user_data);
gboolean parla_audio_backend_play (gpointer handle);
void parla_audio_backend_pause (gpointer handle);
void parla_audio_backend_stop (gpointer handle);
void parla_audio_backend_seek (gpointer handle, gint64 position_us);
void parla_audio_backend_set_rate (gpointer handle, gdouble rate);
gint64 parla_audio_backend_get_position (gpointer handle);
gint64 parla_audio_backend_get_duration (gpointer handle);
gboolean parla_audio_backend_is_playing (gpointer handle);
gboolean parla_audio_backend_can_seek (gpointer handle);
void parla_audio_backend_free (gpointer handle);

/*
 * Voice-message recording. macOS records mono AAC with AVAudioRecorder
 * after asking for microphone access; other platforms report no native
 * recorder and spawn GStreamer or FFmpeg instead. The callback runs on the
 * main loop and fires once: completed=TRUE after parla_audio_recorder_stop()
 * once the file is closed, or completed=FALSE with a user-facing message
 * when recording could not start or broke down.
 */
typedef void (*ParlaAudioRecorderCallback) (gboolean     completed,
                                            const gchar *message,
                                            gpointer     user_data);

gboolean parla_audio_recorder_supported (void);
gpointer parla_audio_recorder_new (const gchar                *path,
                                   ParlaAudioRecorderCallback  callback,
                                   gpointer                    user_data);
void parla_audio_recorder_stop (gpointer handle);
void parla_audio_recorder_free (gpointer handle);

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
