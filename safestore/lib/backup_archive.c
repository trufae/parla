#include "backup_archive.h"
#include "pty_password.h"
#include <glib/gstdio.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdlib.h>
#ifdef G_OS_WIN32
#include <windows.h>
#include <sddl.h>
#include <io.h>
#else
#include <unistd.h>
#include <stdio.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#endif
#ifdef HAVE_BACKUP_ZIP
#include <zip.h>

struct _SafeStoreArchive {
    zip_t *zip;
    SafeStoreSecretMemory *password;
    GCancellable *cancel;
};

static gboolean zip_failure (SafeStoreArchive *self, GError **error)
{
    if (self->cancel && g_cancellable_set_error_if_cancelled (self->cancel, error)) return FALSE;
    int code = zip_error_code_zip (zip_get_error (self->zip));
    g_set_error (error, G_IO_ERROR,
        code == ZIP_ER_WRONGPASSWD ? G_IO_ERROR_PERMISSION_DENIED : G_IO_ERROR_INVALID_DATA,
        "Encrypted backup: %s", zip_strerror (self->zip));
    return FALSE;
}

static int cancelled (zip_t *zip, void *data)
{
    (void) zip;
    SafeStoreArchive *self = data;
    return self->cancel && g_cancellable_is_cancelled (self->cancel);
}

gboolean safestore_archive_available (void)
{
    return zip_encryption_method_supported (ZIP_EM_AES_256, 1)
        && zip_encryption_method_supported (ZIP_EM_AES_256, 0);
}

SafeStoreArchive *safestore_archive_new (const gchar *path, gboolean create,
    const gchar *password, GCancellable *cancel, GError **error)
{
    if (!safestore_archive_available ()) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "AES-256 backup support is unavailable");
        return NULL;
    }
    int code;
    zip_t *zip = zip_open (path, create ? ZIP_CREATE | ZIP_EXCL : ZIP_RDONLY | ZIP_CHECKCONS, &code);
    if (!zip) {
        zip_error_t ze;
        zip_error_init_with_code (&ze, code);
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Could not open backup: %s", zip_error_strerror (&ze));
        zip_error_fini (&ze);
        return NULL;
    }
    SafeStoreArchive *self = g_new0 (SafeStoreArchive, 1);
    self->zip = zip;
    self->password = safestore_secret_memory_new (password);
    self->cancel = cancel ? g_object_ref (cancel) : NULL;
    if (create && zip_register_cancel_callback_with_state (zip, cancelled, NULL, self) < 0) {
        zip_failure (self, error);
        safestore_archive_free (self);
        return NULL;
    }
    return self;
}

void safestore_archive_free (SafeStoreArchive *self)
{
    if (!self) return;
    if (self->zip) zip_discard (self->zip);
    safestore_secret_memory_unref (self->password);
    g_clear_object (&self->cancel);
    g_free (self);
}

static gboolean add_source (SafeStoreArchive *self, const gchar *name, zip_source_t *source, GError **error)
{
    if (!source) return zip_failure (self, error);
    zip_int64_t index = zip_file_add (self->zip, name, source, ZIP_FL_ENC_UTF_8);
    if (index < 0) {
        zip_source_free (source);
        return zip_failure (self, error);
    }
    if (zip_file_set_encryption (self->zip, index, ZIP_EM_AES_256,
            safestore_secret_memory_peek (self->password)) < 0
            || zip_set_file_compression (self->zip, index, ZIP_CM_DEFLATE, 6) < 0)
        return zip_failure (self, error);
    return TRUE;
}

gboolean safestore_archive_add_file (SafeStoreArchive *self, const gchar *name,
    const gchar *path, GError **error)
{
    return add_source (self, name, zip_source_file (self->zip, path, 0, -1), error);
}

gboolean safestore_archive_add_text (SafeStoreArchive *self, const gchar *name,
    const gchar *text, GError **error)
{
    gchar *copy = g_strdup (text);
    zip_source_t *source = zip_source_buffer (self->zip, copy, strlen (copy), 1);
    if (!source) g_free (copy);
    return add_source (self, name, source, error);
}

gboolean safestore_archive_finish (SafeStoreArchive *self, GError **error)
{
    if (zip_close (self->zip) < 0) return zip_failure (self, error);
    self->zip = NULL;
    return TRUE;
}

gint64 safestore_archive_count (SafeStoreArchive *self) { return zip_get_num_entries (self->zip, 0); }

gchar *safestore_archive_name (SafeStoreArchive *self, guint64 index, GError **error)
{
    const gchar *name = zip_get_name (self->zip, index, ZIP_FL_ENC_STRICT);
    if (!name) { zip_failure (self, error); return NULL; }
    return g_strdup (name);
}

guint64 safestore_archive_size (SafeStoreArchive *self, const gchar *name, GError **error)
{
    zip_stat_t stat;
    if (zip_stat (self->zip, name, ZIP_FL_ENC_UTF_8, &stat) < 0) { zip_failure (self, error); return 0; }
    if (!(stat.valid & ZIP_STAT_ENCRYPTION_METHOD) || stat.encryption_method != ZIP_EM_AES_256
            || !(stat.valid & ZIP_STAT_SIZE)) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Every backup entry must use AES-256 encryption");
        return 0;
    }
    return stat.size;
}

/* Reading to EOF checks both the encrypted authentication tag and the ZIP CRC.
 * Return a hash only after those checks; callers compare the encrypted manifest. */
static gboolean read_entry (SafeStoreArchive *self, const gchar *name, guint64 expected,
    GOutputStream *output, GChecksum *hash, GError **error)
{
    zip_file_t *file = zip_fopen_encrypted (self->zip, name, 0, safestore_secret_memory_peek (self->password));
    if (!file) return zip_failure (self, error);
    guint8 buffer[65536];
    guint64 total = 0;
    gboolean ok = FALSE;
    for (;;) {
        if (self->cancel && g_cancellable_set_error_if_cancelled (self->cancel, error)) break;
        zip_int64_t count = zip_fread (file, buffer, sizeof buffer);
        if (count < 0) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Backup authentication or decompression failed");
            break;
        }
        if (count == 0) {
            if (total == expected) ok = TRUE;
            else g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Backup entry size does not match its manifest");
            break;
        }
        if ((guint64) count > expected - total) {
            g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Backup entry exceeds its declared size");
            break;
        }
        total += count;
        if (hash) g_checksum_update (hash, buffer, count);
        if (output && !g_output_stream_write_all (output, buffer, count, NULL, self->cancel, error)) break;
    }
    if (zip_fclose (file) < 0 && ok) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Backup entry could not be verified");
        ok = FALSE;
    }
    return ok;
}

gchar *safestore_archive_read_text (SafeStoreArchive *self, const gchar *name,
    guint64 limit, GError **error)
{
    guint64 size = safestore_archive_size (self, name, error);
    if (error && *error) return NULL;
    if (size > limit) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Backup manifest is too large");
        return NULL;
    }
    GOutputStream *out = g_memory_output_stream_new_resizable ();
    gboolean ok = read_entry (self, name, size, out, NULL, error);
    if (ok) ok = g_output_stream_write_all (out, "", 1, NULL, NULL, error);
    g_output_stream_close (out, NULL, NULL);
    gchar *text = ok ? g_memory_output_stream_steal_data (G_MEMORY_OUTPUT_STREAM (out)) : NULL;
    g_object_unref (out);
    if (text && (strlen (text) != size || !g_utf8_validate (text, -1, NULL))) {
        g_free (text);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Invalid backup manifest text");
        return NULL;
    }
    return text;
}

gchar *safestore_archive_read_file (SafeStoreArchive *self, const gchar *name,
    const gchar *destination, guint64 expected_size, GError **error)
{
    guint64 size = safestore_archive_size (self, name, error);
    if (error && *error) return NULL;
    if (size != expected_size) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Backup sizes do not match");
        return NULL;
    }
    GFileOutputStream *out = NULL;
    if (destination) {
        GFile *target = g_file_new_for_path (destination);
        out = g_file_create (target, G_FILE_CREATE_PRIVATE, self->cancel, error);
        g_object_unref (target);
        if (!out) return NULL;
    }
    GChecksum *hash = g_checksum_new (G_CHECKSUM_SHA256);
    gboolean ok = read_entry (self, name, size, out ? G_OUTPUT_STREAM (out) : NULL, hash, error);
    if (out) {
        if (ok) ok = g_output_stream_close (G_OUTPUT_STREAM (out), self->cancel, error);
        g_object_unref (out);
    }
    gchar *result = ok ? g_strdup (g_checksum_get_string (hash)) : NULL;
    g_checksum_free (hash);
    return result;
}
#else
struct _SafeStoreArchive { int unused; };
gboolean safestore_archive_available (void) { return FALSE; }
#define UNAVAILABLE() g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Encrypted backups are unavailable in this build")
SafeStoreArchive *safestore_archive_new (const gchar *path, gboolean create, const gchar *password, GCancellable *cancel, GError **error) { UNAVAILABLE (); return NULL; }
void safestore_archive_free (SafeStoreArchive *self) { g_free (self); }
gboolean safestore_archive_add_file (SafeStoreArchive *self, const gchar *name, const gchar *path, GError **error) { UNAVAILABLE (); return FALSE; }
gboolean safestore_archive_add_text (SafeStoreArchive *self, const gchar *name, const gchar *text, GError **error) { UNAVAILABLE (); return FALSE; }
gboolean safestore_archive_finish (SafeStoreArchive *self, GError **error) { UNAVAILABLE (); return FALSE; }
gint64 safestore_archive_count (SafeStoreArchive *self) { return 0; }
gchar *safestore_archive_name (SafeStoreArchive *self, guint64 index, GError **error) { UNAVAILABLE (); return NULL; }
guint64 safestore_archive_size (SafeStoreArchive *self, const gchar *name, GError **error) { UNAVAILABLE (); return 0; }
gchar *safestore_archive_read_text (SafeStoreArchive *self, const gchar *name, guint64 limit, GError **error) { UNAVAILABLE (); return NULL; }
gchar *safestore_archive_read_file (SafeStoreArchive *self, const gchar *name, const gchar *destination, guint64 expected_size, GError **error) { UNAVAILABLE (); return NULL; }
#endif

gboolean safestore_backup_sync (const gchar *path, gboolean directory, GError **error)
{
#ifdef G_OS_WIN32
    /* Flush file contents before publishing. Directory handles do not support
     * FlushFileBuffers; publication uses MoveFileExW with WRITE_THROUGH below. */
    if (directory) return TRUE;
    gunichar2 *wide = g_utf8_to_utf16 (path, -1, NULL, NULL, error);
    if (!wide) return FALSE;
    HANDLE file = CreateFileW ((LPCWSTR) wide, GENERIC_WRITE, FILE_SHARE_READ, NULL,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    g_free (wide);
    gboolean ok = file != INVALID_HANDLE_VALUE && FlushFileBuffers (file);
    if (file != INVALID_HANDLE_VALUE) CloseHandle (file);
#else
    int fd = g_open (path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0), 0);
    gboolean ok = fd >= 0 && fsync (fd) == 0;
    if (fd >= 0) close (fd);
#endif
    if (!ok) g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not synchronize backup data to storage");
    return ok;
}

/* Same-filesystem, atomic, no-replace publication, including FAT/exFAT USB
 * drives (a hard-link based implementation would not work there). */
gboolean safestore_backup_publish (const gchar *source, const gchar *destination, GError **error)
{
    gboolean ok = FALSE;
#ifdef G_OS_WIN32
    gunichar2 *from = g_utf8_to_utf16 (source, -1, NULL, NULL, error);
    if (!from) return FALSE;
    gunichar2 *to = g_utf8_to_utf16 (destination, -1, NULL, NULL, error);
    if (!to) { g_free (from); return FALSE; }
    ok = MoveFileExW ((LPCWSTR) from, (LPCWSTR) to, MOVEFILE_WRITE_THROUGH);
    g_free (from); g_free (to);
#elif defined(__linux__) && defined(SYS_renameat2)
    ok = syscall (SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, 1 /* RENAME_NOREPLACE */) == 0;
#elif defined(__APPLE__)
    ok = renamex_np (source, destination, RENAME_EXCL) == 0;
#endif
    if (!ok) g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
        "Could not publish the backup safely. Choose a new filename on a supported writable drive; existing files were not replaced.");
    return ok;
}

gboolean safestore_backup_mkdir (const gchar *path, GError **error)
{
#ifdef G_OS_WIN32
    gunichar2 *wide = g_utf8_to_utf16 (path, -1, NULL, NULL, error);
    if (!wide) return FALSE;
    PSECURITY_DESCRIPTOR sd = NULL;
    /* Protected, inheritable ACL granting full access to the owner only. */
    gboolean ok = ConvertStringSecurityDescriptorToSecurityDescriptorW (
        L"D:P(A;OICI;FA;;;OW)", SDDL_REVISION_1, &sd, NULL);
    if (ok) {
        SECURITY_ATTRIBUTES attributes = { sizeof attributes, sd, FALSE };
        ok = CreateDirectoryW ((LPCWSTR) wide, &attributes);
        LocalFree (sd);
    }
    g_free (wide);
#else
    gboolean ok = g_mkdir (path, 0700) == 0;
#endif
    if (!ok) g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
        "Could not create a new private directory. Choose a writable location and a folder that does not already exist.");
    return ok;
}

gchar *safestore_backup_resolve_directory (const gchar *path, GError **error)
{
    gchar *result = NULL;
#ifdef G_OS_WIN32
    gunichar2 *wide = g_utf8_to_utf16 (path, -1, NULL, NULL, error);
    if (!wide) return NULL;
    HANDLE handle = CreateFileW ((LPCWSTR) wide, 0,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    g_free (wide);
    if (handle != INVALID_HANDLE_VALUE) {
        DWORD length = GetFinalPathNameByHandleW (handle, NULL, 0, FILE_NAME_NORMALIZED);
        if (length > 0) {
            wide = g_new0 (gunichar2, length + 1);
            DWORD written = GetFinalPathNameByHandleW (handle, (LPWSTR) wide, length + 1, FILE_NAME_NORMALIZED);
            if (written > 0 && written <= length) result = g_utf16_to_utf8 (wide, -1, NULL, NULL, NULL);
            g_free (wide);
        }
        CloseHandle (handle);
    }
#else
    char *resolved = realpath (path, NULL);
    if (resolved) { result = g_strdup (resolved); free (resolved); }
#endif
    if (!result) g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
        "Could not resolve the storage directory");
    return result;
}
