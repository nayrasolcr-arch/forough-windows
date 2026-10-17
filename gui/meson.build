project(
  'forough-gui',
  ['vala', 'c'],
  version: '2.0.0',
  meson_version: '>=0.59.0',
)

gnome = import('gnome')

is_windows = host_machine.system() == 'windows'

# Explicitly define the WINDOWS preprocessor symbol for Vala's #if
# directives. (valac on a mingw host usually defines it already; passing it
# makes the build independent of that detail.)
if is_windows
  add_project_arguments('-D', 'WINDOWS', language: ['vala'])
endif

node = find_program('node')
project_root = meson.project_source_root() / '..'

bundle_stamp = custom_target(
  'bundle-server-list',
  output: 'bundle-server-list.stamp',
  command: [node, project_root / 'scripts' / 'bundle-server-list.js', '@OUTPUT@'],
  build_by_default: true,
)

version_json = custom_target(
  'generate-version',
  output: 'version.json',
  command: [node, project_root / 'scripts' / 'generate-version.js', '--gui-output', '@OUTPUT@'],
  build_by_default: true,
  install: true,
  install_dir: get_option('datadir') / 'forough',
)

deps = [
  dependency('gtk4', version: '>=4.6'),
  dependency('libadwaita-1', version: '>=1.2'),
  dependency('json-glib-1.0'),
  dependency('gio-2.0'),
  dependency('glib-2.0'),
]

sources = files(
  'src/main.vala',
  'src/application.vala',
  'src/window.vala',
  'src/widgets/connection-panel.vala',
  'src/widgets/settings-dialog.vala',
  'src/widgets/scanner-dialog.vala',
  'src/widgets/logs-dialog.vala',
  'src/widgets/stats-panel.vala',
  'src/services/config-service.vala',
  'src/services/settings-service.vala',
  'src/services/log-service.vala',
  'src/services/ip-service.vala',
  'src/services/server-list-service.vala',
  'src/services/notice-parser.vala',
  'src/services/stats-service.vala',
  'src/services/tunnel-manager.vala',
  'src/services/cdn-scanner.vala',
  'src/services/cloudflare-service.vala',
  'src/services/system-proxy-service.vala',
  'src/services/sing-box-manager.vala',
  'src/models/protocol-mode.vala',
  'src/models/region.vala',
  'src/models/tunnel-options.vala',
  'src/models/tunnel-stats.vala',
  'src/utils/constants.vala',
  'src/utils/i18n.vala',
  'src/utils/format.vala',
  'src/utils/gsettings-setup.vala',
  'src/utils/runtime-paths.vala',
  'src/utils/region-flags.vala',
  'src/utils/version-info.vala',
  'src/widgets/about-dialog.vala',
)

extra_sources = []
if is_windows
  # Embedded application icon + version info for forough.exe (compiled with
  # x86_64-w64-mingw32-windres, part of the mingw binutils package).
  mod = import('windows')
  extra_sources += mod.compile_resources('forough.rc')
endif

executable(
  'forough',
  sources,
  extra_sources,
  bundle_stamp,
  version_json,
  dependencies: deps,
  install: true,
)

fs = import('fs')
config_assets = [
  '../configs/psiphon.config',
]
list_source = project_root / 'configs' / 'server_list_compressed'
if fs.exists(list_source)
  config_assets += '../configs/server_list_compressed'
endif

install_data(
  config_assets,
  install_dir: get_option('datadir') / 'forough' / 'configs',
)

if fs.exists(list_source)
  install_data(
    list_source,
    install_dir: get_option('datadir') / 'forough' / 'configs',
    rename: 'remote_server_list',
  )
endif

subdir('data')

if is_windows
  summary('Forough engine runtime location', get_option('bindir') / 'psiphon-tunnel-core-x86_64.exe (deployed next to forough.exe in the bundle)', section: 'Paths')
else
  summary('Forough engine install path', get_option('prefix') / get_option('libdir') / 'forough' / 'psiphon-tunnel-core-x86_64', section: 'Paths')
endif
