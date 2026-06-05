project('parla', ['vala', 'c'],
  version: '0.4.0',
  meson_version: '>= 0.59.0',
)

# posix vapi provides Posix.getpid () for the StatusNotifierItem bus name
add_project_arguments(['--pkg', 'posix'], language: 'vala')

deps = [
  dependency('glib-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.5'),
  dependency('json-glib-1.0'),
]

config = configuration_data()
config.set('VERSION', meson.project_version())
config_file = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: config,
)

gnome = import('gnome')
resources = gnome.compile_resources(
  'parla-resources',
  'data/parla.gresource.xml',
  source_dir: 'data/icons/hicolor',
)

sources = files(
  'src/main.vala',
  'src/application.vala',
  'src/window.vala',
  'src/rpc_transport.vala',
  'src/rpc_params.vala',
  'src/rpc_parsers.vala',
  'src/rpc_client.vala',
  'src/account_finder.vala',
  'src/rpc_installer.vala',
  'src/models.vala',
  'src/chat_row.vala',
  'src/markdown.vala',
  'src/message_row.vala',
  'src/image_viewer.vala',
  'src/video_player.vala',
  'src/audio_player.vala',
  'src/compose_bar.vala',
  'src/conversation_view.vala',
  'src/chat_info_dialog.vala',
  'src/contact_picker_dialog.vala',
  'src/new_group_dialog.vala',
  'src/settings_dialog.vala',
  'src/tray_icon.vala',
  'src/storage_quota.vala',
  'src/profile_dialog.vala',
  'src/pinned_messages_manager.vala',
  'src/quick_switch_dialog.vala',
  'src/event_handler.vala',
  'src/message_actions.vala',
  'src/account_creation.vala',
  'src/relay_picker.vala',
)

executable('parla',
  sources, config_file, resources,
  dependencies: deps,
  install: true,
)

install_data(
  'data/io.github.trufae.Parla.desktop',
  install_dir: get_option('datadir') / 'applications',
)

install_data(
  'data/io.github.trufae.Parla.metainfo.xml',
  install_dir: get_option('datadir') / 'metainfo',
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
