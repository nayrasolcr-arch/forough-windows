namespace PsiphonCliGui.RuntimePaths {
    public string executable_path () {
#if WINDOWS
        // /proc/self/exe does not exist on Windows; ask the loader for the
        // module directory (handles Unicode paths — the W API is used
        // internally by GLib) and re-attach the exe name.
        string dir = win32_module_dir ();
        if (dir.length == 0) {
            return "";
        }
        return Path.build_filename (dir, "forough.exe");
#else
        try {
            return FileUtils.read_link ("/proc/self/exe");
        } catch (FileError e) {
            return "";
        }
#endif
    }

#if WINDOWS
    private string win32_module_dir () {
        // g_win32_get_package_installation_directory_of_module(NULL) returns
        // the directory that contains the running executable (UTF-8).
        string dir = GLib.Win32.get_package_installation_directory_of_module (null);
        return dir != null ? dir : "";
    }
#endif

    public string executable_dir () {
        string exe = executable_path ();
        if (exe.length == 0) {
            return "";
        }
        return Path.get_dirname (exe);
    }

    public string? find_schema_dir () {
        foreach (string candidate in schema_dir_candidates ()) {
            string compiled = Path.build_filename (candidate, "gschemas.compiled");
            if (FileUtils.test (compiled, FileTest.EXISTS)) {
                return candidate;
            }
        }
        return null;
    }

    public string[] config_dir_candidates () {
        string exe_dir = executable_dir ();
        string cwd = Environment.get_current_dir ();

        if (exe_dir.length > 0) {
#if WINDOWS
            // Portable bundle layout: <root>\bin\forough.exe plus
            // <root>\share\forough\configs. The binaries (psiphon-tunnel-core,
            // sing-box, wintun.dll) are also deployed into <root>\bin.
            return {
                Path.build_filename (exe_dir, "..", "share", "forough", "configs"),
                Path.build_filename (exe_dir, "..", "..", "share", "forough", "configs"),
                Path.build_filename (exe_dir, "share", "forough", "configs"),
                Path.build_filename (exe_dir, "..", "configs"),
                Path.build_filename (exe_dir, "configs"),
                Path.build_filename (cwd, "configs"),
                Path.build_filename (cwd, "..", "configs"),
                Path.build_filename (cwd, "..", "..", "configs")
            };
#else
            return {
                "/usr/share/forough/configs",
                "/usr/local/share/forough/configs",
                Path.build_filename (exe_dir, "..", "share", "forough", "configs"),
                Path.build_filename (exe_dir, "..", "..", "share", "forough", "configs"),
                Path.build_filename (cwd, "configs"),
                Path.build_filename (cwd, "..", "configs"),
                Path.build_filename (cwd, "..", "..", "configs"),
                Path.build_filename (exe_dir, "configs"),
                Path.build_filename (exe_dir, "..", "configs")
            };
#endif
        }

        return {
            Path.build_filename (cwd, "configs"),
            Path.build_filename (cwd, "..", "configs"),
            Path.build_filename (cwd, "..", "..", "configs")
        };
    }

    public string[] version_file_candidates () {
        string exe_dir = executable_dir ();
        string cwd = Environment.get_current_dir ();

        if (exe_dir.length > 0) {
#if WINDOWS
            return {
                Path.build_filename (exe_dir, "version.json"),
                Path.build_filename (exe_dir, "..", "share", "forough", "version.json"),
                Path.build_filename (exe_dir, "..", "..", "share", "forough", "version.json"),
                Path.build_filename (cwd, "version.json"),
                Path.build_filename (cwd, "build", "version.json")
            };
#else
            return {
                Path.build_filename (exe_dir, "version.json"),
                Path.build_filename (exe_dir, "..", "share", "forough", "version.json"),
                Path.build_filename (exe_dir, "..", "..", "share", "forough", "version.json"),
                Path.build_filename (cwd, "version.json"),
                Path.build_filename (cwd, "build", "version.json"),
                "/usr/local/share/forough/version.json",
                "/usr/share/forough/version.json"
            };
#endif
        }

        return {
            Path.build_filename (cwd, "version.json"),
            Path.build_filename (cwd, "build", "version.json")
        };
    }

    public string[] installed_core_path_candidates () {
        string exe_dir = executable_dir ();
        if (exe_dir.length > 0) {
#if WINDOWS
            // Portable layout: the engine ships next to the GUI executable.
            return {
                Path.build_filename (exe_dir, Constants.PSIPHON_BIN),
                Path.build_filename (exe_dir, "..", "bin", Constants.PSIPHON_BIN),
                Path.build_filename (exe_dir, "bin", Constants.PSIPHON_BIN)
            };
#else
            return {
                Path.build_filename (exe_dir, Constants.PSIPHON_BIN),
                Path.build_filename (exe_dir, "..", "lib", "forough", Constants.PSIPHON_BIN),
                Path.build_filename (exe_dir, "..", "lib64", "forough", Constants.PSIPHON_BIN),
                Path.build_filename (exe_dir, "..", "libexec", "forough", Constants.PSIPHON_BIN),
                Path.build_filename ("/usr", "lib", "forough", Constants.PSIPHON_BIN),
                Path.build_filename ("/usr", "lib64", "forough", Constants.PSIPHON_BIN),
                Path.build_filename ("/usr", "libexec", "forough", Constants.PSIPHON_BIN),
                Path.build_filename ("/usr", "local", "lib", "forough", Constants.PSIPHON_BIN),
                Path.build_filename ("/usr", "local", "lib64", "forough", Constants.PSIPHON_BIN),
                Path.build_filename ("/usr", "local", "bin", Constants.PSIPHON_BIN)
            };
#endif
        }

#if WINDOWS
        return {
            Path.build_filename (Environment.get_current_dir (), Constants.PSIPHON_BIN)
        };
#else
        return {
            Path.build_filename ("/usr", "lib", "forough", Constants.PSIPHON_BIN),
            Path.build_filename ("/usr", "lib64", "forough", Constants.PSIPHON_BIN),
            Path.build_filename ("/usr", "libexec", "forough", Constants.PSIPHON_BIN),
            Path.build_filename ("/usr", "local", "lib", "forough", Constants.PSIPHON_BIN),
            Path.build_filename ("/usr", "local", "lib64", "forough", Constants.PSIPHON_BIN),
            Path.build_filename ("/usr", "local", "bin", Constants.PSIPHON_BIN)
        };
#endif
    }

    public string[] installed_sing_box_path_candidates () {
        string exe_dir = executable_dir ();
        if (exe_dir.length > 0) {
#if WINDOWS
            return {
                Path.build_filename (exe_dir, Constants.SING_BOX_BIN),
                Path.build_filename (exe_dir, "..", "bin", Constants.SING_BOX_BIN),
                Path.build_filename (exe_dir, "bin", Constants.SING_BOX_BIN)
            };
#else
            return {
                Path.build_filename (exe_dir, Constants.SING_BOX_BIN),
                Path.build_filename (exe_dir, "..", "lib", "forough", Constants.SING_BOX_BIN),
                Path.build_filename (exe_dir, "..", "lib64", "forough", Constants.SING_BOX_BIN),
                Path.build_filename (exe_dir, "..", "libexec", "forough", Constants.SING_BOX_BIN),
                Path.build_filename ("/usr", "lib", "forough", Constants.SING_BOX_BIN),
                Path.build_filename ("/usr", "lib64", "forough", Constants.SING_BOX_BIN),
                Path.build_filename ("/usr", "libexec", "forough", Constants.SING_BOX_BIN),
                Path.build_filename ("/usr", "local", "lib", "forough", Constants.SING_BOX_BIN),
                Path.build_filename ("/usr", "local", "lib64", "forough", Constants.SING_BOX_BIN),
                Path.build_filename ("/usr", "local", "bin", Constants.SING_BOX_BIN)
            };
#endif
        }

#if WINDOWS
        return {
            Path.build_filename (Environment.get_current_dir (), Constants.SING_BOX_BIN)
        };
#else
        return {
            Path.build_filename ("/usr", "lib", "forough", Constants.SING_BOX_BIN),
            Path.build_filename ("/usr", "lib64", "forough", Constants.SING_BOX_BIN),
            Path.build_filename ("/usr", "libexec", "forough", Constants.SING_BOX_BIN),
            Path.build_filename ("/usr", "local", "lib", "forough", Constants.SING_BOX_BIN),
            Path.build_filename ("/usr", "local", "lib64", "forough", Constants.SING_BOX_BIN),
            Path.build_filename ("/usr", "local", "bin", Constants.SING_BOX_BIN)
        };
#endif
    }

    private static string[] schema_dir_candidates () {
        string exe_dir = executable_dir ();

        if (exe_dir.length > 0) {
#if WINDOWS
            return {
                Path.build_filename (exe_dir, "share", "glib-2.0", "schemas"),
                Path.build_filename (exe_dir, "..", "share", "glib-2.0", "schemas"),
                Path.build_filename (exe_dir, "..", "..", "share", "glib-2.0", "schemas")
            };
#else
            return {
                Path.build_filename (exe_dir, "data"),
                Path.build_filename (exe_dir, "..", "data"),
                Path.build_filename (exe_dir, "..", "share", "glib-2.0", "schemas"),
                Path.build_filename (exe_dir, "..", "..", "share", "glib-2.0", "schemas"),
                "/usr/local/share/glib-2.0/schemas",
                "/usr/share/glib-2.0/schemas"
            };
#endif
        }

#if WINDOWS
        return {};
#else
        return {
            "/usr/local/share/glib-2.0/schemas",
            "/usr/share/glib-2.0/schemas"
        };
#endif
    }
}
