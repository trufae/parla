namespace Dc {

    /** Semantic Delta Chat view types for outgoing attachments. */
    public class AttachmentTypes : Object {

        /** Infer semantic types that are intrinsic to an attachment format.
            Stickers are deliberately excluded: callers must mark them from
            the sticker-specific UI action, independently of their encoding. */
        public static string? infer_outgoing_view_type (
                string? file_path, string? file_name = null) {
            if (has_xdc_extension (file_path)
                || has_xdc_extension (file_name)) {
                return "Webxdc";
            }
            return null;
        }

        private static bool has_xdc_extension (string? value) {
            return value != null && value.down ().has_suffix (".xdc");
        }
    }
}
