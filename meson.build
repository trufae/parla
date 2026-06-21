project('parla', ['vala', 'c'],
  version: '0.5.4',
  meson_version: '>= 0.59.0',
)

# posix vapi provides Posix.getpid () for the StatusNotifierItem bus name
add_project_arguments(['--pkg', 'posix'], language: 'vala')

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
  'src/platform.c',
  'src/application.vala',
  'src/window.vala',
  'src/shortcuts/chat_switcher.vala',
  'src/rpc_transport.vala',
  'src/rpc_params.vala',
  'src/rpc_parsers.vala',
  'src/rpc_client.vala',
  'src/account_finder.vala',
  'src/rpc_installer.vala',
  'src/models.vala',
  'src/chat_row.vala',
  'src/markdown.vala',
  'src/image_utils.vala',
  'src/message_row.vala',
  'src/image_viewer.vala',
  'src/video_player.vala',
  'src/audio_player.vala',
  'src/compose_bar.vala',
  'src/emoji.vala',
  'src/file_drop.vala',
  'src/conversation_view.vala',
  'src/chat_info_dialog.vala',
  'src/contact_picker_dialog.vala',
  'src/new_group_dialog.vala',
  'src/settings_dialog.vala',
  'src/tray_icon.vala',
  'src/storage_quota.vala',
  'src/profile_dialog.vala',
  'src/qr_code_view.vala',
  'src/pinned_messages_manager.vala',
  'src/quick_switch_dialog.vala',
  'src/event_handler.vala',
  'src/message_actions.vala',
  'src/account_creation.vala',
  'src/relay_picker.vala',
)

if host_machine.system() == 'darwin'
  add_languages('objc', native: false)
  sources += files('src/platform_macos.m')
  deps += dependency('appleframeworks', modules: ['Cocoa'])
  if get_option('macos_clipboard_workaround')
    add_project_arguments(
      ['--define=PARLA_MACOS_CLIPBOARD_WORKAROUND'],
      language: 'vala',
    )
    add_project_arguments(
      ['-DPARLA_MACOS_CLIPBOARD_WORKAROUND=1'],
      language: ['c', 'objc'],
    )
  endif
endif

executable('parla',
  sources, config_file, appdata_vala, resources,
  dependencies: deps,
  include_directories: src_inc,
  install: true,
)

install_data(
  'data/io.github.trufae.Parla.desktop',
  install_dir: get_option('datadir') / 'applications',
)

install_data(
  'data/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg',
  'data/icons/hicolor/scalable/apps/parla-welcome.svg',
  'data/icons/hicolor/scalable/apps/parla-tray.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)

storage_quota_test = executable(
  'storage-quota-test',
  files('tests/storage_quota_test.vala', 'src/storage_quota.vala'),
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0')],
  install: false,
)

test('storage-quota', storage_quota_test)

markdown_test = executable(
  'markdown-test',
  files('tests/markdown_test.vala', 'src/markdown.vala'),
  dependencies: [dependency('glib-2.0'), dependency('pango')],
  install: false,
)

test('markdown', markdown_test)
