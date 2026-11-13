namespace Dc {
    public class SettingsFonts {
        public static void save_description (SettingsManager settings, Pango.FontDescription desc) {
            string family = desc.get_family () ?? "";
            settings.save_font (family, attribute_from_font_description (desc),
                       size_from_font_description (desc));
        }

        public static int system_font_size () {
            string font_name = system_font_name ();
            var desc = Pango.FontDescription.from_string (font_name);
            int size = size_from_font_description (desc);
            return size > 0 ? SettingsManager.clamp_font_size (size) : FONT_SIZE_FALLBACK;
        }

        public static int effective_size (SettingsManager settings) {
            return settings.font_size > 0 ? settings.font_size : system_font_size ();
        }

        public static Pango.FontDescription description (SettingsManager settings) {
            var desc = Pango.FontDescription.from_string (
                settings.font_family.length > 0 ? settings.font_family : system_font_name ());
            desc.set_style (settings.font_attribute.css_style () == "italic" ? Pango.Style.ITALIC : Pango.Style.NORMAL);
            desc.set_weight (settings.font_attribute.css_weight () == "bold" ? Pango.Weight.BOLD : Pango.Weight.NORMAL);
            desc.set_size (effective_size (settings) * Pango.SCALE);
            return desc;
        }

        private static string system_font_name () {
            var gtk_settings = Gtk.Settings.get_default ();
            if (gtk_settings == null || gtk_settings.gtk_font_name.length == 0) {
                return "Sans %d".printf (FONT_SIZE_FALLBACK);
            }
            return gtk_settings.gtk_font_name;
        }

        private static int size_from_font_description (
                Pango.FontDescription desc) {
            int size = desc.get_size ();
            if (size <= 0) return FONT_SIZE_SYSTEM;
            return (size + (Pango.SCALE / 2)) / Pango.SCALE;
        }

        private static FontAttribute attribute_from_font_description (
                Pango.FontDescription desc) {
            bool italic = desc.get_style () == Pango.Style.ITALIC ||
                desc.get_style () == Pango.Style.OBLIQUE;
            bool bold = ((int) desc.get_weight ()) >=
                ((int) Pango.Weight.BOLD);
            if (italic && bold) return FontAttribute.BOLD_ITALIC;
            if (italic) return FontAttribute.ITALIC;
            if (bold) return FontAttribute.BOLD;
            return FontAttribute.REGULAR;
        }

    }
}
