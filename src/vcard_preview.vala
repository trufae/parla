namespace Dc {

    public class VcardPreview : Gtk.Box {
        public static Gdk.Texture? thumbnail (VcardContact contact, int size = 72) {
            if (contact.image_data == null || contact.image_data.length > VcardDocument.MAX_BYTES) return null;
            try {
                var bytes = new Bytes (decode_rpc_blob (contact.image_data));
                var stream = new MemoryInputStream.from_bytes (bytes);
                var pixbuf = new Gdk.Pixbuf.from_stream_at_scale (stream, size, size, true);
                return texture_from_pixbuf (pixbuf);
            } catch (Error e) {
                return null;
            }
        }

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
                : contact.address.strip ().length > 0 ? contact.address : _("vCard contact");
            avatar.text = contact.name;
            avatar.custom_image = thumbnail (contact);
            tooltip_text = contact.address.strip ().length > 0
                ? contact.name + "\n" + contact.address : contact.name;
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
