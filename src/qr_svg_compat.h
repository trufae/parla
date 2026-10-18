#ifndef PARLA_QR_SVG_COMPAT_H
#define PARLA_QR_SVG_COMPAT_H

#include <gtk/gtk.h>

#if GTK_CHECK_VERSION(4, 22, 0)
static void
parla_qr_svg_error (GtkSvg *svg, GError *error, GError **result)
{
	if (!*result) *result = g_error_copy (error);
}
#endif

/* Android has no SVG pixbuf loader. Use GTK's built-in SVG paintable when
 * available; select in C because the cross-build uses the host's older VAPI. */
static inline GdkPaintable *
parla_qr_svg_from_bytes (GBytes *bytes, GError **error)
{
#if GTK_CHECK_VERSION(4, 22, 0)
	GtkSvg *svg = gtk_svg_new ();
	GError *load_error = NULL;
	gulong handler = g_signal_connect (svg, "error",
		G_CALLBACK (parla_qr_svg_error), &load_error);
	gtk_svg_load_from_bytes (svg, bytes);
	g_signal_handler_disconnect (svg, handler);
	if (load_error) {
		g_propagate_error (error, load_error);
		g_object_unref (svg);
		return NULL;
	}
	return GDK_PAINTABLE (svg);
#else
	GdkTexture *texture = gdk_texture_new_from_bytes (bytes, error);
	return texture ? GDK_PAINTABLE (texture) : NULL;
#endif
}

#endif
