namespace Dc.Platform {
#if ANDROID
    [CCode (cheader_filename = "platform.h", cname = "parla_setup_android_environment")]
    public extern void setup_android_environment ();
#endif

    [CCode (has_target = false)]
    public delegate void RawMacosFileDropCallback (string path, double x,
                                                   double y, void* user_data);

    [CCode (has_target = false)]
    public delegate void RawAudioFinishedCallback (bool completed,
                                                   void* user_data);

    [CCode (has_target = false)]
    public delegate void RawAudioRecorderCallback (bool completed,
                                                   string? message,
                                                   void* user_data);

    [CCode (cheader_filename = "platform.h", cname = "parla_setup_macos_bundle_environment")]
    private extern void platform_setup_macos_bundle_environment ();

    [CCode (cheader_filename = "platform.h", cname = "parla_macos_fix_window_drag")]
    private extern void platform_macos_fix_window_drag ();

    [CCode (cheader_filename = "platform.h", cname = "parla_macos_install_file_drop_handler")]
    private extern void platform_macos_install_file_drop_handler (
        Gtk.Widget widget,
        RawMacosFileDropCallback callback,
        void* user_data);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_supported")]
    private extern bool platform_audio_backend_supported ();

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_new")]
    private extern void* platform_audio_backend_new (
        string path, RawAudioFinishedCallback callback, void* user_data);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_play")]
    private extern bool platform_audio_backend_play (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_pause")]
    private extern void platform_audio_backend_pause (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_stop")]
    private extern void platform_audio_backend_stop (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_seek")]
    private extern void platform_audio_backend_seek (void* handle,
                                                     int64 position_us);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_set_rate")]
    private extern void platform_audio_backend_set_rate (void* handle,
                                                         double rate);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_get_position")]
    private extern int64 platform_audio_backend_get_position (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_get_duration")]
    private extern int64 platform_audio_backend_get_duration (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_is_playing")]
    private extern bool platform_audio_backend_is_playing (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_can_seek")]
    private extern bool platform_audio_backend_can_seek (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_backend_free")]
    private extern void platform_audio_backend_free (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_recorder_supported")]
    private extern bool platform_audio_recorder_supported ();

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_recorder_new")]
    private extern void* platform_audio_recorder_new (
        string path, RawAudioRecorderCallback callback, void* user_data);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_recorder_stop")]
    private extern void platform_audio_recorder_stop (void* handle);

    [CCode (cheader_filename = "platform.h", cname = "parla_audio_recorder_free")]
    private extern void platform_audio_recorder_free (void* handle);

    /* Background/service mode is a freedesktop pattern: it depends on
       D-Bus-based single-instance ownership and activation. On macOS and
       Windows `--background` degrades to a normal launch. */
    public bool supports_background_mode () {
        return !is_macos () && !is_windows () && !is_sailfish ();
    }

    public void setup_macos_bundle_environment () {
        platform_setup_macos_bundle_environment ();
    }

    /* Makes dragging the header bar move the window reliably on macOS. */
    public void fix_macos_window_drag () {
        if (is_macos ()) platform_macos_fix_window_drag ();
    }

    public void install_macos_file_drop_handler (Gtk.Widget widget,
                                                 RawMacosFileDropCallback callback,
                                                 void* user_data) {
        if (!is_macos ()) return;
        platform_macos_install_file_drop_handler (widget, callback, user_data);
    }

    public bool audio_backend_supported () {
        return platform_audio_backend_supported ();
    }

    public void* audio_backend_new (string path,
                                    RawAudioFinishedCallback callback,
                                    void* user_data) {
        return platform_audio_backend_new (path, callback, user_data);
    }

    public bool audio_backend_play (void* handle) {
        return platform_audio_backend_play (handle);
    }

    public void audio_backend_pause (void* handle) {
        platform_audio_backend_pause (handle);
    }

    public void audio_backend_stop (void* handle) {
        platform_audio_backend_stop (handle);
    }

    public void audio_backend_seek (void* handle, int64 position_us) {
        platform_audio_backend_seek (handle, position_us);
    }

    public void audio_backend_set_rate (void* handle, double rate) {
        platform_audio_backend_set_rate (handle, rate);
    }

    public int64 audio_backend_get_position (void* handle) {
        return platform_audio_backend_get_position (handle);
    }

    public int64 audio_backend_get_duration (void* handle) {
        return platform_audio_backend_get_duration (handle);
    }

    public bool audio_backend_is_playing (void* handle) {
        return platform_audio_backend_is_playing (handle);
    }

    public bool audio_backend_can_seek (void* handle) {
        return platform_audio_backend_can_seek (handle);
    }

    public void audio_backend_free (void* handle) {
        platform_audio_backend_free (handle);
    }

    /* Native voice recorder (AVAudioRecorder on macOS). The callback runs on
       the main loop, after audio_recorder_new returned, and exactly once. */
    public bool audio_recorder_supported () {
        return platform_audio_recorder_supported ();
    }

    public void* audio_recorder_new (string path,
                                     RawAudioRecorderCallback callback,
                                     void* user_data) {
        return platform_audio_recorder_new (path, callback, user_data);
    }

    public void audio_recorder_stop (void* handle) {
        platform_audio_recorder_stop (handle);
    }

    public void audio_recorder_free (void* handle) {
        platform_audio_recorder_free (handle);
    }

    public bool has_primary_modifier (Gdk.ModifierType state) {
        var mask = is_macos () ? Gdk.ModifierType.META_MASK
                               : Gdk.ModifierType.CONTROL_MASK;
        return (state & mask) != 0;
    }


}
