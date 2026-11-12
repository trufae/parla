namespace Dc {

    /** Core supplies the same metadata for messages and parsed VCF files.
        profileImage is embedded base64 here, unlike Contact.profile_image. */
    public class VcardContact : Object {
        public string name { get; private set; }
        public string address { get; private set; }
        public string? image_data { get; private set; }

        public VcardContact (Json.Object obj) {
            address = json_str (obj, "addr") ?? "";
            name = json_str (obj, "displayName") ?? address;
            if (name.length == 0) name = address;
            image_data = json_str (obj, "profileImage");
        }

        public Gdk.Texture? thumbnail (int size = 72) {
            if (image_data == null || image_data.length > VcardDocument.MAX_BYTES) return null;
            try {
                var bytes = new Bytes (decode_rpc_blob (image_data));
                var stream = new MemoryInputStream.from_bytes (bytes);
                var pixbuf = new Gdk.Pixbuf.from_stream_at_scale (stream, size, size, true);
                return texture_from_pixbuf (pixbuf);
            } catch (Error e) {
                return null;
            }
        }
    }

    /** Preview and import use the same immutable snapshot. Opening a file
        never adds contacts; only the viewer's explicit import action does. */
    public class VcardDocument : Object {
        public const int MAX_BYTES = 4 * 1024 * 1024;
        public string contents { get; private set; }
        public string filename { get; private set; default = "contact.vcf"; }
        public GenericArray<VcardContact> contacts = new GenericArray<VcardContact> ();

        public static async VcardDocument load (RpcClient rpc, File file) throws Error {
            var stream = yield file.read_async ();
            var buffer = new ByteArray ();
            try {
                while (true) {
                    var bytes = yield stream.read_bytes_async (65536);
                    if (bytes.get_size () == 0) break;
                    if (buffer.len + bytes.get_size () > MAX_BYTES)
                        throw new IOError.INVALID_DATA (_("Contact file is too large (maximum 4 MiB)."));
                    buffer.append (bytes.get_data ());
                }
            } finally {
                try { yield stream.close_async (); }
                catch (Error e) { /* Preserve the original read error. */ }
            }
            uint length = buffer.len;
            buffer.append ({ 0 });
            string text = (string) buffer.data;
            if (length == 0 || text.length != length || !text.validate ())
                throw new IOError.INVALID_DATA (_("Contact file is empty or is not valid UTF-8."));
            return yield from_contents (rpc, text, file.get_basename () ?? "contact.vcf");
        }

        public static async VcardDocument from_contents (RpcClient rpc, string text,
                                                         string name = "contact.vcf") throws Error {
            if (text.length > MAX_BYTES || !text.validate ())
                throw new IOError.INVALID_DATA (_("Invalid or oversized contact file."));
            var doc = new VcardDocument ();
            doc.contents = text;
            doc.filename = AttachmentTypes.is_vcard (name) ? Path.get_basename (name) : "contact.vcf";
            string path = doc.write_temp ();
            try {
                var items = yield rpc.parse_vcard (path);
                if (items != null) {
                    for (uint i = 0; i < items.get_length (); i++) {
                        var item = items.get_element (i);
                        if (item.get_node_type () == Json.NodeType.OBJECT) {
                            var contact = new VcardContact (item.get_object ());
                            if (contact.address.strip ().length > 0) doc.contacts.add (contact);
                        }
                    }
                }
                if (doc.contacts.length == 0)
                    throw new IOError.INVALID_DATA (_("No supported contacts found. A vCard must contain an email address."));
            } finally {
                FileUtils.unlink (path);
            }
            return doc;
        }

        /** The caller takes ownership and must remove the temporary file. */
        public string write_temp () throws Error {
            FileIOStream stream;
            var file = File.new_tmp ("parla-contact-XXXXXX.vcf", out stream);
            string path = file.get_path ();
            try {
                size_t written;
                stream.output_stream.write_all (contents.data, out written);
                stream.close ();
            } catch (Error e) {
                FileUtils.unlink (path);
                throw e;
            }
            return path;
        }
    }

    public class VcardPreview : Gtk.Box {
        private Adw.Avatar avatar;
        private Gtk.Label name_label;
        private Gtk.Label detail_label;

        public VcardPreview (VcardContact? contact = null, string? fallback = null) {
            Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 12);
            hexpand = true;
            avatar = new Adw.Avatar (48, "", true);
            avatar.icon_name = "avatar-default-symbolic";
            append (avatar);
            var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
            labels.valign = Gtk.Align.CENTER;
            labels.hexpand = true;
            name_label = new Gtk.Label (fallback ?? _("Contact card"));
            name_label.xalign = 0;
            name_label.ellipsize = Pango.EllipsizeMode.END;
            name_label.max_width_chars = 28;
            name_label.add_css_class ("heading");
            labels.append (name_label);
            detail_label = new Gtk.Label (_("vCard contact"));
            detail_label.xalign = 0;
            detail_label.ellipsize = Pango.EllipsizeMode.END;
            detail_label.max_width_chars = 32;
            detail_label.add_css_class ("dim-label");
            labels.append (detail_label);
            append (labels);
            if (contact != null) set_contact (contact);
        }

        public void set_contact (VcardContact contact, uint count = 1) {
            name_label.label = contact.name;
            detail_label.label = count > 1
                ? ngettext ("%u contact", "%u contacts", count).printf (count)
                : contact.address;
            avatar.text = contact.name;
            avatar.custom_image = contact.thumbnail ();
            tooltip_text = contact.name + "\n" + contact.address;
        }

        public async void load (RpcClient rpc, string path) {
            try {
                var doc = yield VcardDocument.load (rpc, File.new_for_path (path));
                set_contact (doc.contacts[0], doc.contacts.length);
            } catch (Error e) {
                detail_label.label = _("Could not preview contact");
                tooltip_text = e.message;
            }
        }
    }
}
