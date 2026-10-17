namespace PsiphonCliGui {
    public class SingBoxManager : Object {
        public signal void diagnostic (string line);

        private ConfigService config;
        private Subprocess? process = null;
        private bool running = false;
        private string last_error = "";
        private StringBuilder log_buffer = new StringBuilder ();

        // Exit bookkeeping (v1.5.1): the field report that cracked the
        // "connected but nothing loads" blackout showed sing-box VERIFIED at
        // +2s and later GONE with an empty log. A silent SIGKILL (OOM killer,
        // external pkill) leaves no stderr at level=warn, so the old code
        // recorded nothing. We now always capture how the process ended.
        public string last_exit_reason { get; private set; default = ""; }
        public uint unexpected_exits { get; private set; default = 0; }

        // Log buffer cap: sing-box at level=info emits a steady trickle; an
        // unbounded StringBuilder slowly becomes the memory leak that gets
        // the whole desktop OOM-killed.
        private const int LOG_BUFFER_MAX_LINES = 400;

        public string last_error_message {
            get { return last_error; }
        }

        public string log_text {
            get { return log_buffer.str; }
        }

        public void clear_logs () {
            log_buffer = new StringBuilder ();
            last_error = "";
        }

        // Resident memory of the running sing-box in KB (0 = unknown).
        // Feeds the tunnel-manager watchdog: a leaking mixed-stack instance
        // is restarted BEFORE the OOM killer murderously restarts it for us.
        public uint64 rss_kb () {
            if (process == null) {
                return 0;
            }

            string? identifier = process.get_identifier ();
            if (identifier == null || identifier.length == 0) {
                return 0;
            }

#if WINDOWS
            // tasklist /FO CSV /NH prints: "sing-box.exe","<pid>","Console",
            // "<session>","45,012 K" — the working set in KB with comma
            // separators. Normalize and read the integer before " K".
            string? stdout_buf = null;
            try {
                Process.spawn_command_line_sync (
                    "tasklist /FI \"PID eq %s\" /FO CSV /NH".printf (identifier),
                    out stdout_buf, null, null
                );
            } catch (Error err) {
                return 0;
            }
            if (stdout_buf == null) {
                return 0;
            }

            string flat = stdout_buf.replace (",", "").replace ("\"", "");
            int kpos = flat.index_of (" K");
            if (kpos < 0) {
                return 0;
            }
            int end = kpos;
            int start = end;
            while (start > 0 && flat[start - 1] >= '0' && flat[start - 1] <= '9') {
                start--;
            }
            if (end == start) {
                return 0;
            }
            return uint64.parse (flat[start:end]);
#else
            string status_path = "/proc/%s/status".printf (identifier);
            string contents;
            try {
                if (!FileUtils.get_contents (status_path, out contents)) {
                    return 0;
                }
            } catch (Error err) {
                return 0;
            }

            foreach (unowned string line in contents.split ("\n")) {
                if (line.has_prefix ("VmRSS:")) {
                    string[] parts = line.split (" ");
                    foreach (string part in parts) {
                        if (part.length > 0 && part[0] >= '0' && part[0] <= '9') {
                            return uint64.parse (part);
                        }
                    }
                }
            }
            return 0;
#endif
        }

        // Synchronous hard stop used by the watchdog before a restart. The
        // regular stop() is async (SIGTERM, 3s grace, SIGKILL) which is right
        // for disconnects but wrong when the next start must see a clean
        // slate immediately.
        public void kill_now () {
            force_stop ();
        }

        public bool is_running {
            get { return running; }
        }

        // Fast-DNS Fake-IP mode (v1.4.0): when true, A/AAAA queries are
        // answered instantly from a fake-IP pool and the real domain is
        // resolved at the tunnel exit when the app connects. Toggled from
        // Settings; default on — it is the effective DNS behavior Android
        // users already get from tun2socks+udpgw.
        public bool fakeip_enabled { get; set; default = true; }

        public SingBoxManager (ConfigService config) {
            this.config = config;
        }

        public string resolve_path (string custom_path) {
            string trimmed = custom_path.strip ();
            if (trimmed.length > 0 && FileUtils.test (trimmed, FileTest.IS_EXECUTABLE)) {
                return trimmed;
            }

            string from_settings = read_sing_box_path_setting ();
            if (from_settings.length > 0 && FileUtils.test (from_settings, FileTest.IS_EXECUTABLE)) {
                return from_settings;
            }

            // The bundled binary (RPM install) wins over a random PATH hit:
            // the TUN config syntax is validated against the bundled version,
            // so an older distro sing-box on PATH could reject it and silently
            // kill TUN routing.
            foreach (string candidate in RuntimePaths.installed_sing_box_path_candidates ()) {
                if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE)) {
                    return candidate;
                }
            }

            string? from_path = Environment.find_program_in_path (Constants.SING_BOX_BIN);
            if (from_path != null && from_path.length > 0) {
                return from_path;
            }

            foreach (string candidate in extra_candidates ()) {
                if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE)) {
                    return candidate;
                }
            }

            return "";
        }

        private string[] extra_candidates () {
#if WINDOWS
            // The bundle deploys sing-box.exe next to the GUI executable;
            // there is no /usr/bin on Windows.
            return {
                Path.build_filename (Environment.get_current_dir (), "..", Constants.SING_BOX_BIN),
                Path.build_filename (Environment.get_current_dir (), Constants.SING_BOX_BIN),
                Path.build_filename (Environment.get_current_dir (), "..", "..", Constants.SING_BOX_BIN)
            };
#else
            return {
                Path.build_filename (Environment.get_current_dir (), "..", Constants.SING_BOX_BIN),
                Path.build_filename (Environment.get_current_dir (), Constants.SING_BOX_BIN),
                Path.build_filename (Environment.get_current_dir (), "..", "..", Constants.SING_BOX_BIN),
                "/usr/local/bin/%s".printf (Constants.SING_BOX_BIN),
                "/usr/bin/%s".printf (Constants.SING_BOX_BIN)
            };
#endif
        }

        public string config_path () {
            return Path.build_filename (config.config_dir, Constants.SING_BOX_CONFIG_FILE);
        }

        public string pid_path () {
            return Path.build_filename (config.config_dir, Constants.SING_BOX_PID_FILE);
        }

        // ----- TUN capability pre-flight (POSIX) -----

#if WINDOWS
        // Windows has no file capabilities. The wintun adapter is created by
        // sing-box, which requires an elevated (Administrator) process. There
        // is no self-service repair the pkexec path could offer, so the
        // pre-flight is a no-op and startup errors carry the elevation hint.
        public async bool ensure_tun_permission (string sing_box_path) {
            return true;
        }

        public string cap_readout (string sing_box_path) {
            return "n/a on Windows";
        }
#else

        // auto_route TUN needs CAP_NET_ADMIN on the sing-box binary (the app
        // itself never runs as root). The RPM %post normally sets the file
        // capability; when it is missing (portable runs, degraded installs)
        // we try once to repair it via pkexec, which pops the standard
        // admin-password dialog — the desktop equivalent of Android's
        // "allow VPN" prompt. Returns true when the binary may proceed.
        public async bool ensure_tun_permission (string sing_box_path) {
            if (Environment.get_user_name () == "root") {
                return true;
            }

            CapState state = read_cap_state (sing_box_path);
            if (state == CapState.HAS_CAP) {
                return true;
            }
            if (state == CapState.CHECK_FAILED) {
                // getcap missing: cannot verify — let start() try and surface
                // the kernel error if the capability really is absent.
                return true;
            }

            diagnostic ("TUN capability missing on sing-box binary — requesting admin permission (pkexec setcap)…");
            bool repaired = yield repair_cap_via_pkexec (sing_box_path);
            if (repaired && read_cap_state (sing_box_path) == CapState.HAS_CAP) {
                diagnostic ("CAP_NET_ADMIN granted to sing-box");
                return true;
            }
            return false;
        }

        private enum CapState {
            HAS_CAP,
            NO_CAP,
            CHECK_FAILED
        }

        private CapState read_cap_state (string sing_box_path) {
            string? getcap = find_tool ("getcap", { "/usr/sbin/getcap", "/usr/bin/getcap" });
            if (getcap.length == 0) {
                return CapState.CHECK_FAILED;
            }

            string? stdout_buf = null;
            string? stderr_buf = null;
            int exit_status = -1;
            try {
                Process.spawn_command_line_sync (
                    "%s %s".printf (getcap, sing_box_path),
                    out stdout_buf, out stderr_buf, out exit_status
                );
            } catch (Error err) {
                return CapState.CHECK_FAILED;
            }

            if (stdout_buf == null || stdout_buf.strip ().length == 0) {
                return CapState.NO_CAP;
            }
            return stdout_buf.contains ("cap_net_admin") ? CapState.HAS_CAP : CapState.NO_CAP;
        }

        private async bool repair_cap_via_pkexec (string sing_box_path) {
            string? setcap = find_tool ("setcap", { "/usr/sbin/setcap", "/usr/bin/setcap" });
            if (setcap.length == 0) {
                diagnostic ("setcap not found on this system");
                return false;
            }

            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDERR_PIPE);
                Subprocess proc = launcher.spawn (
                    "pkexec", setcap, "cap_net_admin+ep", sing_box_path
                );
                yield proc.wait_async (null);
                return proc.get_if_exited () && proc.get_exit_status () == 0;
            } catch (Error err) {
                diagnostic ("pkexec setcap failed: %s".printf (err.message));
                return false;
            }
        }

        private string find_tool (string name, string[] fallback_paths) {
            string? from_path = Environment.find_program_in_path (name);
            if (from_path != null && FileUtils.test (from_path, FileTest.EXISTS)) {
                return from_path;
            }
            foreach (string candidate in fallback_paths) {
                if (FileUtils.test (candidate, FileTest.EXISTS)) {
                    return candidate;
                }
            }
            return "";
        }
#endif // !WINDOWS

        // Whether the TUN device is actually up right now.
        public bool tun_interface_exists () {
#if WINDOWS
            // `netsh interface show interface` lists every adapter by name;
            // the wintun adapter created by sing-box carries the configured
            // interface_name (forough0).
            string? stdout_buf = null;
            try {
                Process.spawn_command_line_sync (
                    "netsh interface show interface",
                    out stdout_buf, null, null
                );
            } catch (Error err) {
                return false;
            }
            return stdout_buf != null
                && stdout_buf.down ().contains (Constants.SING_BOX_TUN_INTERFACE);
#else
            int exit_status = -1;
            string? stdout_buf = null;
            try {
                Process.spawn_command_line_sync (
                    "ip link show %s".printf (Constants.SING_BOX_TUN_INTERFACE),
                    out stdout_buf, null, out exit_status
                );
            } catch (Error err) {
                return false;
            }
            return exit_status == 0;
#endif
        }

        // Which device owns the route to a public IP right now. Used to
        // verify that auto_route really captured the default path.
        public string route_device_for (string ip) {
#if WINDOWS
            // Windows has no "ip route get"; route ownership under auto_route
            // is managed inside sing-box (wintun). Callers treat "" as "not
            // introspectable" and rely on the end-to-end probe instead.
            return "";
#else
            string? stdout_buf = null;
            try {
                Process.spawn_command_line_sync (
                    "ip route get %s".printf (ip),
                    out stdout_buf, null, null
                );
            } catch (Error err) {
                return "";
            }
            if (stdout_buf == null) {
                return "";
            }
            // "... dev forough0 ..." — pick the token after "dev".
            string[] tokens = stdout_buf.split (" ");
            for (int i = 0; i < tokens.length - 1; i++) {
                if (tokens[i] == "dev") {
                    return tokens[i + 1].strip ();
                }
            }
            return "";
#endif
        }

        // ----- Diagnostics helpers (report / support bundle) -----

        // First line of "sing-box version" for the resolved binary.
        public string version_of (string sing_box_path) {
            if (sing_box_path.length == 0) {
                return "not found";
            }

            string? stdout_buf = null;
            int exit_status = -1;
            try {
                Process.spawn_command_line_sync (
                    "'%s' version".printf (sing_box_path),
                    out stdout_buf, null, out exit_status
                );
            } catch (Error err) {
                return "exec failed";
            }

            if (exit_status != 0 || stdout_buf == null || stdout_buf.strip ().length == 0) {
                return "unknown";
            }
            return stdout_buf.strip ().split ("\n")[0].strip ();
        }

#if !WINDOWS
        // Raw getcap output for the resolved binary.
        public string cap_readout (string sing_box_path) {
            if (sing_box_path.length == 0) {
                return "sing-box not found";
            }

            string? getcap = find_tool ("getcap", { "/usr/sbin/getcap", "/usr/bin/getcap" });
            if (getcap.length == 0) {
                return "getcap not installed";
            }

            string? stdout_buf = null;
            try {
                Process.spawn_command_line_sync (
                    "%s '%s'".printf (getcap, sing_box_path),
                    out stdout_buf, null, null
                );
            } catch (Error err) {
                return "check failed";
            }

            return (stdout_buf != null && stdout_buf.strip ().length > 0)
                ? stdout_buf.strip ()
                : "no capabilities set";
        }
#endif // !WINDOWS

        public void start (string custom_path, string socks_endpoint, string core_binary_name) throws Error {
            if (running) {
                return;
            }

            // A previous instance may still be exiting (stop() is async). Kill
            // any leftover here so a quick disconnect→connect or auto-restart
            // cycle cannot end up with two sing-box instances or a stale TUN.
            force_stop ();

            string sing_box_path = resolve_path (custom_path);
            if (sing_box_path.length == 0) {
#if WINDOWS
                throw new IOError.NOT_FOUND (
                    "sing-box.exe was not found. Put it (with wintun.dll) next to forough.exe, or set a custom path in Settings."
                );
#else
                throw new IOError.NOT_FOUND (
                    "sing-box was not found. Run npm run download-sing-box, install the RPM, or set a custom path."
                );
#endif
            }

            string socks_host;
            int socks_port;
            parse_endpoint (socks_endpoint, out socks_host, out socks_port);
            write_config (socks_host, socks_port, core_binary_name);
            clear_logs ();

            string lib_path = library_path (sing_box_path);
            validate_config (sing_box_path, lib_path);

            try {
                var launcher = new SubprocessLauncher (
                    SubprocessFlags.STDERR_PIPE | SubprocessFlags.STDOUT_PIPE
                );
                apply_library_path (launcher, lib_path);
                process = launcher.spawn (
                    sing_box_path,
                    "run",
                    "-c",
                    config_path ()
                );

                string? identifier = process.get_identifier ();
                if (identifier != null) {
                    FileUtils.set_contents (pid_path (), identifier);
                }

                DataInputStream stderr_stream = new DataInputStream (process.get_stderr_pipe ());
                DataInputStream stdout_stream = new DataInputStream (process.get_stdout_pipe ());
                read_stream.begin (stderr_stream);
                read_stream.begin (stdout_stream);

                // Instance-safe child watch: the callback captures THE
                // process it was created for. Without this, a force_stop()
                // + immediate respawn (watchdog restart, quick reconnect)
                // let the OLD watch fire after the NEW spawn and stomp the
                // fresh state via cleanup_process — the manager then believed
                // nothing was running while a healthy sing-box actually was.
                Subprocess watched = process;
                watched.wait_async.begin (null, (obj, res) => {
                    try {
                        watched.wait_async.end (res);
                    } catch (Error err) {
                        warning ("Could not wait for sing-box: %s", err.message);
                    }
                    if (process == watched) {
                        record_exit (watched);
                        cleanup_process (true);
                    }
                    // else: stale watch from a replaced instance — ignore.
                });

                running = true;
            } catch (Error err) {
                process = null;
                string detail = last_error.length > 0 ? last_error : err.message;
#if WINDOWS
                throw new IOError.FAILED (
                    "Failed to start sing-box: %s. On Windows, TUN mode requires running Forough as Administrator (wintun adapter creation) and wintun.dll next to sing-box.exe.".printf (
                        detail
                    )
                );
#else
                throw new IOError.FAILED (
                    "Failed to start sing-box: %s. TUN mode may require CAP_NET_ADMIN on the sing-box binary (the RPM post-install script tries to set this).".printf (
                        detail
                    )
                );
#endif
            }
        }

        public void stop () {
            if (process != null) {
                // Capture the instance: a stale 3s escalation timer must
                // never SIGKILL a freshly started replacement.
                Subprocess proc = process;
#if WINDOWS
                // On Windows there is no SIGTERM: TerminateProcess (via
                // force_exit) is the only reliable stop, and a hung sing-box
                // with auto_route keeps the TUN default route alive and kills
                // all connectivity after a disconnect.
                proc.force_exit ();
#else
                proc.send_signal (15);
                Timeout.add (3000, () => {
                    if (process == proc) {
                        proc.send_signal (9);
                    }
                    return Source.REMOVE;
                });
#endif
                return;
            }

            fallback_stop ();
        }

        // Synchronous best-effort cleanup used before starting a new instance.
        private void force_stop () {
            if (process != null) {
                process.send_signal (9);
                process = null;
            }
            running = false;
            remove_pid_file ();

            // Kill any orphaned sing-box from an earlier session (crash,
            // GUI force-quit) that would otherwise hold the TUN hostage.
#if WINDOWS
            // taskkill by exact image name — the engine ships with this name
            // in the bundle, so an orphaned instance is always ours.
            try {
                Process.spawn_command_line_sync ("taskkill /F /IM sing-box.exe");
            } catch (Error err) {
                warning ("Could not clean up leftover sing-box: %s", err.message);
            }
#else
            // NOTE: pkill -f matched the literal string "sing-box run
            // 2>/dev/null" (no shell here — the redirection was part of the
            // pattern) and NEVER matched anything. -x matches the exact
            // process name, which is how sing-box actually shows up.
            try {
                Process.spawn_command_line_sync ("pkill -9 -x sing-box");
            } catch (Error err) {
                warning ("Could not clean up leftover sing-box: %s", err.message);
            }
#endif
        }

        // Fingerprint how the process ended so the next diagnostics report
        // can distinguish "crashed with a fatal line" from "silently killed"
        // (SIGKILL → OOM/external) from "clean exit".
        private void record_exit (Subprocess proc) {
            bool signaled = proc.get_if_signaled ();
            int term_sig = signaled ? proc.get_term_sig () : 0;
            int code = proc.get_if_exited () ? proc.get_exit_status () : -1;
            bool expected = !running;   // cleanup already ran (stop() path)

            if (signaled) {
                last_exit_reason = "killed by signal %d".printf (term_sig);
                if (term_sig == 9) {
                    last_exit_reason += " (SIGKILL — OOM killer or external kill)";
                } else if (term_sig == 15) {
                    last_exit_reason += " (SIGTERM)";
                }
            } else if (code == 0) {
                last_exit_reason = "exited cleanly";
            } else {
                last_exit_reason = "exit code %d".printf (code);
            }

            if (!expected) {
                unexpected_exits += 1;
                string line = "sing-box %s%s".printf (
                    last_exit_reason,
                    last_error.length > 0 ? " — last error: %s".printf (last_error) : ""
                );
                append_log_line (line);
                diagnostic (line);
                if (last_error.length == 0) {
                    // Make sure a silent death is never invisible again.
                    last_error = line;
                }
            }
        }

        private void cleanup_process (bool notify_exit) {
            bool was_running = running;
            process = null;
            running = false;
            remove_pid_file ();

            if (notify_exit && was_running && last_error.length > 0) {
                diagnostic ("exited: %s".printf (last_error));
            }
        }

        private void append_log_line (string line) {
            log_buffer.append (line);
            log_buffer.append_c ('\n');

            // Cap the buffer: drop the oldest lines once over budget.
            string[] lines = log_buffer.str.split ("\n");
            if (lines.length > LOG_BUFFER_MAX_LINES) {
                var trimmed = new StringBuilder ();
                int start = lines.length - LOG_BUFFER_MAX_LINES;
                for (int i = start; i < lines.length; i++) {
                    trimmed.append (lines[i]);
                    trimmed.append_c ('\n');
                }
                log_buffer.assign (trimmed.str);
            }
        }

        private void fallback_stop () {
            try {
                if (FileUtils.test (pid_path (), FileTest.EXISTS)) {
                    string pid;
                    FileUtils.get_contents (pid_path (), out pid);
#if WINDOWS
                    Process.spawn_command_line_sync ("taskkill /F /PID %s".printf (pid.strip ()));
#else
                    Process.spawn_command_line_sync ("kill -TERM %s".printf (pid.strip ()));
#endif
                    remove_pid_file ();
                    running = false;
                    return;
                }

#if WINDOWS
                Process.spawn_command_line_sync ("taskkill /F /IM sing-box.exe");
#else
                Process.spawn_command_line_sync ("pkill -f 'sing-box run'");
#endif
                remove_pid_file ();
                running = false;
            } catch (Error err) {
                warning ("Could not stop sing-box: %s", err.message);
            }
        }

        private void remove_pid_file () {
            if (FileUtils.test (pid_path (), FileTest.EXISTS)) {
                FileUtils.remove (pid_path ());
            }
        }

        private void validate_config (string sing_box_path, string lib_path) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDERR_PIPE);
            apply_library_path (launcher, lib_path);

            try {
                Subprocess check = launcher.spawn (sing_box_path, "check", "-c", config_path ());
                string? stdout_output = null;
                string? stderr_output = null;
                check.communicate_utf8 (null, null, out stdout_output, out stderr_output);
                if (check.get_exit_status () != 0) {
                    string detail = stderr_output != null ? stderr_output.strip () : "";
                    if (detail.length == 0) {
                        detail = "sing-box rejected the generated TUN config";
                    }
                    last_error = detail;
                    diagnostic (detail);
                    throw new IOError.FAILED (detail);
                }
            } catch (Error err) {
                if (err is IOError.FAILED) {
                    throw err;
                }
                throw new IOError.FAILED ("Could not validate sing-box config: %s".printf (err.message));
            }
        }

        // Reads until EOF — NOT gated on `running`. The death-bed output of
        // a dying sing-box (fatal config/TUN errors) arrives at the exact
        // moment cleanup flips the flags; stopping on `running` used to
        // swallow precisely the lines that explain the death.
        private async void read_stream (DataInputStream stream) {
            try {
                while (true) {
                    size_t length = 0;
                    string? line = yield stream.read_line_async (Priority.DEFAULT, null, out length);
                    if (line == null) {
                        break;
                    }

                    string trimmed = line.strip ();
                    if (trimmed.length == 0) {
                        continue;
                    }

                    append_log_line (trimmed);
                    if (is_error_line (trimmed)) {
                        last_error = trimmed;
                    }
                    diagnostic (trimmed);
                }
            } catch (Error err) {
                warning ("Could not read sing-box output: %s", err.message);
            }
        }

        private void write_config (string socks_host, int socks_port, string core_binary_name) throws Error {
            config.ensure_config_dir ();

            // Common hardening (v1.3.1, kept in both modes):
            //
            //  - process_name rule keeps the tunnel alive: sing-box's
            //    auto_route default route captures EVERY process's packets,
            //    including psiphon-tunnel-core's own meek connections. Those
            //    then loop back into the local SOCKS proxy and the tunnel
            //    starves ("connects, then drops"). Exempting the backend is
            //    the desktop equivalent of VpnService.protect() on Android.
            //  - IPv6 ULA on the TUN makes auto_route capture ::/0 too. With
            //    an IPv4-only TUN, IPv6 networks sent DNS straight out over
            //    v6 into censored resolvers ("connected with a German IP but
            //    nothing opens").
            //  - UDP reject: the local SOCKS is CONNECT-only (goptlib), so
            //    non-DNS UDP (QUIC/HTTP3, NTP) can never traverse it — reject
            //    fast so browsers fall back to TCP/443 immediately.
            //  - sniff is UDP-only with a short timeout: TCP flows used to
            //    pay up to the sniff timeout on first connect for metadata
            //    they never need (there are no domain rules); DNS detection
            //    only needs UDP.
            //
            // Fast DNS via Fake-IP (v1.4.0, default on): A/AAAA queries are
            // answered INSTANTLY from an in-memory fake-IP pool; when the app
            // later connects to the fake IP, sing-box sends the DOMAIN through
            // the Psiphon SOCKS and the exit server resolves it. That removes
            // the TCP-DNS-to-8.8.8.8-through-the-tunnel round trip from every
            // new hostname — the same effective behavior Android gets from
            // tun2socks+udpgw (domains resolved at the exit). Non-A/AAAA
            // queries (and everything when Fake-IP is off) still ride TCP
            // through the tunnel: UDP detours can never work on goptlib.
            // dns-remote therefore rides a 4096-entry DNS cache (v1.4.1,
            // dns.cache_capacity at the resolver root — the placement sing-box
            // 1.14.3 validates): HTTPS/type-65 and other non-A/AAAA queries
            // browsers make for every page would otherwise pay a full meek
            // round trip EACH time, and in forward mode (Fake-IP off) every
            // A lookup too. prefer_ipv4 keeps forward mode from handing out
            // real AAAA records the IPv4-only goptlib CONNECT cannot
            // service; in Fake-IP mode the rule already routes A/AAAA to the
            // fake pool so it is a no-op there.
            // The fake-IP mapping store persists in cache_file so reconnects
            // keep already-resolved clients working.
            string core_name = core_binary_name.strip ();
            if (core_name.length == 0) {
                core_name = Constants.PSIPHON_BIN;
            }

            string json;
#if WINDOWS
            // Windows TUN variant. Differences from the Linux template:
            //  - NO manual device/route commands: sing-box's own auto_route +
            //    strict_route own the wintun adapter and the routing table
            //    (the GUI never touches `netsh`/`route`).
            //  - dns-local uses the `local` server type (the Windows system
            //    resolver) instead of systemd-resolved's 127.0.0.53 stub.
            //  - clash_api exposes an external controller so the GUI's live
            //    traffic graph can poll /traffic (same trick every clash-based
            //    Windows client uses); bound to loopback only.
            if (fakeip_enabled) {
                string cache_path = Path.build_filename (config.config_dir, "sing-box-cache.db");
                json = """
{
  "log": {
    "level": "info"
  },
  "dns": {
    "cache_capacity": 4096,
    "strategy": "prefer_ipv4",
    "servers": [
      {
        "tag": "dns-fake",
        "type": "fakeip",
        "inet4_range": "198.18.0.0/15",
        "inet6_range": "fc00::/18"
      },
      {
        "tag": "dns-remote",
        "type": "tcp",
        "server": "8.8.8.8",
        "detour": "psiphon"
      },
      {
        "tag": "dns-local",
        "type": "local"
      }
    ],
    "rules": [
      {
        "inbound": "tun-in",
        "query_type": ["A", "AAAA"],
        "server": "dns-fake"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "%s",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "psiphon",
      "server": "%s",
      "server_port": %d
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "tun-in",
        "network": "udp",
        "action": "sniff",
        "timeout": "300ms"
      },
      {
        "inbound": "tun-in",
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "inbound": "tun-in",
        "network": "udp",
        "action": "reject"
      },
      {
        "process_name": ["%s"],
        "action": "route",
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      }
    ],
    "final": "psiphon",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local"
  },
  "experimental": {
    "clash_api": {
      "external_controller": "%s"
    },
    "cache_file": {
      "enabled": true,
      "path": "%s",
      "store_fakeip": true
    }
  }
}
""".printf (
                    Constants.SING_BOX_TUN_INTERFACE, socks_host, socks_port,
                    core_name, Constants.CLASH_API_CONTROLLER, cache_path
                );
            } else {
                json = """
{
  "log": {
    "level": "info"
  },
  "dns": {
    "cache_capacity": 4096,
    "strategy": "prefer_ipv4",
    "servers": [
      {
        "tag": "dns-remote",
        "type": "tcp",
        "server": "8.8.8.8",
        "detour": "psiphon"
      },
      {
        "tag": "dns-local",
        "type": "local"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "%s",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "psiphon",
      "server": "%s",
      "server_port": %d
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "tun-in",
        "network": "udp",
        "action": "sniff",
        "timeout": "300ms"
      },
      {
        "inbound": "tun-in",
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "inbound": "tun-in",
        "network": "udp",
        "action": "reject"
      },
      {
        "process_name": ["%s"],
        "action": "route",
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      }
    ],
    "final": "psiphon",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local"
  },
  "experimental": {
    "clash_api": {
      "external_controller": "%s"
    }
  }
}
""".printf (Constants.SING_BOX_TUN_INTERFACE, socks_host, socks_port, core_name, Constants.CLASH_API_CONTROLLER);
            }
#else
            // Linux template: unchanged v1.5.1 behavior — dns-local rides the
            // systemd-resolved stub (127.0.0.53), no clash API needed since
            // the live traffic graph reads /sys/class/net counters directly.
            if (fakeip_enabled) {
                string cache_path = Path.build_filename (config.config_dir, "sing-box-cache.db");
                json = """
{
  "log": {
    "level": "info"
  },
  "dns": {
    "cache_capacity": 4096,
    "strategy": "prefer_ipv4",
    "servers": [
      {
        "tag": "dns-fake",
        "type": "fakeip",
        "inet4_range": "198.18.0.0/15",
        "inet6_range": "fc00::/18"
      },
      {
        "tag": "dns-remote",
        "type": "tcp",
        "server": "8.8.8.8",
        "detour": "psiphon"
      },
      {
        "tag": "dns-local",
        "type": "udp",
        "server": "127.0.0.53"
      }
    ],
    "rules": [
      {
        "inbound": "tun-in",
        "query_type": ["A", "AAAA"],
        "server": "dns-fake"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "%s",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "psiphon",
      "server": "%s",
      "server_port": %d
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "tun-in",
        "network": "udp",
        "action": "sniff",
        "timeout": "300ms"
      },
      {
        "inbound": "tun-in",
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "inbound": "tun-in",
        "network": "udp",
        "action": "reject"
      },
      {
        "process_name": ["%s"],
        "action": "route",
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      }
    ],
    "final": "psiphon",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "%s",
      "store_fakeip": true
    }
  }
}
""".printf (
                    Constants.SING_BOX_TUN_INTERFACE, socks_host, socks_port,
                    core_name, cache_path
                );
            } else {
                json = """
{
  "log": {
    "level": "info"
  },
  "dns": {
    "cache_capacity": 4096,
    "strategy": "prefer_ipv4",
    "servers": [
      {
        "tag": "dns-remote",
        "type": "tcp",
        "server": "8.8.8.8",
        "detour": "psiphon"
      },
      {
        "tag": "dns-local",
        "type": "udp",
        "server": "127.0.0.53"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "%s",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "psiphon",
      "server": "%s",
      "server_port": %d
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "tun-in",
        "network": "udp",
        "action": "sniff",
        "timeout": "300ms"
      },
      {
        "inbound": "tun-in",
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "inbound": "tun-in",
        "network": "udp",
        "action": "reject"
      },
      {
        "process_name": ["%s"],
        "action": "route",
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      }
    ],
    "final": "psiphon",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local"
  }
}
""".printf (Constants.SING_BOX_TUN_INTERFACE, socks_host, socks_port, core_name);
            }
#endif

            FileUtils.set_contents (config_path (), json);
        }

#if !WINDOWS
        private string library_path (string sing_box_path) {
            string sing_box_dir = Path.get_dirname (sing_box_path);
            string? existing_lib_path = Environment.get_variable ("LD_LIBRARY_PATH");
            if (existing_lib_path != null && existing_lib_path.length > 0) {
                return "%s:%s".printf (sing_box_dir, existing_lib_path);
            }
            return sing_box_dir;
        }

        private void apply_library_path (SubprocessLauncher launcher, string lib_path) {
            launcher.setenv ("LD_LIBRARY_PATH", lib_path, true);
        }
#else
        // Windows keeps the same call sites but has no shared-library search
        // path to juggle: wintun.dll sits next to sing-box.exe and is loaded
        // through the default DLL search order (application directory first).
        private string library_path (string sing_box_path) {
            return "";
        }

        private void apply_library_path (SubprocessLauncher launcher, string lib_path) {
        }
#endif

        private bool is_error_line (string line) {
            string lower = line.down ();
            return lower.contains ("fatal") ||
                lower.contains ("error") ||
                lower.contains ("legacy") ||
                lower.contains ("failed") ||
                lower.contains ("rejected");
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

        private string read_sing_box_path_setting () {
            SettingsSchemaSource? source = SettingsSchemaSource.get_default ();
            if (source == null) {
                return "";
            }

            SettingsSchema? schema = source.lookup (Constants.SETTINGS_SCHEMA_ID, true);
            if (schema == null) {
                return "";
            }

            var settings = new Settings (Constants.SETTINGS_SCHEMA_ID);
            return settings.get_string ("sing-box-path").strip ();
        }
    }
}
