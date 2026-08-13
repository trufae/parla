namespace Dc {

    public delegate void SettingWriter (KeyFile kf);

    public const int FONT_SIZE_SYSTEM = 0;
    public const int FONT_SIZE_MIN = 6;
    public const int FONT_SIZE_MAX = 32;
    public const int FONT_SIZE_FALLBACK = 11;
    public const int AUTO_DOWNLOAD_NEVER = 32 * 1024;
    public const int AUTO_DOWNLOAD_DEFAULT = 1024 * 1024;

    public enum SidebarMode {
        FULL = 0,
        COMPACT = 1,
        HIDDEN = 2
    }

    public enum ThemeOverride {
        SYSTEM = 0,
        LIGHT = 1,
        DARK = 2;
    }

    public enum MessageStyle {
        BUBBLES = 0,
        IRC = 1,
        WORKSPACE = 2;
    }

    public enum BubbleAvatarDisplay {
        NONE = 0,
        OTHER = 1,
        BOTH = 2;
    }

    public enum BackgroundMode {
        SYSTEM = 0,
        SOLID = 1,
        GRADIENT = 2;
    }

    public enum FontAttribute {
        REGULAR = 0,
        ITALIC = 1,
        BOLD = 2,
        BOLD_ITALIC = 3;

        public Pango.Style pango_style () {
            return this == ITALIC || this == BOLD_ITALIC
                ? Pango.Style.ITALIC
                : Pango.Style.NORMAL;
        }

        public Pango.Weight pango_weight () {
            return this == BOLD || this == BOLD_ITALIC
                ? Pango.Weight.BOLD
                : Pango.Weight.NORMAL;
        }

        public string css_style () {
            return pango_style () == Pango.Style.ITALIC ? "italic" : "normal";
        }

        public string css_weight () {
            return pango_weight () == Pango.Weight.BOLD ? "bold" : "normal";
        }
    }

    public class SettingsManager : Object {

        public signal void appearance_changed ();
        public signal void font_changed ();

        public int double_click_action { get; set; default = 0; }
        public MarkdownMode markdown_mode { get; set; default = MarkdownMode.ENABLED; }
        public CodeTheme code_theme { get; set; default = CodeTheme.ADAPTIVE; }
        public bool shift_enter_sends { get; set; default = false; }
        public bool notifications_enabled { get; set; default = true; }
        public bool show_notification_contents { get; set; default = true; }
        public bool minimize_to_tray { get; set; default = false; }
        public bool system_audio_player { get; set; default = false; }
        public bool animate_stickers { get; set; default = true; }
        /* Only honored in builds with -Dwebxdc=true (Webxdc.AVAILABLE). */
        public bool webxdc_apps { get; set; default = true; }
        /* App windows follow their chat: hidden unless the chat is open. */
        public bool webxdc_follow_chat { get; set; default = false; }
        /* Webxdc capabilities are opt-in: missing settings stay safest. */
        public bool webxdc_allow_internet { get; set; default =
            WebxdcSecurity.SAFE_ALLOW_INTERNET; }
        public bool webxdc_allow_wasm { get; set; default =
            WebxdcSecurity.SAFE_ALLOW_WASM; }
        public bool webxdc_allow_webgl { get; set; default =
            WebxdcSecurity.SAFE_ALLOW_WEBGL; }
        public bool webxdc_allow_hardware_acceleration { get; set; default =
            WebxdcSecurity.SAFE_ALLOW_HARDWARE_ACCELERATION; }
        public int auto_download_limit { get; set; default = AUTO_DOWNLOAD_DEFAULT; }
        public string rpc_server_path { get; set; default = ""; }
        /* An empty value deliberately means the standard Parla account store. */
        public string accounts_path { get; set; default = ""; }
        public RpcServerSource rpc_server_source { get; set; default = RpcServerSource.AUTO; }
        public bool rpc_check_updates_on_startup { get; set; default = true; }
        public SidebarMode sidebar_mode { get; set; default = SidebarMode.FULL; }
        public string default_account_addr { get; set; default = ""; }
        public ThemeOverride theme_override { get; set; default = ThemeOverride.SYSTEM; }
        public MessageStyle message_style { get; set; default = MessageStyle.BUBBLES; }
        public BubbleAvatarDisplay bubble_avatar_display { get; set; default = BubbleAvatarDisplay.NONE; }
        public bool bubble_avatars_in_direct_chats { get; set; default = false; }
        public string accent_color { get; set; default = ""; }
        public BackgroundMode background_mode { get; set; default = BackgroundMode.SYSTEM; }
        public string background_color { get; set; default = ""; }
        public string font_family { get; set; default = ""; }
        public FontAttribute font_attribute { get; set; default = FontAttribute.REGULAR; }
        public int font_size { get; set; default = FONT_SIZE_SYSTEM; }

        public static string get_config_path () {
            return Path.build_filename (
                Environment.get_user_config_dir (),
                "parla", "settings.ini");
        }

        /**
         * True when this build pins the deltachat-rpc-server to a fixed binary
         * (meson -Drpc_server_path=...). Such builds always use that binary as
         * the Custom server and never auto-update the engine.
         */
        public static bool rpc_server_path_is_fixed () {
            return Parla.RPC_SERVER_PATH.length > 0;
        }

        /** Server path to actually use: the pinned one if set, else the user's. */
        public string effective_rpc_server_path () {
            return rpc_server_path_is_fixed ()
                ? Parla.RPC_SERVER_PATH : rpc_server_path;
        }

        /** Server source to actually use: Custom when pinned, else the user's. */
        public RpcServerSource effective_rpc_server_source () {
            return rpc_server_path_is_fixed ()
                ? RpcServerSource.CUSTOM : rpc_server_source;
        }

        /** Whether Parla may check for / install engine updates. */
        public bool rpc_auto_update_enabled () {
            return !rpc_server_path_is_fixed () && rpc_check_updates_on_startup;
        }

        public string default_accounts_path () {
            return Path.build_filename (AccountFinder.get_data_dir (), "accounts");
        }

        private string normalize_accounts_path (string value) {
            string path = value.strip ();
            while (path.length > 1 &&
                   (path.has_suffix ("/") || path.has_suffix ("\\"))) {
                if (path.length == 3 && path[1] == ':') break;
                path = path[0:path.length - 1];
            }
            return path;
        }

        public bool is_default_accounts_path (string value) {
            return normalize_accounts_path (value) == default_accounts_path ();
        }

        public bool uses_default_accounts_path () {
            return is_default_accounts_path (accounts_path);
        }

        public string effective_accounts_path () {
            return accounts_path.length > 0 ? accounts_path : default_accounts_path ();
        }

        public void load () {
            var kf = new KeyFile ();
            try { kf.load_from_file (get_config_path (), KeyFileFlags.NONE); }
            catch (Error e) { /* file may not exist — helpers return defaults */ }
            double_click_action = kf_enum (kf, "double_click_action", 0, 5);
            markdown_mode = kf_markdown_mode (kf);
            Markdown.mode = markdown_mode;
            code_theme = (CodeTheme) kf_enum (kf, "code_theme",
                (int) CodeTheme.ADAPTIVE, (int) CodeTheme.NONE);
            SyntaxHighlight.theme = code_theme;
            shift_enter_sends = kf_bool (kf, "shift_enter_sends", false);
            notifications_enabled = kf_bool (kf, "notifications_enabled", true);
            show_notification_contents =
                kf_bool (kf, "show_notification_contents", true);
            minimize_to_tray = kf_bool (kf, "minimize_to_tray", false);
            system_audio_player = kf_bool (kf, "system_audio_player", false);
            AudioPlayer.prefer_system = system_audio_player;
            animate_stickers = kf_bool (kf, "animate_stickers", true);
            webxdc_apps = kf_bool (kf, "webxdc_apps", true);
            webxdc_follow_chat = kf_bool (kf, "webxdc_follow_chat", false);
            webxdc_allow_internet =
                kf_bool (kf, "webxdc_allow_internet",
                         WebxdcSecurity.SAFE_ALLOW_INTERNET);
            webxdc_allow_wasm = kf_bool (kf, "webxdc_allow_wasm",
                                         WebxdcSecurity.SAFE_ALLOW_WASM);
            webxdc_allow_webgl = kf_bool (kf, "webxdc_allow_webgl",
                                          WebxdcSecurity.SAFE_ALLOW_WEBGL);
            webxdc_allow_hardware_acceleration = kf_bool (kf,
                "webxdc_allow_hardware_acceleration",
                WebxdcSecurity.SAFE_ALLOW_HARDWARE_ACCELERATION);
            auto_download_limit = normalize_auto_download_limit (
                kf_int (kf, "auto_download_limit", AUTO_DOWNLOAD_DEFAULT));
            rpc_server_path = kf_str (kf, "rpc_server_path", "");
            accounts_path = normalize_accounts_path (kf_str (kf, "accounts_path", ""));
            if (is_default_accounts_path (accounts_path)) accounts_path = "";
            int source = kf_enum (kf, "rpc_server_source",
                                  (int) RpcServerSource.AUTO, 1);
            rpc_server_source = (RpcServerSource) source;
            rpc_check_updates_on_startup =
                kf_bool (kf, "rpc_check_updates_on_startup", true);
            int sb = kf_enum (kf, "sidebar_mode", (int) SidebarMode.FULL, 2);
            sidebar_mode = (SidebarMode) sb;
            default_account_addr = kf_str (kf, "default_account_addr", "");
            int theme = kf_enum (kf, "theme_override",
                                 (int) ThemeOverride.SYSTEM, 2);
            theme_override = (ThemeOverride) theme;
            int ms = kf_enum (kf, "message_style",
                              (int) MessageStyle.BUBBLES, 2);
            message_style = (MessageStyle) ms;
            int bad = kf_enum (kf, "bubble_avatar_display",
                               (int) BubbleAvatarDisplay.NONE, 2);
            bubble_avatar_display = (BubbleAvatarDisplay) bad;
            bubble_avatars_in_direct_chats =
                kf_bool (kf, "bubble_avatars_in_direct_chats", false);
            accent_color = kf_str (kf, "accent_color", "");
            int bm = kf_enum (kf, "background_mode",
                              (int) BackgroundMode.SYSTEM, 2);
            background_mode = (BackgroundMode) bm;
            background_color = kf_str (kf, "background_color", "");
            font_family = kf_str (kf, "font_family", "").strip ();
            int fa = kf_enum (kf, "font_attribute",
                              (int) FontAttribute.REGULAR, 3);
            font_attribute = (FontAttribute) fa;
            font_size = clamp_font_size (kf_int (kf, "font_size",
                                                 FONT_SIZE_SYSTEM));
        }

        private static int kf_int (KeyFile kf, string k, int d) {
            try { return kf.get_integer ("General", k); } catch { return d; }
        }

        private static bool kf_bool (KeyFile kf, string k, bool d) {
            try { return kf.get_boolean ("General", k); } catch { return d; }
        }

        private static string kf_str (KeyFile kf, string k, string d) {
            try { return kf.get_string ("General", k); } catch { return d; }
        }

        private static int kf_enum (KeyFile kf, string k, int d, int max) {
            int v = kf_int (kf, k, d);
            return v >= 0 && v <= max ? v : d;
        }

        private static MarkdownMode kf_markdown_mode (KeyFile kf) {
            try {
                int value = kf.get_integer ("General", "markdown_rendering");
                if (value >= (int) MarkdownMode.ENABLED
                    && value <= (int) MarkdownMode.DISABLED) {
                    return (MarkdownMode) value;
                }
            } catch { }

            /* Migrate the previous switch value stored as true/false. */
            try {
                return kf.get_boolean ("General", "markdown_rendering")
                    ? MarkdownMode.ENABLED
                    : MarkdownMode.DISABLED;
            } catch {
                return MarkdownMode.ENABLED;
            }
        }

        public void save_double_click_action (int v) {
            double_click_action = v;
            save_int ("double_click_action", v);
        }

        public void save_markdown_mode (MarkdownMode mode) {
            markdown_mode = mode;
            Markdown.mode = mode;
            save_int ("markdown_rendering", (int) mode);
            appearance_changed ();
        }

        public void save_code_theme (CodeTheme theme) {
            code_theme = theme;
            SyntaxHighlight.theme = theme;
            save_int ("code_theme", (int) theme);
            appearance_changed ();
        }

        public void save_shift_enter_sends (bool v) {
            shift_enter_sends = v;
            save_bool ("shift_enter_sends", v);
        }

        public void save_notifications_enabled (bool v) {
            notifications_enabled = v;
            save_bool ("notifications_enabled", v);
        }

        public void save_show_notification_contents (bool v) {
            show_notification_contents = v;
            save_bool ("show_notification_contents", v);
        }

        public void save_minimize_to_tray (bool v) {
            minimize_to_tray = v;
            save_bool ("minimize_to_tray", v);
        }

        public void save_system_audio_player (bool v) {
            system_audio_player = v;
            AudioPlayer.prefer_system = v;
            save_bool ("system_audio_player", v);
        }

        public void save_animate_stickers (bool v) {
            animate_stickers = v;
            save_bool ("animate_stickers", v);
            appearance_changed ();
        }

        public void save_webxdc_apps (bool v) {
            webxdc_apps = v;
            save_bool ("webxdc_apps", v);
        }

        public void save_webxdc_follow_chat (bool v) {
            webxdc_follow_chat = v;
            save_bool ("webxdc_follow_chat", v);
        }

        public void save_webxdc_allow_internet (bool v) {
            webxdc_allow_internet = v;
            save_bool ("webxdc_allow_internet", v);
        }

        public void save_webxdc_allow_wasm (bool v) {
            webxdc_allow_wasm = v;
            save_bool ("webxdc_allow_wasm", v);
        }

        public void save_webxdc_allow_webgl (bool v) {
            webxdc_allow_webgl = v;
            save_bool ("webxdc_allow_webgl", v);
        }

        public void save_webxdc_allow_hardware_acceleration (bool v) {
            webxdc_allow_hardware_acceleration = v;
            save_bool ("webxdc_allow_hardware_acceleration", v);
        }

        public void save_auto_download_limit (int bytes) {
            auto_download_limit = normalize_auto_download_limit (bytes);
            save_int ("auto_download_limit", auto_download_limit);
        }

        public static int normalize_auto_download_limit (int bytes) {
            switch (bytes) {
            case 0:
            case AUTO_DOWNLOAD_NEVER:
            case 256 * 1024:
            case 512 * 1024:
            case 1024 * 1024:
            case 2 * 1024 * 1024:
            case 5 * 1024 * 1024:
                return bytes;
            default:
                return AUTO_DOWNLOAD_DEFAULT;
            }
        }

        public void save_rpc_server_path (string v) {
            rpc_server_path = v;
            save_string ("rpc_server_path", v);
        }

        public void save_accounts_path (string v) {
            string clean_path = normalize_accounts_path (v);
            accounts_path = is_default_accounts_path (clean_path) ? "" : clean_path;
            save_string ("accounts_path", accounts_path);
        }

        public void reset_accounts_path () {
            save_accounts_path ("");
        }

        public void save_rpc_server_source (RpcServerSource v) {
            rpc_server_source = v;
            save_int ("rpc_server_source", (int) v);
        }

        public void save_rpc_check_updates_on_startup (bool v) {
            rpc_check_updates_on_startup = v;
            save_bool ("rpc_check_updates_on_startup", v);
        }

        public void save_sidebar_mode (SidebarMode v) {
            sidebar_mode = v;
            save_int ("sidebar_mode", (int) v);
        }

        public void save_default_account_addr (string v) {
            default_account_addr = v;
            save_string ("default_account_addr", v);
        }

        public void save_theme_override (ThemeOverride v) {
            theme_override = v;
            save_int ("theme_override", (int) v);
        }

        public void save_message_style (MessageStyle v) {
            message_style = v;
            save_int ("message_style", (int) v);
            appearance_changed ();
        }

        public void save_bubble_avatar_display (BubbleAvatarDisplay v) {
            bubble_avatar_display = v;
            save_int ("bubble_avatar_display", (int) v);
            appearance_changed ();
        }

        public void save_bubble_avatars_in_direct_chats (bool v) {
            bubble_avatars_in_direct_chats = v;
            save_bool ("bubble_avatars_in_direct_chats", v);
            appearance_changed ();
        }

        public void save_accent_color (string v) {
            accent_color = v;
            save_string ("accent_color", v);
            appearance_changed ();
        }

        /* The background is pure window CSS — it does not affect message
           widgets, so (unlike accent/message-style) these do NOT emit
           appearance_changed; the dialog applies the change directly,
           avoiding a needless rebuild of every conversation view. */
        public void save_background_mode (BackgroundMode v) {
            background_mode = v;
            save_int ("background_mode", (int) v);
        }

        public void save_background_color (string v) {
            background_color = v;
            save_string ("background_color", v);
        }

        public void save_font_size (int v) {
            save_font (font_family, font_attribute, v);
        }

        public void save_font_description (Pango.FontDescription desc) {
            string family = desc.get_family () ?? "";
            save_font (family, attribute_from_font_description (desc),
                       size_from_font_description (desc));
        }

        public void reset_font_defaults () {
            save_font ("", FontAttribute.REGULAR, FONT_SIZE_SYSTEM);
        }

        private void save_font (string family, FontAttribute attr, int size) {
            string clean_family = family.strip ();
            int clean_size = clamp_font_size (size);
            if (font_family == clean_family &&
                font_attribute == attr &&
                font_size == clean_size) {
                return;
            }

            font_family = clean_family;
            font_attribute = attr;
            font_size = clean_size;
            save_to_file ((kf) => {
                kf.set_string ("General", "font_family", font_family);
                kf.set_integer ("General", "font_attribute",
                                (int) font_attribute);
                kf.set_integer ("General", "font_size", font_size);
            });
            font_changed ();
        }

        public static int clamp_font_size (int size) {
            if (size <= FONT_SIZE_SYSTEM) return FONT_SIZE_SYSTEM;
            if (size < FONT_SIZE_MIN) return FONT_SIZE_MIN;
            if (size > FONT_SIZE_MAX) return FONT_SIZE_MAX;
            return size;
        }

        public static int system_font_size () {
            string font_name = system_font_name ();
            var desc = Pango.FontDescription.from_string (font_name);
            int size = size_from_font_description (desc);
            return size > 0 ? clamp_font_size (size) : FONT_SIZE_FALLBACK;
        }

        public int effective_font_size () {
            return font_size > 0 ? font_size : system_font_size ();
        }

        public Pango.FontDescription effective_font_description () {
            var desc = Pango.FontDescription.from_string (
                font_family.length > 0 ? font_family : system_font_name ());
            desc.set_style (font_attribute.pango_style ());
            desc.set_weight (font_attribute.pango_weight ());
            desc.set_size (effective_font_size () * Pango.SCALE);
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

        private void save_int (string key, int value) {
            save_to_file ((kf) => { kf.set_integer ("General", key, value); });
        }

        private void save_bool (string key, bool value) {
            save_to_file ((kf) => { kf.set_boolean ("General", key, value); });
        }

        private void save_string (string key, string value) {
            save_to_file ((kf) => { kf.set_string ("General", key, value); });
        }

        public void save_to_file (SettingWriter writer) {
            var kf = new KeyFile ();
            try {
                kf.load_from_file (get_config_path (), KeyFileFlags.NONE);
            } catch (Error e) { /* file may not exist yet */ }
            writer (kf);
            try {
                var dir = Path.get_dirname (get_config_path ());
                DirUtils.create_with_parents (dir, 0755);
                kf.save_to_file (get_config_path ());
            } catch (Error e) {
                warning ("Failed to save settings: %s", e.message);
            }
        }
    }

    public class SettingsDialog : Adw.PreferencesDialog {

        private unowned Window app_window;
        private RpcClient rpc;
        private Adw.ActionRow proxy_switch_row;
        private Adw.ActionRow proxy_url_row;
        private Gtk.Switch proxy_switch;
        private Gtk.Entry proxy_entry;
        private Adw.ActionRow rpc_row;
        private Adw.ComboRow rpc_source_dropdown;
        private Gtk.Button rpc_choose_btn;
        private Gtk.Button rpc_check_btn;
        private Adw.ActionRow accounts_path_row;
        private Gtk.Button accounts_path_reset_btn;
        private bool loading_proxy = false;
        private bool saving_proxy = false;
        private bool saved_proxy_enabled = false;
        private string saved_proxy_url = "";
        private bool syncing_rpc_source = false;
        private Adw.ActionRow font_type_row;
        private Gtk.Button font_btn;
        private uint rpc_version_request = 0;
        private string? rpc_current_version = null;

        public SettingsDialog (Window window, RpcClient rpc) {
            this.app_window = window;
            this.rpc = rpc;
            this.content_width = 640;
            this.content_height = 576;

            var general_page = new Adw.PreferencesPage ();
            general_page.title = "General";
            general_page.icon_name = "preferences-system-symbolic";
            this.add (general_page);

            var advanced_page = new Adw.PreferencesPage ();
            advanced_page.title = "Advanced";
            advanced_page.icon_name = "preferences-other-symbolic";
            this.add (advanced_page);

            var appearance_group = settings_group (general_page, "Appearance");

            string[] theme_labels = { "System", "Light", "Dark" };
            var theme_combo = row_combo (appearance_group,
                "GTK theme", "Override the system light or dark theme",
                theme_labels, (uint) app_window.settings.theme_override);
            theme_combo.notify["selected"].connect (() => {
                app_window.settings.save_theme_override (
                    (ThemeOverride) theme_combo.selected);
                apply_theme_override ();
            });

            string[] code_labels = {
                "Adaptive", "Solarized", "Monokai", "Nord", "None"
            };
            var code_combo = row_combo (appearance_group,
                "Code highlighting", "Color scheme for code blocks in messages",
                code_labels, (uint) app_window.settings.code_theme);
            code_combo.notify["selected"].connect (() => {
                app_window.settings.save_code_theme (
                    (CodeTheme) code_combo.selected);
            });

            string[] style_labels = { "Bubbles", "IRC", "Workspace" };
            var style_combo = row_combo (appearance_group,
                "Message style", "Chat bubbles, compact IRC lines or workspace rows",
                style_labels, (uint) app_window.settings.message_style);
            style_combo.notify["selected"].connect (() => {
                app_window.settings.save_message_style (
                    (MessageStyle) style_combo.selected);
            });

            string[] avatar_labels = { "none", "other", "both" };
            var avatar_combo = row_combo (appearance_group,
                "Bubble avatars", "Show small avatars beside message bubbles",
                avatar_labels, (uint) app_window.settings.bubble_avatar_display);
            avatar_combo.notify["selected"].connect (() => {
                app_window.settings.save_bubble_avatar_display (
                    (BubbleAvatarDisplay) avatar_combo.selected);
            });

            var direct_avatar_row = action_row (
                "Use avatars in 1:1 chats",
                "Use the bubble avatar setting in direct conversations");
            var direct_avatar_check = new Gtk.CheckButton ();
            direct_avatar_check.active =
                app_window.settings.bubble_avatars_in_direct_chats;
            direct_avatar_check.toggled.connect (() => {
                app_window.settings.save_bubble_avatars_in_direct_chats (
                    direct_avatar_check.active);
            });
            direct_avatar_row.add_suffix (direct_avatar_check);
            direct_avatar_row.activatable_widget = direct_avatar_check;
            appearance_group.add (direct_avatar_row);

            font_type_row = action_row (
                "Conversation font",
                "Use the system font or choose another family, style and size");
            /* Bound to 1/2 lines: this row's suffix (font chooser + reset
               button) leaves little room, and without a cap the title can
               collapse into vertical, one-letter-per-line wrapping. */
            font_type_row.title_lines = 1;
            font_type_row.subtitle_lines = 2;
            var font_dialog = new Gtk.FontDialog ();
            font_dialog.title = "Choose Font";
            font_dialog.modal = true;
            font_btn = new Gtk.Button.with_label ("Choose");
            font_btn.valign = Gtk.Align.CENTER;
            font_btn.add_css_class ("flat");
            font_btn.tooltip_text = "Choose a font family, style and size";
            font_btn.clicked.connect (() => { on_choose_font.begin (font_dialog); });
            font_type_row.add_suffix (font_btn);

            var font_reset_btn = new Gtk.Button.from_icon_name ("edit-undo-symbolic");
            font_reset_btn.valign = Gtk.Align.CENTER;
            font_reset_btn.add_css_class ("flat");
            font_reset_btn.tooltip_text = "Reset font settings to defaults";
            font_reset_btn.clicked.connect (() => {
                app_window.settings.reset_font_defaults ();
                sync_font_controls ();
            });
            font_type_row.add_suffix (font_reset_btn);
            appearance_group.add (font_type_row);

            sync_font_controls ();

            var accent_row = action_row (
                "Accent color",
                "Override the system accent color");

            var accent_btn = new Gtk.ColorDialogButton (new Gtk.ColorDialog ());
            accent_btn.valign = Gtk.Align.CENTER;
            apply_hex_to_button (accent_btn, app_window.settings.accent_color);
            accent_btn.notify["rgba"].connect (() => {
                app_window.settings.save_accent_color (
                    hex_from_rgba (accent_btn.get_rgba ()));
            });

            var accent_reset_btn = new Gtk.Button.from_icon_name ("edit-undo-symbolic");
            accent_reset_btn.valign = Gtk.Align.CENTER;
            accent_reset_btn.add_css_class ("flat");
            accent_reset_btn.tooltip_text = "Use system accent color";
            accent_reset_btn.clicked.connect (() => {
                app_window.settings.save_accent_color ("");
                apply_hex_to_button (accent_btn, "");
            });

            accent_row.add_suffix (accent_btn);
            accent_row.add_suffix (accent_reset_btn);
            appearance_group.add (accent_row);

            string[] bg_mode_labels = { "System", "Solid", "Gradient" };
            var bg_mode_combo = row_combo (appearance_group,
                "Background color",
                "Tint the window background with a solid color or a gradient",
                bg_mode_labels, (uint) app_window.settings.background_mode);

            var bg_color_btn = new Gtk.ColorDialogButton (new Gtk.ColorDialog ());
            bg_color_btn.valign = Gtk.Align.CENTER;
            apply_hex_to_button (bg_color_btn, app_window.settings.background_color);
            /* The picker only matters for Solid/Gradient; dim it for System. */
            bg_color_btn.sensitive =
                app_window.settings.background_mode != BackgroundMode.SYSTEM;

            bg_mode_combo.notify["selected"].connect (() => {
                var mode = (BackgroundMode) bg_mode_combo.selected;
                bg_color_btn.sensitive = mode != BackgroundMode.SYSTEM;
                app_window.settings.save_background_mode (mode);
                apply_background ();
            });
            bg_color_btn.notify["rgba"].connect (() => {
                app_window.settings.save_background_color (
                    hex_from_rgba (bg_color_btn.get_rgba ()));
                apply_background ();
            });

            bg_mode_combo.add_suffix (bg_color_btn);

            var behavior_group = settings_group (general_page, "Behavior");

            string[] dblclick_labels = {
                "Reply to message",
                "React with ❤️",
                "React with 👍",
                "Open user profile",
                "Open context menu",
                "Do nothing"
            };

            uint dblclick_selected = (uint) app_window.settings.double_click_action;
            if (dblclick_selected == 4) dblclick_selected = 5;
            else if (dblclick_selected == 5) dblclick_selected = 4;
            var dblclick_combo = row_combo (behavior_group,
                "Double-click on message",
                "Action when a message is double-clicked",
                dblclick_labels, dblclick_selected);
            dblclick_combo.notify["selected"].connect (() => {
                uint selected = dblclick_combo.selected;
                int action = (int) selected;
                if (selected == 4) action = 5;
                else if (selected == 5) action = 4;
                app_window.settings.save_double_click_action (action);
            });

            string[] md_labels = { "Enabled", "Stripped", "Disabled" };
            var md_combo = row_combo (behavior_group,
                "Markdown rendering", "Render, strip, or preserve markdown syntax",
                md_labels, (uint) app_window.settings.markdown_mode);
            md_combo.notify["selected"].connect (() => {
                app_window.settings.save_markdown_mode (
                    (MarkdownMode) md_combo.selected);
            });

            var shift_row = action_row (
                "Shift+Return sends message",
                "When on, Return inserts a newline and Shift+Return sends");
            var shift_switch = row_switch (
                shift_row, app_window.settings.shift_enter_sends);
            shift_switch.notify["active"].connect (() => {
                app_window.settings.save_shift_enter_sends (shift_switch.active);
            });

            behavior_group.add (shift_row);

            var audio_row = action_row (
                "System audio tools",
                "Prefer system programs for voice playback and recording "
                + "instead of Parla's GTK/GStreamer media path");
            var audio_switch = row_switch (
                audio_row, app_window.settings.system_audio_player);
            audio_switch.notify["active"].connect (() => {
                app_window.settings.save_system_audio_player (audio_switch.active);
            });

            /* Backed by the StatusNotifierItem on freedesktop systems and
               by the NSStatusItem shim on macOS (tray_macos.m). */
            var tray_row = action_row (
                Platform.is_macos ()
                    ? "Minimize to menu bar"
                    : "Minimize to status bar",
                Platform.is_macos ()
                    ? "Closing the window keeps Parla running as a menu bar "
                    + "icon; the Dock icon stays visible and notifications "
                    + "still appear"
                    : "Closing the window keeps Parla running in the status "
                    + "bar; notifications still appear");
            var tray_switch = row_switch (
                tray_row, app_window.settings.minimize_to_tray);
            tray_switch.notify["active"].connect (() => {
                app_window.set_minimize_to_tray (tray_switch.active);
            });

            behavior_group.add (tray_row);

            var notifications_group = settings_group (general_page, "Notifications");
            var notif_row = action_row (
                "Desktop notifications",
                "Notify on incoming messages when the window is not focused");
            var notif_switch = row_switch (
                notif_row, app_window.settings.notifications_enabled);
            notif_switch.notify["active"].connect (() => {
                app_window.set_notifications_enabled (notif_switch.active);
            });

            notifications_group.add (notif_row);


            var notification_contents_row = action_row (
                "Show message contents in notifications",
                "Include sender text and attachment names in desktop notifications");
            var notification_contents_switch = row_switch (
                notification_contents_row,
                app_window.settings.show_notification_contents);
            notification_contents_switch.notify["active"].connect (() => {
                app_window.settings.save_show_notification_contents (
                    notification_contents_switch.active);
            });
            notifications_group.add (notification_contents_row);

            var chatmail_group = settings_group (advanced_page, "Chatmail Core");

            string[] rpc_source_labels = { "Auto", "Custom" };
            rpc_source_dropdown = row_combo (chatmail_group, "Source", null,
                rpc_source_labels,
                (uint) app_window.settings.effective_rpc_server_source ());
            rpc_row = rpc_source_dropdown;
            rpc_source_dropdown.notify["selected"].connect (on_rpc_source_changed);

            rpc_choose_btn = new Gtk.Button.with_label ("Choose");
            rpc_choose_btn.valign = Gtk.Align.CENTER;
            rpc_choose_btn.add_css_class ("flat");
            rpc_choose_btn.tooltip_text = "Choose a Chatmail Core binary";
            rpc_choose_btn.clicked.connect (() => { on_browse_rpc_server.begin (); });
            rpc_row.add_suffix (rpc_choose_btn);

            rpc_check_btn = new Gtk.Button.with_label ("Check");
            rpc_check_btn.valign = Gtk.Align.CENTER;
            rpc_check_btn.add_css_class ("flat");
            rpc_check_btn.tooltip_text = "Check for the latest Chatmail Core release";
            rpc_check_btn.clicked.connect (() => { check_rpc_updates.begin (); });
            rpc_row.add_suffix (rpc_check_btn);

            var rpc_autocheck_row = action_row (
                "Check for updates on startup",
                "Notify when a newer Chatmail Core version is available");
            var autocheck_switch = row_switch (
                rpc_autocheck_row,
                app_window.settings.rpc_check_updates_on_startup);
            autocheck_switch.notify["active"].connect (() => {
                app_window.settings.save_rpc_check_updates_on_startup (
                    autocheck_switch.active);
            });
            /* Updates are off entirely when the binary path is pinned. */
            rpc_autocheck_row.visible = !SettingsManager.rpc_server_path_is_fixed ();
            chatmail_group.add (rpc_autocheck_row);

            update_rpc_row ();

            accounts_path_row = action_row ("Accounts Path");
            accounts_path_row.subtitle_lines = 2;

            var accounts_path_change_btn = new Gtk.Button.from_icon_name (
                "folder-symbolic");
            accounts_path_change_btn.valign = Gtk.Align.CENTER;
            accounts_path_change_btn.add_css_class ("flat");
            accounts_path_change_btn.tooltip_text = "Choose a different folder";
            accounts_path_change_btn.clicked.connect (() => {
                on_browse_accounts_path.begin ();
            });
            accounts_path_row.add_suffix (accounts_path_change_btn);

            accounts_path_reset_btn = new Gtk.Button.from_icon_name (
                "edit-undo-symbolic");
            accounts_path_reset_btn.valign = Gtk.Align.CENTER;
            accounts_path_reset_btn.add_css_class ("flat");
            accounts_path_reset_btn.tooltip_text = "Use the default folder";
            accounts_path_reset_btn.clicked.connect (() => {
                app_window.settings.reset_accounts_path ();
                sync_accounts_path_row ();
                app_window.reconnect_rpc_server.begin ();
            });
            accounts_path_row.add_suffix (accounts_path_reset_btn);
            chatmail_group.add (accounts_path_row);

            sync_accounts_path_row ();

            var network_group = settings_group (advanced_page, "Network");

            proxy_switch_row = action_row (
                "Use Proxy",
                "Route this profile through the configured proxy");
            proxy_switch = row_switch (proxy_switch_row, false);
            proxy_switch.notify["active"].connect (() => {
                if (!loading_proxy) save_proxy_settings.begin ();
            });
            network_group.add (proxy_switch_row);

            proxy_url_row = action_row (
                "Proxy URL",
                "socks5://, http://, https://, or ss://");

            proxy_entry = new Gtk.Entry ();
            proxy_entry.placeholder_text = "socks5://127.0.0.1:9050";
            proxy_entry.input_purpose = Gtk.InputPurpose.URL;
            proxy_entry.hexpand = true;
            proxy_entry.valign = Gtk.Align.CENTER;
            proxy_entry.activate.connect (() => { save_proxy_settings.begin (); });
            var proxy_focus = new Gtk.EventControllerFocus ();
            proxy_focus.leave.connect (() => { save_proxy_settings.begin (); });
            proxy_entry.add_controller (proxy_focus);
            proxy_url_row.add_suffix (proxy_entry);
            proxy_url_row.activatable_widget = proxy_entry;
            network_group.add (proxy_url_row);

            load_proxy_settings.begin ();

            var sticker_row = action_row (
                "Sticker animations",
                "Auto-play GIF, WebP and WebM stickers; " +
                "clicking a sticker toggles playback");
            var sticker_switch = row_switch (
                sticker_row, app_window.settings.animate_stickers);
            sticker_switch.notify["active"].connect (() => {
                app_window.settings.save_animate_stickers (
                    sticker_switch.active);
            });

            string[] download_labels = {
                "Never", "256 KB", "512 KB", "1 MB", "2 MB", "5 MB", "Unlimited"
            };
            var download_combo = row_combo (behavior_group,
                "Auto-download attachments",
                "Larger attachments wait for approval; applies to all profiles",
                download_labels, auto_download_limit_index (
                    app_window.settings.auto_download_limit));
            download_combo.notify["selected"].connect (() => {
                app_window.set_auto_download_limit.begin (
                    auto_download_limit_for_index (download_combo.selected));
            });

            bool whisper_found = Transcriber.available ();
            var transcription_row = action_row (
                "Voice transcription",
                whisper_found
                    ? "Whisper is available in PATH"
                    : "Whisper was not found in PATH");
            var transcription_status = new Gtk.Label (
                whisper_found ? "Available" : "Not found");
            transcription_status.valign = Gtk.Align.CENTER;
            transcription_status.add_css_class ("dim-label");
            transcription_row.add_suffix (transcription_status);

            behavior_group.add (audio_row);
            behavior_group.add (transcription_row);
            behavior_group.add (sticker_row);

            build_webxdc_section (advanced_page);

            var reset_group = settings_group (advanced_page, "Factory Reset");
            var reset_row = action_row (
                "Factory Reset",
                "Remove all settings and close the app");
            var reset_btn = new Gtk.Button.with_label ("Factory Reset");
            reset_btn.valign = Gtk.Align.CENTER;
            reset_btn.add_css_class ("destructive-action");
            reset_btn.tooltip_text = "Delete all Parla configuration and start fresh";
            reset_btn.clicked.connect (() => { on_reset_settings.begin (); });
            reset_row.add_suffix (reset_btn);
            reset_group.add (reset_row);
        }

        /** All Webxdc switches in one place: the enable toggle and how the
            app windows behave. Builds without -Dwebxdc=true say so instead
            of offering switches that cannot work. */
        private void build_webxdc_section (Adw.PreferencesPage page) {
            var webxdc_group = settings_group (page, "Webxdc Apps");

            if (!Webxdc.AVAILABLE) {
                var unavailable_row = action_row (
                    "Webxdc apps",
                    "This build of Parla was compiled without Webxdc "
                    + "support");
                var status = new Gtk.Label ("Unavailable");
                status.valign = Gtk.Align.CENTER;
                status.add_css_class ("dim-label");
                unavailable_row.add_suffix (status);
                webxdc_group.add (unavailable_row);
                return;
            }

            var enable_row = action_row (
                "Webxdc apps",
                "Run Delta Chat mini-apps shared in chats (experimental)");
            var enable_switch = row_switch (
                enable_row, app_window.settings.webxdc_apps);
            enable_switch.notify["active"].connect (() => {
                app_window.settings.save_webxdc_apps (enable_switch.active);
            });
            webxdc_group.add (enable_row);

            var behavior_row = action_row (
                "Keep apps with their chat",
                "Hide app windows when you leave the chat");
            var behavior_switch = row_switch (
                behavior_row, app_window.settings.webxdc_follow_chat);
            behavior_switch.notify["active"].connect (() => {
                app_window.settings.save_webxdc_follow_chat (
                    behavior_switch.active);
            });
            webxdc_group.add (behavior_row);

            var internet_row = action_row (
                "Internet access",
                "Allow apps to make direct network requests (unsafe)");
            var internet_switch = row_switch (
                internet_row, app_window.settings.webxdc_allow_internet);
            internet_switch.notify["active"].connect (() => {
                app_window.settings.save_webxdc_allow_internet (
                    internet_switch.active);
            });
            webxdc_group.add (internet_row);

            var wasm_row = action_row (
                "WebAssembly",
                "Allow apps to compile and run WebAssembly");
            var wasm_switch = row_switch (
                wasm_row, app_window.settings.webxdc_allow_wasm);
            wasm_switch.notify["active"].connect (() => {
                app_window.settings.save_webxdc_allow_wasm (
                    wasm_switch.active);
            });
            webxdc_group.add (wasm_row);

            var webgl_row = action_row (
                "WebGL",
                Platform.is_macos ()
                    ? "Best-effort restriction on macOS; WKWebView has no "
                    + "public hard-disable API"
                    : "Allow apps to access accelerated 3D graphics");
            var webgl_switch = row_switch (
                webgl_row, app_window.settings.webxdc_allow_webgl);
            webgl_switch.notify["active"].connect (() => {
                app_window.settings.save_webxdc_allow_webgl (
                    webgl_switch.active);
            });
            webxdc_group.add (webgl_row);

            Gtk.Switch? acceleration_switch = null;
            if (!Platform.is_macos ()) {
                var acceleration_row = action_row (
                    "Hardware acceleration",
                    "Allow WebKit to use GPU-accelerated rendering");
                var acceleration = row_switch (acceleration_row,
                    app_window.settings.webxdc_allow_hardware_acceleration);
                acceleration.notify["active"].connect (() => {
                    app_window.settings
                        .save_webxdc_allow_hardware_acceleration (
                            acceleration.active);
                });
                acceleration_switch = acceleration;
                webxdc_group.add (acceleration_row);
            }

            var safest_row = action_row (
                "Safest defaults",
                "Turn off extra access and close running apps");
            var safest_button = new Gtk.Button.with_label ("Use safest");
            safest_button.valign = Gtk.Align.CENTER;
            safest_button.clicked.connect (() => {
                internet_switch.active =
                    WebxdcSecurity.SAFE_ALLOW_INTERNET;
                wasm_switch.active = WebxdcSecurity.SAFE_ALLOW_WASM;
                webgl_switch.active = WebxdcSecurity.SAFE_ALLOW_WEBGL;
                if (acceleration_switch != null) {
                    acceleration_switch.active = WebxdcSecurity
                        .SAFE_ALLOW_HARDWARE_ACCELERATION;
                } else {
                    app_window.settings
                        .save_webxdc_allow_hardware_acceleration (
                            WebxdcSecurity
                                .SAFE_ALLOW_HARDWARE_ACCELERATION);
                }
                app_window.show_toast ("Webxdc safest defaults restored");
            });
            safest_row.add_suffix (safest_button);
            webxdc_group.add (safest_row);
        }

        private Adw.PreferencesGroup settings_group (Adw.PreferencesPage page,
                                                      string title) {
            var group = new Adw.PreferencesGroup ();
            group.title = title;
            page.add (group);
            return group;
        }

        private static uint auto_download_limit_index (int bytes) {
            switch (bytes) {
            case AUTO_DOWNLOAD_NEVER: return 0;
            case 256 * 1024: return 1;
            case 512 * 1024: return 2;
            case 1024 * 1024: return 3;
            case 2 * 1024 * 1024: return 4;
            case 5 * 1024 * 1024: return 5;
            case 0: return 6;
            default: return 3;
            }
        }

        private static int auto_download_limit_for_index (uint index) {
            switch (index) {
            case 0: return AUTO_DOWNLOAD_NEVER;
            case 1: return 256 * 1024;
            case 2: return 512 * 1024;
            case 3: return 1024 * 1024;
            case 4: return 2 * 1024 * 1024;
            case 5: return 5 * 1024 * 1024;
            case 6: return 0;
            default: return AUTO_DOWNLOAD_DEFAULT;
            }
        }

        private static Adw.ActionRow action_row (string title,
                                                 string? subtitle = null) {
            var row = new Adw.ActionRow ();
            row.title = title;
            if (subtitle != null) row.subtitle = subtitle;
            return row;
        }

        private static Gtk.Switch row_switch (Adw.ActionRow row, bool active) {
            var sw = new Gtk.Switch ();
            sw.active = active;
            sw.valign = Gtk.Align.CENTER;
            row.add_suffix (sw);
            row.activatable_widget = sw;
            return sw;
        }

        /* Adw.ComboRow (not a raw Gtk.DropDown suffix) so the row stays
           usable when narrow: its value renders as ellipsizable text
           instead of a button sized to the widest option label. */
        private static Adw.ComboRow row_combo (Adw.PreferencesGroup group,
                                               string title, string? subtitle,
                                               string[] labels, uint selected) {
            var row = new Adw.ComboRow ();
            row.title = title;
            if (subtitle != null) row.subtitle = subtitle;
            row.model = new Gtk.StringList (labels);
            row.expression = new Gtk.PropertyExpression (
                typeof (Gtk.StringObject), null, "string");
            row.selected = selected;
            group.add (row);
            return row;
        }

        private void sync_font_controls () {
            string family = app_window.settings.font_family;
            font_type_row.subtitle = family.length > 0
                ? family
                : "System default";
            font_type_row.tooltip_text = family.length > 0 ? family : null;
        }

        private async void on_choose_font (Gtk.FontDialog dialog) {
            try {
                var desc = yield dialog.choose_font (app_window,
                    app_window.settings.effective_font_description (), null);
                if (desc != null) {
                    app_window.settings.save_font_description (desc);
                    sync_font_controls ();
                }
            } catch (Error e) {
                if (!is_dialog_dismissal (e))
                    show_error (app_window, e.message);
            }
        }

        private static string hex_from_rgba (Gdk.RGBA c) {
            return "#%02x%02x%02x".printf (
                (uint) (c.red * 255), (uint) (c.green * 255),
                (uint) (c.blue * 255));
        }

        private async void load_proxy_settings () {
            if (!rpc.is_connected || rpc.account_id <= 0) {
                set_proxy_controls_sensitive (false);
                proxy_switch_row.subtitle = "No active profile";
                proxy_url_row.subtitle = "No active profile";
                return;
            }

            loading_proxy = true;
            set_proxy_controls_sensitive (false);

            try {
                string? enabled = yield rpc.get_config ("proxy_enabled",
                                                        rpc.account_id);
                string? proxy_url = yield rpc.get_config ("proxy_url",
                                                          rpc.account_id);
                string first = first_proxy_url (proxy_url ?? "");
                proxy_switch.active = (enabled ?? "") == "1";
                proxy_entry.text = first;
                saved_proxy_enabled = proxy_switch.active;
                saved_proxy_url = first;

                proxy_switch_row.subtitle = proxy_switch.active
                    ? "Enabled for current profile"
                    : "Disabled for current profile";
                proxy_url_row.subtitle = "socks5://, http://, https://, or ss://";
                proxy_url_row.tooltip_text = first.length > 0 ? first : null;
            } catch (Error e) {
                proxy_switch_row.subtitle = "Unable to read proxy settings";
                proxy_url_row.tooltip_text = e.message;
            } finally {
                loading_proxy = false;
                set_proxy_controls_sensitive (true);
            }
        }

        private void set_proxy_controls_sensitive (bool sensitive) {
            bool active = sensitive && rpc.is_connected && rpc.account_id > 0;
            proxy_switch.sensitive = active;
            proxy_entry.sensitive = active;
        }

        private static string first_proxy_url (string urls) {
            foreach (string line in urls.split ("\n")) {
                string s = line.strip ();
                if (s.length > 0) return s;
            }
            return "";
        }

        private async string? normalize_proxy_url (string url) {
            try {
                var qr = yield rpc.check_qr (rpc.account_id, url);
                if (qr == null || !qr.has_member ("kind") ||
                    qr.get_string_member ("kind") != "proxy") {
                    show_error (this, "Invalid proxy URL: " + url);
                    return null;
                }
                return qr.has_member ("url") ? qr.get_string_member ("url") : url;
            } catch (Error e) {
                show_error (this, "Invalid proxy URL: %s\n%s".printf (
                    url, e.message));
                return null;
            }
        }

        private async void save_proxy_settings () {
            if (loading_proxy || saving_proxy) return;

            if (!rpc.is_connected || rpc.account_id <= 0) {
                app_window.show_toast ("No active profile");
                return;
            }

            string url = proxy_entry.text.strip ();
            bool enabled = proxy_switch.active;

            if (enabled == saved_proxy_enabled && url == saved_proxy_url) {
                return;
            }

            if (enabled && url.length == 0) {
                show_error (this, "Enter a proxy URL before enabling the proxy.");
                loading_proxy = true;
                proxy_switch.active = false;
                loading_proxy = false;
                enabled = false;
                if (!saved_proxy_enabled && saved_proxy_url.length == 0) {
                    return;
                }
            }

            saving_proxy = true;
            set_proxy_controls_sensitive (false);

            if (url.length > 0) {
                string? normalized = yield normalize_proxy_url (url);
                if (normalized == null) {
                    saving_proxy = false;
                    set_proxy_controls_sensitive (true);
                    return;
                }
                url = normalized;
                proxy_entry.text = url;
            }

            try {
                yield rpc.batch_set_config ("proxy_url", url, rpc.account_id);
                yield rpc.batch_set_config ("proxy_enabled",
                                            enabled ? "1" : "0",
                                            rpc.account_id);
                yield rpc.stop_io (rpc.account_id);
                yield rpc.start_io (rpc.account_id);

                proxy_switch_row.subtitle = enabled
                    ? "Enabled for current profile"
                    : "Disabled for current profile";
                proxy_url_row.tooltip_text = url.length > 0 ? url : null;
                saved_proxy_enabled = enabled;
                saved_proxy_url = url;
                app_window.show_toast ("Proxy settings saved");
            } catch (Error e) {
                show_error (this, "Failed to save proxy settings: " + e.message);
            } finally {
                saving_proxy = false;
                set_proxy_controls_sensitive (true);
            }
        }

        private void update_rpc_row () {
            sync_rpc_source_dropdown ();

            bool pinned = SettingsManager.rpc_server_path_is_fixed ();
            string custom = app_window.settings.effective_rpc_server_path ();
            RpcServerSource source = app_window.settings.effective_rpc_server_source ();
            string? found = AccountFinder.find_rpc_server (custom, source);
            /* A pinned build can't change source or update the engine. */
            rpc_source_dropdown.sensitive = !pinned;
            rpc_choose_btn.visible = source == RpcServerSource.CUSTOM && !pinned;
            rpc_choose_btn.sensitive = source == RpcServerSource.CUSTOM && !pinned;
            rpc_check_btn.visible = source == RpcServerSource.AUTO && !pinned;
            rpc_check_btn.sensitive = !pinned;
            switch (source) {
            case RpcServerSource.CUSTOM:
                if (custom.length == 0) {
                    rpc_row.subtitle = "No custom binary selected";
                    rpc_row.tooltip_text = "Choose a Chatmail Core binary";
                } else if (found == null) {
                    rpc_row.subtitle = "Custom path is not executable";
                    rpc_row.tooltip_text = custom;
                } else {
                    rpc_row.subtitle = "Checking version…";
                    rpc_row.tooltip_text = custom;
                }
                break;
            case RpcServerSource.AUTO:
            default:
                rpc_row.subtitle = found != null
                    ? "Checking version…"
                    : "Chatmail Core not found";
                rpc_row.tooltip_text = found
                    ?? "Install Chatmail Core or choose a custom binary";
                break;
            }
            update_rpc_version_row.begin (found);
        }

        private async void update_rpc_version_row (string? rpc_path) {
            uint request_id = ++rpc_version_request;
            rpc_current_version = null;
            if (rpc_path == null || rpc_path.length == 0) return;

            try {
                string? stdout_buf;
                string? stderr_buf;
                bool successful;
#if WINDOWS
                var run = yield Platform.run_hidden ({ rpc_path, "--version" });
                stdout_buf = run.output;
                stderr_buf = run.errout;
                successful = run.status == 0;
#else
                var process = new Subprocess (
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                    rpc_path, "--version");
                yield process.communicate_utf8_async (
                    null, null, out stdout_buf, out stderr_buf);
                successful = process.get_successful ();
#endif

                if (request_id != rpc_version_request) return;

                string version = ((stdout_buf ?? "").strip ().length > 0)
                    ? (stdout_buf ?? "").strip ()
                    : (stderr_buf ?? "").strip ();
                if (successful && version.length > 0) {
                    rpc_current_version = RpcInstaller.extract_version (version);
                    rpc_row.subtitle = rpc_current_version ?? version;
                } else {
                    rpc_row.subtitle = "Unable to read version";
                }
            } catch (Error e) {
                if (request_id != rpc_version_request) return;
                rpc_row.subtitle = "Unable to read version";
                rpc_row.tooltip_text = "%s\n%s".printf (rpc_path, e.message);
            }
        }

        private async bool confirm_update_dialog (string title, string body,
                                                   string action_label) {
            var d = new Adw.AlertDialog (title, body);
            d.add_response ("dismiss", "Dismiss");
            d.add_response ("update", action_label);
            d.set_response_appearance ("update", Adw.ResponseAppearance.SUGGESTED);
            d.default_response = "update";
            d.close_response = "dismiss";
            return (yield d.choose (app_window, null)) == "update";
        }

        private async void check_rpc_updates () {
            if (rpc_check_btn == null || !rpc_check_btn.sensitive) return;

            rpc_check_btn.sensitive = false;
            string previous_subtitle = rpc_row.subtitle;
            rpc_row.subtitle = "Checking for updates…";

            try {
                string latest_tag = yield RpcInstaller.fetch_latest_tag ();
                string? latest_version = RpcInstaller.extract_version (latest_tag);
                rpc_row.subtitle = previous_subtitle;
                if (latest_version == null) {
                    app_window.show_toast ("Could not parse the latest Chatmail Core version");
                    return;
                }

                if (rpc_current_version != null && rpc_current_version == latest_version) {
                    app_window.show_toast ("Chatmail Core is up to date: " + latest_version);
                    return;
                }

                bool managed_active =
                    AccountFinder.find_rpc_server (
                        app_window.settings.effective_rpc_server_path (),
                        app_window.settings.effective_rpc_server_source ())
                    == AccountFinder.get_managed_rpc_path ();

                if (!managed_active && rpc_current_version != null) {
                    /* Parla doesn't control the active binary, so it can't
                       overwrite it — point at the release instead. */
                    if (yield confirm_update_dialog ("Update Available",
                            "Chatmail Core %s is available. Parla doesn't manage the active binary, so open its release page to update it manually.".printf (latest_version),
                            "View Release")) {
                        yield open_rpc_download_page ();
                    }
                    return;
                }

                if (!RpcInstaller.can_auto_install ()) {
                    if (yield confirm_update_dialog ("Update Available",
                            "Chatmail Core %s is available, but no prebuilt binary exists for this platform.".printf (latest_version),
                            "View Release")) {
                        yield open_rpc_download_page ();
                    }
                    return;
                }

                string body = rpc_current_version == null
                    ? "Chatmail Core %s is available to install.".printf (latest_version)
                    : "Chatmail Core %s is available (installed: %s).".printf (
                        latest_version, rpc_current_version);
                if (yield confirm_update_dialog (
                        "Update Available", body,
                        rpc_current_version == null ? "Install" : "Update")) {
                    yield install_managed_server ();
                }
            } catch (Error e) {
                rpc_row.subtitle = previous_subtitle;
                app_window.show_toast ("Update check failed: " + e.message);
            } finally {
                rpc_check_btn.sensitive = !SettingsManager.rpc_server_path_is_fixed ();
            }
        }

        private void sync_rpc_source_dropdown () {
            syncing_rpc_source = true;
            rpc_source_dropdown.selected =
                (uint) app_window.settings.effective_rpc_server_source ();
            syncing_rpc_source = false;
        }

        private void on_rpc_source_changed () {
            if (syncing_rpc_source) return;

            RpcServerSource source = (RpcServerSource) rpc_source_dropdown.selected;
            if (source == RpcServerSource.CUSTOM &&
                app_window.settings.rpc_server_path.length == 0) {
                on_browse_rpc_server.begin ();
                return;
            }

            app_window.settings.save_rpc_server_source (source);
            app_window.show_toast ("Chatmail Core source saved");
            update_rpc_row ();
            app_window.reconnect_rpc_server.begin ();
        }

        private async void on_browse_rpc_server () {
            var dlg = new Gtk.FileDialog ();
            dlg.title = "Locate a Chatmail Core binary";
            dlg.modal = true;

            string start = app_window.settings.rpc_server_path;
            if (start.length == 0) start = AccountFinder.find_rpc_server () ?? "";
            if (start.length > 0) dlg.initial_file = File.new_for_path (start);

            try {
                var file = yield dlg.open (app_window, null);
                if (file != null) {
                    string? path = file.get_path ();
                    if (path != null && FileUtils.test (path, FileTest.IS_EXECUTABLE)) {
                        app_window.settings.save_rpc_server_path (path);
                        app_window.settings.save_rpc_server_source (RpcServerSource.CUSTOM);
                        sync_rpc_source_dropdown ();
                        app_window.show_toast ("Chatmail Core binary saved");
                        app_window.reconnect_rpc_server.begin ();
                    } else {
                        show_error (app_window, "Selected file is not an executable binary.");
                    }
                }
            } catch (Error e) {
                if (!is_dialog_dismissal (e))
                    show_error (app_window, e.message);
            }
            update_rpc_row ();
        }

        private void sync_accounts_path_row () {
            string path = app_window.settings.effective_accounts_path ();
            accounts_path_row.subtitle = path;
            accounts_path_row.tooltip_text = path;
            accounts_path_reset_btn.sensitive =
                !app_window.settings.uses_default_accounts_path ();
        }

        private async void on_browse_accounts_path () {
            var dlg = new Gtk.FileDialog ();
            dlg.title = "Choose accounts folder";
            dlg.modal = true;

            string path = app_window.settings.effective_accounts_path ();
            if (FileUtils.test (path, FileTest.IS_DIR)) {
                dlg.initial_folder = File.new_for_path (path);
            }

            try {
                var folder = yield dlg.select_folder (app_window, null);
                if (folder != null) {
                    string? selected_path = folder.get_path ();
                    if (selected_path != null) {
                        app_window.settings.save_accounts_path (selected_path);
                        sync_accounts_path_row ();
                        app_window.show_toast ("Accounts path saved");
                        app_window.reconnect_rpc_server.begin ();
                    }
                }
            } catch (Error e) {
                if (!is_dialog_dismissal (e))
                    show_error (app_window, e.message);
            }
        }

        /* Downloads the latest Chatmail Core into Parla's data dir. Only
           called after check_rpc_updates() confirms with the user. */
        private async void install_managed_server () {
            if (!RpcInstaller.can_auto_install ()) {
                /* No prebuilt binary for this arch — fall back to the browser. */
                yield open_rpc_download_page ();
                return;
            }

            rpc_check_btn.sensitive = false;
            string prev_subtitle = rpc_row.subtitle;

            var installer = new RpcInstaller ();
            installer.progress.connect ((received, total) => {
                if (total > 0) {
                    rpc_row.subtitle = "Downloading… %.0f%%".printf (
                        (double) received / (double) total * 100.0);
                } else {
                    rpc_row.subtitle = "Downloading… %.1f MB".printf (
                        received / 1048576.0);
                }
            });

            try {
                yield installer.download_latest ();
                /* Make sure the freshly installed managed binary is the one
                   Parla resolves immediately. */
                if (app_window.settings.rpc_server_source != RpcServerSource.AUTO) {
                    app_window.settings.save_rpc_server_source (RpcServerSource.AUTO);
                    sync_rpc_source_dropdown ();
                }
                app_window.show_toast ("Chatmail Core installed");
                yield app_window.reconnect_rpc_server ();
            } catch (Error e) {
                rpc_row.subtitle = prev_subtitle;
                app_window.show_toast ("Download failed: " + e.message);
            } finally {
                rpc_check_btn.sensitive = !SettingsManager.rpc_server_path_is_fixed ();
            }
            update_rpc_row ();
        }

        private async void open_rpc_download_page () {
            try {
                yield (new Gtk.UriLauncher (
                    "https://github.com/chatmail/core/releases/latest")).launch (
                    app_window, null);
            } catch (Error e) {
                show_error (app_window, "Unable to open download page: " + e.message);
            }
        }

        private async void on_reset_settings () {
            if (yield confirm_action (app_window, "Factory Reset",
                "This will delete all Parla configuration files and close the application. " +
                "Your Delta Chat accounts and messages are not affected.",
                "reset", "Reset & Close")) {
                delete_parla_config ();
                app_window.quit_application ();
            }
        }

        private void apply_background () {
            ((Dc.Application) app_window.application).apply_background (
                app_window.settings.background_mode,
                app_window.settings.background_color);
        }

        private void apply_theme_override () {
            ((Dc.Application) app_window.application).apply_theme_override (
                app_window.settings.theme_override);
        }

        private static void apply_hex_to_button (Gtk.ColorDialogButton btn,
                                                  string hex) {
            var rgba = Gdk.RGBA ();
            if (hex.length == 0 || !rgba.parse (hex)) {
                rgba.parse ("#3584e4");
            }
            btn.set_rgba (rgba);
        }

        private static void delete_parla_config () {
            var dir = Path.build_filename (
                Environment.get_user_config_dir (), "parla");
            FileUtils.unlink (Path.build_filename (dir, "settings.ini"));
            DirUtils.remove (dir);
        }
    }

}
