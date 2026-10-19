#pragma once
#include <gio/gio.h>
typedef struct _SafeStoreLease SafeStoreLease;
SafeStoreLease *safestore_lease_new (const gchar *path, GError **error);
void safestore_lease_free (SafeStoreLease *lease);
