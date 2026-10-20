# Shared by the standalone wrapper and Parla, which supply WINDOWS globally.
# SafeStore uses DARWIN, while Parla uses MACOS.
safestore_cc = meson.get_compiler('c')
safestore_vala_args = []
safestore_c_args = safestore_cc.get_supported_arguments([
  '-Wno-unused-but-set-variable', '-Wno-unused-function',
  '-Wno-unused-value', '-Wno-unused-variable', '-Wno-unused-label',
  '-Wno-incompatible-pointer-types', '-Wno-discarded-qualifiers',
])
safestore_core_deps = [dependency('glib-2.0', version: '>= 2.66'), dependency('gio-2.0')]
safestore_system = host_machine.system()
if safestore_system == 'windows'
  safestore_core_deps += safestore_cc.find_library('advapi32')
else
  safestore_vala_args += ['--pkg', 'posix']
  if safestore_system == 'darwin'
    safestore_vala_args += '--define=DARWIN'
  elif safestore_system == 'linux'
    safestore_vala_args += '--define=LINUX'
  endif
endif

if safestore_desktop
  safestore_zip = dependency('libzip', version: '>= 1.7')
  safestore_c_args += '-DHAVE_BACKUP_ZIP'
  if safestore_system != 'windows'
    safestore_util = safestore_cc.find_library('util', required: false)
    if safestore_util.found()
      safestore_core_deps += safestore_util
    endif
  endif
  if safestore_system == 'linux'
    safestore_secret = dependency('libsecret-1', required: false)
    if safestore_secret.found()
      safestore_vala_args += '--define=HAVE_LIBSECRET'
      safestore_core_deps += safestore_secret
    endif
  endif
else
  safestore_vala_args += '--define=SAFESTORE_UNSUPPORTED'
  safestore_c_args += '-DSAFESTORE_NO_PTY'
endif

# Keep libzip behind a C target so Vala consumers need no libzip VAPI.
safestore_archive_deps = [dependency('gio-2.0')]
if safestore_desktop
  safestore_archive_deps += safestore_zip
endif
if safestore_system == 'windows'
  safestore_archive_deps += safestore_cc.find_library('advapi32')
endif
safestore_archive_lib = static_library('safestore-backup', 'backup_archive.c',
  dependencies: safestore_archive_deps, c_args: safestore_c_args,
  install: safestore_install_devel)
safestore_core_deps += declare_dependency(link_with: safestore_archive_lib)

safestore_sources = files(
  'backups.vala', 'backup_archive.vapi',
  'metadata.vala', 'accounts_location.vala', 'zip_format.vala', 'lease.vapi', 'lease.c',
  'store.vala', 'settings.vala', 'backend.vala', 'path_policy.vala',
  'secret_memory.vapi', 'secret_value.vala', 'zip_backend.vala',
  'plaintext_eraser.vala', 'mount_check.vala', 'vault.vala',
  'keyring.vala', 'credential_store.vala', 'cryfs_controller.vala',
  'pty_password.c',
)
safestore_inc = include_directories('.')
safestore_lib = static_library(
  'safestore-1', safestore_sources,
  dependencies: safestore_core_deps,
  vala_args: safestore_vala_args,
  c_args: safestore_c_args,
  vala_header: 'safestore-1.h',
  vala_vapi: 'safestore-1.vapi',
  include_directories: safestore_inc,
  install: safestore_install_devel,
  install_dir: [get_option('libdir'), get_option('includedir') / 'safestore-1',
                get_option('datadir') / 'vala' / 'vapi'],
)
safestore_dep = declare_dependency(
  link_with: safestore_lib,
  include_directories: safestore_inc,
  dependencies: safestore_core_deps,
)

if safestore_install_devel
  import('pkgconfig').generate(
    safestore_lib, name: 'SafeStore', filebase: 'safestore-1',
    description: 'Experimental encrypted account storage API',
    version: '0.1.0', subdirs: 'safestore-1',
  )
  install_data('safestore-1.deps',
    install_dir: get_option('datadir') / 'vala' / 'vapi')
endif
