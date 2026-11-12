#include "disk_space.h"

#ifdef G_OS_WIN32
#include <windows.h>
#else
#include <sys/statvfs.h>
#endif

gboolean
parla_disk_space_query (const gchar *path, guint64 *total, guint64 *available)
{
	*total = *available = 0;
#ifdef G_OS_WIN32
	gunichar2 *wide_path = g_utf8_to_utf16 (path, -1, NULL, NULL, NULL);
	if (!wide_path) return FALSE;
	ULARGE_INTEGER size, free_bytes;
	gboolean ok = GetDiskFreeSpaceExW ((LPCWSTR) wide_path, &free_bytes, &size, NULL);
	g_free (wide_path);
	if (!ok) return FALSE;
	*total = size.QuadPart;
	*available = free_bytes.QuadPart;
#else
	struct statvfs info;
	/* One filesystem query supplies both values. Use blocks available to
	 * this user, excluding blocks reserved for the administrator. */
	if (statvfs (path, &info) != 0) return FALSE;
	*total = (guint64) info.f_blocks * info.f_frsize;
	*available = (guint64) info.f_bavail * info.f_frsize;
#endif
	return TRUE;
}
