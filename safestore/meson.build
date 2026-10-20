project('safestore', ['vala', 'c'], version: '0.1.0', meson_version: '>= 0.59.0')

safestore_desktop = host_machine.system() in ['linux', 'darwin', 'windows']
safestore_install_devel = get_option('install_devel')
if host_machine.system() == 'windows'
  add_project_arguments('--define=WINDOWS', language: 'vala')
endif
subdir('lib')

frontend_sources = files('frontend/accounts_path.vala', 'frontend/settings.vala')
frontend_args = []
if host_machine.system() != 'windows'
  frontend_args += ['--pkg', 'posix']
endif

if get_option('cli')
  executable('safestore', files('cli/main.vala'), frontend_sources,
    dependencies: safestore_dep, vala_args: frontend_args,
    c_args: safestore_c_args, install: true)
endif

if get_option('gui')
  adwaita_dep = dependency('libadwaita-1', version: '>= 1.5')
  gui_args = frontend_args
  if host_machine.system() == 'darwin'
    prefix = adwaita_dep.get_variable(pkgconfig: 'prefix')
    gui_args += '--vapidir=' + prefix / 'share' / 'vala' / 'vapi'
  endif
  executable('safestore-gui', files('gui/main.vala', 'gui/window.vala'), frontend_sources,
    dependencies: [safestore_dep, dependency('gtk4'), adwaita_dep],
    vala_args: gui_args, c_args: safestore_c_args,
    install: true, win_subsystem: 'windows')
  install_data('data/io.github.trufae.SafeStore.desktop',
    install_dir: get_option('datadir') / 'applications')
endif

if get_option('tests')
  subdir('tests')
endif
