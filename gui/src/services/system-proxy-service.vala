namespace PsiphonCliGui {
#if !WINDOWS
    private struct ProxySnapshot {
        int mode;
        string http_host;
        int http_port;
        string https_host;
        int https_port;
        string socks_host;
        int socks_port;
        bool use_same_proxy;
        bool saved;
    }
#endif

    public class SystemProxyService : Object {
#if !WINDOWS
        private ProxySnapshot snapshot;
        private bool active = false;
        private bool kde_applied = false;
        private string kde_snapshot = "";
        private bool kde_snapshot_saved = false;

        public bool schema_available {
            get {
                return SettingsSchemaSource.get_default ().lookup (
                    "org.gnome.system.proxy",
                    true
                ) != null;
            }
        }

        public bool is_active {
            get { return active; }
        }

        // Fedora KDE (and other Plasma sessions) do not read GNOME/gsettings
        // proxy settings, so "System proxy active" would silently be a lie
        // there. When a KDE session is detected we additionally write the
        // Plasma proxy configuration (~/.config/kdeglobals [Proxy]) so KDE
        // applications that honor it pick the tunnel up too.
        public bool kde_detected {
            get {
                string? desktop = Environment.get_variable ("XDG_CURRENT_DESKTOP");
                if (desktop == null || desktop.length == 0) {
                    desktop = Environment.get_variable ("XDG_SESSION_DESKTOP");
                }
                return desktop != null && desktop.down ().contains ("kde");
            }
        }

        public bool kde_is_applied {
            get { return kde_applied; }
        }

        public void enable (string http_endpoint, string socks_endpoint) throws Error {
            if (active) {
                return;
            }

            save_snapshot ();

            string http_host;
            int http_port;
            string socks_host;
            int socks_port;
            parse_endpoint (http_endpoint, out http_host, out http_port);
            parse_endpoint (socks_endpoint, out socks_host, out socks_port);

            if (schema_available) {
                var proxy = new Settings ("org.gnome.system.proxy");
                proxy.set_enum ("mode", 1);

                var http = new Settings ("org.gnome.system.proxy.http");
                http.set_string ("host", http_host);
                http.set_int ("port", http_port);

                var https = new Settings ("org.gnome.system.proxy.https");
                https.set_string ("host", http_host);
                https.set_int ("port", http_port);

                var socks = new Settings ("org.gnome.system.proxy.socks");
                socks.set_string ("host", socks_host);
                socks.set_int ("port", socks_port);

                proxy.set_boolean ("use-same-proxy", true);
            }

            if (kde_detected) {
                // Best effort: never fail the connection because the KDE
                // settings file could not be updated.
                kde_applied = apply_kde_proxy (http_host, http_port, socks_host, socks_port);
            }

            if (!schema_available && !kde_applied) {
                throw new IOError.FAILED (
                    "Desktop proxy settings (org.gnome.system.proxy) are not available on this system."
                );
            }

            active = true;
        }

        public void disable () {
            if (!active) {
                return;
            }

            restore_kde_proxy ();

            if (schema_available && snapshot.saved) {
                var proxy = new Settings ("org.gnome.system.proxy");
                proxy.set_enum ("mode", snapshot.mode);

                var http = new Settings ("org.gnome.system.proxy.http");
                http.set_string ("host", snapshot.http_host);
                http.set_int ("port", snapshot.http_port);

                var https = new Settings ("org.gnome.system.proxy.https");
                https.set_string ("host", snapshot.https_host);
                https.set_int ("port", snapshot.https_port);

                var socks = new Settings ("org.gnome.system.proxy.socks");
                socks.set_string ("host", snapshot.socks_host);
                socks.set_int ("port", snapshot.socks_port);

                proxy.set_boolean ("use-same-proxy", snapshot.use_same_proxy);
            }

            snapshot.saved = false;
            active = false;
        }

        private void save_snapshot () {
            if (schema_available) {
                var proxy = new Settings ("org.gnome.system.proxy");
                snapshot.mode = proxy.get_enum ("mode");
                snapshot.use_same_proxy = proxy.get_boolean ("use-same-proxy");

                var http = new Settings ("org.gnome.system.proxy.http");
                snapshot.http_host = http.get_string ("host");
                snapshot.http_port = http.get_int ("port");

                var https = new Settings ("org.gnome.system.proxy.https");
                snapshot.https_host = https.get_string ("host");
                snapshot.https_port = https.get_int ("port");

                var socks = new Settings ("org.gnome.system.proxy.socks");
                snapshot.socks_host = socks.get_string ("host");
                snapshot.socks_port = socks.get_int ("port");
                snapshot.saved = true;
            }
        }

        // ----- KDE Plasma (kdeglobals) support -----

        private string kde_globals_path () {
            return Path.build_filename (
                Environment.get_user_config_dir (), "kdeglobals"
            );
        }

        private bool apply_kde_proxy (string http_host, int http_port, string socks_host, int socks_port) {
            string path = kde_globals_path ();
            string original = "";
            if (FileUtils.test (path, FileTest.EXISTS)) {
                try {
                    FileUtils.get_contents (path, out original);
                } catch (Error err) {
                    return false;
                }
            }

            if (!kde_snapshot_saved) {
                kde_snapshot = original;
                kde_snapshot_saved = true;
            }

            string updated = replace_kde_proxy_group (original, http_host, http_port, socks_host, socks_port);
            try {
                FileUtils.set_contents (path, updated);
            } catch (Error err) {
                return false;
            }
            return true;
        }

        private void restore_kde_proxy () {
            if (!kde_snapshot_saved || !kde_applied) {
                kde_applied = false;
                return;
            }

            try {
                FileUtils.set_contents (kde_globals_path (), kde_snapshot);
            } catch (Error err) {
                warning ("Could not restore kdeglobals: %s", err.message);
            }
            kde_snapshot_saved = false;
            kde_applied = false;
        }

        // KConfig files are INI-like: "[Proxy]" header followed by key=value
        // lines until the next header. Replace that group wholesale; keep
        // everything else byte-for-byte.
        private string replace_kde_proxy_group (
            string content, string http_host, int http_port, string socks_host, int socks_port
        ) {
            string[] lines;
            if (content.length > 0) {
                lines = content.split ("\n");
            } else {
                lines = {};
            }

            var result = new StringBuilder ();
            bool in_proxy_group = false;
            bool group_written = false;

            foreach (unowned string line in lines) {
                string stripped = line.strip ();
                bool is_header = stripped.has_prefix ("[") && stripped.has_suffix ("]");

                if (is_header && in_proxy_group) {
                    in_proxy_group = false;
                }

                if (is_header && stripped.down () == "[proxy]") {
                    in_proxy_group = true;
                    if (!group_written) {
                        result.append (kde_proxy_group_text (http_host, http_port, socks_host, socks_port));
                        group_written = true;
                    }
                    continue;
                }

                if (in_proxy_group) {
                    continue;
                }

                result.append (line);
                result.append_c ('\n');
            }

            if (!group_written) {
                result.append (kde_proxy_group_text (http_host, http_port, socks_host, socks_port));
            }

            return result.str;
        }

        // Plasma manual-proxy format as written by the KDE proxy KCM:
        // "Proxy Type=1" plus "<scheme>://<host> <port>" values.
        private string kde_proxy_group_text (
            string http_host, int http_port, string socks_host, int socks_port
        ) {
            return "[Proxy]\n"
                + "Proxy Type=1\n"
                + "httpProxy=http://%s %d\n".printf (http_host, http_port)
                + "httpsProxy=http://%s %d\n".printf (http_host, http_port)
                + "socksProxy=socks://%s %d\n".printf (socks_host, socks_port);
        }

        private void parse_endpoint (string endpoint, out string host, out int port) {
            host = "127.0.0.1";
            port = Constants.SOCKS_PROXY_PORT;

            string[] parts = endpoint.split (":", 2);
            if (parts.length == 2) {
                host = parts[0].strip ();
                port = int.parse (parts[1].strip ());
            }

            if (host == "0.0.0.0") {
                host = "127.0.0.1";
            }
        }
    }
#else
        private bool active = false;

        public bool is_active {
            get { return active; }
        }

        public void enable (string http_endpoint, string socks_endpoint) throws Error {
            if (active) {
                return;
            }

            // WinInet user proxy: HKCU\...\Internet Settings. Snapshot the
            // previous values first so disconnect restores exactly what the
            // user had (including "the value was not there at all").
            save_snapshot ();

            string host;
            int port;
            parse_endpoint (http_endpoint, out host, out port);
            string proxy_server = "%s:%d".printf (host, port);

            string override_value = "<local>";
            if (snapshot_override.length > 0) {
                // Keep the user's existing bypass list and append <local>
                // when it is not already covered.
                override_value = snapshot_override;
                if (!override_value.down ().contains ("<local>")) {
                    override_value += ";<local>";
                }
            }

            reg_set_dword ("ProxyEnable", 1);
            reg_set_string ("ProxyServer", proxy_server);
            reg_set_string ("ProxyOverride", override_value);
            refresh_wininet ();

            active = true;
        }

        public void disable () {
            if (!active) {
                return;
            }

            // Restore the snapshot; ProxyEnable is always written back (it
            // existed in every Windows install), ProxyServer/ProxyOverride
            // only when they existed before — otherwise deleted.
            reg_set_dword ("ProxyEnable", snapshot_enable);
            if (snapshot_server.length > 0) {
                reg_set_string ("ProxyServer", snapshot_server);
            } else {
                reg_delete ("ProxyServer");
            }
            if (snapshot_override.length > 0) {
                reg_set_string ("ProxyOverride", snapshot_override);
            } else {
                reg_delete ("ProxyOverride");
            }
            refresh_wininet ();

            active = false;
        }

        // ----- Snapshot / registry plumbing (reg.exe, no P/Invoke) -----

        private int snapshot_enable = 0;
        private string snapshot_server = "";
        private string snapshot_override = "";
        private bool snapshot_saved = false;

        private const string REG_KEY =
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";

        private void save_snapshot () {
            if (snapshot_saved) {
                return;
            }

            string? enable_out = reg_query ("ProxyEnable");
            snapshot_enable = 0;
            if (enable_out != null) {
                // "ProxyEnable    REG_DWORD    0x1"
                foreach (unowned string token in enable_out.split (" ")) {
                    string t = token.strip ().down ();
                    if (t.has_prefix ("0x")) {
                        snapshot_enable = (int) uint64.parse (t) & 1;
                    }
                }
            }
            snapshot_server = reg_query ("ProxyServer") ?? "";
            snapshot_override = reg_query ("ProxyOverride") ?? "";
            snapshot_saved = true;
        }

        private string? reg_query (string value_name) {
            string? stdout_buf = null;
            try {
                Process.spawn_command_line_sync (
                    "reg query \"%s\" /v %s".printf (REG_KEY, value_name),
                    out stdout_buf, null, null
                );
            } catch (Error err) {
                return null;
            }
            if (stdout_buf == null || !stdout_buf.contains (value_name)) {
                return null;
            }
            // Return the first non-empty token after the type column
            // ("REG_SZ" / "REG_DWORD"). reg.exe pads the columns with runs of
            // spaces, so a plain split produces empty strings in between.
            string[] tokens = stdout_buf.split (" ");
            for (int i = 0; i < tokens.length - 1; i++) {
                string t = tokens[i].strip ();
                if (t == "REG_SZ" || t == "REG_DWORD") {
                    for (int j = i + 1; j < tokens.length; j++) {
                        string v = tokens[j].strip ();
                        if (v.length > 0) {
                            return v;
                        }
                    }
                    return null;
                }
            }
            return null;
        }

        private void reg_set_string (string value_name, string data) {
            try {
                Process.spawn_command_line_sync (
                    "reg add \"%s\" /v %s /t REG_SZ /d \"%s\" /f".printf (
                        REG_KEY, value_name, data
                    )
                );
            } catch (Error err) {
                warning ("Could not set %s: %s", value_name, err.message);
            }
        }

        private void reg_set_dword (string value_name, int data) {
            try {
                Process.spawn_command_line_sync (
                    "reg add \"%s\" /v %s /t REG_DWORD /d %d /f".printf (
                        REG_KEY, value_name, data
                    )
                );
            } catch (Error err) {
                warning ("Could not set %s: %s", value_name, err.message);
            }
        }

        private void reg_delete (string value_name) {
            try {
                Process.spawn_command_line_sync (
                    "reg delete \"%s\" /v %s /f".printf (REG_KEY, value_name)
                );
            } catch (Error err) {
                warning ("Could not delete %s: %s", value_name, err.message);
            }
        }

        // Make WinInet pick up the change without a logoff. rundll32 cannot
        // pass the needed InternetSetOption arguments, so run the canonical
        // one-liner PowerShell snippet (INTERNET_OPTION_SETTINGS_CHANGED +
        // INTERNET_OPTION_REFRESH). Best-effort: browsers also re-read the
        // registry on their next request even without the refresh.
        private void refresh_wininet () {
            string snippet =
                "Add-Type -Namespace WinINet -Name NativeMethods -MemberDefinition " +
                "'[System.Runtime.InteropServices.DllImport(\"wininet.dll\", SetLastError = true)] " +
                "public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);'; " +
                "[WinINet.NativeMethods]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null; " +
                "[WinINet.NativeMethods]::InternetSetOption([IntPtr]::Zero, 95, [IntPtr]::Zero, 0) | Out-Null";
            try {
                Process.spawn_command_line_async (
                    "powershell -NoProfile -WindowStyle Hidden -Command \"%s\"".printf (
                        snippet.replace ("\"", "\\\"")
                    )
                );
            } catch (Error err) {
                // Never fail the connect over the notification refresh.
                warning ("WinInet refresh skipped: %s", err.message);
            }
        }

        private void parse_endpoint (string endpoint, out string host, out int port) {
            host = "127.0.0.1";
            port = Constants.HTTP_PROXY_PORT;

            string[] parts = endpoint.split (":", 2);
            if (parts.length == 2) {
                host = parts[0].strip ();
                port = int.parse (parts[1].strip ());
            }

            if (host == "0.0.0.0") {
                host = "127.0.0.1";
            }
        }
    }
#endif
}
