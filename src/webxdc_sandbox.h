#pragma once
#include <gio/gio.h>
G_BEGIN_DECLS
/* The launcher owns process lifetime. All returned streams are owned by the
 * caller. No backend may fall back to an unsandboxed launch. */
gpointer parla_webxdc_sandbox_launch (const char *helper,
    gboolean internet, gboolean acceleration, gboolean wasm,
    GInputStream **input, GOutputStream **output, GError **error);
void parla_webxdc_sandbox_stop (gpointer process);
void parla_webxdc_helper_stdio (GInputStream **input, GOutputStream **output);
void parla_webxdc_helper_init (gboolean internet);
void parla_webxdc_helper_run (void);
void parla_webxdc_helper_quit (void);
G_END_DECLS
