int main (string[] args) {
#if SAILFISHOS
    /* Sailfish OS has no AT-SPI accessibility bus. Select GTK's supported
       no-a11y backend before Adw.Application can initialize GTK; otherwise
       every launch waits for D-Bus and prints a misleading warning. */
    Environment.set_variable ("GTK_A11Y", "none", true);
#endif
    Dc.Platform.setup_macos_bundle_environment ();
    var app = new Dc.Application ();
    return app.run (args);
}
