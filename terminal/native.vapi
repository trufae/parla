namespace Parla.Terminal {
    [Compact]
    [CCode (cheader_filename = "native.h", cname = "ParlaTty", free_function = "parla_tty_free")]
    internal class Tty {
        [CCode (cname = "parla_tty_open")]
        public Tty () throws GLib.Error;
        [CCode (cname = "parla_tty_resize_fd")]
        public int resize_fd ();
        [CCode (cname = "parla_tty_size")]
        public void size (out int width, out int height);
        [CCode (cname = "parla_tty_write")]
        public bool write (string text) throws GLib.Error;
    }
}
