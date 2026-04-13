project('deltachat-gnome', ['vala', 'c'],
  version: '0.2.0',
  meson_version: '>= 0.59.0',
)

deps = [
  dependency('glib-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.5'),
  dependency('json-glib-1.0'),
]

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

executable('deltachat-gnome',
  sources,
  dependencies: deps,
  install: true,
)

install_data(
  'data/org.deltachat.Gnome.desktop',
  install_dir: get_option('datadir') / 'applications',
)

install_data(
  'data/icons/hicolor/scalable/apps/org.deltachat.Gnome.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
