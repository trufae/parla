#pragma once

#include <glib.h>

gboolean parla_disk_space_query (const gchar *path, guint64 *total, guint64 *available);
