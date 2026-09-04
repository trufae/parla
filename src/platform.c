#include "platform.h"

#include <glib-object.h>
#include <gmodule.h>

#if defined(__APPLE__)
# include <mach-o/dyld.h>
# include <glib/gstdio.h>
# include <stdlib.h>
# include <string.h>
#elif defined(__linux__)
# include <limits.h>
# include <unistd.h>
#elif defined(_WIN32)
# include <windows.h>
#endif

gchar *
parla_get_executable_path (void)
{
#if defined(__APPLE__)
	char probe[1];
	uint32_t size = sizeof (probe);
	if (_NSGetExecutablePath (probe, &size) == 0) {
		return g_strdup (probe);
	}

	char *path = g_malloc0 (size + 1);
	if (_NSGetExecutablePath (path, &size) != 0) {
		g_free (path);
		return NULL;
	}

	char *resolved = realpath (path, NULL);
	if (resolved != NULL) {
		gchar *result = g_strdup (resolved);
		free (resolved);
		g_free (path);
		return result;
	}

	return path;
#elif defined(__linux__)
	char path[PATH_MAX + 1];
	ssize_t size = readlink ("/proc/self/exe", path, sizeof (path) - 1);
	if (size < 0) {
		return NULL;
	}
	path[size] = '\0';
	return g_strdup (path);
#elif defined(_WIN32)
	wchar_t path[MAX_PATH];
	DWORD size = GetModuleFileNameW (NULL, path, MAX_PATH);
	if (size == 0 || size >= MAX_PATH) {
		return NULL;
	}
	return g_utf16_to_utf8 ((gunichar2 *) path, -1, NULL, NULL, NULL);
#else
	return NULL;
#endif
}

gboolean
parla_platform_is_macos (void)
{
#if defined(__APPLE__)
	return TRUE;
#else
	return FALSE;
#endif
}

#if defined(__APPLE__)
static void
prepend_env_path (const gchar *name, const gchar *path)
{
	const gchar *old_value = g_getenv (name);
	if (old_value && *old_value) {
		g_autofree gchar *value = g_strconcat (path, G_SEARCHPATH_SEPARATOR_S, old_value, NULL);
		g_setenv (name, value, TRUE);
	} else {
		g_setenv (name, path, TRUE);
	}
}

static gchar **
pixbuf_query_argv (const gchar *query_path, const gchar *loaders_dir)
{
	GDir *dir = g_dir_open (loaders_dir, 0, NULL);
	if (!dir) {
		return NULL;
	}

	GPtrArray *argv = g_ptr_array_new_with_free_func (g_free);
	guint loaders = 0;
	g_ptr_array_add (argv, g_strdup (query_path));

	const gchar *name;
	while ((name = g_dir_read_name (dir)) != NULL) {
		if (g_str_has_suffix (name, ".so")) {
			g_ptr_array_add (argv, g_build_filename (loaders_dir, name, NULL));
			loaders++;
		}
	}
	g_dir_close (dir);

	if (loaders == 0) {
		g_ptr_array_free (argv, TRUE);
		return NULL;
	}

	g_ptr_array_add (argv, NULL);
	return (gchar **) g_ptr_array_free (argv, FALSE);
}

static gboolean
cache_covers_loaders (const gchar *cache_path, const gchar *loaders_dir)
{
	g_autofree gchar *contents = NULL;
	if (!g_file_get_contents (cache_path, &contents, NULL, NULL)) {
		return FALSE;
	}

	GDir *dir = g_dir_open (loaders_dir, 0, NULL);
	if (!dir) {
		return FALSE;
	}

	gboolean complete = TRUE;
	const gchar *name;
	while ((name = g_dir_read_name (dir)) != NULL) {
		if (!g_str_has_suffix (name, ".so")) {
			continue;
		}
		g_autofree gchar *path = g_build_filename (loaders_dir, name, NULL);
		if (strstr (contents, path) == NULL) {
			complete = FALSE;
			break;
		}
	}
	g_dir_close (dir);
	return complete;
}

static gchar *
macos_cache_root (void)
{
	const gchar *xdg_cache_home = g_getenv ("XDG_CACHE_HOME");
	if (xdg_cache_home && *xdg_cache_home) {
		return g_strdup (xdg_cache_home);
	}

	const gchar *home = g_get_home_dir ();
	if (home && *home) {
		return g_build_filename (home, "Library", "Caches", NULL);
	}

	return g_strdup (g_get_tmp_dir ());
}

static void
setup_pixbuf_cache (const gchar *resources_dir)
{
	g_autofree gchar *loaders_dir = g_build_filename (
		resources_dir, "lib", "gdk-pixbuf-2.0", "2.10.0", "loaders", NULL);
	g_autofree gchar *query_path = g_build_filename (
		resources_dir, "bin", "gdk-pixbuf-query-loaders", NULL);

	if (!g_file_test (loaders_dir, G_FILE_TEST_IS_DIR) ||
	    !g_file_test (query_path, G_FILE_TEST_IS_EXECUTABLE)) {
		return;
	}

	g_autofree gchar *cache_root = macos_cache_root ();
	g_autofree gchar *cache_dir = g_build_filename (cache_root, "Parla", NULL);
	g_autofree gchar *cache_path = g_build_filename (
		cache_dir, "gdk-pixbuf-loaders.cache", NULL);

	if (g_mkdir_with_parents (cache_dir, 0700) == 0 &&
	    !cache_covers_loaders (cache_path, loaders_dir)) {
		g_auto(GStrv) argv = pixbuf_query_argv (query_path, loaders_dir);
		g_autofree gchar *stdout_data = NULL;
		gint wait_status = 0;

		if (argv &&
		    g_spawn_sync (NULL, argv, NULL, G_SPAWN_DEFAULT, NULL, NULL,
		                  &stdout_data, NULL, &wait_status, NULL) &&
		    wait_status == 0 &&
		    stdout_data != NULL) {
			g_file_set_contents (cache_path, stdout_data, -1, NULL);
		} else {
			g_unlink (cache_path);
		}
	}

	if (g_file_test (cache_path, G_FILE_TEST_EXISTS)) {
		g_setenv ("GDK_PIXBUF_MODULE_FILE", cache_path, TRUE);
	}
	g_setenv ("GDK_PIXBUF_MODULEDIR", loaders_dir, TRUE);
}
#endif

void
parla_setup_macos_bundle_environment (void)
{
#if defined(__APPLE__)
	g_autofree gchar *exe_path = parla_get_executable_path ();
	if (!exe_path) {
		return;
	}

	g_autofree gchar *macos_dir = g_path_get_dirname (exe_path);
	g_autofree gchar *macos_base = g_path_get_basename (macos_dir);
	if (g_strcmp0 (macos_base, "MacOS") != 0) {
		return;
	}

	g_autofree gchar *contents_dir = g_path_get_dirname (macos_dir);
	g_autofree gchar *contents_base = g_path_get_basename (contents_dir);
	if (g_strcmp0 (contents_base, "Contents") != 0) {
		return;
	}

	g_autofree gchar *resources_dir = g_build_filename (contents_dir, "Resources", NULL);
	if (!g_file_test (resources_dir, G_FILE_TEST_IS_DIR)) {
		return;
	}

	g_autofree gchar *share_dir = g_build_filename (resources_dir, "share", NULL);
	g_autofree gchar *schema_dir = g_build_filename (
		share_dir, "glib-2.0", "schemas", NULL);
	g_autofree gchar *gio_modules_dir = g_build_filename (
		resources_dir, "lib", "gio", "modules", NULL);

	prepend_env_path ("XDG_DATA_DIRS", share_dir);
	g_setenv ("GSETTINGS_SCHEMA_DIR", schema_dir, TRUE);
	g_setenv ("GTK_DATA_PREFIX", resources_dir, TRUE);
	g_setenv ("GTK_EXE_PREFIX", contents_dir, TRUE);
	g_setenv ("GTK_PATH", resources_dir, TRUE);
	g_setenv ("GIO_EXTRA_MODULES", gio_modules_dir, TRUE);
	setup_pixbuf_cache (resources_dir);
#endif
}

#if !defined(__APPLE__)
void
parla_macos_install_file_drop_handler (GtkWidget                  *widget,
                                       ParlaMacosFileDropCallback  callback,
                                       gpointer                    user_data)
{
	(void) widget;
	(void) callback;
	(void) user_data;
}

/* Keep GstPlay optional at link time. GTK installations commonly provide it,
 * but Parla can still fall back to GtkMediaFile or a system player when they
 * do not. GstPlay's API has been stable since its 1.20 introduction. */
typedef gpointer (*ParlaGstPlayNew) (gpointer renderer);
typedef void (*ParlaGstPlaySetUri) (gpointer play, const gchar *uri);
typedef void (*ParlaGstPlayAction) (gpointer play);
typedef void (*ParlaGstPlaySeek) (gpointer play, guint64 position_ns);
typedef void (*ParlaGstPlaySetRate) (gpointer play, gdouble rate);
typedef guint64 (*ParlaGstPlayGetTime) (gpointer play);
typedef gpointer (*ParlaGstPlayGetBus) (gpointer play);
typedef gboolean (*ParlaGstPlayIsMessage) (gpointer message);
typedef void (*ParlaGstPlayParseType) (gpointer message, gint *type);
typedef gboolean (*ParlaGstBusFunc) (gpointer bus, gpointer message,
                                     gpointer user_data);
typedef guint (*ParlaGstBusAddWatch) (gpointer bus, ParlaGstBusFunc callback,
                                     gpointer user_data);
typedef void (*ParlaGstBusSetFlushing) (gpointer bus, gboolean flushing);

typedef struct {
	ParlaGstPlayNew play_new;
	ParlaGstPlaySetUri set_uri;
	ParlaGstPlayAction play;
	ParlaGstPlayAction pause;
	ParlaGstPlayAction stop;
	ParlaGstPlaySeek seek;
	ParlaGstPlaySetRate set_rate;
	ParlaGstPlayGetTime get_position;
	ParlaGstPlayGetTime get_duration;
	ParlaGstPlayGetBus get_message_bus;
	ParlaGstPlayIsMessage is_play_message;
	ParlaGstPlayParseType parse_message_type;
	ParlaGstBusAddWatch bus_add_watch;
	ParlaGstBusSetFlushing bus_set_flushing;
} ParlaGstPlayApi;

typedef struct {
	gpointer play;
	gpointer bus;
	guint bus_watch;
	gboolean playing;
	ParlaAudioFinishedCallback callback;
	gpointer user_data;
} ParlaGstAudioBackend;

static ParlaGstPlayApi gst_play_api;
static GModule *gst_play_module;
static GModule *gstreamer_module;
static gboolean gst_play_checked;
static gboolean gst_play_available;

static GModule *
parla_open_first_module (const gchar * const *names)
{
	for (guint i = 0; names[i] != NULL; i++) {
		GModule *module = g_module_open (names[i], G_MODULE_BIND_LAZY);
		if (module != NULL) {
			return module;
		}
	}
	return NULL;
}

static gboolean
parla_load_symbol (GModule *module, const gchar *name, gpointer *target)
{
	return module != NULL && g_module_symbol (module, name, target);
}

#define PARLA_LOAD_PLAY(member, name) \
	parla_load_symbol (gst_play_module, name, (gpointer *) &gst_play_api.member)
#define PARLA_LOAD_GST(member, name) \
	parla_load_symbol (gstreamer_module, name, (gpointer *) &gst_play_api.member)

static gboolean
parla_load_gst_play (void)
{
	if (gst_play_checked) {
		return gst_play_available;
	}
	gst_play_checked = TRUE;

	if (!g_module_supported ()) {
		return FALSE;
	}

#if defined(_WIN32)
	const gchar *play_names[] = {
		"libgstplay-1.0-0.dll", "libgstplay-1.0.dll", NULL
	};
	const gchar *gst_names[] = {
		"libgstreamer-1.0-0.dll", "libgstreamer-1.0.dll", NULL
	};
#else
	const gchar *play_names[] = {
		"libgstplay-1.0.so.0", "libgstplay-1.0.so", NULL
	};
	const gchar *gst_names[] = {
		"libgstreamer-1.0.so.0", "libgstreamer-1.0.so", NULL
	};
#endif

	gst_play_module = parla_open_first_module (play_names);
	gstreamer_module = parla_open_first_module (gst_names);
	if (gst_play_module == NULL || gstreamer_module == NULL) {
		return FALSE;
	}

	gst_play_available =
		PARLA_LOAD_PLAY (play_new, "gst_play_new") &&
		PARLA_LOAD_PLAY (set_uri, "gst_play_set_uri") &&
		PARLA_LOAD_PLAY (play, "gst_play_play") &&
		PARLA_LOAD_PLAY (pause, "gst_play_pause") &&
		PARLA_LOAD_PLAY (stop, "gst_play_stop") &&
		PARLA_LOAD_PLAY (seek, "gst_play_seek") &&
		PARLA_LOAD_PLAY (set_rate, "gst_play_set_rate") &&
		PARLA_LOAD_PLAY (get_position, "gst_play_get_position") &&
		PARLA_LOAD_PLAY (get_duration, "gst_play_get_duration") &&
		PARLA_LOAD_PLAY (get_message_bus, "gst_play_get_message_bus") &&
		PARLA_LOAD_PLAY (is_play_message, "gst_play_is_play_message") &&
		PARLA_LOAD_PLAY (parse_message_type, "gst_play_message_parse_type") &&
		PARLA_LOAD_GST (bus_add_watch, "gst_bus_add_watch") &&
		PARLA_LOAD_GST (bus_set_flushing, "gst_bus_set_flushing");

	return gst_play_available;
}

#undef PARLA_LOAD_PLAY
#undef PARLA_LOAD_GST

static gboolean
parla_gst_audio_message (gpointer bus, gpointer message, gpointer user_data)
{
	(void) bus;
	ParlaGstAudioBackend *backend = user_data;
	if (!gst_play_api.is_play_message (message)) {
		return G_SOURCE_CONTINUE;
	}

	gint type = -1;
	gst_play_api.parse_message_type (message, &type);
	/* GstPlayMessage: END_OF_STREAM = 5, ERROR = 6. */
	if (type != 5 && type != 6) {
		return G_SOURCE_CONTINUE;
	}

	backend->playing = FALSE;
	backend->bus_watch = 0;
	ParlaAudioFinishedCallback callback = backend->callback;
	gpointer callback_data = backend->user_data;
	if (callback != NULL) {
		callback (type == 5, callback_data);
	}
	return G_SOURCE_REMOVE;
}

gboolean
parla_audio_backend_supported (void)
{
	return parla_load_gst_play ();
}

gpointer
parla_audio_backend_new (const gchar                *path,
                         ParlaAudioFinishedCallback  callback,
                         gpointer                    user_data)
{
	if (path == NULL || !parla_load_gst_play ()) {
		return NULL;
	}

	g_autofree gchar *uri = g_filename_to_uri (path, NULL, NULL);
	if (uri == NULL) {
		return NULL;
	}

	ParlaGstAudioBackend *backend = g_new0 (ParlaGstAudioBackend, 1);
	backend->play = gst_play_api.play_new (NULL);
	if (backend->play == NULL) {
		g_free (backend);
		return NULL;
	}
	backend->callback = callback;
	backend->user_data = user_data;
	gst_play_api.set_uri (backend->play, uri);
	backend->bus = gst_play_api.get_message_bus (backend->play);
	if (backend->bus != NULL) {
		backend->bus_watch = gst_play_api.bus_add_watch (
			backend->bus, parla_gst_audio_message, backend);
	}
	return backend;
}

gboolean
parla_audio_backend_play (gpointer handle)
{
	ParlaGstAudioBackend *backend = handle;
	if (backend == NULL) {
		return FALSE;
	}
	gst_play_api.play (backend->play);
	backend->playing = TRUE;
	return TRUE;
}

void
parla_audio_backend_pause (gpointer handle)
{
	ParlaGstAudioBackend *backend = handle;
	if (backend == NULL) return;
	gst_play_api.pause (backend->play);
	backend->playing = FALSE;
}

void
parla_audio_backend_stop (gpointer handle)
{
	ParlaGstAudioBackend *backend = handle;
	if (backend == NULL) return;
	gst_play_api.stop (backend->play);
	backend->playing = FALSE;
}

void
parla_audio_backend_seek (gpointer handle, gint64 position_us)
{
	ParlaGstAudioBackend *backend = handle;
	if (backend == NULL) return;
	gst_play_api.seek (backend->play,
	                   (guint64) MAX ((gint64) 0, position_us) * 1000);
}

void
parla_audio_backend_set_rate (gpointer handle, gdouble rate)
{
	ParlaGstAudioBackend *backend = handle;
	if (backend != NULL) gst_play_api.set_rate (backend->play, rate);
}

static gint64
parla_gst_time_to_us (guint64 time_ns)
{
	return time_ns == G_MAXUINT64 ? 0 : (gint64) (time_ns / 1000);
}

gint64
parla_audio_backend_get_position (gpointer handle)
{
	ParlaGstAudioBackend *backend = handle;
	return backend == NULL ? 0 : parla_gst_time_to_us (
		gst_play_api.get_position (backend->play));
}

gint64
parla_audio_backend_get_duration (gpointer handle)
{
	ParlaGstAudioBackend *backend = handle;
	return backend == NULL ? 0 : parla_gst_time_to_us (
		gst_play_api.get_duration (backend->play));
}

gboolean
parla_audio_backend_is_playing (gpointer handle)
{
	ParlaGstAudioBackend *backend = handle;
	return backend != NULL && backend->playing;
}

gboolean
parla_audio_backend_can_seek (gpointer handle)
{
	return parla_audio_backend_get_duration (handle) > 0;
}

void
parla_audio_backend_free (gpointer handle)
{
	ParlaGstAudioBackend *backend = handle;
	if (backend == NULL) return;
	if (backend->bus_watch != 0) {
		g_source_remove (backend->bus_watch);
	}
	if (backend->bus != NULL) {
		gst_play_api.bus_set_flushing (backend->bus, TRUE);
		g_object_unref (backend->bus);
	}
	gst_play_api.stop (backend->play);
	g_object_unref (backend->play);
	g_free (backend);
}

/* No native recorder outside macOS: AudioRecorder spawns gst-launch or
 * ffmpeg instead. */
gboolean
parla_audio_recorder_supported (void)
{
	return FALSE;
}

gpointer
parla_audio_recorder_new (const gchar                *path,
                          ParlaAudioRecorderCallback  callback,
                          gpointer                    user_data)
{
	(void) path;
	(void) callback;
	(void) user_data;
	return NULL;
}

void
parla_audio_recorder_stop (gpointer handle)
{
	(void) handle;
}

void
parla_audio_recorder_free (gpointer handle)
{
	(void) handle;
}
#endif
