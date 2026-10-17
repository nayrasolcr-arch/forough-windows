namespace PsiphonCliGui {
    public class AboutDialogHelper {
        public static void present (Gtk.Window parent) {
            var info = VersionInfo.load ();

            var dialog = new Adw.AboutDialog ();
            dialog.application_name = I18n.t ("Forough");
            dialog.application_icon = Constants.APPLICATION_ID;
            dialog.version = info.version;
            dialog.developer_name = "Forough contributors";
            dialog.comments = I18n.t (
                "Forough is a fast, beautiful desktop VPN client for the open internet — built on the Psiphon network, with a native GTK4 interface, full Persian RTL support, a manual CDN edge scanner, live traffic graph, built-in speed test, a TUN watchdog with auto-restart, and an automatic system-proxy fallback.\n\nUnofficial project — not affiliated with Psiphon Inc. Learn more at psiphon.ca."
            );
            dialog.website = "https://github.com/nayrasolcr-arch/forough-windows";
            dialog.issue_url = "https://github.com/nayrasolcr-arch/forough-windows/issues";
            dialog.license_type = Gtk.License.GPL_3_0;
            dialog.present (parent);
        }
    }
}
