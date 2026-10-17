namespace PsiphonCliGui {
    public class StatsPanel : Gtk.Box {
        private Gtk.Label status_value;
        private Gtk.Label protocol_value;
        private Gtk.Label tunnel_value;
        private Gtk.Label uptime_value;
        private Gtk.Label proxy_value;
        private Gtk.Label regions_value;
        private Gtk.Label beast_mode_value;
        private Gtk.Label cdn_scan_value;
        private Gtk.Label traffic_value;
        private Gtk.Label public_ip_value;
        private Gtk.Label routing_value;

        public StatsPanel () {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 6);
            add_css_class ("card");
            margin_top = 0;
            margin_bottom = 0;
            margin_start = 0;
            margin_end = 0;

            var title = new Gtk.Label (I18n.t ("Live stats"));
            title.add_css_class ("heading");
            title.halign = Gtk.Align.START;
            title.margin_top = 8;
            title.margin_start = 10;
            title.margin_end = 10;
            append (title);

            var grid = new Gtk.Grid ();
            grid.column_spacing = 16;
            grid.row_spacing = 4;
            grid.margin_start = 10;
            grid.margin_end = 10;
            grid.margin_bottom = 10;
            grid.hexpand = true;
            append (grid);

            status_value = add_cell (grid, 0, 0, I18n.t ("Status"));
            protocol_value = add_cell (grid, 0, 1, I18n.t ("Protocol"));
            tunnel_value = add_cell (grid, 1, 0, I18n.t ("Tunnel"));
            uptime_value = add_cell (grid, 1, 1, I18n.t ("Uptime"));
            proxy_value = add_cell (grid, 2, 0, I18n.t ("Proxies"));
            regions_value = add_cell (grid, 2, 1, I18n.t ("Regions"));
            beast_mode_value = add_cell (grid, 3, 0, I18n.t ("Beast mode"));
            cdn_scan_value = add_cell (grid, 3, 1, I18n.t ("CDN scan"));
            traffic_value = add_cell (grid, 4, 0, I18n.t ("Traffic"), 2);
            public_ip_value = add_cell (grid, 5, 0, I18n.t ("Public IP"));
            routing_value = add_cell (grid, 5, 1, I18n.t ("Routing"));

            show_disconnected ();
        }

        public void show_disconnected () {
            status_value.label = "disconnected";
            protocol_value.label = "-";
            tunnel_value.label = "-";
            uptime_value.label = "-";
            proxy_value.label = "HTTP 127.0.0.1:8081 · SOCKS 127.0.0.1:1081";
            regions_value.label = "- → -";
            beast_mode_value.label = "-";
            cdn_scan_value.label = "-";
            traffic_value.label = "↓ 0 B/s · ↑ 0 B/s";
            public_ip_value.label = "-";
            routing_value.label = "-";
        }

        public void update_stats (TunnelStats stats) {
            status_value.label = stats.status;
            protocol_value.label = stats.protocol;
            tunnel_value.label = stats.tunnel_protocol;
            uptime_value.label = Format.uptime (stats.uptime_ms);
            proxy_value.label = "HTTP %s · SOCKS %s".printf (stats.http_proxy, stats.socks_proxy);

            string egress = stats.egress_region;
            string egress_flag = RegionFlags.flag_for_code (stats.egress_region);
            if (egress_flag.length > 0 && egress != "-") {
                egress = "%s %s".printf (egress_flag, egress);
            }

            regions_value.label = "%s → %s".printf (stats.client_region, egress);
            beast_mode_value.label = stats.beast_mode;
            cdn_scan_value.label = stats.cdn_scan;
            traffic_value.label = "%s · %s".printf (
                traffic_status_label (stats),
                "↓ %s (%s) · ↑ %s (%s)".printf (
                    Format.bytes_per_sec (stats.downstream_bps),
                    Format.bytes (stats.total_down_bytes),
                    Format.bytes_per_sec (stats.upstream_bps),
                    Format.bytes (stats.total_up_bytes)
                )
            );
            public_ip_value.label = stats.public_ip;
            routing_value.label = stats.routing_status;
        }

        // "Connected" alone is not proof the tunnel passes traffic. Surface the
        // GUI's end-to-end probe result (curl through the local HTTP proxy)
        // next to the byte counters.
        private string traffic_status_label (TunnelStats stats) {
            switch (stats.traffic_status) {
                case "ok":
                    return I18n.t ("online");
                case "failed":
                    return I18n.t ("no traffic");
                case "checking":
                    return I18n.t ("checking traffic…");
                case "restarting":
                    return I18n.t ("restarting tunnel…");
                default:
                    return "-";
            }
        }

        private Gtk.Label add_cell (Gtk.Grid grid, int row, int col, string label, int colspan = 1) {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.hexpand = true;

            var key = new Gtk.Label (label);
            key.add_css_class ("dim-label");
            key.halign = Gtk.Align.START;
            key.xalign = 0;
            box.append (key);

            var value = new Gtk.Label ("-");
            value.halign = Gtk.Align.START;
            value.xalign = 0;
            value.selectable = true;
            value.wrap = true;
            box.append (value);

            grid.attach (box, col, row, colspan, 1);
            return value;
        }
    }
}
