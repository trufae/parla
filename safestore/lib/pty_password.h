#pragma once

#include <gio/gio.h>

typedef struct _SafeStoreSecretMemory SafeStoreSecretMemory;

SafeStoreSecretMemory *safestore_secret_memory_new (const gchar *value);
SafeStoreSecretMemory *safestore_secret_memory_ref (SafeStoreSecretMemory *self);
void safestore_secret_memory_unref (SafeStoreSecretMemory *self);
const gchar *safestore_secret_memory_peek (SafeStoreSecretMemory *self);
void safestore_secret_memory_clear (SafeStoreSecretMemory *self);

gboolean safestore_run_pty_password (gchar **argv,
                                     const gchar *cwd,
                                     const gchar *password,
                                     gboolean confirm,
                                     gchar **output,
                                     GError **error);
