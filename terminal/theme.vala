namespace Parla.Terminal {
    /** Named semantic colors, using ANSI names or #RRGGBB, optionally FG:BG. */
    public class Theme : Object {
        public const string[] ROLES = { "text", "message", "timestamp", "own_nick", "nick1", "nick2", "nick3", "nick4",
            "status", "tab", "active_tab", "unread_tab", "contact", "active_contact", "open_contact", "selected_contact",
            "input", "separator", "info", "completion", "code", "accent", "error", "contact_preview", "selected_message" };
        private HashTable<string, string> colors = new HashTable<string, string> (str_hash, str_equal);
        private HashTable<string, string> encoded = new HashTable<string, string> (str_hash, str_equal);
        private static string[] names = { "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
            "bright_black", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan", "bright_white" };

        public Theme (string preset = "default") {
            foreach (var role in ROLES) colors[role] = "default";
            colors["own_nick"] = "green";
            colors["nick1"] = "bright_blue"; colors["nick2"] = "magenta";
            colors["nick3"] = "cyan"; colors["nick4"] = "yellow";
            colors["status"] = "black:white"; colors["active_tab"] = "black:cyan";
            colors["unread_tab"] = "yellow"; colors["active_contact"] = "black:cyan";
            colors["selected_contact"] = "white:blue";
            colors["contact_preview"] = "#999999";
            colors["selected_message"] = "white:#334155";
            colors["open_contact"] = "cyan"; colors["completion"] = "cyan";
            colors["separator"] = "bright_black"; colors["info"] = "cyan";
            colors["code"] = "yellow"; colors["accent"] = "cyan"; colors["error"] = "red";
            if (preset == "light") {
                colors["own_nick"] = "magenta"; colors["nick1"] = "blue"; colors["nick2"] = "green";
                colors["nick3"] = "cyan"; colors["nick4"] = "red"; colors["unread_tab"] = "red";
                colors["active_contact"] = "white:blue"; colors["open_contact"] = "cyan";
                colors["status"] = "white:blue"; colors["active_tab"] = "white:blue";
            } else if (preset == "ocean") {
                colors["text"] = "#cbd5e1:#0f172a"; colors["message"] = colors["text"];
                colors["own_nick"] = "#4ade80"; colors["nick1"] = "#60a5fa"; colors["nick2"] = "#e879f9";
                colors["nick3"] = "#22d3ee"; colors["nick4"] = "#facc15";
                colors["status"] = "#e2e8f0:#1e293b"; colors["active_tab"] = "#0f172a:#38bdf8";
            }
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
            if (Style.QR in style) return ";38;2;0;0;0;48;2;255;255;255";
            string role = "text";
            if (Style.STATUS in style) role = "status";
            else if (Style.UNREAD_TAB in style) role = "unread_tab";
            else if (Style.ACTIVE_TAB in style) role = "active_tab";
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
            string cache_key = role + (Style.PREVIEW in style ? ":preview" : "") + (selected_message ? ":selected" : "");
            string? cached = encoded[cache_key];
            if (cached != null) return cached;
            string[] pair = get_color (role).split (":");
            string[] own = get_color ("own_nick").split (":");
            string[] base_color = get_color ("text").split (":");
            string foreground = pair[0];
            string[] preview = get_color ("contact_preview").split (":");
            if (Style.PREVIEW in style) foreground = preview[0];
            // Never let a custom remote nick reuse the configured own-nick foreground.
            if (role.has_prefix ("nick") && foreground == own[0])
                foreground = foreground == "cyan" ? "magenta" : "cyan";
            string background = pair.length == 2 ? pair[1] : base_color.length == 2 ? base_color[1] : "default";
            if (selected_message) {
                string[] selected = get_color ("selected_message").split (":");
                if (selected.length == 2) background = selected[1];
                if (role == "text" || role == "message") foreground = selected[0];
            }
            string codes = ansi_color (foreground, false) + ansi_color (background, true);
            encoded[cache_key] = codes;
            return codes;
        }
    }
}
