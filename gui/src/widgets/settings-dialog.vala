namespace PsiphonCliGui {
    public class SettingsDialog : Adw.Dialog {
        public signal void settings_saved (TunnelOptions options);

        private SettingsService settings_service;
        private ServerListService server_list_service;
        private Adw.ToastOverlay toast_overlay;
        private weak Gtk.Window? parent_window;

        private Adw.ComboRow protocol_row;
        private Adw.ComboRow region_row;
        private Adw.EntryRow upstream_proxy_row;
        private Adw.EntryRow compartment_row;
        private Adw.EntryRow cdn_ip_list_row;
        private Adw.EntryRow cdn_sni_row;
        private Adw.EntryRow osl_urls_row;
        private Adw.ComboRow language_row;
        private Adw.EntryRow core_path_row;
        private Adw.EntryRow config_dir_row;
        private Adw.SwitchRow lan_row;
        private Adw.SwitchRow beast_mode_row;
        private Adw.SwitchRow timeout_row;
        private Adw.SwitchRow system_proxy_row;
        private Adw.SwitchRow tun_row;
        private Adw.SwitchRow fakeip_row;
        private Adw.EntryRow sing_box_path_row;
        private Adw.ActionRow refresh_row;
        private Gtk.Stack refresh_stack;
        private Gtk.Button refresh_button;
        private Gtk.Spinner refresh_spinner;
        private Gtk.Label refresh_busy_label;
        private bool refresh_in_progress = false;
        private Region[] regions;

        public SettingsDialog (
            SettingsService settings_service,
            ServerListService server_list_service
        ) {
            Object (title: I18n.t ("Connection settings"), content_width: 540, content_height: 680);

            this.settings_service = settings_service;
            this.server_list_service = server_list_service;
            regions = Region.all ();

            toast_overlay = new Adw.ToastOverlay ();
            set_child (toast_overlay);

            var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            toast_overlay.set_child (root);

            var scrolled = new Gtk.ScrolledWindow ();
            scrolled.vexpand = true;
            root.append (scrolled);

            var prefs = new Adw.PreferencesPage ();
            scrolled.set_child (prefs);

            var general = new Adw.PreferencesGroup ();
            general.title = I18n.t ("Connection");
            general.description = I18n.t ("Protocol, region, and proxy options used on connect.");
            prefs.add (general);

            protocol_row = new Adw.ComboRow ();
            protocol_row.title = I18n.t ("Protocol");
            protocol_row.subtitle = I18n.t ("Auto, Conduit, Direct, or CDN Fronting");
            protocol_row.model = new Gtk.StringList ({
                I18n.t ("Auto"),
                I18n.t ("Conduit"),
                I18n.t ("Direct"),
                I18n.t ("CDN Fronting")
            });
            general.add (protocol_row);

            region_row = new Adw.ComboRow ();
            region_row.title = I18n.t ("Region");
            region_row.subtitle = I18n.t ("Egress country for the tunnel");
            region_row.model = new Gtk.StringList (build_region_items ());
            general.add (region_row);

            upstream_proxy_row = new Adw.EntryRow ();
            upstream_proxy_row.title = I18n.t ("Upstream proxy");
            upstream_proxy_row.text = "";
            general.add (upstream_proxy_row);

            beast_mode_row = new Adw.SwitchRow ();
            beast_mode_row.title = I18n.t ("Beast mode");
            beast_mode_row.subtitle = I18n.t ("Aggressive establishment: try all protocols on all servers");
            general.add (beast_mode_row);

            var conduit_group = new Adw.PreferencesGroup ();
            conduit_group.title = I18n.t ("Conduit mode");
            conduit_group.description = I18n.t ("Personal conduits (compartment ID) or public conduits");
            prefs.add (conduit_group);

            compartment_row = new Adw.EntryRow ();
            compartment_row.title = I18n.t ("Personal conduit compartment ID");
            conduit_group.add (compartment_row);

            var cdn_group = new Adw.PreferencesGroup ();
            cdn_group.title = I18n.t ("CDN fronting");
            cdn_group.description = I18n.t ("Custom IP candidates for the built-in CDN scan (used in CDN Fronting mode)");
            prefs.add (cdn_group);

            cdn_ip_list_row = new Adw.EntryRow ();
            cdn_ip_list_row.title = I18n.t ("IP candidates");
            cdn_ip_list_row.tooltip_text = I18n.t ("IPv4 or CIDR, separated by space, comma, or semicolon");
            cdn_group.add (cdn_ip_list_row);

            cdn_sni_row = new Adw.EntryRow ();
            cdn_sni_row.title = I18n.t ("Custom SNI");
            cdn_sni_row.tooltip_text = I18n.t ("Hostname used for scanning and edge overrides; leave empty to use the IP");
            cdn_group.add (cdn_sni_row);

            osl_urls_row = new Adw.EntryRow ();
            osl_urls_row.title = I18n.t ("OSL server list URLs");
            osl_urls_row.tooltip_text = I18n.t ("Obfuscated server list root URLs — adds protocol-specific server buckets (incl. CDN fronting); leave empty to use the standard list");
            cdn_group.add (osl_urls_row);

            var interface_group = new Adw.PreferencesGroup ();
            interface_group.title = I18n.t ("Interface");
            prefs.add (interface_group);

            language_row = new Adw.ComboRow ();
            language_row.title = I18n.t ("Language");
            language_row.subtitle = I18n.t ("Interface language (takes effect after restart)");
            language_row.model = new Gtk.StringList ({
                I18n.t ("System"),
                I18n.t ("Persian"),
                I18n.t ("English")
            });
            interface_group.add (language_row);

            var routing = new Adw.PreferencesGroup ();
            routing.title = I18n.t ("Routing");
            routing.description = I18n.t ("Enable either or both. Each runs independently after connect.");
            prefs.add (routing);

            system_proxy_row = new Adw.SwitchRow ();
            system_proxy_row.title = I18n.t ("System proxy");
            system_proxy_row.subtitle = I18n.t ("Set desktop proxy settings to the local tunnel ports");
            routing.add (system_proxy_row);

            tun_row = new Adw.SwitchRow ();
            tun_row.title = I18n.t ("TUN routing (recommended)");
#if WINDOWS
            tun_row.subtitle = I18n.t ("Route all traffic through sing-box into the local SOCKS proxy — requires running Forough as Administrator (wintun)");
#else
            tun_row.subtitle = I18n.t ("Route all traffic through sing-box into the local SOCKS proxy — the desktop equivalent of Android's VPN mode");
#endif
            routing.add (tun_row);
            tun_row.notify["active"].connect (() => update_routing_rows ());

            fakeip_row = new Adw.SwitchRow ();
            fakeip_row.title = I18n.t ("Fast DNS (Fake-IP)");
            fakeip_row.subtitle = I18n.t ("Answer DNS instantly and resolve domains at the tunnel exit — like Android. Turn off only if an app misbehaves");
            routing.add (fakeip_row);

            sing_box_path_row = new Adw.EntryRow ();
            sing_box_path_row.title = I18n.t ("sing-box path");
            var sing_box_browse = new Gtk.Button.from_icon_name ("folder-open-symbolic");
            sing_box_browse.valign = Gtk.Align.CENTER;
            sing_box_browse.tooltip_text = I18n.t ("Browse for sing-box");
            sing_box_browse.clicked.connect (() => browse_sing_box_path.begin ());
            sing_box_path_row.add_suffix (sing_box_browse);
            routing.add (sing_box_path_row);

            var advanced = new Adw.PreferencesGroup ();
            advanced.title = I18n.t ("Advanced");
            advanced.description = I18n.t ("Core binary, config directory, and tunnel behavior.");
            prefs.add (advanced);

            core_path_row = new Adw.EntryRow ();
            core_path_row.title = I18n.t ("Core binary path");
            var core_browse = new Gtk.Button.from_icon_name ("folder-open-symbolic");
            core_browse.valign = Gtk.Align.CENTER;
            core_browse.tooltip_text = I18n.t ("Browse for psiphon-tunnel-core");
            core_browse.clicked.connect (() => browse_core_path.begin ());
            core_path_row.add_suffix (core_browse);
            advanced.add (core_path_row);

            config_dir_row = new Adw.EntryRow ();
            config_dir_row.title = I18n.t ("Config directory");
            var config_browse = new Gtk.Button.from_icon_name ("folder-open-symbolic");
            config_browse.valign = Gtk.Align.CENTER;
            config_browse.tooltip_text = I18n.t ("Browse for config directory");
            config_browse.clicked.connect (() => browse_config_dir.begin ());
            config_dir_row.add_suffix (config_browse);
            advanced.add (config_dir_row);

            lan_row = new Adw.SwitchRow ();
            lan_row.title = I18n.t ("Enable LAN");
            lan_row.subtitle = I18n.t ("Listen on 0.0.0.0 instead of 127.0.0.1");
            advanced.add (lan_row);

            timeout_row = new Adw.SwitchRow ();
            timeout_row.title = I18n.t ("Enable timeout");
            timeout_row.subtitle = I18n.t ("Use the establish-tunnel timeout from psiphon.config");
            advanced.add (timeout_row);

            var actions = new Adw.PreferencesGroup ();
            actions.title = I18n.t ("Maintenance");
            prefs.add (actions);

            refresh_button = new Gtk.Button.with_label (I18n.t ("Refresh"));
            refresh_button.valign = Gtk.Align.CENTER;
            refresh_button.clicked.connect (() => refresh_server_list.begin ());

            refresh_spinner = new Gtk.Spinner ();
            refresh_spinner.valign = Gtk.Align.CENTER;
            refresh_spinner.width_request = 24;
            refresh_spinner.height_request = 24;

            refresh_busy_label = new Gtk.Label (I18n.t ("Downloading…"));
            refresh_busy_label.valign = Gtk.Align.CENTER;
            refresh_busy_label.add_css_class ("accent");

            var refresh_busy_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
            refresh_busy_box.valign = Gtk.Align.CENTER;
            refresh_busy_box.append (refresh_spinner);
            refresh_busy_box.append (refresh_busy_label);

            refresh_stack = new Gtk.Stack ();
            refresh_stack.valign = Gtk.Align.CENTER;
            refresh_stack.halign = Gtk.Align.END;
            refresh_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            refresh_stack.transition_duration = 150;
            refresh_stack.add_named (refresh_button, "idle");
            refresh_stack.add_named (refresh_busy_box, "busy");
            refresh_stack.visible_child_name = "idle";

            refresh_row = new Adw.ActionRow ();
            refresh_row.title = I18n.t ("Server list");
            refresh_row.subtitle = I18n.t ("Download the latest official Psiphon server list.");
            refresh_row.add_suffix (refresh_stack);
            refresh_row.activatable_widget = refresh_button;
            actions.add (refresh_row);

            var footer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            footer.margin_top = 12;
            footer.margin_bottom = 12;
            footer.margin_start = 12;
            footer.margin_end = 12;
            footer.halign = Gtk.Align.END;

            var cancel_button = new Gtk.Button.with_label (I18n.t ("Cancel"));
            cancel_button.clicked.connect (() => close ());
            footer.append (cancel_button);

            var save_button = new Gtk.Button.with_label (I18n.t ("Save"));
            save_button.add_css_class ("suggested-action");
            save_button.clicked.connect (() => save_and_close ());
            footer.append (save_button);
            root.append (footer);
        }

        public void open (Gtk.Window parent) {
            parent_window = parent;
            load_from_settings ();
            present (parent);
        }

        private void load_from_settings () {
            var options = settings_service.load_options ();
            protocol_row.selected = (uint) options.protocol;
            select_region (options.region);
            upstream_proxy_row.text = options.upstream_proxy_url;
            compartment_row.text = options.inproxy_compartment_id;
            cdn_ip_list_row.text = options.cdn_fronting_ip_list;
            cdn_sni_row.text = options.cdn_fronting_sni;
            osl_urls_row.text = options.osl_urls;
            language_row.selected = load_language_index ();
            core_path_row.text = options.core_path;
            config_dir_row.text = options.config_dir.length > 0
                ? options.config_dir
                : Constants.default_config_dir ();
            lan_row.active = options.enable_lan;
            beast_mode_row.active = options.enable_beast_mode;
            timeout_row.active = options.enable_timeout;
            system_proxy_row.active = options.enable_system_proxy;
            tun_row.active = options.enable_tun;
            fakeip_row.active = options.tun_fakeip;
            sing_box_path_row.text = options.sing_box_path;
            update_routing_rows ();
        }

        private uint load_language_index () {
            string pref = "system";
            try {
                var settings = new Settings (Constants.SETTINGS_SCHEMA_ID);
                pref = settings.get_string ("language").strip ();
                if (pref.length == 0) {
                    pref = "system";
                }
            } catch (Error e) {
                pref = "system";
            }

            if (pref == "fa") {
                return 1;
            } else if (pref == "en") {
                return 2;
            }
            return 0;
        }

        private string save_language_value () {
            switch (language_row.selected) {
                case 1:
                    return "fa";
                case 2:
                    return "en";
                case 0:
                default:
                    return "system";
            }
        }

        private void save_and_close () {
            var options = build_options ();
            settings_service.save_options (options);
            try {
                var settings = new Settings (Constants.SETTINGS_SCHEMA_ID);
                settings.set_string ("language", save_language_value ());
            } catch (Error e) {
                warning ("Could not persist language setting: %s", e.message);
            }
            settings_saved (options);
            close ();
        }

        private TunnelOptions build_options () {
            var options = new TunnelOptions ();
            options.protocol = ProtocolMode.from_index (protocol_row.selected);
            options.region = selected_region_code ();
            options.upstream_proxy_url = upstream_proxy_row.text.strip ();
            options.inproxy_compartment_id = compartment_row.text.strip ();
            options.cdn_fronting_ip_list = cdn_ip_list_row.text.strip ();
            options.cdn_fronting_sni = cdn_sni_row.text.strip ();
            options.osl_urls = osl_urls_row.text.strip ();
            options.core_path = core_path_row.text.strip ();
            string config_dir = config_dir_row.text.strip ();
            if (config_dir == Constants.default_config_dir ()) {
                config_dir = "";
            }
            options.config_dir = config_dir;
            options.enable_lan = lan_row.active;
            options.enable_beast_mode = beast_mode_row.active;
            options.enable_timeout = timeout_row.active;
            options.enable_system_proxy = system_proxy_row.active;
            options.enable_tun = tun_row.active;
            options.tun_fakeip = fakeip_row.active;
            options.sing_box_path = sing_box_path_row.text.strip ();
            return options;
        }

        private void update_routing_rows () {
            sing_box_path_row.visible = tun_row.active;
            fakeip_row.visible = tun_row.active;
        }

        private async void browse_sing_box_path () {
            if (parent_window == null) {
                return;
            }

            var dialog = new Gtk.FileDialog ();
            dialog.title = I18n.t ("Browse for sing-box");

            try {
                File file = yield dialog.open (parent_window, null);
                sing_box_path_row.text = file.get_path ();
            } catch (Error err) {
                if (err is IOError.CANCELLED) {
                    return;
                }
                toast_overlay.add_toast (new Adw.Toast (err.message));
            }
        }

        private async void browse_core_path () {
            if (parent_window == null) {
                return;
            }

            var dialog = new Gtk.FileDialog ();
            dialog.title = I18n.t ("Browse for psiphon-tunnel-core");

            try {
                File file = yield dialog.open (parent_window, null);
                core_path_row.text = file.get_path ();
            } catch (Error err) {
                if (err is IOError.CANCELLED) {
                    return;
                }
                toast_overlay.add_toast (new Adw.Toast (err.message));
            }
        }

        private async void browse_config_dir () {
            if (parent_window == null) {
                return;
            }

            var dialog = new Gtk.FileDialog ();
            dialog.title = I18n.t ("Browse for config directory");

            try {
                File folder = yield dialog.select_folder (parent_window, null);
                config_dir_row.text = folder.get_path ();
            } catch (Error err) {
                if (err is IOError.CANCELLED) {
                    return;
                }
                toast_overlay.add_toast (new Adw.Toast (err.message));
            }
        }

        private void set_refresh_busy (bool busy) {
            refresh_in_progress = busy;
            refresh_button.sensitive = !busy;
            refresh_row.activatable = !busy;

            if (busy) {
                refresh_stack.visible_child_name = "busy";
                refresh_row.subtitle = I18n.t ("Downloading the latest official Psiphon server list…");
                refresh_spinner.start ();
            } else {
                refresh_stack.visible_child_name = "idle";
                refresh_row.subtitle = I18n.t ("Download the latest official Psiphon server list.");
                refresh_spinner.stop ();
            }
        }

        private async void refresh_server_list () {
            if (refresh_in_progress) {
                return;
            }

            set_refresh_busy (true);
            var progress_toast = new Adw.Toast (I18n.t ("Downloading server list…"));
            progress_toast.timeout = 0;
            toast_overlay.add_toast (progress_toast);

            try {
                string path = yield server_list_service.refresh_server_list ();
                progress_toast.dismiss ();
                var done_toast = new Adw.Toast (I18n.t ("Server list saved to %s").printf (path));
                done_toast.timeout = 5;
                toast_overlay.add_toast (done_toast);
            } catch (Error err) {
                progress_toast.dismiss ();
                var error_toast = new Adw.Toast (err.message);
                error_toast.timeout = 6;
                toast_overlay.add_toast (error_toast);
            } finally {
                set_refresh_busy (false);
            }
        }

        private string selected_region_code () {
            uint selected = region_row.selected;
            if (selected == 0) {
                return "";
            }

            int index = (int) selected - 1;
            if (index >= 0 && index < regions.length) {
                return regions[index].code;
            }

            return "";
        }

        private void select_region (string code) {
            if (code.length == 0) {
                region_row.selected = 0;
                return;
            }

            for (int i = 0; i < regions.length; i++) {
                if (regions[i].code == code) {
                    region_row.selected = (uint) (i + 1);
                    return;
                }
            }
        }

        private string[] build_region_items () {
            string[] items = { I18n.t ("Auto") };
            foreach (Region region in regions) {
                items += region.display_name_with_flag ();
            }
            return items;
        }
    }
}
