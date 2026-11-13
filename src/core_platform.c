#include "platform.h"

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

#if !defined(__APPLE__)
gchar *
parla_get_system_languages (void)
{
	return NULL;
}

#endif
