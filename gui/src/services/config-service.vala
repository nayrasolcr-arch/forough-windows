namespace PsiphonCliGui {
    public errordomain ConfigError {
        DEFAULT_CONFIG_MISSING,
        INVALID_UPSTREAM_PROXY,
        READ_FAILED,
        WRITE_FAILED
    }

    public class ConfigService : Object {
        public string config_dir { get; set; }

        public ConfigService () {
            config_dir = Constants.default_config_dir ();
        }

        public void apply_config_dir (string custom_dir) {
            string trimmed = custom_dir.strip ();
            if (trimmed.length > 0) {
                config_dir = trimmed;
            } else {
                config_dir = Constants.default_config_dir ();
            }
        }

        public string config_path () {
            return Path.build_filename (config_dir, Constants.CONFIG_FILE);
        }

        public string pid_path () {
            return Path.build_filename (config_dir, Constants.PID_FILE);
        }

        public string stats_path () {
            return Path.build_filename (config_dir, Constants.STATS_FILE);
        }

        public string log_path () {
            return Path.build_filename (config_dir, Constants.LOG_FILE);
        }

        public void ensure_config_dir () throws Error {
            DirUtils.create_with_parents (config_dir, 0755);
        }

        public void ensure_seed_files () throws Error {
            ensure_config_dir ();

            string default_config_path = find_default_asset (Constants.CONFIG_FILE);
            string user_config_path = config_path ();

            if (!FileUtils.test (user_config_path, FileTest.EXISTS)) {
                copy_file (default_config_path, user_config_path);
            }

            seed_server_list (user_config_path);
        }

        public string build_config (TunnelOptions options) throws Error {
            apply_config_dir (options.config_dir);
            ensure_seed_files ();
            ensure_server_list_ready ();

            string contents;
            FileUtils.get_contents (config_path (), out contents);

            var parser = new Json.Parser ();
            parser.load_from_data (contents, contents.length);

            Json.Object root = parser.get_root ().get_object ();
            root.set_string_member ("EgressRegion", options.region.strip ());
            root.set_boolean_member ("EmitBytesTransferred", true);

            // Psiphon Android client parity (TunnelManager.buildTunnelCoreConfig):
            // server alerts stay visible to the user, network parameters are
            // emitted for diagnostics, and the resolver gets public fallback
            // servers for environments where system DNS is unusable.
            // EmitDiagnosticNotices is required for the "ActiveTunnel" notice
            // (the actual established protocol, e.g. FRONTED-MEEK-CDN-OSSH on
            // Android); without it the GUI can never show the real protocol.
            root.set_boolean_member ("EmitDiagnosticNotices", true);
            root.set_boolean_member ("EmitServerAlerts", true);
            root.set_boolean_member ("EmitDiagnosticNetworkParameters", true);
            var dns_alternates = new Json.Array ();
            dns_alternates.add_string_element ("1.1.1.1");
            dns_alternates.add_string_element ("1.0.0.1");
            dns_alternates.add_string_element ("8.8.8.8");
            dns_alternates.add_string_element ("8.8.4.4");
            root.set_array_member ("DNSResolverAlternateServers", dns_alternates);

            if (options.enable_timeout) {
                root.remove_member ("EstablishTunnelTimeoutSeconds");
            } else {
                // Timeout disabled: wait indefinitely for establish and dial
                // patiently. Android sets the same lambda when the user
                // disables timeouts (NetworkLatencyMultiplierLambda = 0.1),
                // which substantially improves first-connect success on
                // high-latency censored networks.
                root.set_int_member ("EstablishTunnelTimeoutSeconds", 0);
                root.set_double_member ("NetworkLatencyMultiplierLambda", 0.1);
            }

            if (options.enable_lan) {
                root.set_string_member ("ListenInterface", "any");
            } else {
                root.remove_member ("ListenInterface");
            }

            if (options.enable_beast_mode) {
                root.set_boolean_member ("AggressiveEstablishment", true);
            } else {
                root.remove_member ("AggressiveEstablishment");
            }

            root.remove_member ("LimitTunnelProtocols");
            // Protocol selection mirrors the Psiphon Android client:
            // conduit -> in-proxy protocols only, cdn_fronting -> CDN-fronted
            // meek protocols + DisableTactics, direct -> direct protocols +
            // DisableTactics, auto -> no limit. CDN fronting overrides are
            // applied for auto/direct/cdn_fronting exactly like the Android
            // putCdnFrontingConfig().
            if (options.protocol == ProtocolMode.CONDUIT) {
                root.set_array_member ("LimitTunnelProtocols",
                    filtered_protocols (Constants.conduit_protocols (), options));
            } else if (options.protocol == ProtocolMode.CDN_FRONTING) {
                root.set_array_member ("LimitTunnelProtocols",
                    filtered_protocols (Constants.cdn_fronting_protocols (), options));
                root.set_boolean_member ("DisableTactics", true);
                put_cdn_fronting_config (root, options);
            } else if (options.protocol == ProtocolMode.DIRECT) {
                root.set_array_member ("LimitTunnelProtocols",
                    filtered_protocols (Constants.direct_protocols (), options));
                root.set_boolean_member ("DisableTactics", true);
                put_cdn_fronting_config (root, options);
            } else {
                put_cdn_fronting_config (root, options);
            }

            if (options.protocol == ProtocolMode.CONDUIT &&
                options.inproxy_compartment_id.strip ().length > 0) {
                // Personal compartment ID for private conduit pairing,
                // same field the Android client sends.
                root.set_string_member ("InproxyClientPersonalCompartmentID",
                                        options.inproxy_compartment_id.strip ());
            } else {
                root.remove_member ("InproxyClientPersonalCompartmentID");
            }

            string upstream_proxy_url = options.upstream_proxy_url.strip ();
            if (upstream_proxy_url.length > 0) {
                validate_upstream_proxy_url (upstream_proxy_url);
                root.set_string_member ("UpstreamProxyURL", upstream_proxy_url);
            } else {
                root.remove_member ("UpstreamProxyURL");
            }

            // Obfuscated server list root URLs (Android embeds these at build
            // time). OSL registry downloads add protocol-specific server
            // buckets — including CDN-fronted meek entries — on top of the
            // common remote server list.
            string[] osl_roots = parse_osl_urls (options.osl_urls);
            if (osl_roots.length > 0) {
                root.set_array_member ("ObfuscatedServerListRootURLs", string_array (osl_roots));
            } else {
                root.remove_member ("ObfuscatedServerListRootURLs");
            }

            if (!root.has_member ("RemoteServerListUrl") ||
                !root.has_member ("RemoteServerListSignaturePublicKey")) {
                warning ("RemoteServerListUrl/RemoteServerListSignaturePublicKey are not set in psiphon.config; official server list will not be used.");
            }

            var generator = new Json.Generator ();
            generator.pretty = true;
            generator.set_root (parser.get_root ());
            string output = generator.to_data (null);
            FileUtils.set_contents (config_path (), output);
            return config_path ();
        }

        public string resolve_core_path (string custom_path) {
            string trimmed = custom_path.strip ();
            if (trimmed.length > 0 && FileUtils.test (trimmed, FileTest.IS_EXECUTABLE)) {
                return trimmed;
            }

            string from_settings = read_core_path_setting ();
            if (from_settings.length > 0 && FileUtils.test (from_settings, FileTest.IS_EXECUTABLE)) {
                return from_settings;
            }

            string? from_path = Environment.find_program_in_path (Constants.PSIPHON_BIN);
            if (from_path != null && from_path.length > 0) {
                return from_path;
            }

            string[] candidates = {
                Path.build_filename (Environment.get_current_dir (), "..", Constants.PSIPHON_BIN),
                Path.build_filename (Environment.get_current_dir (), Constants.PSIPHON_BIN),
                Path.build_filename (Environment.get_current_dir (), "..", "..", Constants.PSIPHON_BIN)
#if !WINDOWS
                ,
                "/usr/local/bin/%s".printf (Constants.PSIPHON_BIN),
                "/usr/bin/%s".printf (Constants.PSIPHON_BIN)
#endif
            };

            foreach (string candidate in RuntimePaths.installed_core_path_candidates ()) {
                if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE)) {
                    return candidate;
                }
            }

            foreach (string candidate in candidates) {
                if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE)) {
                    return candidate;
                }
            }

            return "";
        }

        private void seed_server_list (string user_config_path) {
            try {
                string list_filename = resolve_server_list_filename (user_config_path);
                string default_list_path = find_default_server_list_asset ();
                string user_list_path = Path.build_filename (config_dir, list_filename);

                if (should_seed_server_list (user_list_path, default_list_path)) {
                    copy_file (default_list_path, user_list_path);
                }
            } catch (Error err) {
                warning ("Could not seed server list: %s", err.message);
            }
        }

        private void ensure_server_list_ready () throws Error {
            string list_filename = resolve_server_list_filename (config_path ());
            string user_list_path = Path.build_filename (config_dir, list_filename);

            if (!FileUtils.test (user_list_path, FileTest.EXISTS)) {
                throw new ConfigError.DEFAULT_CONFIG_MISSING (
                    "Server list '%s' was not found in %s. Install the GUI package assets or use Settings → Refresh server list.",
                    list_filename,
                    config_dir
                );
            }

            int64 list_size = query_file_size (user_list_path);
            if (list_size <= 0) {
                throw new ConfigError.DEFAULT_CONFIG_MISSING (
                    "Server list '%s' in %s is empty. Use Settings → Refresh server list or reinstall the package.",
                    list_filename,
                    config_dir
                );
            }
        }

        private string resolve_server_list_filename (string config_file_path) throws Error {
            string contents;
            FileUtils.get_contents (config_file_path, out contents);

            var parser = new Json.Parser ();
            parser.load_from_data (contents, contents.length);
            Json.Object root = parser.get_root ().get_object ();

            if (root.has_member ("RemoteServerListDownloadFilename")) {
                string filename = root.get_string_member ("RemoteServerListDownloadFilename").strip ();
                if (filename.length > 0) {
                    return filename;
                }
            }

            return Constants.SERVER_LIST_FILE;
        }

        private bool should_seed_server_list (string user_list_path, string default_list_path) {
            if (!FileUtils.test (user_list_path, FileTest.EXISTS)) {
                return true;
            }

            try {
                int64 user_size = query_file_size (user_list_path);
                if (user_size <= 0) {
                    return true;
                }

                int64 default_size = query_file_size (default_list_path);
                if (default_size > 1024 && user_size < default_size / 4) {
                    return true;
                }
            } catch (Error err) {
                warning ("Could not inspect server list sizes: %s", err.message);
                return true;
            }

            return false;
        }

        private string find_default_server_list_asset () throws Error {
            try {
                return find_default_asset (Constants.SERVER_LIST_FILE);
            } catch (Error err) {
                return find_default_asset ("server_list_compressed");
            }
        }

        private string find_default_asset (string name) throws Error {
            foreach (string dir in RuntimePaths.config_dir_candidates ()) {
                string candidate = Path.build_filename (dir, name);
                if (FileUtils.test (candidate, FileTest.EXISTS)) {
                    return candidate;
                }
            }

            throw new ConfigError.DEFAULT_CONFIG_MISSING (
                "Default asset '%s' was not found. Run from the portable bundle or install the GUI assets.",
                name
            );
        }

        private int64 query_file_size (string path) throws Error {
            var file = File.new_for_path (path);
            FileInfo info = file.query_info ("standard::size", FileQueryInfoFlags.NONE);
            return info.get_size ();
        }

        private void copy_file (string source, string dest) throws Error {
            var source_file = File.new_for_path (source);
            var dest_file = File.new_for_path (dest);
            source_file.copy (dest_file, FileCopyFlags.OVERWRITE, null, null);
        }

        private Json.Array protocol_array (string[] protocols) {
            var array = new Json.Array ();
            foreach (string protocol in protocols) {
                array.add_string_element (protocol);
            }
            return array;
        }

        // protocol_array with the final-attempt TCP-only self-heal applied:
        // QUIC-based protocols are dropped because throttled-QUIC networks
        // let the handshake succeed but never carry usable traffic.
        private Json.Array filtered_protocols (string[] protocols, TunnelOptions options) {
            if (!options.tcp_only_override) {
                return protocol_array (protocols);
            }

            var array = new Json.Array ();
            foreach (string protocol in protocols) {
                if ("QUIC" in protocol) {
                    continue;
                }
                array.add_string_element (protocol);
            }
            return array;
        }

        // ----- CDN fronting configuration (port of the Psiphon
        // Android client's putCdnFrontingConfig / makeCdnFrontingDialOverrides
        // / makeCdnFrontingScanSpec). Custom IP candidates and SNI names feed
        // FrontedMeekCDNScanSpec, which the tunnel-core built-in CDN scanner
        // probes with its worker pool (30 workers in beast mode) before
        // dialing through working edges.

        private void put_cdn_fronting_config (Json.Object root, TunnelOptions options) {
            root.set_array_member ("FrontedMeekDialOverrides", cdn_fronting_dial_overrides (options.cdn_fronting_sni));
            root.set_double_member ("FrontedMeekDialOverridesProbability", 1.0);
            root.set_boolean_member ("FrontedMeekCDNScanUseBuiltInSpec", true);

            Json.Object? scan_spec = cdn_fronting_scan_spec (
                options.cdn_fronting_ip_list,
                options.cdn_fronting_sni
            );
            if (scan_spec != null) {
                root.set_object_member ("FrontedMeekCDNScanSpec", scan_spec);
            } else {
                root.remove_member ("FrontedMeekCDNScanSpec");
            }
        }

        // Mirror of TunnelManager.makeCdnFrontingScanSpec: the spec is only
        // emitted when at least one valid IP candidate exists; SNI names are
        // optional. Invalid entries are dropped exactly like the Android
        // client (silently, preserving order, deduplicated).
        private Json.Object? cdn_fronting_scan_spec (string custom_ip_list, string custom_sni) {
            string[] ip_candidates = parse_cdn_fronting_ip_candidates (custom_ip_list);
            if (ip_candidates.length == 0) {
                return null;
            }

            var spec = new Json.Object ();
            spec.set_array_member ("IPCandidates", string_array (ip_candidates));

            string[] sni_names = parse_cdn_fronting_sni_list (custom_sni);
            if (sni_names.length > 0) {
                spec.set_array_member ("SNIServerNames", string_array (sni_names));
            }

            return spec;
        }

        // Android TunnelManager.parseCdnFrontingCustomIpCandidates: split on
        // whitespace/comma/semicolon, accept IPv4 or IPv4 CIDR only, dedupe.
        private string[] parse_cdn_fronting_ip_candidates (string custom_ip_list) {
            string[] candidates = {};
            if (custom_ip_list.strip ().length == 0) {
                return candidates;
            }

            foreach (string entry in split_setting_entries (custom_ip_list)) {
                string candidate = entry.strip ();
                if (candidate.length == 0 ||
                    (!is_valid_ipv4_address (candidate) && !is_valid_ipv4_cidr (candidate))) {
                    continue;
                }
                if (!array_contains (candidates, candidate)) {
                    candidates += candidate;
                }
            }

            return candidates;
        }

        // Android TunnelManager.parseCdnFrontingCustomSniList: split, normalize
        // each hostname, drop invalid entries, dedupe.
        private string[] parse_cdn_fronting_sni_list (string custom_sni) {
            string[] names = {};
            if (custom_sni.strip ().length == 0) {
                return names;
            }

            foreach (string entry in split_setting_entries (custom_sni)) {
                string sni = normalize_hostname (entry);
                if (sni.length == 0) {
                    continue;
                }
                if (!array_contains (names, sni)) {
                    names += sni;
                }
            }

            return names;
        }

        private string[] split_setting_entries (string value) {
            return value.split_set (" \t\r\n,;");
        }

        // ObfuscatedServerListRootURLs: split on whitespace/comma/semicolon,
        // keep http(s) URLs only, dedupe.
        private string[] parse_osl_urls (string value) {
            string[] urls = {};
            if (value.strip ().length == 0) {
                return urls;
            }

            foreach (string entry in split_setting_entries (value)) {
                string url = entry.strip ();
                if (url.length == 0 ||
                    (!url.has_prefix ("https://") && !url.has_prefix ("http://"))) {
                    continue;
                }
                if (!array_contains (urls, url)) {
                    urls += url;
                }
            }

            return urls;
        }

        private bool array_contains (string[] values, string needle) {
            foreach (string value in values) {
                if (value == needle) {
                    return true;
                }
            }
            return false;
        }

        private bool is_valid_ipv4_address (string ip) {
            string[] parts = ip.split (".");
            if (parts.length != 4) {
                return false;
            }

            foreach (string part in parts) {
                if (part.length == 0 || part.length > 3) {
                    return false;
                }
                foreach (uint8 c in part.data) {
                    if (c < '0' || c > '9') {
                        return false;
                    }
                }
                int value = int.parse (part);
                if (value < 0 || value > 255) {
                    return false;
                }
            }

            return true;
        }

        private bool is_valid_ipv4_cidr (string cidr) {
            if (cidr.strip ().length == 0) {
                return false;
            }

            string[] parts = cidr.split ("/");
            if (parts.length != 2 || !is_valid_ipv4_address (parts[0])) {
                return false;
            }

            foreach (uint8 c in parts[1].data) {
                if (c < '0' || c > '9') {
                    return false;
                }
            }
            int prefix = int.parse (parts[1]);
            return prefix >= 0 && prefix <= 32;
        }

        private bool is_valid_hostname (string hostname) {
            if (hostname.length == 0 || hostname.length > 253 || is_valid_ipv4_address (hostname)) {
                return false;
            }

            string normalized = hostname;
            if (normalized.has_suffix (".")) {
                normalized = normalized.substring (0, normalized.length - 1);
            }
            if (normalized.length == 0) {
                return false;
            }

            string[] labels = normalized.split (".");
            foreach (string label in labels) {
                if (label.length == 0 || label.length > 63 ||
                    label.has_prefix ("-") || label.has_suffix ("-")) {
                    return false;
                }
                foreach (uint8 c in label.data) {
                    bool is_alnum = (c >= 'a' && c <= 'z') ||
                                    (c >= 'A' && c <= 'Z') ||
                                    (c >= '0' && c <= '9');
                    if (!is_alnum && c != '-') {
                        return false;
                    }
                }
            }

            return true;
        }

        private string normalize_hostname (string hostname) {
            if (hostname.strip ().length == 0) {
                return "";
            }
            string normalized = hostname.strip ().down ();
            if (normalized.has_suffix (".")) {
                normalized = normalized.substring (0, normalized.length - 1);
            }
            if (!is_valid_hostname (normalized)) {
                return "";
            }
            return normalized;
        }

        private Json.Array cdn_fronting_dial_overrides (string custom_sni) {
            var overrides = new Json.Array ();

            // Android normalizeCdnFrontingCustomSni: first valid entry or "".
            string edge_sni = "";
            string[] sni_names = parse_cdn_fronting_sni_list (custom_sni);
            if (sni_names.length > 0) {
                edge_sni = sni_names[0];
            }

            string[] fastly_verify = {
                "www.python.org",
                "pypi.org",
                "fastly.com",
                "www.fastly.com",
                "developer.fastly.com",
                "githubassets.com",
                "github.com",
                "github.io",
                "githubusercontent.com"
            };
            string[] fastly_alpn = { "h2", "http/1.1" };

            overrides.add_object_element (cdn_fronting_override (
                "fastly-provider",
                string_array ({ "(?i)fastly" }),
                null,
                "pypi.org",
                "pypi.org",
                fastly_verify,
                fastly_alpn));
            overrides.add_object_element (cdn_fronting_override (
                "fastly-address",
                null,
                string_array ({ "(?i)(fastly|pypi|python|github)" }),
                "pypi.org",
                "pypi.org",
                fastly_verify,
                fastly_alpn));

            string[] edge_ids = {
                "edge-a-1", "edge-a-2",
                "edge-b-1", "edge-b-2",
                "edge-c-1", "edge-c-2",
                "edge-d-1", "edge-d-2",
                "edge-original"
            };
            string[] edge_ips = {
                "23.215.0.206", "23.215.0.203",
                "23.212.250.91", "23.212.250.78",
                "23.12.147.13", "23.12.147.29",
                "23.73.207.8", "23.73.207.15",
                "92.123.102.43"
            };
            for (int i = 0; i < edge_ids.length; i++) {
                string ip = edge_ips[i];
                // Android makeEdgeCdnFrontingOverride: custom SNI when set,
                // otherwise the edge IP itself.
                string edge_override_sni = edge_sni.length > 0 ? edge_sni : ip;
                overrides.add_object_element (cdn_fronting_override (
                    edge_ids[i],
                    null,
                    string_array ({ ".*" }),
                    ip,
                    edge_override_sni,
                    edge_verify_server_names (ip, edge_override_sni),
                    { "http/1.1" }));
            }

            return overrides;
        }

        private Json.Object cdn_fronting_override (string override_id,
                                                   Json.Array? match_provider,
                                                   Json.Array? match_dial,
                                                   string dial_address,
                                                   string sni,
                                                   string[] verify_names,
                                                   string[] alpn) {
            var obj = new Json.Object ();
            obj.set_string_member ("OverrideID", override_id);
            if (match_provider != null) {
                obj.set_array_member ("MatchFrontingProviderIDRegexes", match_provider);
            }
            if (match_dial != null) {
                obj.set_array_member ("MatchDialAddressRegexes", match_dial);
            }
            obj.set_array_member ("DialAddresses", string_array ({ dial_address }));
            obj.set_string_member ("SNIServerName", sni);
            obj.set_array_member ("VerifyServerNames", string_array (verify_names));
            obj.set_array_member ("ALPNProtocols", string_array (alpn));
            obj.set_string_member ("TLSProfile", "Chrome-83");
            return obj;
        }

        private string[] edge_verify_server_names (string ip, string sni) {
            string[] candidates = {
                sni,
                ip,
                "a248.e.akamai.net",
                "a.akamaized.net",
                "a.akamaized-staging.net",
                "a.akamaihd.net",
                "a.akamaihd-staging.net",
                "www.akamai.com"
            };

            string[] names = {};
            foreach (string candidate in candidates) {
                bool found = false;
                foreach (string existing in names) {
                    if (existing == candidate) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    names += candidate;
                }
            }
            return names;
        }

        private Json.Array string_array (string[] values) {
            var array = new Json.Array ();
            foreach (string value in values) {
                array.add_string_element (value);
            }
            return array;
        }

        private void validate_upstream_proxy_url (string url) throws Error {
            try {
                var parsed = Uri.parse (url, UriFlags.NONE);
                string scheme = parsed.get_scheme ();
                if (scheme != "http" && scheme != "https" && scheme != "socks5") {
                    throw new ConfigError.INVALID_UPSTREAM_PROXY (
                        "Upstream proxy URL must use http, https, or socks5."
                    );
                }
            } catch (UriError err) {
                throw new ConfigError.INVALID_UPSTREAM_PROXY (
                    "Upstream proxy URL is not a valid URL."
                );
            }
        }

        private string read_core_path_setting () {
            SettingsSchemaSource? source = SettingsSchemaSource.get_default ();
            if (source == null) {
                return "";
            }

            SettingsSchema? schema = source.lookup (Constants.SETTINGS_SCHEMA_ID, true);
            if (schema == null) {
                return "";
            }

            var settings = new Settings (Constants.SETTINGS_SCHEMA_ID);
            return settings.get_string ("core-path").strip ();
        }
    }
}
