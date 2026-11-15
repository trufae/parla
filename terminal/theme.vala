namespace Parla.Terminal {
    /** Named semantic colors, using ANSI names or #RRGGBB, optionally FG:BG. */
    public class Theme : Object {
        public const string[] PRESETS = { "default", "ocean", "forest", "ember", "ansi", "mono" };
        public const string[] ROLES = { "text", "message", "timestamp", "own_nick", "nick1", "nick2", "nick3", "nick4",
            "status", "tab", "active_tab", "unread_tab", "contact", "active_contact", "open_contact", "selected_contact",
            "input", "separator", "info", "completion", "code", "accent", "error", "contact_preview", "selected_message" };
        private HashTable<string, string> colors = new HashTable<string, string> (str_hash, str_equal);
        private HashTable<string, string> encoded = new HashTable<string, string> (str_hash, str_equal);
        private bool basic;
        private const string[] names = { "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
            "bright_black", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan", "bright_white" };

        public Theme (string preset = "default") {
            basic = preset == "ansi" || preset == "mono";
            if (preset == "mono") {
                foreach (var role in ROLES) colors[role] = "default";
                return;
            }
            // Each palette follows these semantic groups; backgrounds are shared.
            string[] groups = { "text message contact input active_contact", "timestamp tab contact_preview",
                "own_nick", "nick1", "nick2", "nick3", "nick4 code unread_tab", "status",
                "open_contact info", "completion accent", "separator", "error", "selected_contact selected_message" };
            string palette;
            switch (preset) {
            case "ansi":
                palette = "default default green blue magenta cyan yellow default cyan cyan default red default";
                break;
            case "ocean":
                palette = "#cbd5e1 #94a3b8 #4ade80 #60a5fa #e879f9 #22d3ee #facc15 " +
                    "#e2e8f0 #22d3ee #38bdf8 #486581 #fb7185 #f0f9ff";
                break;
            case "forest":
                palette = "#dce8d5 #94a68c #a3e635 #93c5fd #d8b4fe #5eead4 #e9c46a " +
                    "#c5d8b9 #6ee7b7 #b7d98b #52694c #fda4af #f0fdf4";
                break;
            case "ember":
                palette = "#f1dfd1 #b39b8c #fdba74 #93c5fd #f9a8d4 #67e8f9 #fcd34d " +
                    "#e7c6aa #fda4af #fb923c #796052 #ff8f9b #fff7ed";
                break;
            default:
                palette = "#dce3ed #8e9bb0 #82dfb2 #83b9ff #e9a0d8 #7ddde8 #efca86 " +
                    "#b6c3d7 #6ddbc5 #b1a2ff #465570 #ff8f9b #ffffff";
                break;
            }
            string[] foregrounds = palette.split (" ");
            for (int i = 0; i < groups.length; i++)
                foreach (var role in groups[i].split (" ")) colors[role] = foregrounds[i];
            if (basic) { colors["active_tab"] = "default"; return; }
            colors["text"] = colors["text"] + ":#101521";
            foreach (var role in new string[] { "tab", "status", "unread_tab" }) colors[role] = colors[role] + ":#192131";
            foreach (var role in new string[] { "active_contact", "selected_contact", "selected_message" }) colors[role] = colors[role] + ":#26344d";
            colors["active_tab"] = "#101521:#b1a2ff";
        }

        public string get_color (string role) { return colors[role] ?? "default"; }

        public static bool valid_color (string value) {
            string[] parts = value.down ().split (":");
            if (parts.length > 2) return false;
            foreach (var part in parts) {
                if (part == "default") continue;
                bool valid = false;
                foreach (var name in names) if (part == name) valid = true;
                if (part.length == 7 && part[0] == '#') {
                    valid = true;
                    for (int i = 1; i < 7; i++) if (!part[i].isxdigit ()) valid = false;
                }
                if (!valid) return false;
            }
            return true;
        }

        public void set_color (string role, string value) {
            if (colors.contains (role) && valid_color (value)) {
                colors[role] = value.down ();
                encoded.remove_all ();
            }
        }

        private static string ansi_color (string value, bool background) {
            if (value == "default") return background ? ";49" : ";39";
            for (int i = 0; i < names.length; i++) if (names[i] == value)
                return ";%d".printf ((background ? 40 : 30) + (i >= 8 ? 60 : 0) + i % 8);
            uint rgb = (uint) uint64.parse (value.substring (1), 16);
            return ";%d;2;%u;%u;%u".printf (background ? 48 : 38, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
        }

        public string codes (Style style) {
            // Scanner contrast must be independent of the terminal/theme colors.
            if (Style.QR in style) return basic ? ";30;47" : ";38;2;0;0;0;48;2;255;255;255";
            string role = "text";
            if (Style.STATUS in style) role = "status";
            else if (Style.ACTIVE_TAB in style) role = "active_tab";
            else if (Style.UNREAD_TAB in style) role = "unread_tab";
            else if (Style.TAB in style) role = "tab";
            else if (Style.SELECTED in style && !(Style.MESSAGE in style)) role = "selected_contact";
            else if (Style.ACTIVE_CONTACT in style) role = "active_contact";
            else if (Style.OPEN_CONTACT in style) role = "open_contact";
            else if (Style.CONTACT in style) role = "contact";
            else if (Style.OWN_NICK in style) role = "own_nick";
            else if (Style.NICK1 in style) role = "nick1";
            else if (Style.NICK2 in style) role = "nick2";
            else if (Style.NICK3 in style) role = "nick3";
            else if (Style.NICK4 in style) role = "nick4";
            else if (Style.INPUT in style) role = "input";
            else if (Style.SEPARATOR in style) role = "separator";
            else if (Style.INFO in style) role = "info";
            else if (Style.COMPLETION in style) role = "completion";
            else if (Style.TIME in style) role = "timestamp";
            else if (Style.ERROR in style) role = "error";
            else if (Style.CODE in style) role = "code";
            else if (Style.ACCENT in style) role = "accent";
            else if (Style.MESSAGE in style) role = "message";
            bool selected_message = Style.SELECTED in style && Style.MESSAGE in style;
            bool reverse = basic && (Style.SELECTED in style || Style.ACTIVE_TAB in style || Style.ACTIVE_CONTACT in style);
            string cache_key = role + (Style.PREVIEW in style ? ":preview" : "") + (selected_message ? ":selected" : "") + (reverse ? ":reverse" : "");
            string? cached = encoded[cache_key];
            if (cached != null) return cached;
            string[] pair = get_color (role).split (":");
            string[] own = get_color ("own_nick").split (":");
            string[] base_color = get_color ("text").split (":");
            string foreground = pair[0];
            string[] preview = get_color ("contact_preview").split (":");
            if (Style.PREVIEW in style) foreground = preview[0];
            // Never let a custom remote nick reuse the configured own-nick foreground.
            if (role.has_prefix ("nick") && foreground != "default" && foreground == own[0])
                foreground = foreground == "cyan" ? "magenta" : "cyan";
            string background = pair.length == 2 ? pair[1] : base_color.length == 2 ? base_color[1] : "default";
            if (selected_message) {
                string[] selected = get_color ("selected_message").split (":");
                if (selected.length == 2) background = selected[1];
                if (role == "text" || role == "message") foreground = selected[0];
            }
            string codes = ansi_color (foreground, false) + ansi_color (background, true) + (reverse ? ";7" : "");
            encoded[cache_key] = codes;
            return codes;
        }
    }
}
