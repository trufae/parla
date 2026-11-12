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
            if (is_vcard (file_path, file_name)) return "Vcard";
            return null;
        }

        public static bool is_vcard (string? path, string? name = null,
                                     string? mime = null) {
            string type = mime ?? "";
            int separator = type.index_of_char (';');
            if (separator >= 0) type = type.substring (0, separator);
            type = type.strip ().down ();
            return (path ?? "").down ().has_suffix (".vcf")
                || (name ?? "").down ().has_suffix (".vcf")
                || type == "text/vcard" || type == "text/x-vcard"
                || type == "text/directory";
        }

        private static bool has_xdc_extension (string? value) {
            return value != null && value.down ().has_suffix (".xdc");
        }
    }
}
