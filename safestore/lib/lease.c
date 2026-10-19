#include "lease.h"
#ifdef G_OS_WIN32
#include <windows.h>
struct _SafeStoreLease { HANDLE handle; };
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
struct _SafeStoreLease { int fd; };
#endif

/* Never unlink the lock file: replacing its inode would split ownership. */
SafeStoreLease *safestore_lease_new (const gchar *path, GError **error)
{
#ifdef G_OS_WIN32
    gunichar2 *wide = g_utf8_to_utf16 (path, -1, NULL, NULL, error);
    if (!wide) return NULL;
    HANDLE handle = CreateFileW ((LPCWSTR) wide, GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    g_free (wide);
    if (handle == INVALID_HANDLE_VALUE) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
            "Could not open the store ownership file");
        return NULL;
    }
    BY_HANDLE_FILE_INFORMATION info;
    OVERLAPPED overlap = {0};
    if (!GetFileInformationByHandle (handle, &info)
            || (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) {
        CloseHandle (handle);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
            "Store ownership file must be a regular file");
        return NULL;
    }
    if (!LockFileEx (handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                    0, 1, 0, &overlap)) {
        CloseHandle (handle);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_BUSY,
            "Another session owns this store");
        return NULL;
    }
    SafeStoreLease *lease = g_new0 (SafeStoreLease, 1);
    lease->handle = handle;
#else
    int fd = open (path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno),
            "Could not open store ownership file: %s", g_strerror (errno));
        return NULL;
    }
    struct stat info, named;
    if (fstat (fd, &info) != 0 || !S_ISREG (info.st_mode)
            || info.st_uid != geteuid () || info.st_nlink != 1) {
        close (fd);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
            "Store ownership file must be private and owned by this user");
        return NULL;
    }
    if (flock (fd, LOCK_EX | LOCK_NB) != 0) {
        int saved = errno;
        close (fd);
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (saved),
            "Another session owns this store: %s", g_strerror (saved));
        return NULL;
    }
    if (lstat (path, &named) != 0 || named.st_dev != info.st_dev
            || named.st_ino != info.st_ino || fchmod (fd, 0600) != 0) {
        close (fd);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
            "Store ownership file changed while acquiring it");
        return NULL;
    }
    SafeStoreLease *lease = g_new0 (SafeStoreLease, 1);
    lease->fd = fd;
#endif
    return lease;
}

void safestore_lease_free (SafeStoreLease *lease)
{
    if (!lease) return;
#ifdef G_OS_WIN32
    CloseHandle (lease->handle);
#else
    close (lease->fd);
#endif
    g_free (lease);
}
