namespace Dc {

#if MACOS
    /** Decode only a still frame in a worker, independent of GTK's optional
        media backend. Keep a small memory cache; no extra files on disk. */
    internal class VideoThumbnail : Object {
        private static HashTable<string, Gdk.Texture>? cache = null;

        [CCode (cname = "parla_video_thumbnail_async",
                finish_name = "parla_video_thumbnail_finish",
                cheader_filename = "platform.h")]
        private static extern async Gdk.Pixbuf? generate (string path,
                                                        Cancellable? cancellable = null);

        public static async void load (string path, Gtk.Picture? target) {
            // Keep the weak ref local: valac clears owned struct parameters
            // both on return and when freeing the async task (double clear).
            WeakRef picture_ref = WeakRef (target);
            target = null; // Do not keep a removed preview alive across yield.
            if (cache == null) cache = new HashTable<string, Gdk.Texture> (
                str_hash, str_equal);
            Gdk.Texture? texture = cache.lookup (path);
            if (texture == null) {
                var pixbuf = yield generate (path);
                if (pixbuf == null) return;
                texture = texture_from_pixbuf (pixbuf);
                if (cache.size () >= 32) cache.remove_all ();
                cache.insert (path, texture);
            }
            var picture = picture_ref.get () as Gtk.Picture;
            if (picture != null) picture.paintable = texture;
        }
    }
#endif

    [CCode (lower_case_cprefix = "parla_pixbuf_animation_",
            cheader_filename = "pixbuf_animation_compat.h")]
    namespace PixbufAnimationCompat {
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern Gdk.PixbufAnimation load (string path) throws Error;
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern unowned Gdk.Pixbuf get_static_image (
            Gdk.PixbufAnimation animation);
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern Gdk.PixbufAnimationIter get_iter (
            Gdk.PixbufAnimation animation);
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern unowned Gdk.Pixbuf iter_get_pixbuf (
            Gdk.PixbufAnimationIter iter);
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern int iter_get_delay_time (Gdk.PixbufAnimationIter iter);
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern bool iter_advance (Gdk.PixbufAnimationIter iter);
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern bool is_static_image (Gdk.PixbufAnimation animation);
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern int get_width (Gdk.PixbufAnimation animation);
        [CCode (cheader_filename = "pixbuf_animation_compat.h")]
        internal extern int get_height (Gdk.PixbufAnimation animation);
    }

    /** Static first frame of an image file, downscaled to fit max_px in
        both dimensions (never upscaled). PixbufAnimation copes with
        animated GIF/WebP, where Pixbuf.from_file_at_scale refuses
        multi-frame files (stickers, typically). */
    internal Gdk.Pixbuf scaled_frame_from_file (string path,
                                                int max_px) throws Error {
        var anim = PixbufAnimationCompat.load (path);
        return scaled_frame_from_animation (anim, max_px);
    }

    internal Gdk.Pixbuf scaled_frame_from_animation (
            Gdk.PixbufAnimation anim, int max_px) {
        Gdk.Pixbuf frame = PixbufAnimationCompat.get_static_image (anim);
        double scale = double.min (1.0, double.min (
            (double) max_px / frame.width,
            (double) max_px / frame.height));
        if (scale < 1.0) {
            frame = frame.scale_simple (
                int.max (1, (int) (frame.width * scale + 0.5)),
                int.max (1, (int) (frame.height * scale + 0.5)),
                Gdk.InterpType.BILINEAR);
        }
        return frame;
    }

    internal Gdk.Texture texture_from_pixbuf (Gdk.Pixbuf pixbuf) {
        var format = pixbuf.has_alpha
            ? Gdk.MemoryFormat.R8G8B8A8
            : Gdk.MemoryFormat.R8G8B8;

        return new Gdk.MemoryTexture (
            pixbuf.width,
            pixbuf.height,
            format,
            pixbuf.read_pixel_bytes (),
            pixbuf.rowstride);
    }
}
