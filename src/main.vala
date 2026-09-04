int main (string[] args) {
#if SAILFISHOS || !A11Y
    /* Sailfish OS has no AT-SPI accessibility bus, and -Da11y=false builds
       opt out of assistive technology entirely. Select GTK's supported
       no-a11y backend before Adw.Application can initialize GTK; otherwise
       every launch waits for D-Bus and prints a misleading warning. */
    Environment.set_variable ("GTK_A11Y", "none", true);
#endif
    Dc.Platform.setup_macos_bundle_environment ();

    /* GTK derives the Wayland surface app_id (and the X11 WM_CLASS) from
       the program name, and GNOME matches that against the desktop file
       to label the window in the Alt+Tab switcher and the dash. Pin it to
       the desktop-file id so the switcher reads "Parla" instead of the
       raw id; a human-readable name is set for contexts that show one
       (#57). Both must precede GTK initialization. */
    if (Environment.get_prgname () == null) {
        Environment.set_prgname ("io.github.trufae.Parla");
    }
    Environment.set_application_name ("Parla");

    var app = new Dc.Application ();
    return app.run (args);
}
