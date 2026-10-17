int main (string[] args) {
#if WINDOWS
    // GSettings persistence on Windows: the keyfile backend stores settings
    // under %LOCALAPPDATA%\glib-2.0 (no dconf daemon exists there). The
    // schema directory points at the portable bundle layout so the compiled
    // Forough schema is always found, even before RuntimePaths kicks in.
    // Both MUST be set before the first GSettings use (GSettingsSetup and
    // I18n read the schema right below). The bundle may be laid out as
    // <root>\bin\forough.exe or <root>\forough.exe, so pick the schema dir
    // that actually exists; "../share" is the fallback for the standard
    // bin/ layout.
    string win_appdir = PsiphonCliGui.RuntimePaths.executable_dir ();
    if (win_appdir.length > 0) {
        string schema_dir = "";
        string[] schema_candidates = {
            GLib.Path.build_filename (win_appdir, "share", "glib-2.0", "schemas"),
            GLib.Path.build_filename (win_appdir, "..", "share", "glib-2.0", "schemas")
        };
        foreach (unowned string candidate in schema_candidates) {
            if (GLib.FileUtils.test (candidate, GLib.FileTest.EXISTS)) {
                schema_dir = candidate;
                break;
            }
        }
        if (schema_dir.length == 0) {
            schema_dir = GLib.Path.build_filename (
                win_appdir, "..", "share", "glib-2.0", "schemas"
            );
        }
        GLib.Environment.set_variable ("GSETTINGS_BACKEND", "keyfile", true);
        GLib.Environment.set_variable ("GSETTINGS_SCHEMA_DIR", schema_dir, true);
        GLib.Environment.set_variable (
            "XDG_DATA_DIRS",
            GLib.Path.get_dirname (GLib.Path.get_dirname (schema_dir)),
            true
        );

        // Fontconfig: point at the portable bundle's etc/fonts so Pango does
        // not depend on a compile-time /mingw64 prefix. The bundled fonts.conf
        // still reads the real Windows font directory (WINDOWSFONTDIR), so
        // system fonts — including full Persian coverage — keep working.
        string[] fontconfig_candidates = {
            GLib.Path.build_filename (win_appdir, "etc", "fonts", "fonts.conf"),
            GLib.Path.build_filename (win_appdir, "..", "etc", "fonts", "fonts.conf")
        };
        foreach (unowned string candidate in fontconfig_candidates) {
            if (GLib.FileUtils.test (candidate, GLib.FileTest.EXISTS)) {
                GLib.Environment.set_variable ("FONTCONFIG_FILE", candidate, true);
                break;
            }
        }
    }
    PsiphonCliGui.GSettingsSetup.ensure_installed_core_path ();
#else
    PsiphonCliGui.GSettingsSetup.ensure_local_schema ();
    PsiphonCliGui.GSettingsSetup.ensure_installed_core_path ();
#endif
    // Resolve UI language before GTK initializes so direction (RTL for
    // Persian) is applied to every widget.
    PsiphonCliGui.I18n.init ();
    if (PsiphonCliGui.I18n.is_rtl ()) {
        Gtk.Widget.set_default_direction (Gtk.TextDirection.RTL);
    } else {
        Gtk.Widget.set_default_direction (Gtk.TextDirection.LTR);
    }
    Adw.init ();
    var app = new PsiphonCliGui.App ();
    return app.run (args);
}
