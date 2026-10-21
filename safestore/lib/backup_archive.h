#pragma once
#include <gio/gio.h>

typedef struct _SafeStoreArchive SafeStoreArchive;
gboolean safestore_archive_available (void);
SafeStoreArchive *safestore_archive_new (const gchar *path, gboolean create,
    const gchar *password, GCancellable *cancel, GError **error);
void safestore_archive_free (SafeStoreArchive *self);
gboolean safestore_archive_add_file (SafeStoreArchive *self, const gchar *name,
    const gchar *path, GError **error);
gboolean safestore_archive_add_text (SafeStoreArchive *self, const gchar *name,
    const gchar *text, GError **error);
gboolean safestore_archive_finish (SafeStoreArchive *self, GError **error);
gint64 safestore_archive_count (SafeStoreArchive *self);
gchar *safestore_archive_name (SafeStoreArchive *self, guint64 index, GError **error);
guint64 safestore_archive_size (SafeStoreArchive *self, const gchar *name, GError **error);
gchar *safestore_archive_read_text (SafeStoreArchive *self, const gchar *name,
    guint64 limit, GError **error);
gchar *safestore_archive_read_file (SafeStoreArchive *self, const gchar *name,
    const gchar *destination, guint64 expected_size, GError **error);
gboolean safestore_backup_sync (const gchar *path, gboolean directory, GError **error);
gboolean safestore_backup_publish (const gchar *source, const gchar *destination, GError **error);
gboolean safestore_archive_replace (const gchar *source, const gchar *destination, GError **error);
gboolean safestore_backup_mkdir (const gchar *path, GError **error);
gchar *safestore_backup_resolve_directory (const gchar *path, GError **error);
