namespace PsiphonCliGui {
    public class MainWindow : Adw.ApplicationWindow {
        private ConfigService config;
        private ConnectionPanel connection_panel;
        private StatsPanel stats_panel;
        private Adw.ToastOverlay toast_overlay;
        private TunnelManager tunnel_manager;
        private SettingsService settings_service;
        private LogService log_service;
        private ServerListService server_list_service;
        private SettingsDialog? settings_dialog = null;
        private ScannerDialog? scanner_dialog = null;
        private LogsWindow? logs_window = null;
        private LogsWindow? sing_box_logs_window = null;
        private Gtk.Button psiphon_logs_button;
        private Gtk.Button sing_box_logs_button;
        private Gtk.Button diagnostics_button;
        private Gtk.Button scanner_button;
        private Gtk.Button speed_test_button;
        private TunnelOptions current_options;

        public MainWindow (Adw.Application app) {
            Object (application: app, title: I18n.t ("Forough"));
            set_default_size (720, 640);

            config = new ConfigService ();
            settings_service = new SettingsService ();
            log_service = new LogService (config);
            var stats_service = new StatsService (config);
            server_list_service = new ServerListService (config);
            var ip_service = new IpService ();
            tunnel_manager = new TunnelManager (config, stats_service, log_service, ip_service);

            current_options = settings_service.load_options ();
            config.apply_config_dir (current_options.config_dir);

            try {
                config.ensure_seed_files ();
            } catch (Error err) {
                warning ("Could not initialize config directory: %s", err.message);
            }

            string resolved_core = config.resolve_core_path (current_options.core_path);
            if (resolved_core.length > 0 && resolved_core != current_options.core_path.strip ()) {
                current_options.core_path = resolved_core;
                settings_service.save_options (current_options);
            }

            var sing_box_manager = new SingBoxManager (config);
            string resolved_sing_box = sing_box_manager.resolve_path (current_options.sing_box_path);
            if (resolved_sing_box.length > 0 && resolved_sing_box != current_options.sing_box_path.strip ()) {
                current_options.sing_box_path = resolved_sing_box;
                settings_service.save_options (current_options);
            }

            toast_overlay = new Adw.ToastOverlay ();
            set_content (toast_overlay);

            var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            toast_overlay.set_child (root);

            var header = new Adw.HeaderBar ();

            psiphon_logs_button = new Gtk.Button.from_icon_name ("text-x-generic-symbolic");
            psiphon_logs_button.tooltip_text = I18n.t ("Psiphon core logs");
            psiphon_logs_button.clicked.connect (() => open_psiphon_logs ());
            header.pack_end (psiphon_logs_button);

            sing_box_logs_button = new Gtk.Button.from_icon_name ("network-wired-symbolic");
            sing_box_logs_button.tooltip_text = I18n.t ("sing-box logs");
            sing_box_logs_button.clicked.connect (() => open_sing_box_logs ());
            header.pack_end (sing_box_logs_button);

            diagnostics_button = new Gtk.Button.from_icon_name ("dialog-information-symbolic");
            diagnostics_button.tooltip_text = I18n.t (
                "Copy diagnostics report to clipboard (share it when reporting connection problems)"
            );
            diagnostics_button.clicked.connect (copy_diagnostics);
            header.pack_end (diagnostics_button);

            var about_button = new Gtk.Button.from_icon_name ("help-about-symbolic");
            about_button.tooltip_text = I18n.t ("About");
            about_button.clicked.connect (open_about);
            header.pack_end (about_button);

            scanner_button = new Gtk.Button.from_icon_name ("edit-find-symbolic");
            scanner_button.tooltip_text = I18n.t ("Scan CDN edges and pick the fastest (manual IP scanner)");
            scanner_button.clicked.connect (open_scanner);
            header.pack_end (scanner_button);

            speed_test_button = new Gtk.Button.from_icon_name ("network-transmit-receive-symbolic");
            speed_test_button.tooltip_text = I18n.t ("Run speed test now (result goes to logs and diagnostics)");
            speed_test_button.clicked.connect (on_speed_test);
            header.pack_end (speed_test_button);

            var settings_button = new Gtk.Button.from_icon_name ("preferences-system-symbolic");
            settings_button.tooltip_text = I18n.t ("Connection settings");
            settings_button.clicked.connect (open_settings);
            header.pack_end (settings_button);
            root.append (header);

            var scrolled = new Gtk.ScrolledWindow ();
            scrolled.vexpand = true;
            root.append (scrolled);

            var clamp = new Adw.Clamp ();
            clamp.maximum_size = 640;
            clamp.tightening_threshold = 480;
            clamp.margin_top = 18;
            clamp.margin_bottom = 18;
            clamp.margin_start = 18;
            clamp.margin_end = 18;
            scrolled.set_child (clamp);

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
            clamp.set_child (content);

            var intro = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            content.append (intro);

            var icon = new Gtk.Image.from_icon_name ("network-vpn-symbolic");
            icon.pixel_size = 36;
            icon.valign = Gtk.Align.CENTER;
            intro.append (icon);

            var intro_text = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            intro_text.valign = Gtk.Align.CENTER;
            intro_text.hexpand = true;
            intro.append (intro_text);

            var title = new Gtk.Label (I18n.t ("Forough"));
            title.add_css_class ("title-2");
            title.halign = Gtk.Align.START;
            intro_text.append (title);

            var subtitle = new Gtk.Label (I18n.t ("Connect, view stats, and inspect tunnel logs."));
            subtitle.add_css_class ("dim-label");
            subtitle.halign = Gtk.Align.START;
            subtitle.wrap = true;
            intro_text.append (subtitle);

            connection_panel = new ConnectionPanel ();
            stats_panel = new StatsPanel ();
            content.append (connection_panel);
            content.append (stats_panel);

            connection_panel.connect_requested.connect (() => {
                tunnel_manager.start_tunnel (current_options);
            });
            connection_panel.disconnect_requested.connect (() => {
                tunnel_manager.stop_tunnel ();
            });

            tunnel_manager.running_changed.connect ((running) => {
                connection_panel.set_running (running);
                if (!running) {
                    stats_panel.show_disconnected ();
                }
            });

            tunnel_manager.stats_changed.connect ((stats) => {
                stats_panel.update_stats (stats);
                connection_panel.update_status (stats);
            });

            tunnel_manager.error.connect ((message) => {
                toast_overlay.add_toast (new Adw.Toast (message));
            });

            tunnel_manager.sing_box_error_changed.connect ((message) => {
                update_sing_box_button (message);
            });

            log_service.line_appended.connect ((line) => {
                if (logs_window != null) {
                    logs_window.append_line (line);
                }
            });

            tunnel_manager.log_line.connect ((line) => {
                if (line.has_prefix ("[sing-box]") && sing_box_logs_window != null) {
                    sing_box_logs_window.append_line (line.substring (11).strip ());
                }
            });

            update_sing_box_button (tunnel_manager.sing_box_last_error ());
        }

        private void update_sing_box_button (string message) {
            string trimmed = message.strip ();
            if (trimmed.length > 0) {
                sing_box_logs_button.add_css_class ("destructive-action");
                sing_box_logs_button.tooltip_text = I18n.t ("sing-box error: %s").printf (trimmed);
                sing_box_logs_button.set_icon_name ("dialog-warning-symbolic");
                return;
            }

            sing_box_logs_button.remove_css_class ("destructive-action");
            sing_box_logs_button.set_icon_name ("network-wired-symbolic");
            sing_box_logs_button.tooltip_text = I18n.t ("sing-box logs");
        }

        private void copy_diagnostics () {
            // Same report that is auto-written when a delivery check fails:
            // versions, resolved binaries, file caps, TUN/route state, proxy
            // settings and log tails — everything needed to debug remotely.
            string report = tunnel_manager.build_diagnostics_report ("manual-copy");
            tunnel_manager.write_diagnostics ("manual-copy");

            var clipboard = Gdk.Display.get_default ().get_clipboard ();
            clipboard.set_text (report);

            var toast = new Adw.Toast (
                I18n.t ("Diagnostics copied to clipboard — also saved to %s").printf (
                    tunnel_manager.diagnostics_path
                )
            );
            toast.timeout = 6;
            toast_overlay.add_toast (toast);
        }

        private void open_about () {
            AboutDialogHelper.present (this);
        }

        private void open_settings () {
            if (settings_dialog == null) {
                settings_dialog = new SettingsDialog (settings_service, server_list_service);
                settings_dialog.settings_saved.connect ((options) => {
                    current_options = options;
                    config.apply_config_dir (options.config_dir);
                });
            }

            settings_dialog.open (this);
        }

        private void open_scanner () {
            if (scanner_dialog == null) {
                scanner_dialog = new ScannerDialog (settings_service, this);
                scanner_dialog.ips_applied.connect ((options) => {
                    current_options = options;
                    show_toast (I18n.t ("CDN edges updated"));
                });
            }

            scanner_dialog.open (this);
        }

        private void on_speed_test () {
            tunnel_manager.run_speed_test_now ();
            show_toast (I18n.t ("Speed test running — numbers land in the log and diagnostics"));
        }

        private void show_toast (string message) {
            var toast = new Adw.Toast (message);
            toast.timeout = 5;
            toast_overlay.add_toast (toast);
        }

        private void open_psiphon_logs () {
            if (logs_window == null) {
                logs_window = new LogsWindow (this, I18n.t ("Psiphon core logs"));
            }

            logs_window.set_text (log_service.get_text ());
            logs_window.present ();
        }

        private void open_sing_box_logs () {
            if (sing_box_logs_window == null) {
                sing_box_logs_window = new LogsWindow (this, I18n.t ("sing-box logs"));
            }

            string text = tunnel_manager.sing_box_log_text ().strip ();
            if (text.length == 0) {
                string last_error = tunnel_manager.sing_box_last_error ().strip ();
                if (last_error.length > 0) {
                    text = last_error;
                } else {
                    text = I18n.t ("No sing-box output yet. Enable TUN routing and connect to populate this log.");
                }
            }

            sing_box_logs_window.set_text (text);
            sing_box_logs_window.present ();
        }
    }
}
