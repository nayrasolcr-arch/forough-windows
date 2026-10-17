desktop_conf = configuration_data()
desktop_conf.set('bindir', get_option('prefix') / get_option('bindir'))

desktop_file = configure_file(
  input: 'io.github.nayrasolcr.Forough.desktop.in',
  output: 'io.github.nayrasolcr.Forough.desktop',
  configuration: desktop_conf,
)

schema_file = 'io.github.nayrasolcr.Forough.gschema.xml'

fs = import('fs')
is_windows = host_machine.system() == 'windows'

if not is_windows
  # Desktop integration is POSIX-only; the Windows bundle carries the .ico
  # embedded in forough.exe plus PNG icons under share/icons instead.
  install_data(
    desktop_file,
    install_dir: get_option('datadir') / 'applications',
  )

  install_data(
    'io.github.nayrasolcr.Forough.metainfo.xml.in',
    rename: 'io.github.nayrasolcr.Forough.metainfo.xml',
    install_dir: get_option('datadir') / 'metainfo',
  )

  core_libdir = get_option('libdir') / 'forough'
  core_install_path = get_option('prefix') / core_libdir / 'psiphon-tunnel-core-x86_64'
  sing_box_install_path = get_option('prefix') / core_libdir / 'sing-box'

  override_conf = configuration_data()
  override_conf.set('core_path', core_install_path)
  override_conf.set('sing_box_path', sing_box_install_path)
  install_data(
    configure_file(
      input: 'io.github.nayrasolcr.Forough.gschema.override.in',
      output: 'io.github.nayrasolcr.Forough.gschema.override',
      configuration: override_conf,
    ),
    install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
  )

  core_source = project_root / 'psiphon-tunnel-core-x86_64'
  if fs.exists(core_source)
    install_data(
      core_source,
      install_dir: core_libdir,
      install_mode: 'rwxr-xr-x',
      rename: 'psiphon-tunnel-core-x86_64',
    )
  endif

  sing_box_source = project_root / 'sing-box'
  if fs.exists(sing_box_source)
    install_data(
      sing_box_source,
      install_dir: core_libdir,
      install_mode: 'rwxr-xr-x',
      rename: 'sing-box',
    )
  endif

  libcronet_source = project_root / 'libcronet.so'
  if fs.exists(libcronet_source)
    install_data(
      libcronet_source,
      install_dir: core_libdir,
      install_mode: 'rwxr-xr-x',
      rename: 'libcronet.so',
    )
  endif
endif

install_data(
  schema_file,
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
)

gnome.compile_schemas(
  build_by_default: true,
  depend_files: files(
    schema_file,
  ),
)

# Hicolor icons (PNG) — used by both the Linux install and the portable
# Windows bundle (share/icons/hicolor/...).
icon_sizes = ['16x16', '24x24', '32x32', '48x48', '64x64', '128x128', '256x256']
foreach size : icon_sizes
  icon = 'icons/hicolor' / size / 'apps' / 'io.github.nayrasolcr.Forough.png'
  if fs.exists(icon)
    install_data(
      icon,
      install_dir: get_option('datadir') / 'icons' / 'hicolor' / size / 'apps',
    )
  endif
endforeach

install_data(
  'io.github.nayrasolcr.Forough.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
