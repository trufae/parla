#if !WINDOWS && !ANDROID
/* The POSIX VAPI only exposes execv/execvp. Pass the original environment
   explicitly so a language override never leaks into the restarted app. */
[CCode (cname = "execve", cheader_filename = "unistd.h")]
private extern int exec_with_environment (string path,
    [CCode (array_length = false, array_null_terminated = true)] string[] argv,
    [CCode (array_length = false, array_null_terminated = true)] string[] envp);
#endif

int main (string[] args) {
#if ANDROID
    Dc.Platform.setup_android_environment ();
#endif
    /* Keep restart independent of language and bundle environment overrides. */
#if !ANDROID
    string[] original_environment = Environ.get ();
#endif
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

    Dc.Localization.initialize (Dc.SettingsManager.load_language ());
    /* Preserve the message locale selected above when GTK initializes. */
    Gtk.disable_setlocale ();

    var app = new Dc.Application ();
    int status = app.run (args);
    bool restart = app.restart_requested;
    /* Release single-instance registration and stop the core before relaunch. */
    app.rpc.stop ();
    app = null;
    if (restart) {
#if ANDROID
        // GTK is loaded by Android, not an executable we can execve.
        return status;
#else
        string? executable = Dc.Platform.get_executable_path ();
#if !MACOS && !WINDOWS
        /* Relaunch the outer AppImage, whose mount belongs to this process. */
        executable = Environment.get_variable ("APPIMAGE") ?? executable;
#endif
        if (executable != null) {
            string[] restart_args = { executable, "--show" };
#if WINDOWS
            try {
                Pid pid;
                Process.spawn_async (null, restart_args, original_environment, 0,
                                     null, out pid);
            } catch (SpawnError e) {
                warning ("Unable to restart Parla: %s", e.message);
                return 1;
            }
#else
            exec_with_environment (executable, restart_args, original_environment);
            warning ("Unable to restart Parla: %s", strerror (errno));
            return 1;
#endif
        } else {
            warning ("Unable to find the Parla executable for restart");
            return 1;
        }
#endif
    }
    return status;
}
