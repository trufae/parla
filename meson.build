# to release update version field below and:
# vim data/io.github.trufae.Parla.appdata.xml
project('parla', ['vala', 'c'],
  version: '0.8.0',
  meson_version: '>= 0.59.0',
  default_options: ['werror=true', 'cpp_std=c++17'],
)

# posix vapi provides Posix.getpid () for the StatusNotifierItem bus name.
# mingw-w64 ships pid_t/getpid but no kill()/SIGKILL, so Windows-only code
# paths are selected with the WINDOWS Vala define.
add_project_arguments(['--pkg', 'posix'], language: 'vala')
if host_machine.system() == 'windows'
  add_project_arguments(['--define=WINDOWS'], language: 'vala')
endif

# Silence warnings emitted by valac-generated C and lagging GTK/glib vapi
# bindings (unused temporaries, g_once_init_enter atomics, const mismatches).
# These are not fixable from the Vala source.
cc = meson.get_compiler('c')
add_project_arguments(
  cc.get_supported_arguments([
    '-Wno-unused-but-set-variable',
    '-Wno-unused-function',
    '-Wno-unused-variable',
    '-Wno-incompatible-pointer-types',
    '-Wno-discarded-qualifiers',
    '-Wno-address',
  ]),
  language: 'c',
)

deps = [
  dependency('glib-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.5'),
  dependency('json-glib-1.0'),
]

config = configuration_data()
config.set('VERSION', meson.project_version())
config.set('RPC_SERVER_PATH', get_option('rpc_server_path'))
config_file = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: config,
)

python = import('python').find_installation()
appdata_xml = files('data/io.github.trufae.Parla.appdata.xml')
appdata_vala = custom_target(
  'appdata-vala',
  input: appdata_xml,
  output: 'appdata.vala',
  command: [
    python,
    files('build-aux/gen-appdata.py'),
    '@INPUT@',
    '@OUTPUT@',
  ],
)
configure_file(
  input: appdata_xml,
  output: 'io.github.trufae.Parla.metainfo.xml',
  copy: true,
  install: true,
  install_dir: get_option('datadir') / 'metainfo',
)

gnome = import('gnome')
resources = gnome.compile_resources(
  'parla-resources',
  'data/parla.gresource.xml',
  source_dir: 'data/icons/hicolor',
)

src_inc = include_directories('src')
sources = files(
  'src/main.vala',
  'src/platform.vala',
  'src/subprocess.vala',
  'src/platform.c',
  'src/application.vala',
  'src/window.vala',
  'src/rpc_transport.vala',
  'src/rpc_params.vala',
  'src/attachment_types.vala',
  'src/rpc_parsers.vala',
  'src/rpc_client.vala',
  'src/account_finder.vala',
  'src/rpc_installer.vala',
  'src/models.vala',
  'src/message_history.vala',
  'src/chat_row.vala',
  'src/markdown.vala',
  'src/syntax_highlight.vala',
  'src/mentions.vala',
  'src/image_utils.vala',
  'src/message_row.vala',
  'src/image_viewer.vala',
  'src/video_player.vala',
  'src/audio_player.vala',
  'src/whisper.vala',
  'src/audio_recorder.vala',
  'src/conversation_media_bar.vala',
  'src/compose_bar.vala',
  'src/link_cleaner.vala',
  'src/emoji.vala',
  'src/file_drop.vala',
  'src/conversation_view.vala',
  'src/full_message_dialog.vala',
  'src/chat_info_dialog.vala',
  'src/sticker_store.vala',
  'src/sticker_manager_dialog.vala',
  'src/sticker_picker.vala',
  'src/contact_picker_dialog.vala',
  'src/new_group_dialog.vala',
  'src/settings_dialog.vala',
  'src/storage_quota.vala',
  'src/profile_dialog.vala',
  'src/qr_code_view.vala',
  'src/pinned_messages_manager.vala',
  'src/webxdc_bar.vala',
  'src/webxdc_manager_dialog.vala',
  'src/webxdc_security.vala',
  'src/quick_switch_dialog.vala',
  'src/event_handler.vala',
  'src/message_details_dialog.vala',
  'src/message_actions.vala',
  'src/save_folder.vala',
  'src/gallery_dialog.vala',
  'src/account_creation.vala',
  'src/classic_email_dialog.vala',
  'src/relay_picker.vala',
)

# Each platform ships only its own tray backend: the freedesktop
# StatusNotifierItem (tray_icon.vala) everywhere except macOS, where an
# NSStatusItem shim replaces it (tray_macos.*, selected in window.vala
# through the MACOS Vala define).
if host_machine.system() == 'darwin'
  add_languages('objc', native: false)
  add_project_arguments(['--define=MACOS'], language: 'vala')
  sources += files(
    'src/platform_macos.m',
    'src/tray_macos.m',
    'src/tray_macos.vala',
  )
  deps += dependency('appleframeworks', modules: ['Cocoa'])
else
  sources += files('src/tray_icon.vala')
endif

# Experimental Webxdc runner (docs/webxdc.md), off by default. Linux uses
# WebKitGTK, macOS uses its system WebKit framework, and Windows uses the
# installed Evergreen WebView2 Runtime through Microsoft's SDK loader.
# Native implementations remain isolated in their platform files.
if get_option('webxdc')
  sources += files('src/webxdc.vala')
  if host_machine.system() == 'darwin'
    sources += files('src/webxdc_macos.m')
    deps += dependency('appleframeworks', modules: ['WebKit'])
  elif host_machine.system() == 'windows'
    webview2_sdk = get_option('webview2_sdk')
    if webview2_sdk == ''
      error('Windows Webxdc builds need -Dwebview2_sdk=/path/to/Microsoft.Web.WebView2')
    endif
    add_languages('cpp', native: false)
    sources += files('src/webxdc_windows.cpp')
    webview2_inc = include_directories(
      webview2_sdk / 'build/native/include',
      is_system: true,
    )
    deps += declare_dependency(include_directories: webview2_inc)
    deps += cc.find_library('ole32')
    deps += cc.find_library('uuid')

    webview2_arch = ''
    if host_machine.cpu_family() == 'x86_64'
      webview2_arch = 'x64'
    elif host_machine.cpu_family() == 'x86'
      webview2_arch = 'x86'
    elif host_machine.cpu_family() == 'aarch64'
      webview2_arch = 'arm64'
    else
      error('The WebView2 SDK has no loader for ' + host_machine.cpu_family())
    endif
    configure_file(
      input: webview2_sdk / 'build/native' / webview2_arch / 'WebView2Loader.dll',
      output: 'WebView2Loader.dll',
      copy: true,
      install: true,
      install_dir: get_option('bindir'),
    )
    configure_file(
      input: webview2_sdk / 'LICENSE.txt',
      output: 'WebView2-LICENSE.txt',
      copy: true,
      install: true,
      install_dir: get_option('datadir') / 'licenses' / 'parla',
    )
  else
    deps += dependency('webkitgtk-6.0')
  endif
else
  sources += files('src/webxdc_stub.vala')
endif

# Ubuntu 24.04 and newer can restrict unprivileged user namespaces with
# AppArmor. WebKitGTK's bubblewrap sandbox needs those namespaces, so native
# Linux installs carry a narrowly attached profile for the installed Parla
# executable. Flatpak has its own outer sandbox and must not install host
# policy below /app.
if get_option('webxdc') \
    and host_machine.system() == 'linux' \
    and get_option('prefix') != '/app'
  apparmor_conf = configuration_data()
  apparmor_conf.set(
    'PARLA_BINARY',
    get_option('prefix') / get_option('bindir') / 'parla',
  )
  apparmor_profile = configure_file(
    input: 'data/apparmor/parla.in',
    output: 'parla.apparmor',
    configuration: apparmor_conf,
  )
  meson.add_install_script(
    'build-aux/install-apparmor-profile.sh',
    apparmor_profile,
  )
endif

if host_machine.system() == 'windows'
  sources += files('src/platform_win32.c')
  deps += dependency('gio-windows-2.0')
  windows = import('windows')
  sources += windows.compile_resources(
    'data/parla.rc',
    depend_files: files('data/parla.ico'),
    include_directories: include_directories('data'),
  )
endif

executable('parla',
  sources, config_file, appdata_vala, resources,
  dependencies: deps,
  include_directories: src_inc,
  install: true,
  # GUI subsystem on Windows so no console window pops up; ignored elsewhere.
  win_subsystem: 'windows',
)

install_data(
  'data/io.github.trufae.Parla.desktop',
  install_dir: get_option('datadir') / 'applications',
)

# D-Bus activation (DBusActivatable=true in the desktop file): launchers
# start Parla by asking the bus for this name instead of forking Exec.
dbus_service_conf = configuration_data()
dbus_service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/io.github.trufae.Parla.service.in',
  output: 'io.github.trufae.Parla.service',
  configuration: dbus_service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services',
)

install_data(
  'data/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg',
  'data/icons/hicolor/scalable/apps/parla-welcome.svg',
  'data/icons/hicolor/scalable/apps/parla-tray.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)

save_folder_test = executable(
  'save-folder-test',
  files('tests/save_folder_test.vala', 'src/save_folder.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0'),
                 dependency('gio-2.0')],
  install: false,
)

test('save-folder', save_folder_test)

link_cleaner_test = executable(
  'link-cleaner-test',
  files('tests/link_cleaner_test.vala', 'src/link_cleaner.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0')],
  install: false,
)

test('link-cleaner', link_cleaner_test)

storage_quota_test = executable(
  'storage-quota-test',
  files('tests/storage_quota_test.vala', 'src/storage_quota.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0')],
  install: false,
)

test('storage-quota', storage_quota_test)

markdown_test = executable(
  'markdown-test',
  files('tests/markdown_test.vala', 'src/markdown.vala',
        'src/syntax_highlight.vala'),
  dependencies: [dependency('glib-2.0'), dependency('pango')],
  install: false,
)

test('markdown', markdown_test)

mentions_test = executable(
  'mentions-test',
  files('tests/mentions_test.vala', 'src/mentions.vala', 'src/markdown.vala',
        'src/syntax_highlight.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0'),
                 dependency('pango')],
  install: false,
)

test('mentions', mentions_test)

attachment_types_test = executable(
  'attachment-types-test',
  files('tests/attachment_types_test.vala', 'src/attachment_types.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0')],
  install: false,
)

test('attachment-types', attachment_types_test)

whisper_test = executable(
  'whisper-test',
  files('tests/whisper_test.vala', 'src/whisper.vala',
        'src/subprocess.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0'),
                 dependency('gio-2.0')],
  install: false,
)

test('whisper', whisper_test)

message_history_test = executable(
  'message-history-test',
  files('tests/message_history_test.vala', 'src/message_history.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0'),
                 dependency('json-glib-1.0')],
  install: false,
)

test('message-history', message_history_test)

webxdc_security_test = executable(
  'webxdc-security-test',
  files('tests/webxdc_security_test.vala', 'src/webxdc_security.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0')],
  install: false,
)

test('webxdc-security', webxdc_security_test)
