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

        public string css_style () {
            return (this == ITALIC || this == BOLD_ITALIC) ? "italic" : "normal";
        }

        public string css_weight () {
            return (this == BOLD || this == BOLD_ITALIC) ? "bold" : "normal";
        }
    }

    public class SettingsManager : Object {

        public signal void appearance_changed ();
        public signal void font_changed ();
        public signal void disk_space_settings_changed ();

        public int double_click_action { get; set; default = 0; }
        public MarkdownMode markdown_mode { get; set; default = MarkdownMode.ENABLED; }
        public CodeTheme code_theme { get; set; default = CodeTheme.ADAPTIVE; }
        public bool a11y_enabled { get; private set; default = true; }
        public bool long_press_context_menu { get; set; default = false; }
        public bool shift_enter_sends { get; set; default = false; }
        public bool clean_pasted_links { get; set; default = false; }
        /* Replace the built-in tracking rules with a uBlock/AdGuard
           $removeparam filter list downloaded from tracking_filter_url. */
        public bool tracking_filter_enabled { get; set; default = false; }
        public string tracking_filter_url { get; set; default = ""; }
        /* Fetch Open Graph metadata for pasted links and attach the
           preview image (sender-side, like Signal). On by default; users
           who do not want the linked site to see their address can turn
           it off in Settings → Links. */
        public bool link_previews { get; set; default = true; }
        public bool notifications_enabled { get; set; default = true; }
        public bool show_notification_contents { get; set; default = true; }
        public bool minimize_to_tray { get; set; default = false; }
        public bool system_audio_player { get; set; default = false; }
        public bool animate_stickers { get; set; default = true; }
        /* Only honored in builds with -Dwebxdc=true (Webxdc.AVAILABLE). */
        public bool webxdc_apps { get; set; default = true; }
        public bool webxdc_realtime { get; set; default = true; }
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
        public bool webxdc_developer_tools { get; set; default =
            WebxdcSecurity.SAFE_DEVELOPER_TOOLS; }
        public int auto_download_limit { get; set; default = AUTO_DOWNLOAD_DEFAULT; }
        public string rpc_server_path { get; set; default = ""; }
        /* An empty value deliberately means the standard Parla account store. */
        public string accounts_path { get; set; default = ""; }
        public RpcServerSource rpc_server_source { get; set; default = RpcServerSource.AUTO; }
        public bool rpc_check_updates_on_startup { get; set; default = true; }
        public bool check_disk_space { get; private set; default = true; }
        public int low_disk_space_gb { get; private set; default = 1; }
        public SidebarMode sidebar_mode { get; set; default = SidebarMode.FULL; }
        public string default_account_addr { get; set; default = ""; }
        public ThemeOverride theme_override { get; set; default = ThemeOverride.SYSTEM; }
        public string language { get; private set; default = ""; }
        public MessageStyle message_style { get; set; default = MessageStyle.BUBBLES; }
        public BubbleAvatarDisplay bubble_avatar_display { get; set; default = BubbleAvatarDisplay.NONE; }
        public bool bubble_avatars_in_direct_chats { get; set; default = false; }
        public string accent_color { get; set; default = ""; }
        public BackgroundMode background_mode { get; set; default = BackgroundMode.SYSTEM; }
        public string background_color { get; set; default = ""; }
        public string font_family { get; set; default = ""; }
        public FontAttribute font_attribute { get; set; default = FontAttribute.REGULAR; }
        public int font_size { get; set; default = FONT_SIZE_SYSTEM; }
        private const uint FONT_SAVE_DEBOUNCE_MS = 250;
        private uint font_save_source = 0;

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
#if ANDROID
            return true; // The core is installed and updated with the APK.
#else
            return Parla.RPC_SERVER_PATH.length > 0;
#endif
        }

        /** Server path to actually use: the pinned one if set, else the user's. */
        public string effective_rpc_server_path () {
#if ANDROID
            return Environment.get_variable ("PARLA_RPC_SERVER") ?? "";
#else
            return rpc_server_path_is_fixed ()
                ? Parla.RPC_SERVER_PATH : rpc_server_path;
#endif
        }

        /** Server source to actually use: Custom when pinned, else the user's. */
        public RpcServerSource effective_rpc_server_source () {
            return rpc_server_path_is_fixed ()
                ? RpcServerSource.CUSTOM : rpc_server_source;
        }

        /** A per-launch override, never written to the user's preferences. */
        public static bool? startup_update_checks_override () {
            string? value = Environment.get_variable ("PARLA_CHECK_UPDATES");
            if (value == null) return null;
            switch (value.strip ().ascii_down ()) {
            case "1": case "true": case "yes": case "on":
                return true;
            case "0": case "false": case "no": case "off":
                return false;
            default:
                return null;
            }
        }

        public static bool startup_update_checks_configurable () {
            return Parla.UPDATE_CHECKS && startup_update_checks_override () == null;
        }

        public bool startup_update_checks_enabled () {
            return startup_update_checks_override () ??
                (Parla.UPDATE_CHECKS && rpc_check_updates_on_startup);
        }

        /** Whether to check for managed engine updates at startup. */
        public bool rpc_auto_update_enabled () {
            return !rpc_server_path_is_fixed () && startup_update_checks_enabled ();
        }

        public string default_accounts_path () {
            return Path.build_filename (AccountFinder.get_data_dir (), "accounts");
        }

        private string normalize_accounts_path (string value) {
            return SafeStore.AccountsLocation.normalize (value);
        }

        public bool is_default_accounts_path (string value) {
            return normalize_accounts_path (value) == default_accounts_path ();
        }

        public bool uses_default_accounts_path () {
            return is_default_accounts_path (accounts_path);
        }

        public string effective_accounts_path () {
            return SafeStore.AccountsLocation.resolve (
                Environment.get_variable ("DC_ACCOUNTS_PATH"), accounts_path, default_accounts_path ());
        }

        public void load () {
            var kf = new KeyFile ();
            try { kf.load_from_file (get_config_path (), KeyFileFlags.NONE); }
            catch (Error e) { /* file may not exist — helpers return defaults */ }
            double_click_action = kf_enum (kf, "double_click_action", 0, 5);
            markdown_mode = kf_markdown_mode (kf);
            code_theme = (CodeTheme) kf_enum (kf, "code_theme",
                (int) CodeTheme.ADAPTIVE, (int) CodeTheme.NONE);
            a11y_enabled = kf_bool (kf, "a11y_enabled", true);
            long_press_context_menu = kf_bool (kf, "long_press_context_menu",
                Platform.is_android () || is_phosh_session ());
            shift_enter_sends = kf_bool (kf, "shift_enter_sends", false);
            clean_pasted_links = kf_bool (kf, "clean_pasted_links", false);
            tracking_filter_enabled =
                kf_bool (kf, "tracking_filter_enabled", false);
            tracking_filter_url = kf_str (kf, "tracking_filter_url", "").strip ();
            apply_tracking_filter ();
            link_previews = kf_bool (kf, "link_previews", true);
            notifications_enabled = kf_bool (kf, "notifications_enabled", true);
            show_notification_contents =
                kf_bool (kf, "show_notification_contents", true);
            minimize_to_tray = kf_bool (kf, "minimize_to_tray", false);
#if ANDROID
            minimize_to_tray = false;
            notifications_enabled = false;
#endif
            system_audio_player = kf_bool (kf, "system_audio_player", false);
            animate_stickers = kf_bool (kf, "animate_stickers", true);
            webxdc_apps = kf_bool (kf, "webxdc_apps", true);
            webxdc_realtime = kf_bool (kf, "webxdc_realtime", true);
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
            webxdc_developer_tools = kf_bool (kf,
                "webxdc_developer_tools",
                WebxdcSecurity.SAFE_DEVELOPER_TOOLS);
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
            check_disk_space = kf_bool (kf, "check_disk_space", true);
            low_disk_space_gb = kf_int (kf, "low_disk_space_gb", 1).clamp (1, 1024);
            int sb = kf_enum (kf, "sidebar_mode", (int) SidebarMode.FULL, 2);
            sidebar_mode = (SidebarMode) sb;
            default_account_addr = kf_str (kf, "default_account_addr", "");
            language = Localization.normalize_language (kf_str (kf, "language", ""));
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

        /* Read before initializing GTK/gettext, without loading unrelated
           settings or constructing any widgets. */
        public static string load_language () {
            var kf = new KeyFile ();
            try { kf.load_from_file (get_config_path (), KeyFileFlags.NONE); }
            catch (Error e) { return ""; }
            return Localization.normalize_language (kf_str (kf, "language", ""));
        }

        public void save_language (string code) {
            language = Localization.normalize_language (code);
            save_string ("language", language);
        }

        /* GTK chooses its accessibility backend before the window loads
           the rest of the settings. Leave the platform default enabled. */
        public static bool load_a11y_enabled () {
            var kf = new KeyFile ();
            try { kf.load_from_file (get_config_path (), KeyFileFlags.NONE); }
            catch (Error e) { return true; }
            return kf_bool (kf, "a11y_enabled", true);
        }

        public void save_a11y_enabled (bool enabled) {
            a11y_enabled = enabled;
            save_bool ("a11y_enabled", enabled);
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
            save_int ("markdown_rendering", (int) mode);
            appearance_changed ();
        }

        public void save_code_theme (CodeTheme theme) {
            code_theme = theme;
            save_int ("code_theme", (int) theme);
            appearance_changed ();
        }

        public void save_long_press_context_menu (bool v) {
            long_press_context_menu = v;
            save_bool ("long_press_context_menu", v);
        }

        public void save_shift_enter_sends (bool v) {
            shift_enter_sends = v;
            save_bool ("shift_enter_sends", v);
        }

        public void save_clean_pasted_links (bool v) {
            clean_pasted_links = v;
            save_bool ("clean_pasted_links", v);
        }

        public void save_tracking_filter_enabled (bool v) {
            tracking_filter_enabled = v;
            save_bool ("tracking_filter_enabled", v);
            apply_tracking_filter ();
        }

        public void save_tracking_filter_url (string v) {
            tracking_filter_url = v.strip ();
            save_string ("tracking_filter_url", tracking_filter_url);
        }

        /** Installs the cached filter list as the active link cleaner
            when enabled, or reverts to the built-in rules. */
        public void apply_tracking_filter () {
            RemoveParamFilter.active =
                tracking_filter_enabled && tracking_filter_url.length > 0
                    ? RemoveParamFilter.load_cached () : null;
        }

        public void save_link_previews (bool v) {
            link_previews = v;
            save_bool ("link_previews", v);
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

        public void save_webxdc_realtime (bool v) {
            webxdc_realtime = v;
            save_bool ("webxdc_realtime", v);
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

        public void save_webxdc_developer_tools (bool v) {
            webxdc_developer_tools = v;
            save_bool ("webxdc_developer_tools", v);
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

        // Switching after restore must not silently succeed if persistence fails.
        public void save_restored_accounts_path (string path) throws Error {
            var key = new KeyFile ();
            try { key.load_from_file (get_config_path (), KeyFileFlags.NONE); }
            catch (FileError.NOENT e) { }
            key.set_string ("General", "accounts_path", path);
            if (DirUtils.create_with_parents (Path.get_dirname (get_config_path ()), 0700) != 0)
                throw new IOError.FAILED (_("Could not create the settings folder"));
            try {
                FileUtils.set_contents_full (get_config_path (), key.to_data (), -1,
                    FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
            } catch (Error e) {
                // A flush error can follow publication. Follow the file that is
                // actually selected so this process and the next start agree.
                var observed = new KeyFile ();
                bool published = false;
                try {
                    observed.load_from_file (get_config_path (), KeyFileFlags.NONE);
                    published = observed.get_string ("General", "accounts_path") == path;
                } catch (Error ignored) { }
                if (published) {
                    accounts_path = path;
                    throw new IOError.FAILED (_("The restored folder was selected, but durable settings storage could not be confirmed: %s").printf (e.message));
                }
                throw e;
            }
            accounts_path = path;
        }

        public void save_rpc_server_source (RpcServerSource v) {
            rpc_server_source = v;
            save_int ("rpc_server_source", (int) v);
        }

        public void save_rpc_check_updates_on_startup (bool v) {
            rpc_check_updates_on_startup = v;
            save_bool ("rpc_check_updates_on_startup", v);
        }

        public void save_check_disk_space (bool v) {
            check_disk_space = v;
            save_bool ("check_disk_space", v);
            disk_space_settings_changed ();
        }

        public void save_low_disk_space_gb (int v) {
            low_disk_space_gb = v.clamp (1, 1024);
            save_int ("low_disk_space_gb", low_disk_space_gb);
            disk_space_settings_changed ();
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

        public void reset_font_defaults () {
            save_font ("", FontAttribute.REGULAR, FONT_SIZE_SYSTEM);
        }

        public void save_font (string family, FontAttribute attr, int size) {
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
            schedule_font_save ();
            font_changed ();
        }

        private void schedule_font_save () {
            /* Wheel zoom may produce dozens of changes in one gesture. Keep
               the in-memory setting immediate, but persist only after rest. */
            if (font_save_source != 0) {
                Source.remove (font_save_source);
                font_save_source = 0;
            }
            font_save_source = add_font_save_timeout (this);
        }

        private static uint add_font_save_timeout (SettingsManager target) {
            WeakRef settings_ref = WeakRef (target);
            return Timeout.add (FONT_SAVE_DEBOUNCE_MS, () => {
                var settings = settings_ref.get () as SettingsManager;
                if (settings != null) {
                    settings.font_save_source = 0;
                    settings.write_font_settings ();
                }
                return Source.REMOVE;
            });
        }

        private void write_font_settings () {
            save_to_file ((kf) => {
                kf.set_string ("General", "font_family", font_family);
                kf.set_integer ("General", "font_attribute",
                                (int) font_attribute);
                kf.set_integer ("General", "font_size", font_size);
            });
        }

        public override void dispose () {
            if (font_save_source != 0) {
                Source.remove (font_save_source);
                font_save_source = 0;
                write_font_settings ();
            }
            base.dispose ();
        }

        public static int clamp_font_size (int size) {
            if (size <= FONT_SIZE_SYSTEM) return FONT_SIZE_SYSTEM;
            if (size < FONT_SIZE_MIN) return FONT_SIZE_MIN;
            if (size > FONT_SIZE_MAX) return FONT_SIZE_MAX;
            return size;
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

}
