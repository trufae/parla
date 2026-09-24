int main (string[] args) {
#if SAILFISHOS || !A11Y
    /* Sailfish OS has no AT-SPI accessibility bus, and -Da11y=false builds
       opt out of assistive technology entirely. Select GTK's supported
       no-a11y backend before Adw.Application can initialize GTK; otherwise
       every launch waits for D-Bus and prints a misleading warning. */
    Environment.set_variable ("GTK_A11Y", "none", true);
#endif
    Dc.Platform.setup_macos_bundle_environment ();

    // X11 uses this as WM_CLASS and as the switcher's uninstalled-app name.
    // GtkApplication supplies the desktop-file ID separately on Wayland.
    if (Environment.get_prgname () == null) {
        Environment.set_prgname ("Parla");
    }
    Environment.set_application_name ("Parla");

    var app = new Dc.Application ();
    return app.run (args);
}
