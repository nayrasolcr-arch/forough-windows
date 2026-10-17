namespace PsiphonCliGui {
    /** One probed CDN edge: TCP connect + TLS handshake with a fronting SNI. */
    public class CdnScanResult : Object {
        public string ip;
        public string sni;
        public uint tcp_ms;
        public uint tls_ms;
        public bool alive;      // TCP + TLS both succeeded
        public bool tcp_only;   // TCP ok, TLS failed

        public uint total_ms () {
            return tcp_ms + tls_ms;
        }
    }

    /**
     * Manual CDN edge scanner (v1.5.0).
     *
     * Samples random IPv4 addresses from the same CDN ranges the bundled
     * tunnel-core uses for its built-in fronting scan (Cloudflare, Fastly,
     * Akamai, Bunny, CloudFront — snapshots embedded in
     * psiphon/frontedMeekCDNScanBuiltIn.go) and probes each sampled IP with
     * a TCP connect plus a TLS handshake that presents a fronting SNI name.
     *
     * This is the "responsiveness" pass. Selected IPs are written into the
     * existing CDN fronting IP-candidates setting; when the tunnel then
     * connects, the tunnel-core scanner dials those user candidates FIRST
     * and ranks them by measured real-tunnel establishment time (the fork's
     * quality ranking), so the final edge choice is made with real tunnel
     * data, not just the TLS probe.
     *
     * Threading model: N worker GLib.Threads pull targets from an atomic
     * index; results are marshaled back to the main loop with Idle.add.
     */
    public class CdnScanner : Object {
        public signal void progress (uint scanned, uint total, uint alive);
        public signal void result_added (CdnScanResult result);
        public signal void finished (uint alive, uint total);

        public bool scan_cloudflare { get; set; default = true; }
        public bool scan_fastly { get; set; default = false; }
        public bool scan_akamai { get; set; default = false; }
        public bool scan_bunny { get; set; default = false; }
        public bool scan_cloudfront { get; set; default = false; }
        public string custom_cidrs { get; set; default = ""; }
        public string custom_snis { get; set; default = ""; }
        public uint sample_count { get; set; default = 1024; }
        public uint concurrency { get; set; default = 96; }

        private GLib.Cancellable cancellable;
        private int next_index = 0;
        private uint scanned = 0;
        private uint alive_count = 0;
        private uint total_count = 0;
        private string[] targets;
        private string[] sni_pool;
        private Mutex state_mutex;
        // finished must reach the dialog EXACTLY once (several workers can
        // observe completion simultaneously), and MUST reach it even when a
        // stop() leaves every worker exiting at the loop top — otherwise the
        // dialog stays in "running" state forever and Start never comes
        // back (the v1.5.0 "scanner does not work" report).
        private bool finish_emitted = false;
        private bool active = false;

        public bool is_running {
            get { return active; }
        }

        // ----- Built-in scope data (snapshots from the tunnel-core fork's
        // frontedMeekCDNScanBuiltIn.go; kept in sync at release time). -----

        private const string[] CLOUDFLARE_RANGES = {
            "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
            "104.16.0.0/13", "104.24.0.0/14", "108.162.192.0/18",
            "131.0.72.0/22", "141.101.64.0/18", "162.158.0.0/15",
            "172.64.0.0/13", "173.245.48.0/20", "188.114.96.0/20",
            "190.93.240.0/20", "197.234.240.0/22", "198.41.128.0/17"
        };

        private const string[] FASTLY_RANGES = {
            "103.244.50.0/24", "103.245.222.0/23", "103.245.224.0/24",
            "104.156.80.0/20", "140.248.128.0/17", "140.248.64.0/18",
            "146.75.0.0/17", "151.101.0.0/16", "157.52.64.0/18",
            "167.82.0.0/17", "167.82.128.0/20", "167.82.160.0/20",
            "167.82.224.0/20", "172.111.64.0/18", "185.31.16.0/22",
            "199.232.0.0/16", "199.27.72.0/21", "23.235.32.0/20",
            "43.249.72.0/22"
        };

        private const string[] AKAMAI_RANGES = {
            // Curated Akamai edges from the fork (individual addresses).
            "2.16.19.136", "2.16.20.51", "2.16.53.11", "2.16.53.50",
            "2.16.53.57", "2.16.53.65", "2.16.221.37", "2.17.35.24",
            "23.12.147.13", "23.12.147.29", "23.73.207.8", "23.73.207.15",
            "23.212.250.78", "23.212.250.91", "23.215.0.203", "23.215.0.206",
            "92.123.102.43"
        };

        private const string[] CLOUDFRONT_RANGES = {
            // Largest CloudFront v4 prefixes (from the fork's AWS snapshot).
            "13.32.0.0/15", "13.33.0.0/16", "13.224.0.0/14", "13.249.0.0/16",
            "18.64.0.0/14", "18.154.0.0/15", "18.239.0.0/16", "18.244.0.0/15",
            "52.84.0.0/15", "52.222.128.0/17", "52.46.32.0/22",
            "71.152.0.0/17", "99.86.0.0/16", "108.138.0.0/15",
            "130.176.0.0/16", "143.204.0.0/16", "144.220.112.0/20",
            "205.251.208.0/20"
        };

        private const string[] BUNNY_NOTE = {
            // Bunny's list is 573 individual /24-ish entries; sampled from a
            // compact representative subset here (largest POP prefixes).
            "185.107.56.0/24", "185.107.57.0/24", "89.187.160.0/24",
            "89.187.161.0/24", "89.187.162.0/24", "89.187.163.0/24",
            "89.187.164.0/24", "89.187.165.0/24", "89.187.166.0/24",
            "89.187.167.0/24", "89.187.168.0/24", "89.187.169.0/24",
            "138.199.0.0/24", "138.199.1.0/24", "138.199.2.0/24",
            "138.199.3.0/24", "138.199.4.0/24", "138.199.5.0/24",
            "138.199.6.0/24", "138.199.7.0/24", "138.199.8.0/24",
            "138.199.9.0/24", "138.199.10.0/24", "138.199.11.0/24",
            "138.199.12.0/24", "138.199.13.0/24", "138.199.14.0/24",
            "138.199.15.0/24", "138.199.16.0/24", "138.199.17.0/24",
            "138.199.18.0/24", "138.199.19.0/24", "138.199.20.0/24",
            "138.199.21.0/24", "138.199.22.0/24", "138.199.23.0/24",
            "138.199.24.0/24", "138.199.25.0/24", "138.199.26.0/24",
            "138.199.27.0/24", "138.199.28.0/24", "138.199.29.0/24",
            "138.199.30.0/24", "138.199.31.0/24", "138.199.32.0/24",
            "138.199.33.0/24", "138.199.34.0/24", "138.199.35.0/24",
            "138.199.36.0/24", "138.199.37.0/24", "138.199.38.0/24",
            "138.199.39.0/24", "138.199.40.0/24", "138.199.41.0/24",
            "138.199.42.0/24", "138.199.43.0/24", "138.199.44.0/24",
            "138.199.45.0/24", "138.199.46.0/24", "138.199.47.0/24",
            "138.199.48.0/24", "138.199.49.0/24", "138.199.50.0/24"
        };

        private const string[] CLOUDFLARE_SNIS = {
            "cdnjs.cloudflare.com", "cloudflare.com", "www.cloudflare.com",
            "lickbash-nonal-nonink.psiphon3.net",
            "morer-actocumerl-reless.psiphon3.net",
            "serce-sourite-docurch.psiphon3.net"
        };

        private const string[] FASTLY_SNIS = {
            "actions.githubusercontent.com", "api.github.com",
            "github.com", "prod.global.ssl.fastly.net",
            "quic.map.fastly.net", "fastly.com", "www.fastly.com",
            "theguardian.com", "imgix.net", "nyt.com"
        };

        private const string[] AKAMAI_SNIS = {
            "a.akamaihd.net", "a.akamaized.net", "a248.e.akamai.net",
            "www.akamai.com", "aparat.com", "digikala.com", "snapp.ir",
            "telewebion.com", "varzesh3.com", "bmi.ir"
        };

        private const string[] CLOUDFRONT_SNIS = {
            "d1.awsstatic.com", "d2c02a9g55p4vc.cloudfront.net",
            "d36p7catgf5u26.cloudfront.net", "images-na.ssl-images-amazon.com",
            "dw2bjjbfmlfhy.cloudfront.net"
        };

        private const string[] BUNNY_SNIS = {
            "b-cdn.net", "megram-supg-instem.b-cdn.net",
            "pirtus-moding-hareware.b-cdn.net"
        };

        public CdnScanner () {
            state_mutex = new Mutex ();
        }

        /** Builds the target sample and starts the worker pool. */
        public void start () throws Error {
            if (total_count > 0 && scanned < total_count) {
                throw new GLib.Error (GLib.Quark.from_string ("skh-scanner"), 0,
                    I18n.t("A scan is already running"));
            }

            cancellable = new GLib.Cancellable ();
            next_index = 0;
            scanned = 0;
            alive_count = 0;
            total_count = 0;
            finish_emitted = false;
            active = true;

            string[] ranges = build_range_list ();
            string[] snis = build_sni_pool ();
            if (ranges.length == 0) {
                throw new GLib.Error (GLib.Quark.from_string ("skh-scanner"), 1,
                    I18n.t("No scan scope selected"));
            }
            if (snis.length == 0) {
                snis = CLOUDFLARE_SNIS;
            }
            sni_pool = snis;
            targets = sample_ranges (ranges, sample_count);
            total_count = targets.length;
            if (total_count == 0) {
                throw new GLib.Error (GLib.Quark.from_string ("skh-scanner"), 2,
                    I18n.t("No candidate IPs generated"));
            }

            uint workers = concurrency.clamp (8, 256);
            for (uint i = 0; i < workers; i++) {
                string name = "cdn-scan-%u".printf (i);
                try {
                    new GLib.Thread<void*> (name, worker_loop);
                } catch (Error e) {
                    // Thread pool partially started is still useful.
                    if (i == 0) {
                        throw e;
                    }
                    break;
                }
            }
        }

        public void stop () {
            if (cancellable != null) {
                cancellable.cancel ();
            }

            // Safety net: workers that exit at the loop top never schedule
            // the finished signal. Emit it here if nobody else did, so the
            // dialog always returns to a usable state.
            Timeout.add_seconds (3, () => {
                bool need = false;
                state_mutex.lock ();
                need = !finish_emitted;
                if (need) {
                    finish_emitted = true;
                }
                state_mutex.unlock ();

                if (need) {
                    uint a = alive_count;
                    uint t = total_count;
                    Idle.add (() => {
                        active = false;
                        finished (a, t);
                        return false;
                    });
                }
                return Source.REMOVE;
            });
        }

        /** The SNI pool actually used — applied to the IP-candidate setting. */
        public string[] current_sni_pool () {
            return sni_pool;
        }

        // ----- Worker plumbing -----

        private void* worker_loop () {
            while (true) {
                if (cancellable.is_cancelled ()) {
                    break;
                }
                int index = GLib.AtomicInt.add (ref next_index, 1) - 1;
                if (index < 0 || index >= targets.length) {
                    break;
                }

                string ip = targets[index];
                string sni = sni_pool[index % sni_pool.length];
                CdnScanResult result = probe (ip, sni);

                bool done = false;
                bool emit_finish = false;
                state_mutex.lock ();
                scanned += 1;
                if (result.alive) {
                    alive_count += 1;
                }
                uint s = scanned, a = alive_count;
                done = (s >= total_count) || cancellable.is_cancelled ();
                emit_finish = done && !finish_emitted;
                if (emit_finish) {
                    finish_emitted = true;
                }
                state_mutex.unlock ();

                Idle.add (() => {
                    if (result.alive || result.tcp_only) {
                        result_added (result);
                    }
                    progress (s, total_count, a);
                    if (emit_finish) {
                        active = false;
                        finished (a, total_count);
                    }
                    return false;
                });

                if (done) {
                    break;
                }
            }
            return null;
        }

        /** TCP connect + TLS handshake (SNI = sni), both with timeouts. */
        private CdnScanResult probe (string ip, string sni) {
            var result = new CdnScanResult ();
            result.ip = ip;
            result.sni = sni;
            result.alive = false;
            result.tcp_only = false;

            var client = new GLib.SocketClient ();
            client.timeout = 2;           // TCP connect timeout (s)
            client.enable_proxy = false;  // never ride a system proxy

            int64 t0 = GLib.get_monotonic_time ();
            GLib.InetSocketAddress addr;
            try {
                addr = (GLib.InetSocketAddress) new GLib.InetAddress.from_string (ip);
            } catch (Error e) {
                return result;
            }
            addr = new GLib.InetSocketAddress (addr.address, 443);

            GLib.SocketConnection tcp;
            try {
                tcp = client.connect (addr, cancellable);
            } catch (Error e) {
                return result; // TCP failed -> dead edge
            }
            result.tcp_ms = (uint) ((GLib.get_monotonic_time () - t0) / 1000);

            // TLS with fronting SNI: the server_identity hostname supplies the
            // SNI and the validation reference while the socket stays on the
            // dialed IP. A probe-local cancellable enforces the TLS timeout
            // without killing the shared scan cancellable.
            int64 t1 = GLib.get_monotonic_time ();
            var probe_cancel = new GLib.Cancellable ();
            var timeout_source = GLib.Timeout.add_seconds (3, () => {
                probe_cancel.cancel ();
                return false;
            });
            try {
                var identity = new GLib.NetworkAddress (sni, 443);
                var tls = GLib.TlsClientConnection.new (tcp, identity);
                if (tls == null) {
                    result.tcp_only = true;
                    return result;
                }
                tls.handshake (probe_cancel);
                result.alive = true;
            } catch (Error e) {
                result.tcp_only = true;
            } finally {
                GLib.Source.remove (timeout_source);
            }
            result.tls_ms = (uint) ((GLib.get_monotonic_time () - t1) / 1000);

            try {
                tcp.close ();
            } catch (Error e) {
                // ignore close errors
            }
            return result;
        }

        // ----- Range / SNI construction -----

        private string[] build_range_list () {
            string[] ranges = {};
            if (scan_cloudflare) {
                ranges = append_all (ranges, CLOUDFLARE_RANGES);
            }
            if (scan_fastly) {
                ranges = append_all (ranges, FASTLY_RANGES);
            }
            if (scan_akamai) {
                ranges = append_all (ranges, AKAMAI_RANGES);
            }
            if (scan_cloudfront) {
                ranges = append_all (ranges, CLOUDFRONT_RANGES);
            }
            if (scan_bunny) {
                ranges = append_all (ranges, BUNNY_NOTE);
            }
            foreach (string cidr in split_entries (custom_cidrs)) {
                ranges += cidr;
            }
            return ranges;
        }

        private string[] build_sni_pool () {
            string[] snis = {};
            foreach (string sni in split_entries (custom_snis)) {
                snis += sni;
            }
            if (snis.length > 0) {
                return snis;
            }
            if (scan_cloudfront) {
                snis = append_all (snis, CLOUDFRONT_SNIS);
            }
            if (scan_akamai) {
                snis = append_all (snis, AKAMAI_SNIS);
            }
            if (scan_fastly) {
                snis = append_all (snis, FASTLY_SNIS);
            }
            if (scan_bunny) {
                snis = append_all (snis, BUNNY_SNIS);
            }
            snis = append_all (snis, CLOUDFLARE_SNIS);
            return snis;
        }

        private string[] append_all (string[] a, string[] b) {
            string[] merged = new string[a.length + b.length];
            int k = 0;
            for (int i = 0; i < a.length; i++) {
                merged[k++] = a[i];
            }
            for (int i = 0; i < b.length; i++) {
                merged[k++] = b[i];
            }
            return merged;
        }

        private string[] split_entries (string raw) {
            string[] out_items = {};
            if (raw == null || raw.strip ().length == 0) {
                return out_items;
            }
            foreach (string part in raw.split_set (" ,;\n")) {
                string p = part.strip ();
                if (p.length > 0) {
                    out_items += p;
                }
            }
            return out_items;
        }

        // Weighted random sampling: each range contributes addresses
        // proportionally to its size, capped so huge prefixes cannot starve
        // small ones (per-range share = sample_count / ranges.length, at
        // least 1, at most the range size).
        private string[] sample_ranges (string[] ranges, uint n) {
            string[] pool = {};
            uint share = uint.max (1, n / (ranges.length > 0 ? ranges.length : 1));
            foreach (string spec in ranges) {
                uint32 first = 0, last = 0;
                if (!cidr_bounds (spec, out first, out last)) {
                    continue;
                }
                uint64 size = (uint64) last - first + 1;
                uint take = (uint) uint64.min (size, share);
                for (uint i = 0; i < take; i++) {
                    uint32 offset = 0;
                    if (size > 1) {
                        offset = (uint32) GLib.Random.int_range (0,
                            (int32) int64.min ((int64) size - 1, 2147483647));
                    }
                    uint32 ip = first + offset;
                    pool += "%u.%u.%u.%u".printf (
                        (ip >> 24) & 0xff, (ip >> 16) & 0xff,
                        (ip >> 8) & 0xff, ip & 0xff);
                }
            }
            return shuffle (pool);
        }

        private bool cidr_bounds (string spec, out uint32 first, out uint32 last) {
            first = 0;
            last = 0;
            string[] parts = spec.split ("/");
            if (parts.length == 1) {
                uint32 ip;
                if (!parse_ipv4 (parts[0].strip (), out ip)) {
                    return false;
                }
                first = ip;
                last = ip;
                return true;
            }
            if (parts.length != 2) {
                return false;
            }
            uint32 ip = 0, plen = 0;
            if (!parse_ipv4 (parts[0].strip (), out ip) ||
                !parse_uint (parts[1].strip (), out plen) || plen > 32) {
                return false;
            }
            if (plen == 0) {
                first = 0;
                last = (uint32) 0xffffffffL;
                return true;
            }
            uint32 mask = (uint32) (0xffffffffL << (32 - plen));
            uint32 net = (uint32) (ip & mask);
            first = net;
            last = (uint32) (net | (~mask));
            // Never probe the network/broadcast edge constants for /31+/32s
            // this is fine; for larger ranges the random sample rarely hits
            // them anyway.
            return first <= last;
        }

        private bool parse_ipv4 (string raw, out uint32 ip) {
            ip = 0;
            string[] octets = raw.split (".");
            if (octets.length != 4) {
                return false;
            }
            uint32 value = 0;
            foreach (string o in octets) {
                uint32 oct;
                if (!parse_uint (o, out oct) || oct > 255) {
                    return false;
                }
                value = (value << 8) | oct;
            }
            ip = value;
            return true;
        }

        private bool parse_uint (string raw, out uint32 value) {
            value = 0;
            if (raw.length == 0 || raw.length > 10) {
                return false;
            }
            foreach (uint8 c in raw.data) {
                if (c < '0' || c > '9') {
                    return false;
                }
                value = value * 10 + (c - '0');
            }
            return true;
        }

        private string[] shuffle (string[] input) {
            for (int i = (int) input.length - 1; i > 0; i--) {
                int j = GLib.Random.int_range (0, i + 1);
                string tmp = input[i];
                input[i] = input[j];
                input[j] = tmp;
            }
            return input;
        }
    }
}
