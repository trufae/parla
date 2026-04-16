project('parla', ['vala', 'c'],
  version: '0.2.1',
  meson_version: '>= 0.59.0',
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
config_file = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: config,
)

sources = files(
  'src/main.vala',
  'src/application.vala',
  'src/window.vala',
  'src/rpc_client.vala',
  'src/account_finder.vala',
  'src/models.vala',
  'src/chat_row.vala',
  'src/markdown.vala',
  'src/message_row.vala',
  'src/compose_bar.vala',
  'src/conversation_view.vala',
  'src/chat_info_dialog.vala',
  'src/contact_picker_dialog.vala',
  'src/new_group_dialog.vala',
  'src/settings_dialog.vala',
  'src/profile_dialog.vala',
  'src/pinned_messages_manager.vala',
  'src/quick_switch_dialog.vala',
  'src/event_handler.vala',
  'src/message_actions.vala',
)

executable('parla',
  sources, config_file,
  dependencies: deps,
  install: true,
)

install_data(
  'data/io.github.trufae.Parla.desktop',
  install_dir: get_option('datadir') / 'applications',
)

install_data(
  'data/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
