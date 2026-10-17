namespace PsiphonCliGui {
    public class ConnectionPanel : Gtk.Box {
        public signal void connect_requested ();
        public signal void disconnect_requested ();

        private Gtk.Button connect_button;
        private Gtk.Label status_label;
        private Gtk.Label ip_label;
        private Gtk.Label routing_label;
        private Gtk.Label traffic_label;
        private Gtk.DrawingArea traffic_graph;
        private double[] rx_history;
        private double[] tx_history;
#if !WINDOWS
        private uint64 last_rx_bytes = 0;
        private uint64 last_tx_bytes = 0;
        private bool have_last_bytes = false;
#endif
        private uint traffic_timer_id = 0;
        private bool running = false;

        private const int TRAFFIC_WINDOW = 60;

        public ConnectionPanel () {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 12);
            halign = Gtk.Align.CENTER;
            margin_top = 12;
            margin_bottom = 12;

            var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 18);
            actions.halign = Gtk.Align.CENTER;
            append (actions);

            connect_button = new Gtk.Button ();
            connect_button.add_css_class ("circular");
            connect_button.add_css_class ("suggested-action");
            connect_button.set_icon_name ("network-vpn-symbolic");
            connect_button.tooltip_text = I18n.t ("Connect");
            connect_button.width_request = 96;
            connect_button.height_request = 96;
            connect_button.clicked.connect (() => {
                if (running) {
                    disconnect_requested ();
                } else {
                    connect_requested ();
                }
            });
            actions.append (connect_button);

            status_label = new Gtk.Label (I18n.t ("Ready to connect"));
            status_label.add_css_class ("title-4");
            status_label.halign = Gtk.Align.CENTER;
            append (status_label);

            ip_label = new Gtk.Label ("");
            ip_label.add_css_class ("dim-label");
            ip_label.halign = Gtk.Align.CENTER;
            ip_label.selectable = true;
            append (ip_label);

            routing_label = new Gtk.Label ("");
            routing_label.add_css_class ("caption");
            routing_label.add_css_class ("dim-label");
            routing_label.halign = Gtk.Align.CENTER;
            append (routing_label);

            // Live traffic graph (v1.5.0): samples the TUN interface counters
            // once per second and draws the last 60 seconds as two filled
            // sparklines (download + upload).
            rx_history = new double[TRAFFIC_WINDOW];
            tx_history = new double[TRAFFIC_WINDOW];
            for (int i = 0; i < TRAFFIC_WINDOW; i++) {
                rx_history[i] = 0.0;
                tx_history[i] = 0.0;
            }

            traffic_label = new Gtk.Label ("");
            traffic_label.add_css_class ("caption");
            traffic_label.add_css_class ("dim-label");
            traffic_label.halign = Gtk.Align.CENTER;
            append (traffic_label);

            traffic_graph = new Gtk.DrawingArea ();
            traffic_graph.set_content_height (72);
            traffic_graph.set_content_width (360);
            traffic_graph.halign = Gtk.Align.CENTER;
            traffic_graph.set_draw_func (on_graph_draw);
            append (traffic_graph);
        }

        // ----- Traffic sampling -----

        private void start_traffic_sampling () {
            if (traffic_timer_id != 0) {
                return;
            }
#if !WINDOWS
            have_last_bytes = false;
#endif
            for (int i = 0; i < TRAFFIC_WINDOW; i++) {
                rx_history[i] = 0.0;
                tx_history[i] = 0.0;
            }
            traffic_timer_id = GLib.Timeout.add_seconds (1, () => {
                sample_traffic ();
                return Source.CONTINUE;
            });
        }

        private void stop_traffic_sampling () {
            if (traffic_timer_id != 0) {
                Source.remove (traffic_timer_id);
                traffic_timer_id = 0;
            }
            traffic_label.label = "";
            traffic_graph.queue_draw ();
        }

        private void sample_traffic () {
#if WINDOWS
            // The Windows sing-box config exposes a loopback-only clash API;
            // its /traffic endpoint streams one {"up":N,"down":M} JSON line
            // per second (bytes per second). curl is cut by --max-time after
            // the first line — a timeout exit with partial output is still a
            // real measurement (same policy as the performance probe).
            double down = 0, up = 0;
            if (!read_clash_traffic (out down, out up)) {
                traffic_graph.queue_draw ();
                return;
            }

            push_sample (rx_history, down);
            push_sample (tx_history, up);
            traffic_label.label = "%s %s/s   %s %s/s".printf (
                I18n.t ("↓"), Format.bytes_per_sec ((int64) down),
                I18n.t ("↑"), Format.bytes_per_sec ((int64) up));
            traffic_graph.queue_draw ();
#else
            uint64 rx = 0, tx = 0;
            if (!read_tun_counters (out rx, out tx)) {
                traffic_graph.queue_draw ();
                return;
            }

            if (have_last_bytes) {
                double down = rx >= last_rx_bytes ? (rx - last_rx_bytes) : 0.0;
                double up = tx >= last_tx_bytes ? (tx - last_tx_bytes) : 0.0;
                push_sample (rx_history, down);
                push_sample (tx_history, up);
                traffic_label.label = "%s %s/s   %s %s/s".printf (
                    I18n.t ("↓"), Format.bytes_per_sec ((int64) down),
                    I18n.t ("↑"), Format.bytes_per_sec ((int64) up));
            }
            last_rx_bytes = rx;
            last_tx_bytes = tx;
            have_last_bytes = true;
            traffic_graph.queue_draw ();
#endif
        }

        private void push_sample (double[] history, double value) {
            for (int i = 0; i < history.length - 1; i++) {
                history[i] = history[i + 1];
            }
            history[history.length - 1] = value;
        }

#if WINDOWS
        private bool read_clash_traffic (out double down, out double up) {
            down = 0;
            up = 0;

            string? stdout_buf = null;
            try {
                Process.spawn_command_line_sync (
                    "curl -s -N --noproxy '*' --max-time 2 http://%s/traffic".printf (
                        Constants.CLASH_API_CONTROLLER
                    ),
                    out stdout_buf, null, null
                );
            } catch (Error e) {
                return false;
            }

            if (stdout_buf == null) {
                return false;
            }

            string trimmed = stdout_buf.strip ();
            if (trimmed.length == 0) {
                return false;
            }

            // Keep the last complete JSON line (the stream may have delivered
            // more than one sample within the 2s window).
            string[] lines = trimmed.split ("\n");
            string line = lines[lines.length - 1].strip ();
            if (line.length == 0 && lines.length > 1) {
                line = lines[lines.length - 2].strip ();
            }

            try {
                var parser = new Json.Parser ();
                parser.load_from_data (line, line.length);
                Json.Object root = parser.get_root ().get_object ();
                down = root.get_double_member ("down");
                up = root.get_double_member ("up");
                return true;
            } catch (Error e) {
                return false;
            }
        }
#endif

#if !WINDOWS
        private bool read_tun_counters (out uint64 rx, out uint64 tx) {
            rx = 0;
            tx = 0;
            string base_path = "/sys/class/net/%s/statistics".printf (
                Constants.SING_BOX_TUN_INTERFACE);
            string rx_text, tx_text;
            try {
                FileUtils.get_contents (base_path + "/rx_bytes", out rx_text);
                FileUtils.get_contents (base_path + "/tx_bytes", out tx_text);
            } catch (Error e) {
                return false;
            }
            rx = uint64.parse (rx_text.strip ());
            tx = uint64.parse (tx_text.strip ());
            return true;
        }
#endif

        private void on_graph_draw (Gtk.DrawingArea area, Cairo.Context ctx,
            int width, int height) {
            // background
            ctx.set_source_rgba (0.5, 0.5, 0.5, 0.12);
            ctx.rectangle (0, 0, width, height);
            ctx.fill ();

            draw_series (ctx, width, height, rx_history, 0.20, 0.55, 0.95);
            draw_series (ctx, width, height, tx_history, 0.15, 0.75, 0.35);
        }

        private void draw_series (Cairo.Context ctx, int width, int height,
            double[] history, double r, double g, double b) {
            double max = 1.0;
            foreach (double v in history) {
                if (v > max) {
                    max = v;
                }
            }

            double step = (double) width / (history.length - 1);
            ctx.move_to (0, height);
            for (int i = 0; i < history.length; i++) {
                double y = height - (history[i] / max) * (height - 4) - 2;
                ctx.line_to (i * step, y);
            }
            ctx.line_to (width, height);
            ctx.close_path ();
            ctx.set_source_rgba (r, g, b, 0.35);
            ctx.fill_preserve ();
            ctx.set_source_rgba (r, g, b, 0.95);
            ctx.set_line_width (1.5);
            ctx.stroke ();
        }

        public void set_running (bool running) {
            this.running = running;

            if (running) {
                connect_button.remove_css_class ("suggested-action");
                connect_button.add_css_class ("destructive-action");
                connect_button.set_icon_name ("network-offline-symbolic");
                connect_button.tooltip_text = I18n.t ("Disconnect");
                status_label.label = I18n.t ("Connecting...");
                ip_label.label = "";
                start_traffic_sampling ();
            } else {
                connect_button.remove_css_class ("destructive-action");
                connect_button.add_css_class ("suggested-action");
                connect_button.set_icon_name ("network-vpn-symbolic");
                connect_button.tooltip_text = I18n.t ("Connect");
                status_label.label = I18n.t ("Ready to connect");
                ip_label.label = "";
                routing_label.label = "";
                stop_traffic_sampling ();
            }
        }

        public void update_status (TunnelStats stats) {
            if (!running) {
                return;
            }

            if (stats.status == "connected") {
                double seconds = stats.connect_duration_ms / 1000.0;
                status_label.label = I18n.t ("Connected in %.1fs").printf (seconds);

                string flag = RegionFlags.flag_for_code (stats.egress_region);
                if (stats.public_ip != "-" && stats.public_ip.length > 0) {
                    ip_label.label = "%s %s".printf (flag, stats.public_ip);
                } else if (flag.length > 0) {
                    ip_label.label = "%s %s".printf (flag, stats.egress_region);
                } else {
                    ip_label.label = stats.egress_region;
                }
            } else if (stats.status == "connecting") {
                status_label.label = I18n.t ("Connecting...");
                ip_label.label = "";
                routing_label.label = "";
            } else if (stats.status == "reconnecting") {
                status_label.label = I18n.t ("Reconnecting...");
                ip_label.label = "";
            } else if (stats.status == "disconnecting" || stats.status == "exiting") {
                status_label.label = I18n.t ("Disconnecting...");
                ip_label.label = "";
                routing_label.label = "";
            }

            if (stats.routing_status != "-" && stats.routing_status.length > 0) {
                routing_label.label = stats.routing_status;
            } else {
                routing_label.label = "";
            }
        }
    }
}
