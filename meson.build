project('deltachat-gnome', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0',
)

deps = [
  dependency('glib-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.0'),
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
  'src/message_row.vala',
  'src/compose_bar.vala',
  'src/chat_info_dialog.vala',
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
