namespace Dc {

    /* Mono AAC recorder. macOS records natively through AVAudioRecorder
       (Platform.audio_recorder_*); elsewhere a GStreamer or FFmpeg child
       process writes the file. */
    public class AudioRecorder : Object {

        public string output_path { get; private set; default = ""; }

        private bool prefer_external;
        private bool tried_gstreamer;
        private bool tried_ffmpeg;
        private bool using_ffmpeg;
        private Subprocess? process;
        private void* native = null;
        private bool stop_requested;
        private bool timed_out;
        private uint stop_timeout;

        public signal void completed ();
        public signal void failed (string message);

        public AudioRecorder (bool prefer_external) {
            this.prefer_external = prefer_external;
        }

        public void start () throws Error {
            if (process != null || native != null || output_path.length > 0)
                throw new IOError.BUSY ("An audio recording is already active");

            FileIOStream stream;
            output_path = File.new_tmp (
                "parla-voice-XXXXXX.m4a", out stream).get_path ();
            stream.close ();
            /* The recorder creates the file itself; an empty leftover would
               otherwise pass as a finished recording. */
            FileUtils.unlink (output_path);

            if (Platform.audio_recorder_supported ()) {
                native = Platform.audio_recorder_new (
                    output_path, on_native_event, this);
                if (native == null) {
                    discard_output ();
                    throw new IOError.FAILED (
                        "The system audio recorder could not be created");
                }
                return;
            }
            if (!spawn_next ()) {
                discard_output ();
                throw new IOError.NOT_SUPPORTED (
                    "Install GStreamer or FFmpeg to record voice messages");
            }
        }

        public void stop () {
            if (stop_requested) return;
            if (native != null) {
                stop_requested = true;
                Platform.audio_recorder_stop (native);
                arm_stop_timeout ();
                return;
            }

            var active = process;
            if (active == null) return;

            stop_requested = true;
            if (using_ffmpeg) {
                try {
                    var input = active.get_stdin_pipe ();
                    if (input != null) {
                        size_t written;
                        input.write_all ("q\n".data, out written);
                        input.close ();
                    }
                } catch (Error e) {
                    active.force_exit ();
                }
            } else {
#if WINDOWS
                active.force_exit ();
#else
                /* gst-launch -e converts SIGINT to EOS and finalizes mp4mux. */
                active.send_signal ((int) Posix.Signal.INT);
#endif
            }
            arm_stop_timeout ();
        }

        public string take_output () {
            string path = output_path;
            output_path = "";
            return path;
        }

        public void cancel () {
            clear_stop_timeout ();
            release_native ();
            var active = process;
            process = null;
            if (active != null) active.force_exit ();
            discard_output ();
        }

        /* A backend that ignores the stop request would leave the composer
           stuck on "Finishing recording…"; give up after a grace period. */
        private void arm_stop_timeout () {
            var active = process;
            stop_timeout = Timeout.add_seconds (8, () => {
                stop_timeout = 0;
                if (native != null) {
                    timed_out = true;
                    release_native ();
                    finish_stopped ();
                } else if (active != null && process == active) {
                    timed_out = true;
                    active.force_exit ();
                }
                return Source.REMOVE;
            });
        }

        private void release_native () {
            if (native == null) return;
            Platform.audio_recorder_free (native);
            native = null;
        }

        private static void on_native_event (bool completed, string? message,
                                             void* user_data) {
            /* Hold a reference: handlers of failed() may drop the recorder. */
            AudioRecorder self = (AudioRecorder) user_data;
            if (self.native == null) return;
            self.release_native ();
            self.clear_stop_timeout ();

            if (!completed) {
                self.discard_output ();
                self.failed (message ?? "The voice recording failed");
            } else if (!self.stop_requested) {
                self.discard_output ();
                self.failed ("The recording ended unexpectedly");
            } else {
                self.finish_stopped ();
            }
        }

        private bool spawn_next () {
            bool[] order = { prefer_external, !prefer_external };
            foreach (bool ffmpeg in order) {
                if (ffmpeg ? tried_ffmpeg : tried_gstreamer) continue;
                if (ffmpeg) tried_ffmpeg = true;
                else tried_gstreamer = true;

                string[]? argv = ffmpeg
                    ? ffmpeg_command (output_path)
                    : gstreamer_command (output_path);
                if (argv == null) continue;

                FileUtils.unlink (output_path);
                try {
                    var launcher = new SubprocessLauncher (
                        SubprocessFlags.STDIN_PIPE
                        | SubprocessFlags.STDOUT_SILENCE
                        | SubprocessFlags.STDERR_SILENCE);
                    var child = SubprocessUtil.spawnv (launcher, argv);
                    process = child;
                    using_ffmpeg = ffmpeg;
                    child.wait_async.begin (null, (obj, res) => {
                        try { child.wait_async.end (res); }
                        catch (Error e) {}
                        on_process_exit (child);
                    });
                    return true;
                } catch (Error e) {
                    warning ("audio recording: failed to spawn %s: %s",
                        argv[0], e.message);
                }
            }
            return false;
        }

        private void on_process_exit (Subprocess child) {
            if (process != child) return;
            process = null;
            clear_stop_timeout ();

            if (stop_requested) {
                finish_stopped ();
                return;
            }
            if (spawn_next ()) return;

            discard_output ();
            failed ("Could not access the microphone; check microphone "
                + "permission and the configured media tools");
        }

        private void finish_stopped () {
            if (!timed_out && output_size () > 512) {
                completed ();
                return;
            }
            discard_output ();
            failed (timed_out
                ? "Audio recording did not stop cleanly"
                : "The recording was too short or could not be encoded");
        }

        private void clear_stop_timeout () {
            if (stop_timeout == 0) return;
            Source.remove (stop_timeout);
            stop_timeout = 0;
        }

        private int64 output_size () {
            try {
                return File.new_for_path (output_path).query_info (
                    "standard::size", FileQueryInfoFlags.NONE).get_size ();
            } catch (Error e) {
                return 0;
            }
        }

        private void discard_output () {
            if (output_path.length == 0) return;
            FileUtils.unlink (take_output ());
        }

        private static string[]? gstreamer_command (string output) {
#if WINDOWS
            return null;
#else
            if (Environment.find_program_in_path ("gst-launch-1.0") == null)
                return null;
            return {
                "gst-launch-1.0", "-q", "-e",
                "autoaudiosrc", "!", "audioconvert", "!", "audioresample",
                "!", "audio/x-raw,rate=48000,channels=1", "!",
                "avenc_aac", "bitrate=64000", "!",
                "mp4mux", "faststart=true", "!",
                "filesink", "location=" + output
            };
#endif
        }

        private static string[]? ffmpeg_command (string output) {
            if (Environment.find_program_in_path ("ffmpeg") == null) return null;

#if WINDOWS
            string format = "dshow";
            string source = "audio=default";
#else
            string format = "pulse";
            string source = "default";
#endif
            return {
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostats",
                "-y", "-f", format, "-i", source, "-vn", "-ac", "1",
                "-ar", "48000", "-c:a", "aac", "-b:a", "64k",
                "-movflags", "+faststart", output
            };
        }
    }
}
