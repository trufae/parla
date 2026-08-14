namespace Dc.Platform {
    [CCode (has_target = false)]
    public delegate void RawMacosFileDropCallback (string path, double x,
                                                   double y, void* user_data);

    [CCode (cheader_filename = "platform.h", cname = "parla_get_executable_path")]
    private extern string? platform_get_executable_path ();

    [CCode (cheader_filename = "platform.h", cname = "parla_platform_is_macos")]
    private extern bool platform_is_macos ();

    [CCode (cheader_filename = "platform.h", cname = "parla_setup_macos_bundle_environment")]
    private extern void platform_setup_macos_bundle_environment ();

    [CCode (cheader_filename = "platform.h", cname = "parla_macos_install_file_drop_handler")]
    private extern void platform_macos_install_file_drop_handler (
        Gtk.Widget widget,
        RawMacosFileDropCallback callback,
        void* user_data);

#if WINDOWS
    [CCode (cheader_filename = "platform.h", cname = "parla_win32_spawn")]
    private extern bool win32_spawn (
        [CCode (array_length = false, array_null_terminated = true,
                type = "const gchar * const *")]
        string[] argv,
        string? cwd,
        string? env_name,
        string? env_value,
        bool with_stdin,
        out void* process,
        out GLib.OutputStream? stdin_stream,
        out GLib.InputStream? stdout_stream,
        out GLib.InputStream? stderr_stream) throws GLib.Error;

    [CCode (cheader_filename = "platform.h", cname = "parla_win32_process_wait_sync")]
    private extern int win32_process_wait_sync (void* process, uint timeout_ms);

    [CCode (cheader_filename = "platform.h", cname = "parla_win32_process_terminate")]
    private extern void win32_process_terminate (void* process);

    [CCode (cheader_filename = "platform.h", cname = "parla_win32_process_free")]
    private extern void win32_process_free (void* process);

    /**
     * Spawn a console child with hidden window and piped stdio. GSubprocess
     * cannot be used on Windows: GLib's CRT-based spawn leaves the child
     * attached to a fresh console instead of the pipes (see platform.h).
     */
    public void spawn_hidden (string[] argv, string? cwd,
                              string? env_name, string? env_value,
                              out void* process,
                              out GLib.OutputStream? stdin_stream,
                              out GLib.InputStream? stdout_stream,
                              out GLib.InputStream? stderr_stream) throws GLib.Error {
        win32_spawn (argv, cwd, env_name, env_value, true,
                     out process, out stdin_stream, out stdout_stream,
                     out stderr_stream);
    }

    public void process_terminate (void* process) {
        win32_process_terminate (process);
    }

    public void process_free (void* process) {
        win32_process_free (process);
    }

    public class RunResult {
        public int status;
        public string output = "";
        public string errout = "";
    }

    /** Run a command hidden, collect stdout/stderr and the exit code. */
    public async RunResult run_hidden (string[] argv) throws GLib.Error {
        void* process;
        GLib.OutputStream? child_in;
        GLib.InputStream? child_out;
        GLib.InputStream? child_err;
        win32_spawn (argv, null, null, null, false,
                     out process, out child_in, out child_out, out child_err);

        var result = new RunResult ();
        int remaining = 2;
        SourceFunc resume = run_hidden.callback;
        read_all_text.begin (child_out, (obj, res) => {
            result.output = read_all_text.end (res);
            if (--remaining == 0) resume ();
        });
        read_all_text.begin (child_err, (obj, res) => {
            result.errout = read_all_text.end (res);
            if (--remaining == 0) resume ();
        });
        yield;

        /* Both pipes hit EOF, so the child is gone or exiting; the wait
           only fetches the exit code and guards against stragglers. */
        result.status = win32_process_wait_sync (process, 5000);
        win32_process_free (process);
        return result;
    }

    private async string read_all_text (GLib.InputStream stream) {
        var sb = new StringBuilder ();
        try {
            while (true) {
                var bytes = yield stream.read_bytes_async (
                    8192, GLib.Priority.DEFAULT, null);
                var data = bytes.get_data ();
                if (data.length == 0) break;
                sb.append_len ((string) data, data.length);
            }
        } catch (GLib.Error e) {
            /* EOF-equivalent: return what was read. */
        }
        return sb.str;
    }
#endif

    public string? get_executable_path () {
        return platform_get_executable_path ();
    }

    public bool is_macos () {
        return platform_is_macos ();
    }

    public bool is_windows () {
#if WINDOWS
        return true;
#else
        return false;
#endif
    }

    /* Background/service mode is a freedesktop pattern: it depends on
       D-Bus-based single-instance ownership and activation. On macOS and
       Windows `--background` degrades to a normal launch. */
    public bool supports_background_mode () {
        return !is_macos () && !is_windows ();
    }

    public void setup_macos_bundle_environment () {
        platform_setup_macos_bundle_environment ();
    }

    public void install_macos_file_drop_handler (Gtk.Widget widget,
                                                 RawMacosFileDropCallback callback,
                                                 void* user_data) {
        if (!is_macos ()) return;
        platform_macos_install_file_drop_handler (widget, callback, user_data);
    }

    public bool has_primary_modifier (Gdk.ModifierType state) {
        var mask = is_macos () ? Gdk.ModifierType.META_MASK
                               : Gdk.ModifierType.CONTROL_MASK;
        return (state & mask) != 0;
    }

    public string primary_accelerator_prefix () {
        return is_macos () ? "<Meta>" : "<Control>";
    }

    public string primary_shortcut_text (string key) {
        return "%s+%s".printf (is_macos () ? "Command" : "Ctrl", key);
    }
}
