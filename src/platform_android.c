#include "platform.h"

/* Pixiewood already exports this GLib helper for GTK's Android runtime.
 * Override GTK's external-storage defaults before Parla loads any settings:
 * account databases and encryption keys belong in internal app storage. */
void g_set_user_dirs (const gchar *first_dir_type, ...) G_GNUC_NULL_TERMINATED;

void
parla_setup_android_environment (void)
{
	const gchar *files = g_getenv ("PARLA_ANDROID_FILES");
	const gchar *cache = g_getenv ("PARLA_ANDROID_CACHE");
	if (!files || !cache) {
		g_error ("Parla's Android application did not initialize its directories");
	}
	g_autofree gchar *config = g_build_filename (files, "config", NULL);
	g_autofree gchar *data = g_build_filename (files, "data", NULL);
	g_set_user_dirs ("HOME", files,
	                 "XDG_CONFIG_HOME", config,
	                 "XDG_DATA_HOME", data,
	                 "XDG_CACHE_HOME", cache, NULL);
	g_setenv ("TMPDIR", cache, TRUE);
}
