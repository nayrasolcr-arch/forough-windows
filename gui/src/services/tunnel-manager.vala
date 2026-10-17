namespace PsiphonCliGui {
    public class TunnelManager : Object {
        public signal void stats_changed (TunnelStats stats);
        public signal void running_changed (bool running);
        public signal void error (string message);
        public signal void log_line (string line);
        public signal void sing_box_error_changed (string message);

        private ConfigService config;
        private StatsService stats_service;
        private LogService log_service;
        private IpService ip_service;
        private NoticeParser parser;
        private SystemProxyService system_proxy;
        private SingBoxManager sing_box;
        private Subprocess? process = null;
        private TunnelStats stats = new TunnelStats ();
        private TunnelOptions? current_options = null;
        private uint stats_timer_id = 0;
        private bool ip_fetch_started = false;
        private bool routing_started = false;
        private string proxy_host = "127.0.0.1";

        // End-to-end traffic verification. "Connected" (SSH+API handshake over
        // meek) can coexist with dead traffic — e.g. a fronting edge that passes
        // the handshake but drops the relay, or broken local routing. The GUI
        // probes real egress through its own HTTP proxy and restarts the tunnel
        // automatically when the route turns out to be a dead end.
        //
        // Safety rules for the auto-restart, learned from the field:
        //  - a probe set counts as failed only when EVERY probe URL fails
        //    (single-URL probes killed healthy tunnels on networks that block
        //    gstatic but not the rest of the internet);
        //  - a tunnel that has passed at least one probe is never restarted
        //    for later failures until they persist for a full minute — and
        //    then only once;
        //  - the last automatic attempt strips QUIC protocols, which Iranian
        //    ISPs throttle so aggressively that a QUIC-based tunnel handshake
        //    succeeds but cannot carry traffic.
        private uint traffic_timer_id = 0;
        private bool traffic_in_flight = false;
        private int traffic_failures = 0;
        private int auto_restart_count = 0;
        private bool auto_restart_pending = false;
        private bool traffic_ever_ok = false;

        // One-shot performance probe (v1.3.2): measures what users actually
        // feel — how long the first web response takes (TTFB through the
        // tunnel) and sustained download throughput. Results land in the
        // session log and in the diagnostics report, so "is it slow?" can be
        // answered with numbers before and after any change (same machine,
        // same tunnel path, same conditions).
        private uint perf_probe_timer_id = 0;
        private bool perf_probe_in_flight = false;
        private bool perf_probe_done = false;
        private string perf_probe_report = "";
        private string[] routing_parts = {};
        // Session-level TUN decision: options.enable_tun AND sing-box actually
        // present. sing-box missing must not kill the connect — the session
        // falls back to the system proxy and says so.
        private bool tun_runtime_enabled = false;

        // TUN supervision (v1.5.1). The field report that cracked the
        // "connected but nothing loads" blackout showed the full failure
        // chain: sing-box VERIFIED at +2s, silently killed later (OOM/
        // external), nobody noticed, the traffic probe kept saying "ok"
        // because it tests the tunnel via the HTTP proxy (bypasses TUN), and
        // with the system proxy disabled nothing routed at all. The watchdog
        // closes that gap: it polls sing-box + TUN state every few seconds,
        // restarts sing-box when it dies (bounded), engages the system proxy
        // as a last-resort delivery path, and never lets the UI claim a
        // healthy session while the routing layer is dead.
        private uint tun_watchdog_timer_id = 0;
        private int tun_restart_count = 0;
        private bool tun_restarting = false;
        private bool tun_fallback_proxy = false;
        private bool tun_ever_verified = false;

        private const int TUN_WATCHDOG_START_DELAY_SEC = 15;
        private const int TUN_WATCHDOG_INTERVAL_SEC = 5;
        private const int TUN_RESTART_MAX = 2;
        // Restart a leaking sing-box BEFORE the kernel OOM killer does it
        // mid-page-load (the mixed stack buffers aggressively).
        private const uint64 TUN_RSS_RESTART_KB = 1536 * 1024;

#if WINDOWS
        // Windows curl maps /dev/null only in newer builds; NUL is the
        // always-correct null device for every System32/MSYS2 curl.
        private const string CURL_DEV_NULL = "NUL";
#else
        private const string CURL_DEV_NULL = "/dev/null";
#endif

        private const int TRAFFIC_CHECK_FIRST_DELAY_SEC = 6;
        private const int TRAFFIC_CHECK_INTERVAL_SEC = 20;
        private const int TRAFFIC_CHECK_MAX_TIME_SEC = 8;
        private const int TRAFFIC_FAIL_RESTART_THRESHOLD = 2;
        private const int TRAFFIC_FAIL_RESTART_THRESHOLD_AFTER_OK = 3;
        private const int AUTO_RESTART_MAX = 2;

        public bool is_running {
            get { return process != null; }
        }

        public TunnelManager (
            ConfigService config,
            StatsService stats_service,
            LogService log_service,
            IpService ip_service
        ) {
            this.config = config;
            this.stats_service = stats_service;
            this.log_service = log_service;
            this.ip_service = ip_service;
            this.parser = new NoticeParser ();
            this.system_proxy = new SystemProxyService ();
            this.sing_box = new SingBoxManager (config);
            this.sing_box.diagnostic.connect ((line) => {
                string formatted = "[sing-box] %s".printf (line);
                log_service.append_line (formatted);
                log_line (formatted);
                if (is_sing_box_error_line (line)) {
                    sing_box_error_changed (line);
                }
            });

            ip_service.ip_fetched.connect ((ip) => {
                stats.public_ip = ip;
                stats_changed (stats.copy ());
            });
        }

        public string sing_box_log_text () {
            return sing_box.log_text;
        }

        public string sing_box_last_error () {
            return sing_box.last_error_message;
        }

        // ----- Diagnostics report -----

        // A single self-contained report that captures everything needed to
        // reason about a "connects but nothing works" report remotely: which
        // binaries were used, what the OS routing actually looks like, what
        // the proxy settings say, and what both logs recorded. Written
        // automatically whenever a delivery check fails, and on demand from
        // the header bar button.
        public string diagnostics_path {
            owned get {
                return Path.build_filename (
                    Environment.get_user_state_dir (), "forough", "diagnostics-latest.txt"
                );
            }
        }

        public void write_diagnostics (string trigger) {
            string report = build_diagnostics_report (trigger);
            try {
                DirUtils.create_with_parents (Path.get_dirname (diagnostics_path), 0755);
                FileUtils.set_contents (diagnostics_path, report);
                string line = "diagnostics written to %s (trigger: %s)".printf (
                    diagnostics_path, trigger
                );
                log_service.append_line (line);
                log_line (line);
            } catch (Error err) {
                warning ("Could not write diagnostics: %s", err.message);
            }
        }

        public string build_diagnostics_report (string trigger) {
            var v = VersionInfo.load ();
            var sb = new StringBuilder ();

            sb.append ("== Forough diagnostics ==\n");
            sb.append_printf ("app_version: %s\n", v.version);
            sb.append_printf ("time: %s\n", new DateTime.now_local ().to_string ());
            sb.append_printf ("trigger: %s\n", trigger);
#if WINDOWS
            sb.append ("platform: windows\n");
#else
            sb.append_printf ("desktop: %s | session: %s\n",
                Environment.get_variable ("XDG_CURRENT_DESKTOP") ?? "?",
                Environment.get_variable ("XDG_SESSION_DESKTOP") ?? "?");
#endif

            sb.append ("-- state --\n");
            if (current_options != null) {
                sb.append_printf ("options: tun=%s system_proxy=%s fakeip=%s beast=%s lan=%s protocol=%s\n",
                    current_options.enable_tun.to_string (),
                    current_options.enable_system_proxy.to_string (),
                    current_options.tun_fakeip.to_string (),
                    current_options.enable_beast_mode.to_string (),
                    current_options.enable_lan.to_string (),
                    current_options.protocol.config_value ());
                sb.append_printf ("core_path: %s\n",
                    config.resolve_core_path (current_options.core_path));
            }
            sb.append_printf ("tunnel_status: %s\n", stats.status);
            sb.append_printf ("connect_time_ms: %s\n",
                stats.connect_duration_ms > 0 ? stats.connect_duration_ms.to_string () : "-");
            sb.append_printf ("tunnel_protocol: %s\n", stats.tunnel_protocol);
            sb.append_printf ("egress_region: %s\n", stats.egress_region);
            sb.append_printf ("public_ip: %s\n", stats.public_ip);
            sb.append_printf ("routing_status: %s\n", stats.routing_status);
            sb.append_printf ("traffic_status: %s\n", stats.traffic_status);
            sb.append_printf ("http_proxy: %s | socks_proxy: %s\n",
                stats.http_proxy, stats.socks_proxy);

            sb.append ("-- sing-box --\n");
            string sb_path = current_options != null
                ? sing_box.resolve_path (current_options.sing_box_path)
                : "";
            sb.append_printf ("path: %s\n", sb_path.length > 0 ? sb_path : "not found");
            sb.append_printf ("running: %s\n", sing_box.is_running.to_string ());
            sb.append_printf ("last_exit: %s\n",
                sing_box.last_exit_reason.length > 0 ? sing_box.last_exit_reason : "-");
            sb.append_printf ("unexpected_exits: %u | watchdog_restarts: %d | fallback_proxy: %s\n",
                sing_box.unexpected_exits, tun_restart_count,
                tun_fallback_proxy.to_string ());
            sb.append_printf ("rss_kb: %s\n",
                sing_box.rss_kb () > 0 ? sing_box.rss_kb ().to_string () : "-");
            sb.append_printf ("version: %s\n", sing_box.version_of (sb_path));
            sb.append_printf ("file_caps: %s\n", sing_box.cap_readout (sb_path));
            sb.append_printf ("tun_interface: %s\n",
                sing_box.tun_interface_exists () ? "present" : "absent");
#if WINDOWS
            // Windows: auto_route is fully owned by sing-box (wintun), so
            // route ownership is not introspectable the Linux way. Ship the
            // machine network state instead — it is what a support report
            // needs to reason about a "connected but nothing loads" report.
            sb.append_printf ("route_v4_1.1.1.1_dev: %s\n",
                sing_box.route_device_for ("1.1.1.1"));
            sb.append ("-- network state (ipconfig /all, excerpt) --\n");
            sb.append (run_cmd_excerpt ("ipconfig /all", 60));
            sb.append ("-- routing table (route print -4, excerpt) --\n");
            sb.append (run_cmd_excerpt ("route print -4", 40));
#else
            sb.append_printf ("route_v4_1.1.1.1_dev: %s\n", sing_box.route_device_for ("1.1.1.1"));
            sb.append_printf ("route_v6_2606:4700:4700::1111_dev: %s\n",
                sing_box.route_device_for ("2606:4700:4700::1111"));
            string oom = run_shell_capture (
                "journalctl -k --since '-30 min' --no-pager 2>/dev/null | grep -iE 'oom-kill|out of memory|killed process' | tail -3"
            );
            sb.append_printf ("kernel_oom_scan: %s\n",
                oom.length > 0 ? oom.replace ("\n", " | ") : "(none found / unavailable)");
#endif

            sb.append ("-- system proxy settings --\n");
#if WINDOWS
            // WinInet/WinHTTP proxy state is the Windows equivalent of the
            // gsettings readout below.
            sb.append_printf ("registry ProxyEnable: %s\n",
                run_cmd_capture ("reg query \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\" /v ProxyEnable"));
            sb.append_printf ("registry ProxyServer: %s\n",
                run_cmd_capture ("reg query \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\" /v ProxyServer"));
            sb.append_printf ("registry ProxyOverride: %s\n",
                run_cmd_capture ("reg query \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\" /v ProxyOverride"));
#else
            sb.append_printf ("gsettings mode: %s\n",
                run_cmd_capture ("gsettings get org.gnome.system.proxy mode"));
            sb.append_printf ("gsettings http: %s:%s\n",
                run_cmd_capture ("gsettings get org.gnome.system.proxy.http host"),
                run_cmd_capture ("gsettings get org.gnome.system.proxy.http port"));
            sb.append_printf ("gsettings socks: %s:%s\n",
                run_cmd_capture ("gsettings get org.gnome.system.proxy.socks host"),
                run_cmd_capture ("gsettings get org.gnome.system.proxy.socks port"));
            sb.append ("kdeglobals:\n" + kde_proxy_block ());
#endif

            sb.append ("-- performance probe (last result) --\n");
            sb.append (perf_probe_report.length > 0 ? perf_probe_report : "(not run this session)\n");

            sb.append ("-- tunnel log (last 60 lines) --\n");
            sb.append (tail_lines (log_service.get_text (), 60));
            sb.append ("-- sing-box log (last 40 lines) --\n");
            sb.append (tail_lines (sing_box_log_text (), 40));

            return sb.str;
        }

        private string run_cmd_capture (string command) {
            string? stdout_buf = null;
            int exit_status = -1;
            try {
                Process.spawn_command_line_sync (
                    command, out stdout_buf, null, out exit_status
                );
            } catch (Error err) {
                return "(failed)";
            }
            if (stdout_buf == null || stdout_buf.strip ().length == 0) {
                return "(no output)";
            }
            return stdout_buf.strip ();
        }

        // First N non-empty lines of a command — used for the Windows
        // diagnostics report (ipconfig /all and route print -4 are huge).
        private string run_cmd_excerpt (string command, int max_lines) {
            string full = run_cmd_capture (command);
            if (full.length == 0) {
                return "(unavailable)\n";
            }
            var excerpt = new StringBuilder ();
            int kept = 0;
            foreach (unowned string line in full.split ("\n")) {
                if (kept >= max_lines) {
                    excerpt.append ("…\n");
                    break;
                }
                excerpt.append (line);
                excerpt.append_c ('\n');
                kept++;
            }
            return excerpt.str;
        }

#if !WINDOWS
        // Shell pipeline capture (spawn_command_line_sync does NOT run a
        // shell — pipes/grep need an explicit sh -c).
        private string run_shell_capture (string command) {
            string? stdout_buf = null;
            try {
                Process.spawn_command_line_sync (
                    "/bin/sh -c '%s'".printf (command),
                    out stdout_buf, null, null
                );
            } catch (Error err) {
                return "";
            }
            return stdout_buf != null ? stdout_buf.strip () : "";
        }

        private string kde_proxy_block () {
            string path = Path.build_filename (
                Environment.get_user_config_dir (), "kdeglobals"
            );
            if (!FileUtils.test (path, FileTest.EXISTS)) {
                return "(no kdeglobals)\n";
            }

            string contents;
            try {
                FileUtils.get_contents (path, out contents);
            } catch (Error err) {
                return "(unreadable)\n";
            }

            var block = new StringBuilder ();
            bool in_section = false;
            foreach (unowned string line in contents.split ("\n")) {
                string stripped = line.strip ();
                bool is_header = stripped.has_prefix ("[") && stripped.has_suffix ("]");
                if (is_header) {
                    if (in_section) {
                        break;
                    }
                    in_section = stripped.down () == "[proxy]";
                    if (in_section) {
                        block.append (stripped);
                        block.append_c ('\n');
                    }
                    continue;
                }
                if (in_section) {
                    block.append (line);
                    block.append_c ('\n');
                }
            }

            return block.len > 0 ? block.str : "(no [Proxy] section)\n";
        }
#endif

        // Platform-neutral: keeps the last N lines of a text blob (used by the
        // diagnostics report for the GUI log and the sing-box log).
        private string tail_lines (string text, int max_lines) {
            string[] lines = text.split ("\n");
            int start = lines.length > max_lines ? lines.length - max_lines : 0;
            var sb = new StringBuilder ();
            for (int i = start; i < lines.length; i++) {
                sb.append (lines[i]);
                sb.append_c ('\n');
            }
            return sb.str;
        }

        public void start_tunnel (TunnelOptions options) {
            if (is_running) {
                return;
            }

            current_options = options;

            try {
                config.build_config (options);
            } catch (Error err) {
                error (err.message);
                return;
            }

            string core_path = config.resolve_core_path (options.core_path);
            if (core_path.length == 0) {
                error (I18n.t ("%s was not found. Put it next to the app, install it on PATH, or set a custom core path.").printf (Constants.PSIPHON_BIN));
                return;
            }

            // TUN is requested but sing-box is not installed: degrade to the
            // system proxy instead of aborting the whole connect (Android
            // parity — a missing component never blocks the tunnel).
            tun_runtime_enabled = options.enable_tun;
            if (options.enable_tun && sing_box.resolve_path (options.sing_box_path).length == 0) {
                tun_runtime_enabled = false;
            }

            proxy_host = options.enable_lan ? "0.0.0.0" : "127.0.0.1";
            int64 started_at = now_ms ();
            ip_fetch_started = false;
            routing_started = false;
            // Fresh TUN supervision state per session (the counters persist
            // across auto-restarts of the SAME user session, like
            // auto_restart_count — a fresh manual start clears them).
            if (!auto_restart_pending) {
                tun_restart_count = 0;
                tun_fallback_proxy = false;
                tun_ever_verified = false;
            }
            tun_restarting = false;
            stop_tun_watchdog ();
            if (!auto_restart_pending) {
                // Manual start: a fresh session. Auto-restarts keep the
                // counter so the restart budget (and TCP-only fallback) can
                // never loop forever.
                auto_restart_count = 0;
            }
            reset_traffic_state ();
            stats = new TunnelStats ();
            stats.protocol = options.protocol.config_value ();
            stats.status = "connecting";
            stats.http_proxy = "%s:%d".printf (proxy_host, Constants.HTTP_PROXY_PORT);
            stats.socks_proxy = "%s:%d".printf (proxy_host, Constants.SOCKS_PROXY_PORT);
            stats.beast_mode = options.enable_beast_mode ? "enabled" : "-";
            stats.routing_status = pending_routing_status (options, tun_runtime_enabled);
            stats.started_at_ms = started_at;
            log_service.start_session ();

            if (options.enable_tun && !tun_runtime_enabled) {
                string line = I18n.t ("sing-box was not found — this session routes through the system proxy only");
                log_service.append_line (line);
                log_line (line);
            }

#if WINDOWS
            if (tun_runtime_enabled) {
                // Wintun adapter creation silently fails for non-elevated
                // processes — set the expectation BEFORE sing-box starts so
                // a later "access denied" is self-explanatory.
                string hint = I18n.t ("TUN mode on Windows needs Administrator — right-click Forough and choose “Run as administrator”, or enable the system proxy instead");
                log_service.append_line (hint);
                log_line (hint);
            }
#endif

            try {
                var launcher = new SubprocessLauncher (
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE
                );
                launcher.set_cwd (config.config_dir);
                process = launcher.spawn (core_path, "-config", config.config_path ());

                string? identifier = process.get_identifier ();
                if (identifier != null) {
                    FileUtils.set_contents (config.pid_path (), identifier);
                }

                DataInputStream stdout_stream = new DataInputStream (process.get_stdout_pipe ());
                DataInputStream stderr_stream = new DataInputStream (process.get_stderr_pipe ());
                read_stream.begin (stdout_stream);
                read_stream.begin (stderr_stream);

                process.wait_async.begin (null, (obj, res) => {
                    try {
                        process.wait_async.end (res);
                    } catch (Error err) {
                        warning ("Could not wait for tunnel process: %s", err.message);
                    }
                    cleanup_after_exit ();
                });

                stats_timer_id = Timeout.add (Constants.STATS_UPDATE_MS, () => {
                    stats.uptime_ms = now_ms () - stats.started_at_ms;
                    stats_service.write_stats (stats);
                    stats_changed (stats.copy ());
                    return is_running;
                });

                stats_changed (stats.copy ());
                running_changed (true);
            } catch (Error err) {
                process = null;
                error (I18n.t ("Failed to start psiphon-tunnel-core: %s").printf (err.message));
                cleanup_files ();
            }
        }

        public void stop_tunnel () {
            stop_routing ();

            if (process != null) {
#if WINDOWS
                // GLib maps signals to TerminateProcess on Windows; the
                // explicit force_exit() is the supported equivalent of the
                // SIGTERM path below.
                process.force_exit ();
#else
                process.send_signal (15);
#endif
                return;
            }

            fallback_disconnect ();
        }

        private async void read_stream (DataInputStream stream) {
            try {
                while (is_running) {
                    size_t length = 0;
                    string? line = yield stream.read_line_async (Priority.DEFAULT, null, out length);
                    if (line == null) {
                        break;
                    }

                    log_service.append_line (line);
                    log_line (line);

                    if (parser.apply_line (line, stats, proxy_host)) {
                        handle_stats_update ();
                    }
                }
            } catch (Error err) {
                warning ("Could not read tunnel output: %s", err.message);
            }
        }

        private void handle_stats_update () {
            if (stats.status == "connected" && stats.connected_at_ms == 0) {
                stats.connected_at_ms = now_ms ();
                stats.connect_duration_ms = stats.connected_at_ms - stats.started_at_ms;
                if (!ip_fetch_started) {
                    ip_fetch_started = true;
                    ip_service.fetch_public_ip.begin ("127.0.0.1", Constants.HTTP_PROXY_PORT);
                }
                start_routing ();
                start_traffic_check ();
                schedule_perf_probe ();
            }

            stats_changed (stats.copy ());
        }

        // ----- Performance probe -----

        // Runs once per session, 8 seconds after the tunnel is connected —
        // late enough that establishment churn has settled, early enough that
        // the user has not been waiting forever for the numbers.
        private void schedule_perf_probe () {
            if (perf_probe_timer_id != 0 || perf_probe_done) {
                return;
            }

            perf_probe_timer_id = Timeout.add_seconds (8, () => {
                perf_probe_timer_id = 0;
                run_perf_probe ();
                return Source.REMOVE;
            });
        }

        // Manual on-demand speed test (v1.5.0 header button): re-run the
        // performance probe immediately. The result lands in the session log
        // and in the diagnostics report, replacing the one-shot session value.
        public void run_speed_test_now () {
            if (!is_running || stats.status != "connected" || perf_probe_in_flight) {
                return;
            }
            perf_probe_done = false;
            run_perf_probe ();
        }

        private void stop_perf_probe () {
            if (perf_probe_timer_id != 0) {
                Source.remove (perf_probe_timer_id);
                perf_probe_timer_id = 0;
            }
        }

        private void run_perf_probe () {
            if (perf_probe_in_flight || perf_probe_done ||
                !is_running || stats.status != "connected") {
                return;
            }

            perf_probe_in_flight = true;

            try {
                Thread.create<void*> (() => {
                    string socks = "--socks5-hostname 127.0.0.1:%d".printf (Constants.SOCKS_PROXY_PORT);

                    // First-response latency: connect + TLS + first byte for
                    // a real page over the tunnel.
                    int ttfb_exit = -1;
                    string ttfb_out = run_curl_write_out (
                        "curl -s -o %s -w %%{time_connect}|%%{time_appconnect}|%%{time_starttransfer}|%%{http_code} %s --max-time 20 https://www.wikipedia.org/".printf (CURL_DEV_NULL, socks),
                        out ttfb_exit
                    );

                    // Sustained throughput: 10 MB Cloudflare download capped
                    // at 15s; speed_download reports the measured rate. Small
                    // enough that even a slow meek path yields a NUMBER
                    // instead of a bare FAILED (the 30MB/12s variant used to
                    // time out before curl printed anything useful).
                    int speed_exit = -1;
                    string speed_out = run_curl_write_out (
                        "curl -s -o %s -w %%{size_download}|%%{speed_download}|%%{http_code} %s --max-time 15 https://speed.cloudflare.com/__down?bytes=10000000".printf (CURL_DEV_NULL, socks),
                        out speed_exit
                    );

                    string report = format_perf_report (ttfb_out, speed_out, speed_exit);

                    Idle.add (() => {
                        perf_probe_in_flight = false;
                        perf_probe_done = true;
                        perf_probe_report = report;
                        log_service.append_line (report);
                        log_line (report);
                        return false;
                    });
                    return null;
                }, false);
            } catch (Error err) {
                perf_probe_in_flight = false;
                warning ("Could not start performance probe thread: %s", err.message);
            }
        }

        private string run_curl_write_out (string command, out int exit_status) {
            string? stdout_buf = null;
            string? stderr_buf = null;
            exit_status = -1;
            try {
                Process.spawn_command_line_sync (
                    command, out stdout_buf, out stderr_buf, out exit_status
                );
            } catch (Error err) {
                return "failed (spawn: %s)".printf (err.message);
            }
            if (stdout_buf != null && stdout_buf.strip ().length > 0) {
                // curl prints its -w fields even when the transfer was cut by
                // --max-time: partial bytes are a real measurement.
                return stdout_buf.strip ();
            }
            string detail = stderr_buf != null
                ? stderr_buf.strip ().split ("\n")[0]
                : "";
            return "failed (exit %d%s)".printf (
                exit_status, detail.length > 0 ? ": " + detail : ""
            );
        }

        private string format_perf_report (string ttfb_out, string speed_out, int speed_exit) {
            var sb = new StringBuilder ();
            sb.append_printf ("performance probe (via socks 127.0.0.1:%d):\n", Constants.SOCKS_PROXY_PORT);

            string[] ttfb_parts = ttfb_out.split ("|");
            if (ttfb_parts.length == 4 && ttfb_parts[3] == "200") {
                double connect = double.parse (ttfb_parts[0]);
                double tls = double.parse (ttfb_parts[1]);
                double first_byte = double.parse (ttfb_parts[2]);
                sb.append_printf ("  first response (wikipedia): connect=%.3fs tls=%.3fs first_byte=%.3fs\n",
                    connect, tls, first_byte);
            } else {
                sb.append_printf ("  first response (wikipedia): FAILED (%s)\n", ttfb_out);
            }

            string[] speed_parts = speed_out.split ("|");
            if (speed_parts.length == 3 && speed_parts[2] == "200") {
                double bytes = double.parse (speed_parts[0]);
                double bps = double.parse (speed_parts[1]);
                sb.append_printf ("  download (cloudflare): %.1f MB in 15s max -> %.2f Mbit/s%s\n",
                    bytes / 1000000.0, bps * 8.0 / 1000000.0,
                    speed_exit == 28 ? " (hit the 15s cap — slow path, partial result)" : "");
            } else {
                sb.append_printf ("  download (cloudflare): FAILED (%s)\n", speed_out);
            }

            return sb.str;
        }

        // ----- End-to-end traffic verification -----

        private void reset_traffic_state () {
            traffic_in_flight = false;
            traffic_failures = 0;
            traffic_ever_ok = false;
            stats.traffic_status = "-";
            // Performance probe state is reset per session too — a fresh
            // connect gets a fresh measurement.
            stop_perf_probe ();
            perf_probe_done = false;
            perf_probe_report = "";
            // NOTE: auto_restart_count and auto_restart_pending are
            // deliberately NOT reset here. reset_traffic_state runs on every
            // start_tunnel, including the automatic restarts themselves —
            // zeroing the counter here made dead-traffic tunnels restart
            // forever (connect → 2 failed probes → restart → …), which looked
            // to users like "connects, then drops every few seconds". The
            // counter belongs to the user's session and is cleared in
            // start_tunnel only for manual starts.
        }

        private void stop_traffic_check () {
            if (traffic_timer_id != 0) {
                Source.remove (traffic_timer_id);
                traffic_timer_id = 0;
            }
        }

        private void start_traffic_check () {
            if (traffic_timer_id != 0) {
                return;
            }

            stats.traffic_status = "checking";
            traffic_timer_id = Timeout.add_seconds (
                TRAFFIC_CHECK_FIRST_DELAY_SEC,
                () => {
                    traffic_timer_id = 0;
                    run_traffic_check ();
                    schedule_next_traffic_check ();
                    return Source.REMOVE;
                }
            );
        }

        private void schedule_next_traffic_check () {
            if (traffic_timer_id != 0) {
                return;
            }

            traffic_timer_id = Timeout.add_seconds (
                TRAFFIC_CHECK_INTERVAL_SEC,
                () => {
                    traffic_timer_id = 0;
                    if (is_running && stats.status == "connected") {
                        run_traffic_check ();
                        schedule_next_traffic_check ();
                    }
                    return Source.REMOVE;
                }
            );
        }

        private void run_traffic_check () {
            if (traffic_in_flight || !is_running || stats.status != "connected") {
                return;
            }

            traffic_in_flight = true;
            // Probe several endpoints and accept the first success. All-fail
            // is required to count the check as failed.
            //
            // NOTE: the endpoints are tried sequentially INSIDE this thread —
            // never via a shell "||" chain. g_spawn_command_line_sync does not
            // run a shell, so a chained command used to hand the literal "||"
            // and every following URL to the FIRST curl as arguments, which
            // failed curl's option parsing: the probe reported failure even
            // on a perfectly healthy tunnel (the v1.2.0/v1.2.1 drop reports).
            string[] probe_urls = {
                "http://www.gstatic.com/generate_204",
                "http://cp.cloudflare.com/generate_204",
                "http://example.com/"
            };
            string host = "127.0.0.1";
            int port = Constants.HTTP_PROXY_PORT;

            // v1.5.1: the probe tests the TUNNEL (via the local HTTP proxy,
            // which never touches the TUN). A green probe with a dead routing
            // layer is exactly how the "connected but nothing loads" blackout
            // hid from every indicator. Capture routing health on the main
            // thread and let traffic_check_done tell the truth.
            bool tun_expected = tun_runtime_enabled && routing_started && !tun_fallback_proxy;
            bool tun_healthy = tun_expected
                && sing_box.is_running
                && sing_box.tun_interface_exists ();

            try {
                Thread.create<void*> (() => {
                    int exit_status = -1;
                    string? stdout_buf = null;
                    foreach (string url in probe_urls) {
                        string? probe_stdout = null;
                        int code = 0;
                        try {
                            Process.spawn_command_line_sync (
                                "curl -s -o %s -w %%{http_code} --max-time %d --noproxy '*' -x http://%s:%d %s".printf (
                                    CURL_DEV_NULL, TRAFFIC_CHECK_MAX_TIME_SEC, host, port, url
                                ),
                                out probe_stdout, null, out exit_status
                            );
                        } catch (Error err) {
                            exit_status = -1;
                        }

                        bool probe_ok = exit_status == 0 && probe_stdout != null;
                        if (probe_ok) {
                            string digits = "";
                            string trimmed = probe_stdout.strip ();
                            for (int i = trimmed.length - 1;
                                 i >= 0 && digits.length < 3; i--) {
                                char c = trimmed[i];
                                if (c >= '0' && c <= '9') {
                                    digits = c.to_string () + digits;
                                } else {
                                    break;
                                }
                            }
                            code = int.parse (digits);
                            probe_ok = code >= 200 && code < 400;
                        }

                        if (probe_ok) {
                            stdout_buf = code.to_string ();
                            break;
                        }
                    }

                    bool ok = stdout_buf != null;
                    int code = stdout_buf != null ? int.parse (stdout_buf) : 0;

                    Idle.add (() => {
                        traffic_check_done (ok, code, tun_expected && !tun_healthy);
                        return false;
                    });
                    return null;
                }, false);
            } catch (Error err) {
                traffic_in_flight = false;
                warning ("Could not start traffic check thread: %s", err.message);
            }
        }

        private void traffic_check_done (bool ok, int code, bool routing_down) {
            traffic_in_flight = false;

            if (!is_running || stats.status != "connected") {
                return;
            }

            // The tunnel answers its own proxy while the TUN layer that
            // actually delivers user traffic is dead: report the routing
            // outage instead of a lying "ok" (the watchdog repairs it).
            if (ok && routing_down) {
                if (stats.traffic_status != "tun-down") {
                    stats.traffic_status = "tun-down";
                    string line = "traffic check: tunnel healthy but TUN routing is down — watchdog recovering";
                    log_service.append_line (line);
                    log_line (line);
                    stats_changed (stats.copy ());
                }
                return;
            }

            if (ok) {
                if (traffic_failures > 0 || stats.traffic_status != "ok") {
                    traffic_failures = 0;
                    stats.traffic_status = "ok";
                    stats_changed (stats.copy ());
                }
                traffic_ever_ok = true;
                return;
            }

            traffic_failures += 1;
            stats.traffic_status = "failed";
            string line = "traffic check failed (http code: %d, failures: %d)".printf (
                code, traffic_failures
            );
            log_service.append_line (line);
            log_line (line);
            stats_changed (stats.copy ());

            // A tunnel that has never served a single successful probe gets a
            // fast restart. One that worked before is only restarted when the
            // outage persists (3 consecutive checks) — and only once more, so
            // a healthy tunnel is never killed by a transient blip.
            int threshold = traffic_ever_ok
                ? TRAFFIC_FAIL_RESTART_THRESHOLD_AFTER_OK
                : TRAFFIC_FAIL_RESTART_THRESHOLD;
            bool recovery_restart = traffic_ever_ok && auto_restart_count == 0;

            if (traffic_failures >= threshold) {
                bool can_restart =
                    auto_restart_count < AUTO_RESTART_MAX || recovery_restart;
                write_diagnostics (
                    can_restart ? "traffic-dead-restart" : "traffic-dead-final"
                );
                if (can_restart) {
                    trigger_auto_restart ();
                }
            }
        }

        private void trigger_auto_restart () {
            auto_restart_count += 1;
            auto_restart_pending = true;
            stats.traffic_status = "restarting";

            string message = I18n.t (
                "Traffic is not going through — restarting the tunnel automatically (%d/%d)"
            ).printf (auto_restart_count, AUTO_RESTART_MAX);
            log_service.append_line (message);
            log_line (message);
            stats_changed (stats.copy ());

            // Final automatic attempt: drop QUIC-based protocols. ISPs that
            // throttle QUIC let the handshake pass but never carry traffic,
            // and that is indistinguishable from a dead fronting edge until
            // the tunnel is retried over TCP only.
            if (current_options != null && auto_restart_count >= AUTO_RESTART_MAX) {
                current_options.tcp_only_override = true;
                log_service.append_line (
                    "retrying with TCP-only protocols (QUIC disabled)"
                );
            }

            stop_tunnel ();
        }

        private void start_routing () {
            if (routing_started || current_options == null) {
                return;
            }

            bool want_system_proxy = current_options.enable_system_proxy;
            bool want_tun = tun_runtime_enabled;

            if (!want_system_proxy && !want_tun) {
                // The tunnel is up but NOTHING delivers app traffic into it —
                // the browser keeps going out directly. Say so loudly instead
                // of a silent "-".
                routing_started = true;
                stats.routing_status = I18n.t ("No routing — apps bypass the tunnel");
                string line = I18n.t ("The tunnel is connected, but no routing method is enabled. Turn on TUN or the system proxy in Settings so browser traffic rides the tunnel.");
                log_service.append_line (line);
                log_line (line);
                stats_changed (stats.copy ());
                return;
            }

            routing_started = true;
            routing_parts = {};

            if (want_system_proxy) {
                try {
                    system_proxy.enable (stats.http_proxy, stats.socks_proxy);
#if !WINDOWS
                    if (system_proxy.kde_is_applied) {
                        add_routing_part (I18n.t ("System proxy active (GNOME + KDE)"));
                    } else if (system_proxy.kde_detected) {
                        add_routing_part (I18n.t ("System proxy: GNOME settings only (KDE apps may ignore — use browser proxy or TUN)"));
                    } else {
                        add_routing_part (I18n.t ("System proxy active"));
                    }
#else
                    add_routing_part (I18n.t ("System proxy active"));
#endif
                } catch (Error err) {
                    add_routing_part (I18n.t ("System proxy failed"));
                    error (err.message);
                }
            }

            if (want_tun) {
                start_tun_routing.begin ();
            }
        }

        private void add_routing_part (string part) {
            routing_parts += part;
            stats.routing_status = string.joinv (" · ", routing_parts);
            stats_changed (stats.copy ());
        }

        // TUN startup with a permission pre-flight. The pkexec dialog (when
        // the file capability is missing) is the desktop equivalent of
        // Android's "allow VPN" prompt — routing simply waits for the answer.
        private async void start_tun_routing () {
            if (current_options == null || !is_running) {
                return;
            }

            string sing_box_path = sing_box.resolve_path (current_options.sing_box_path);
            if (sing_box_path.length == 0) {
                add_routing_part (I18n.t ("TUN unavailable (sing-box not found)"));
                return;
            }

            add_routing_part (I18n.t ("TUN: preparing…"));
#if !WINDOWS
            bool permitted = yield sing_box.ensure_tun_permission (sing_box_path);
            if (!is_running || current_options == null) {
                return;
            }
            if (!permitted) {
                add_routing_part (I18n.t ("TUN blocked — admin permission not granted"));
                string line = I18n.t ("sing-box needs CAP_NET_ADMIN for whole-device routing. Approve the permission prompt, or run: sudo setcap cap_net_admin+ep '%s'").printf (sing_box_path);
                log_service.append_line (line);
                log_line (line);
                sing_box_error_changed (I18n.t ("TUN blocked — admin permission not granted"));
                return;
            }
#else
            // Windows: the wintun adapter is created by sing-box itself. No
            // capability dance — but the process must run elevated; if it
            // does not, sing-box fails at startup and the error surfaces in
            // the sing-box log button with a clear hint (see SingBoxManager).
            if (!is_running || current_options == null) {
                return;
            }
#endif

            try {
                string core_binary_name = Constants.PSIPHON_BIN;
                string core_path = config.resolve_core_path (current_options.core_path);
                if (core_path.length > 0) {
                    core_binary_name = Path.get_basename (core_path);
                }
                sing_box.fakeip_enabled = current_options.tun_fakeip;
                string dns_line = "TUN DNS mode: %s".printf (
                    current_options.tun_fakeip
                        ? "fakeip (instant answers, domains resolved at the tunnel exit)"
                        : "forward (TCP DNS through the tunnel)"
                );
                log_service.append_line (dns_line);
                log_line (dns_line);
                sing_box.start (current_options.sing_box_path, stats.socks_proxy, core_binary_name);
                add_routing_part (I18n.t ("TUN active"));
                sing_box_error_changed ("");
                schedule_tun_verification ();
                schedule_tun_watchdog ();
            } catch (Error err) {
                add_routing_part (I18n.t ("TUN failed"));
                sing_box_error_changed (err.message);
                // Not fatal on its own — with the system proxy also enabled,
                // browsers still reach the tunnel. Only alarm the user when
                // TUN was the ONLY routing method.
                if (!current_options.enable_system_proxy) {
                    error (err.message);
                }
            } finally {
                // A watchdog-initiated restart releases its lock here, on
                // every exit path of start_tun_routing.
                tun_restarting = false;
            }
        }

        // ----- TUN watchdog (v1.5.1) -----

        // The blackout post-mortem: sing-box verified at +2s, silently
        // killed later, and every indicator kept lying (traffic "ok" via the
        // TUN-bypassing probe, routing status frozen at "TUN verified", no
        // log because a SIGKILL says nothing). The watchdog polls the real
        // process/device state, restarts sing-box within seconds, and if it
        // cannot restore whole-device routing it engages the system proxy so
        // the user keeps internet THROUGH the tunnel instead of a silent
        // blackout.
        private void schedule_tun_watchdog () {
            stop_tun_watchdog ();
            tun_watchdog_timer_id = Timeout.add_seconds (
                TUN_WATCHDOG_START_DELAY_SEC,
                () => {
                    tun_watchdog_timer_id = Timeout.add_seconds (
                        TUN_WATCHDOG_INTERVAL_SEC,
                        tun_watchdog_tick
                    );
                    tun_watchdog_tick ();   // first tick immediately
                    return Source.REMOVE;
                }
            );
        }

        private void stop_tun_watchdog () {
            if (tun_watchdog_timer_id != 0) {
                Source.remove (tun_watchdog_timer_id);
                tun_watchdog_timer_id = 0;
            }
        }

        private bool tun_watchdog_tick () {
            // Keep the timer alive only inside a connected session with TUN
            // routing expected.
            bool keep = is_running
                && stats.status == "connected"
                && current_options != null
                && tun_runtime_enabled
                && routing_started;
            if (!keep) {
                tun_watchdog_timer_id = 0;
                return Source.REMOVE;
            }

            if (tun_restarting) {
                return Source.CONTINUE;
            }

            // Once the system-proxy fallback carries traffic, TUN recovery
            // is best-effort only — do not flap the delivery path.
            if (tun_fallback_proxy) {
                return Source.CONTINUE;
            }

            bool singbox_alive = sing_box.is_running;
            bool tun_present = singbox_alive && sing_box.tun_interface_exists ();
#if WINDOWS
            // auto_route+strict_route are handled inside sing-box via wintun;
            // there is no "ip route get" equivalent to poll. Adapter present
            // plus process alive is the health signal (the end-to-end probe
            // in verify_tun_routing still catches a black-holed TUN).
            bool route_captured = tun_present;
#else
            bool route_captured = tun_present
                && sing_box.route_device_for ("1.1.1.1") == Constants.SING_BOX_TUN_INTERFACE;
#endif

            if (singbox_alive && tun_present && route_captured) {
                // All good — memory guard only: restart a leaking instance
                // before the OOM killer does it mid-page-load.
                uint64 rss = sing_box.rss_kb ();
                if (rss > TUN_RSS_RESTART_KB) {
                    string line = I18n.t ("sing-box memory usage is high (%s MB) — restarting it cleanly").printf (
                        (rss / 1024).to_string ());
                    log_service.append_line (line);
                    log_line (line);
                    restart_tun_routing ();
                }
                return Source.CONTINUE;
            }

            // Something is broken — classify and repair.
            if (tun_restart_count >= TUN_RESTART_MAX) {
                engage_system_proxy_fallback ();
                return Source.CONTINUE;
            }

            tun_restart_count += 1;
            // Default covers the Windows build, where the final else (route
            // stolen back by the system) is compiled out — auto_route lives
            // inside sing-box there, so only the two states below can occur.
            string reason = I18n.t ("the system took the TUN route back — reapplying it");
            if (!singbox_alive) {
                reason = I18n.t ("TUN routing lost — sing-box is no longer running (%s)").printf (
                    sing_box.last_exit_reason.length > 0
                        ? sing_box.last_exit_reason
                        : I18n.t ("no exit details"));
            } else if (!tun_present) {
                reason = I18n.t ("TUN interface vanished — restarting sing-box");
#if !WINDOWS
            } else {
                reason = I18n.t ("the system took the TUN route back — reapplying it");
#endif
            }

            string message = I18n.t ("%s — restarting sing-box (%d/%d)").printf (
                reason, tun_restart_count, TUN_RESTART_MAX);
            log_service.append_line (message);
            log_line (message);
            if (tun_restart_count == 1) {
                // Capture the machine state of the FIRST failure while it is
                // fresh — this is the report that explains the blackout.
                write_diagnostics ("tun-watchdog");
            }
            restart_tun_routing ();
            return Source.CONTINUE;
        }

        private void restart_tun_routing () {
            if (tun_restarting) {
                return;
            }
            tun_restarting = true;
            sing_box.kill_now ();
            // Fresh status chain so the UI shows the recovery, not a stale
            // "TUN verified" from before the death.
            routing_parts = {};
            add_routing_part (I18n.t ("TUN: preparing…"));
            start_tun_routing.begin ();
        }

        // Last-resort delivery path: TUN could not be restored within the
        // restart budget, so route apps through the local HTTP/SOCKS proxies
        // via desktop proxy settings (GNOME gsettings + Plasma kdeglobals).
        // The tunnel keeps running — the user keeps internet instead of a
        // silent blackout, and the routing status says exactly what happened.
        private void engage_system_proxy_fallback () {
            if (tun_fallback_proxy) {
                return;
            }
            tun_fallback_proxy = true;

            string line = I18n.t ("TUN could not be restored — switching to the system proxy so traffic keeps flowing");
            log_service.append_line (line);
            log_line (line);

            try {
                if (!system_proxy.is_active) {
                    system_proxy.enable (stats.http_proxy, stats.socks_proxy);
                }
                add_routing_part (I18n.t ("System proxy fallback (TUN lost)"));
                sing_box_error_changed ("");
            } catch (Error err) {
                add_routing_part (I18n.t ("System proxy failed"));
                error (I18n.t ("TUN could not be restored and the system proxy failed: %s").printf (err.message));
            }

            write_diagnostics ("tun-fallback-proxy");
        }

        // ----- TUN verification -----

        // "TUN active" only proves the process started. Two cheap checks make
        // a silently broken TUN visible: (1) auto_route really captured the
        // route to public IPs, (2) a packet makes the round trip through it.
        private void schedule_tun_verification () {
            Timeout.add_seconds (2, () => {
                verify_tun_routing ();
                return Source.REMOVE;
            });
        }

        private void verify_tun_routing () {
            if (!is_running || stats.status != "connected") {
                return;
            }

            if (!sing_box.is_running) {
                // sing-box died between start and verification. Never silent
                // again: say it, and let the watchdog (or the fallback path)
                // repair it.
                string line = "TUN verification skipped — sing-box already exited (%s)".printf (
                    sing_box.last_exit_reason.length > 0
                        ? sing_box.last_exit_reason : "no exit details"
                );
                log_service.append_line (line);
                log_line (line);
                add_routing_part (I18n.t ("TUN routing lost"));
                return;
            }

            if (!sing_box.tun_interface_exists ()) {
                add_routing_part (I18n.t ("TUN interface missing"));
                return;
            }

#if !WINDOWS
            string route_dev = sing_box.route_device_for ("1.1.1.1");
            if (route_dev != Constants.SING_BOX_TUN_INTERFACE) {
                add_routing_part (
                    I18n.t ("TUN route not captured (default via %s)").printf (
                        route_dev.length > 0 ? route_dev : "?"
                    )
                );
                return;
            }

            // The v4 route alone is not the whole story: with an IPv6-capable
            // network an uncaptured ::/0 lets the system resolver query v6 DNS
            // servers directly (censored/poisoned), which looks exactly like
            // "connected but no site opens". Surface it when it happens.
            string route_dev6 = sing_box.route_device_for ("2606:4700:4700::1111");
            if (route_dev6.length > 0 && route_dev6 != Constants.SING_BOX_TUN_INTERFACE) {
                add_routing_part (
                    I18n.t ("IPv6 route not captured — DNS may bypass the tunnel")
                );
                string line = "IPv6 default route still via %s — v6 DNS bypasses the tunnel".printf (
                    route_dev6
                );
                log_service.append_line (line);
                log_line (line);
            }
#else
            // Windows: sing-box owns the default route while the wintun
            // adapter is present (strict_route). Route-table introspection is
            // skipped; the end-to-end probe below is the real verdict.
#endif

            try {
                Thread.create<void*> (() => {
                    int exit_status = -1;
                    try {
                        // Plain curl: with auto_route the default path IS the
                        // TUN, and any HTTP response (even a redirect or 403
                        // from the IP literal) proves the round trip works.
                        // No shell, no proxy env: a direct end-to-end probe.
                        Process.spawn_command_line_sync (
                            "curl -s --noproxy '*' -o %s --max-time 6 http://1.1.1.1/".printf (CURL_DEV_NULL),
                            null, null, out exit_status
                        );
                    } catch (Error err) {
                        exit_status = -1;
                    }
                    bool ok = exit_status == 0;
                    Idle.add (() => {
                        tun_probe_done (ok);
                        return false;
                    });
                    return null;
                }, false);
            } catch (Error err) {
                warning ("Could not start TUN probe thread: %s", err.message);
            }
        }

        private void tun_probe_done (bool ok) {
            if (!is_running || stats.status != "connected") {
                return;
            }

            if (ok) {
                tun_ever_verified = true;
                add_routing_part (I18n.t ("TUN verified"));
                string line = "TUN routing verified (default route + end-to-end probe)";
                log_service.append_line (line);
                log_line (line);
            } else {
                add_routing_part (I18n.t ("TUN is up but traffic does not pass"));
                string line = I18n.t ("The TUN device is up and owns the default route, but a probe packet did not come back. Try reconnecting, or report the session log.");
                log_service.append_line (line);
                log_line (line);
                // Capture the full machine state the moment a broken TUN is
                // detected — this file is what makes the report diagnosable.
                write_diagnostics ("tun-probe-failed");
            }
        }

        private void stop_routing () {
            stop_tun_watchdog ();
            tun_restarting = false;

            if (!routing_started && !system_proxy.is_active && !sing_box.is_running) {
                return;
            }

            system_proxy.disable ();
            sing_box.stop ();
            routing_started = false;
            tun_fallback_proxy = false;

            if (current_options != null) {
                stats.routing_status = pending_routing_status (current_options, tun_runtime_enabled);
            }
        }

        private void cleanup_after_exit () {
            stop_traffic_check ();
            stop_perf_probe ();
            stop_routing ();
            process = null;

            var restart_options = current_options;
            current_options = null;

            stats.status = "disconnected";
            stats.routing_status = "-";
            cleanup_files ();
            log_service.close_session ();
            if (stats_timer_id != 0) {
                Source.remove (stats_timer_id);
                stats_timer_id = 0;
            }
            stats_changed (stats.copy ());
            running_changed (false);

            if (auto_restart_pending && restart_options != null) {
                auto_restart_pending = false;
                start_tunnel (restart_options);
            }
        }

        private void cleanup_files () {
            if (FileUtils.test (config.pid_path (), FileTest.EXISTS)) {
                FileUtils.remove (config.pid_path ());
            }
            stats_service.delete_stats ();
        }

        private void fallback_disconnect () {
            stop_routing ();

            try {
                if (FileUtils.test (config.pid_path (), FileTest.EXISTS)) {
                    string pid;
                    FileUtils.get_contents (config.pid_path (), out pid);
#if WINDOWS
                    Process.spawn_command_line_sync ("taskkill /F /PID %s".printf (pid.strip ()));
#else
                    Process.spawn_command_line_sync ("kill -TERM %s".printf (pid.strip ()));
#endif
                    cleanup_files ();
                    log_service.close_session ();
                    running_changed (false);
                    return;
                }

#if WINDOWS
                // Match the exact image name; the engine ships with this name
                // in the bundle so an orphaned instance is always ours.
                Process.spawn_command_line_sync ("taskkill /F /IM %s".printf (Constants.PSIPHON_BIN));
#else
                Process.spawn_command_line_sync ("pkill -f %s".printf (Constants.PSIPHON_BIN));
#endif
                cleanup_files ();
                log_service.close_session ();
                running_changed (false);
            } catch (Error err) {
                error (I18n.t ("Failed to disconnect: %s").printf (err.message));
            }
        }

        private string pending_routing_status (TunnelOptions options, bool tun_enabled) {
            string[] parts = {};

            if (options.enable_system_proxy) {
                parts += "System proxy pending";
            }
            if (tun_enabled) {
                parts += "TUN pending";
            }

            if (parts.length == 0) {
                return "-";
            }

            return string.joinv (" · ", parts);
        }

        private int64 now_ms () {
            return GLib.get_real_time () / 1000;
        }

        private bool is_sing_box_error_line (string line) {
            string lower = line.down ();
            return lower.contains ("fatal") ||
                lower.contains ("error") ||
                lower.contains ("legacy") ||
                lower.contains ("failed") ||
                lower.contains ("rejected") ||
                lower.contains ("exited:");
        }
    }
}
