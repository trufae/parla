# Deliberately independent of parla-core, JSON, GTK and curses.
terminal_deps = [dependency('glib-2.0'), dependency('gio-2.0')]
terminal_inc = include_directories('.')
parla_terminal = static_library('parla-terminal',
  'text.vala', 'theme.vala', 'screen.vala', 'input.vala', 'completion.vala', 'view.vala', 'session.vala',
  'native.vapi', 'native.c',
  dependencies: terminal_deps,
  include_directories: terminal_inc,
  vala_args: ['--pkg', 'posix'],
  vala_header: 'parla-terminal.h', vala_vapi: 'parla-terminal.vapi',
  install: false,
)
parla_terminal_dep = declare_dependency(
  link_with: parla_terminal, dependencies: terminal_deps,
  include_directories: terminal_inc,
)
