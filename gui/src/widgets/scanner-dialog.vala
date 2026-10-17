namespace PsiphonCliGui {
    /**
     * Manual CDN IP scanner dialog (v1.5.0).
     *
     * Scans random samples of the CDN ranges the bundled tunnel-core knows
     * (Cloudflare / Fastly / Akamai / CloudFront / Bunny), lists alive edges
     * with measured TCP+TLS latency, and lets the user pick the edges that
     * are then dialed FIRST by the tunnel-core fronting scanner (which ranks
     * them further by real tunnel establishment time).
     *
     * Apply writes the selection into the existing CDN fronting IP
     * candidates setting (Android parity plumbing), so nothing new is added
     * to the tunnel config path. Export builds a shareable "skh-config"
     * JSON with the selected edges — the automatic config builder.
     */
    public class ScannerDialog : Adw.Dialog {
        public signal void ips_applied (TunnelOptions options);

        private SettingsService settings_service;
        private CloudflareService cf_service;
        private weak Gtk.Window? parent_window;

        private Adw.SwitchRow cloudflare_row;
        private Adw.SwitchRow fastly_row;
        private Adw.SwitchRow akamai_row;
        private Adw.SwitchRow cloudfront_row;
        private Adw.SwitchRow bunny_row;
        private Adw.SpinRow sample_row;
        private Adw.SpinRow concurrency_row;
        private Adw.EntryRow cidrs_row;
        private Adw.EntryRow snis_row;
        private Adw.EntryRow cf_token_row;
        private Adw.ActionRow cf_status_row;

        private Gtk.Button start_button;
        private Gtk.Button stop_button;
        private Gtk.ProgressBar progress_bar;
        private Gtk.Label stats_label;
        private Gtk.ListBox results_list;
        private Gtk.Button select_all_button;
        private Gtk.Button apply_button;
        private Gtk.Button export_button;
        private Gtk.Label selected_label;

        private CdnScanner? scanner = null;
        private uint alive_count_seen = 0;
        private uint selected_count = 0;
        private int64 scan_started_us = 0;
        private bool scan_running = false;

        public ScannerDialog (SettingsService settings_service, Gtk.Window? parent) {
            Object (title: I18n.t ("CDN IP Scanner"), content_width: 660, content_height: 780);

            this.settings_service = settings_service;
            this.parent_window = parent;
            cf_service = new CloudflareService ();
            cf_service.deploy_finished.connect (on_deploy_finished);
            cf_service.probe_finished.connect (on_probe_finished);

            var toast_overlay = new Adw.ToastOverlay ();
            set_child (toast_overlay);

            var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            toast_overlay.set_child (root);

            var header = new Adw.HeaderBar ();
            root.append (header);

            var scrolled = new Gtk.ScrolledWindow ();
            scrolled.vexpand = true;
            root.append (scrolled);

            var prefs = new Adw.PreferencesPage ();
            scrolled.set_child (prefs);

            // ----- Scope group -----
            var scope = new Adw.PreferencesGroup ();
            scope.title = I18n.t ("Scan scope");
            scope.description = I18n.t ("Random samples from the same CDN ranges the tunnel scanner knows");
            prefs.add (scope);

            cloudflare_row = new Adw.SwitchRow ();
            cloudflare_row.title = I18n.t ("Cloudflare");
            cloudflare_row.subtitle = I18n.t ("15 ranges — the main Psiphon CDN fronting network");
            scope.add (cloudflare_row);

            fastly_row = new Adw.SwitchRow ();
            fastly_row.title = I18n.t ("Fastly");
            fastly_row.subtitle = I18n.t ("19 ranges");
            scope.add (fastly_row);

            akamai_row = new Adw.SwitchRow ();
            akamai_row.title = I18n.t ("Akamai");
            akamai_row.subtitle = I18n.t ("Curated edges + Iranian fronting SNIs");
            scope.add (akamai_row);

            cloudfront_row = new Adw.SwitchRow ();
            cloudfront_row.title = I18n.t ("CloudFront");
            cloudfront_row.subtitle = I18n.t ("AWS edge prefixes");
            scope.add (cloudfront_row);

            bunny_row = new Adw.SwitchRow ();
            bunny_row.title = I18n.t ("Bunny CDN");
            bunny_row.subtitle = I18n.t ("Edge POPs used by the Android client");
            scope.add (bunny_row);

            var sample_adjustment = new Gtk.Adjustment (1024, 128, 16384, 128, 1024, 0);
            sample_row = new Adw.SpinRow (sample_adjustment, 1.0, 0);
            sample_row.title = I18n.t ("Sample size");
            sample_row.subtitle = I18n.t ("How many random IPs to probe");
            scope.add (sample_row);

            var conc_adjustment = new Gtk.Adjustment (96, 8, 256, 8, 32, 0);
            concurrency_row = new Adw.SpinRow (conc_adjustment, 1.0, 0);
            concurrency_row.title = I18n.t ("Concurrency");
            concurrency_row.subtitle = I18n.t ("Parallel probes — raise on fast connections");
            scope.add (concurrency_row);

            cidrs_row = new Adw.EntryRow ();
            cidrs_row.title = I18n.t ("Custom ranges (optional)");
            cidrs_row.tooltip_text = I18n.t ("IPv4 or CIDR, separated by space, comma, or semicolon");
            scope.add (cidrs_row);

            snis_row = new Adw.EntryRow ();
            snis_row.title = I18n.t ("Custom SNI (optional)");
            snis_row.tooltip_text = I18n.t ("Overrides the built-in fronting SNI names for this scan");
            scope.add (snis_row);

            // ----- Cloudflare helper group -----
            var cf_group = new Adw.PreferencesGroup ();
            cf_group.title = I18n.t ("Cloudflare helper (optional)");
            cf_group.description = I18n.t ("Token + one-click worker deploy (panel style). The helper reports your nearest Cloudflare data center — it probes edges, it does not carry the tunnel: Psiphon fronting domains are managed on Psiphon servers.");
            prefs.add (cf_group);

            cf_token_row = new Adw.EntryRow ();
            cf_token_row.title = I18n.t ("Cloudflare API token");
            cf_token_row.tooltip_text = I18n.t ("Token needs Account:Read + Workers Scripts:Edit. Stored locally, never sent anywhere but Cloudflare.");
            cf_group.add (cf_token_row);

            cf_status_row = new Adw.ActionRow ();
            cf_status_row.title = I18n.t ("Helper worker");
            cf_status_row.subtitle = I18n.t ("Not deployed yet");
            cf_group.add (cf_status_row);

            var deploy_button = new Gtk.Button ();
            deploy_button.label = I18n.t ("Verify & deploy");
            deploy_button.valign = Gtk.Align.CENTER;
            deploy_button.clicked.connect (on_deploy_clicked);
            cf_status_row.add_suffix (deploy_button);

            var probe_button = new Gtk.Button ();
            probe_button.label = I18n.t ("Probe");
            probe_button.valign = Gtk.Align.CENTER;
            probe_button.tooltip_text = I18n.t ("Measure latency and data-center through the helper");
            probe_button.clicked.connect (on_probe_clicked);
            cf_status_row.add_suffix (probe_button);

            // ----- Run / progress -----
            var run_group = new Adw.PreferencesGroup ();
            prefs.add (run_group);

            var run_row = new Adw.ActionRow ();
            run_row.title = I18n.t ("Scan");
            run_group.add (run_row);

            start_button = new Gtk.Button ();
            start_button.label = I18n.t ("Start scan");
            start_button.valign = Gtk.Align.CENTER;
            start_button.add_css_class ("suggested-action");
            start_button.clicked.connect (on_start);
            run_row.add_suffix (start_button);

            stop_button = new Gtk.Button ();
            stop_button.label = I18n.t ("Stop");
            stop_button.valign = Gtk.Align.CENTER;
            stop_button.sensitive = false;
            stop_button.clicked.connect (on_stop);
            run_row.add_suffix (stop_button);

            var progress_row = new Adw.ActionRow ();
            progress_row.title = I18n.t ("Progress");
            run_group.add (progress_row);

            progress_bar = new Gtk.ProgressBar ();
            progress_bar.valign = Gtk.Align.CENTER;
            progress_bar.width_request = 180;
            progress_row.add_suffix (progress_bar);

            stats_label = new Gtk.Label (I18n.t ("Idle"));
            stats_label.valign = Gtk.Align.CENTER;
            stats_label.add_css_class ("dim-label");
            progress_row.add_suffix (stats_label);

            // ----- Results group -----
            var results_group = new Adw.PreferencesGroup ();
            results_group.title = I18n.t ("Alive edges");
            results_group.description = I18n.t ("Checked edges are dialed first on the next connect (fastest measured tunnel wins)");
            prefs.add (results_group);

            results_list = new Gtk.ListBox ();
            results_list.selection_mode = Gtk.SelectionMode.NONE;
            results_list.add_css_class ("boxed-list");
            results_group.add (results_list);

            // ----- Bottom action bar -----
            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            bar.margin_top = 8;
            bar.margin_bottom = 12;
            bar.margin_start = 12;
            bar.margin_end = 12;
            bar.halign = Gtk.Align.FILL;
            root.append (bar);

            select_all_button = new Gtk.Button ();
            select_all_button.label = I18n.t ("Select all");
            select_all_button.tooltip_text = I18n.t ("Check every alive edge");
            select_all_button.clicked.connect (on_select_all);
            bar.append (select_all_button);

            export_button = new Gtk.Button ();
            export_button.label = I18n.t ("Export config");
            export_button.tooltip_text = I18n.t ("Save a shareable JSON with the selected edges");
            export_button.clicked.connect (on_export);
            bar.append (export_button);

            selected_label = new Gtk.Label ("");
            selected_label.valign = Gtk.Align.CENTER;
            selected_label.halign = Gtk.Align.START;
            selected_label.hexpand = true;
            bar.append (selected_label);

            apply_button = new Gtk.Button ();
            apply_button.label = I18n.t ("Use selected");
            apply_button.add_css_class ("suggested-action");
            apply_button.sensitive = false;
            apply_button.clicked.connect (on_apply);
            bar.append (apply_button);

            load_saved_state ();
            update_selected_label ();
        }

        public void open (Gtk.Window parent) {
            parent_window = parent;
            load_saved_state ();
            present (parent);
        }

        // ----- Settings preload -----

        private void load_saved_state () {
            try {
                var settings = new Settings (Constants.SETTINGS_SCHEMA_ID);
                cf_token_row.text = settings.get_string ("cf-token");
                string worker_url = settings.get_string ("cf-worker-url");
                if (worker_url.length > 0) {
                    cf_status_row.subtitle = worker_url;
                }
                string saved_ips = settings.get_string ("cdn-fronting-ip-list");
                if (saved_ips.length > 0) {
                    stats_label.label = I18n.t ("%d saved candidate(s) active").printf (
                        count_entries (saved_ips));
                }
            } catch (Error e) {
                // schema unavailable (fresh unpacked run) — defaults are fine
            }
        }

        private int count_entries (string raw) {
            int n = 0;
            foreach (string part in raw.split_set (" ,;\n")) {
                if (part.strip ().length > 0) {
                    n++;
                }
            }
            return n;
        }

        // ----- Cloudflare -----

        private void on_deploy_clicked () {
            string token = cf_token_row.text.strip ();
            if (token.length == 0 || cf_service.is_busy ()) {
                return;
            }
            cf_status_row.subtitle = I18n.t ("Verifying token and deploying…");
            cf_service.deploy_helper (token);
        }

        private void on_deploy_finished (bool ok, string worker_url, string message) {
            if (ok) {
                cf_status_row.subtitle = "%s — %s".printf (worker_url, message);
                try {
                    var settings = new Settings (Constants.SETTINGS_SCHEMA_ID);
                    settings.set_string ("cf-token", cf_token_row.text.strip ());
                    settings.set_string ("cf-worker-url", worker_url);
                } catch (Error e) {
                    // non-fatal
                }
                show_toast (message);
            } else {
                cf_status_row.subtitle = message;
                show_toast (message);
            }
        }

        private void on_probe_clicked () {
            string worker_url = "";
            try {
                worker_url = new Settings (Constants.SETTINGS_SCHEMA_ID).get_string ("cf-worker-url");
            } catch (Error e) {
                // ignore
            }
            if (worker_url.length == 0) {
                show_toast (I18n.t ("Deploy the helper worker first"));
                return;
            }
            cf_status_row.subtitle = I18n.t ("Probing…");
            cf_service.probe (worker_url);
        }

        private void on_probe_finished (bool ok, string colo, uint ms, string message) {
            if (ok) {
                cf_status_row.subtitle = "%s — colo %s, %u ms".printf (
                    worker_url_cached (), colo, ms);
            } else {
                cf_status_row.subtitle = message;
            }
        }

        private string worker_url_cached () {
            try {
                return new Settings (Constants.SETTINGS_SCHEMA_ID).get_string ("cf-worker-url");
            } catch (Error e) {
                return "";
            }
        }

        // ----- Scan control -----

        private void on_start () {
            if (scan_running) {
                return;
            }
            scanner = new CdnScanner ();
            scanner.scan_cloudflare = cloudflare_row.active;
            scanner.scan_fastly = fastly_row.active;
            scanner.scan_akamai = akamai_row.active;
            scanner.scan_cloudfront = cloudfront_row.active;
            scanner.scan_bunny = bunny_row.active;
            scanner.custom_cidrs = cidrs_row.text;
            scanner.custom_snis = snis_row.text;
            scanner.sample_count = (uint) sample_row.adjustment.value;
            scanner.concurrency = (uint) concurrency_row.adjustment.value;

            clear_results_rows ();
            result_rows = 0;
            selected_count = 0;
            update_selected_label ();
            progress_bar.fraction = 0.0;

            try {
                scanner.start ();
            } catch (Error e) {
                stats_label.label = e.message;
                show_toast (e.message);
                return;
            }

            scan_running = true;
            scan_started_us = GLib.get_monotonic_time ();
            start_button.sensitive = false;
            stop_button.sensitive = true;
            scanner.progress.connect (on_scan_progress);
            scanner.result_added.connect (on_scan_result);
            scanner.finished.connect (on_scan_finished);
        }

        private void on_stop () {
            if (!scan_running) {
                return;
            }
            if (scanner != null) {
                scanner.stop ();
            }
            // Return the dialog to a usable state IMMEDIATELY — the worker
            // threads wind down in the background. The old code waited for
            // the finished signal, which after a stop could take forever or
            // never arrive, leaving Start disabled ("scanner broken").
            scan_running = false;
            start_button.sensitive = true;
            stop_button.sensitive = false;
            stats_label.label = I18n.t ("Scan stopped");
            show_toast (I18n.t ("Scan stopped"));
        }

        private void on_scan_progress (uint scanned, uint total, uint alive) {
            if (!scan_running) {
                return;
            }
            progress_bar.fraction = total > 0 ? (double) scanned / (double) total : 0.0;
            double seconds = (GLib.get_monotonic_time () - scan_started_us) / 1000000.0;
            stats_label.label = "%u/%u — %s %u — %.0fs".printf (
                scanned, total, I18n.t ("alive"), alive, seconds);
        }

        // Rows are widgets — 16k of them would freeze the list. The fastest
        // results arrive first anyway (sorted at finish); beyond the cap the
        // scan keeps running and counting.
        private const int MAX_RESULT_ROWS = 300;
        private int result_rows = 0;

        private void on_scan_result (CdnScanResult result) {
            if (!scan_running) {
                return;
            }
            alive_count_seen += 1;

            bool is_alive = result.alive;
            bool checked = is_alive;
            if (checked) {
                // Auto-checked rows never fire "toggled", so the counter
                // must be incremented here — otherwise "Use selected" stayed
                // disabled with every checkbox visibly ticked (v1.5.0 bug).
                selected_count += 1;
            }

            if (result_rows >= MAX_RESULT_ROWS) {
                update_selected_label ();
                return;
            }
            result_rows += 1;

            var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
            row_box.margin_top = 6;
            row_box.margin_bottom = 6;
            row_box.margin_start = 12;
            row_box.margin_end = 12;

            var check = new Gtk.CheckButton ();
            check.active = checked;
            check.valign = Gtk.Align.CENTER;
            check.tooltip_text = is_alive
                ? I18n.t ("TCP + TLS handshake succeeded")
                : I18n.t ("TCP opened but the TLS handshake failed — not usable for fronting");
            check.toggled.connect (() => {
                selected_count += check.active ? 1 : -1;
                update_selected_label ();
            });
            check.set_data<uint> ("total_ms", result.total_ms ());
            check.set_data<string> ("ip", result.ip);
            row_box.append (check);

            var text_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            text_box.valign = Gtk.Align.CENTER;
            text_box.hexpand = true;

            var ip_label = new Gtk.Label (result.ip);
            ip_label.halign = Gtk.Align.START;
            ip_label.add_css_class ("monospace");
            text_box.append (ip_label);

            var badges = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            var tcp_label = new Gtk.Label ("TCP %ums".printf (result.tcp_ms));
            tcp_label.add_css_class ("dim-label");
            tcp_label.add_css_class ("caption");
            badges.append (tcp_label);
            if (!is_alive) {
                var fail_label = new Gtk.Label (I18n.t ("TLS failed"));
                fail_label.add_css_class ("caption");
                fail_label.add_css_class ("error");
                badges.append (fail_label);
            }
            var tls_label = new Gtk.Label ("TLS %ums".printf (result.tls_ms));
            tls_label.add_css_class ("dim-label");
            tls_label.add_css_class ("caption");
            badges.append (tls_label);
            var sni_label = new Gtk.Label (result.sni);
            sni_label.add_css_class ("dim-label");
            sni_label.add_css_class ("caption");
            sni_label.ellipsize = Pango.EllipsizeMode.END;
            sni_label.hexpand = true;
            sni_label.halign = Gtk.Align.START;
            badges.append (sni_label);
            text_box.append (badges);

            row_box.append (text_box);

            var row = new Gtk.ListBoxRow ();
            row.child = row_box;
            results_list.append (row);
            update_selected_label ();
        }

        private void on_scan_finished (uint alive, uint total) {
            if (!scan_running) {
                // A stop() already reset the dialog — this late emission is
                // a no-op (the scanner guarantees exactly-once, but stop's
                // safety-net emission can race a manual reset).
                return;
            }
            scan_running = false;
            start_button.sensitive = true;
            stop_button.sensitive = false;
            sort_results_by_speed ();
            update_selected_label ();
            show_toast (I18n.t ("Scan finished: %u alive of %u probed").printf (alive, total));
        }

        private void clear_results_rows () {
            Gtk.Widget? child = results_list.get_first_child ();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling ();
                results_list.remove (child);
                child = next;
            }
        }

        private void sort_results_by_speed () {
            // Rebuild the visible list fastest-first (insertion sort over the
            // row widgets; CompareFunc lambdas cannot capture `this`).
            var rows = new GLib.GenericArray<Gtk.Widget> ();
            Gtk.Widget? it = results_list.get_first_child ();
            while (it != null) {
                rows.add (it);
                it = it.get_next_sibling ();
            }
            for (int i = 1; i < (int) rows.length; i++) {
                Gtk.Widget key = rows[i];
                uint km = row_total_ms (key);
                int j = i - 1;
                while (j >= 0 && row_total_ms (rows[j]) > km) {
                    rows[j + 1] = rows[j];
                    j--;
                }
                rows[j + 1] = key;
            }
            clear_results_rows ();
            foreach (var widget in rows) {
                results_list.append (widget);
            }
        }

        private uint row_total_ms (Gtk.Widget row) {
            var box = ((Gtk.ListBoxRow) row).child as Gtk.Box;
            var check = box != null ? box.get_first_child () as Gtk.CheckButton : null;
            return check != null ? check.get_data<uint> ("total_ms") : uint.MAX;
        }

        private void on_select_all () {
            uint toggled = 0;
            var child = results_list.get_first_child ();
            while (child != null) {
                var row = child as Gtk.ListBoxRow;
                if (row != null && row.child is Gtk.Box) {
                    var box = (Gtk.Box) row.child;
                    var check = box.get_first_child () as Gtk.CheckButton;
                    if (check != null && !check.active) {
                        check.active = true;
                        toggled++;
                    }
                }
                child = child.get_next_sibling ();
            }
            if (toggled > 0) {
                selected_count += toggled;
                update_selected_label ();
            }
        }

        private void update_selected_label () {
            selected_label.label = I18n.t ("%u selected").printf (selected_count);
            apply_button.sensitive = selected_count > 0 && !scan_running;
        }

        // ----- Apply / export -----

        private string[] collect_selected_ips () {
            string[] ips = {};
            var child = results_list.get_first_child ();
            while (child != null) {
                var row = child as Gtk.ListBoxRow;
                if (row != null && row.child is Gtk.Box) {
                    var box = (Gtk.Box) row.child;
                    var check = box.get_first_child () as Gtk.CheckButton;
                    if (check != null && check.active) {
                        ips += check.get_data<string> ("ip");
                    }
                }
                child = child.get_next_sibling ();
            }
            return ips;
        }

        private void on_apply () {
            string[] ips = collect_selected_ips ();
            if (ips.length == 0) {
                return;
            }

            var options = settings_service.load_options ();
            options.cdn_fronting_ip_list = string.joinv (", ", ips);
            // When the user has no custom SNI yet, hand the tunnel scanner the
            // SNI pool the scan validated these IPs with — without it, the
            // user candidates would be dialed with SNI omitted and fail.
            if (options.cdn_fronting_sni.strip ().length == 0 && scanner != null) {
                string[] snis = scanner.current_sni_pool ();
                if (snis.length > 6) {
                    snis = snis[0:6];
                }
                options.cdn_fronting_sni = string.joinv (", ", snis);
            }
            settings_service.save_options (options);

            show_toast (I18n.t ("%u edges applied — reconnect to use them").printf (ips.length));
            ips_applied (options);
        }

        private void on_export () {
            string[] ips = collect_selected_ips ();
            if (ips.length == 0) {
                show_toast (I18n.t ("Select at least one edge to export"));
                return;
            }

            var config_obj = new Json.Object ();
            config_obj.set_string_member ("schema", "forough-cdn-config");
            config_obj.set_string_member ("version", 1.to_string ());
            config_obj.set_string_member ("generated_at",
                new GLib.DateTime.now_utc ().to_string ());
            var ip_array = new Json.Array ();
            foreach (string ip in ips) {
                ip_array.add_string_element (ip);
            }
            config_obj.set_array_member ("ip_candidates", ip_array);
            if (scanner != null) {
                var sni_array = new Json.Array ();
                foreach (string sni in scanner.current_sni_pool ()) {
                    sni_array.add_string_element (sni);
                }
                config_obj.set_array_member ("sni_names", sni_array);
            }
            try {
                var settings = new Settings (Constants.SETTINGS_SCHEMA_ID);
                string worker = settings.get_string ("cf-worker-url");
                if (worker.length > 0) {
                    config_obj.set_string_member ("cf_worker_url", worker);
                }
            } catch (Error e) {
                // optional member
            }

            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (config_obj);
            var gen = new Json.Generator ();
            gen.set_root (node);
            gen.pretty = true;
            string json = gen.to_data (null);

            var dialog = new Gtk.FileDialog ();
            dialog.initial_name = "forough-cdn-config.json";
            dialog.save.begin (parent_window, null, (self, res) => {
                try {
                    var file = dialog.save.end (res);
                    try {
                        FileUtils.set_contents (file.get_path (), json);
                        show_toast (I18n.t ("Config exported"));
                    } catch (Error e) {
                        show_toast (e.message);
                    }
                } catch (Error e) {
                    // user cancelled the file chooser
                }
            });
        }

        private void show_toast (string message) {
            var toast = new Adw.Toast (message);
            toast.timeout = 4;
            // The dialog root is a plain Box; toast via the window overlay.
            var win = parent_window;
            if (win is Adw.Window) {
                var overlay = find_toast_overlay (win);
                if (overlay != null) {
                    overlay.add_toast (toast);
                    return;
                }
            }
            stats_label.label = message;
        }

        private Adw.ToastOverlay? find_toast_overlay (Gtk.Widget widget) {
            Gtk.Widget? child = widget.get_first_child ();
            while (child != null) {
                if (child is Adw.ToastOverlay) {
                    return (Adw.ToastOverlay) child;
                }
                var found = find_toast_overlay (child);
                if (found != null) {
                    return found;
                }
                child = child.get_next_sibling ();
            }
            return null;
        }
    }
}
