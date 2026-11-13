#pragma once
#include <glib.h>

typedef struct ParlaTty ParlaTty;
ParlaTty *parla_tty_open (GError **error);
void parla_tty_free (ParlaTty *tty);
int parla_tty_resize_fd (ParlaTty *tty);
void parla_tty_size (ParlaTty *tty, int *width, int *height);
gboolean parla_tty_write (ParlaTty *tty, const char *text, GError **error);
