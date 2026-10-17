namespace PsiphonCliGui {
    public class TunnelOptions : Object {
        public ProtocolMode protocol { get; set; default = ProtocolMode.AUTO; }
        public string region { get; set; default = ""; }
        public string upstream_proxy_url { get; set; default = ""; }
        public bool enable_timeout { get; set; default = false; }
        public bool enable_lan { get; set; default = false; }
        public bool enable_beast_mode { get; set; default = true; }
        public bool enable_system_proxy { get; set; default = false; }
        public bool enable_tun { get; set; default = false; }
        public string core_path { get; set; default = ""; }
        public string config_dir { get; set; default = ""; }
        public string sing_box_path { get; set; default = ""; }
        // Personal in-proxy (conduit) compartment ID; empty = public conduits.
        public string inproxy_compartment_id { get; set; default = ""; }
        // Custom CDN fronting scan inputs (Psiphon Android client parity):
        // IPv4/CIDR candidates and optional SNI server names. Empty = the
        // tunnel-core built-in edge candidates only.
        public string cdn_fronting_ip_list { get; set; default = ""; }
        public string cdn_fronting_sni { get; set; default = ""; }
        // Obfuscated server list (OSL) root URLs (Android parity: the Android
        // client embeds these at build time). OSL carries protocol-specific
        // server buckets — including the CDN-fronted meek entries that the
        // common remote server list barely contains (3 of 430 servers) — so
        // without OSL the CDN fronting pool is far smaller than on Android.
        // Empty = remote server list only, exactly like previous releases.
        public string osl_urls { get; set; default = ""; }
        // Fast-DNS Fake-IP under TUN (v1.4.0): A/AAAA answered instantly from
        // a fake-IP pool, domains resolved at the tunnel exit. DEFAULT OFF as
        // of v1.5.0: field reports (v1.4.0/v1.4.1) showed tunnels that
        // establish but carry no traffic with Fake-IP on, while the forward
        // path (TCP DNS through the tunnel + dns cache) is the exact
        // configuration proven working since v1.3.1. The DNS cache (added in
        // v1.4.1) keeps the forward path fast, so Fake-IP stays an opt-in
        // experiment behind this switch.
        public bool tun_fakeip { get; set; default = false; }
        // Set by TunnelManager on the final automatic restart: strip QUIC
        // protocols from LimitTunnelProtocols. ISPs that throttle QUIC let
        // the handshake pass but never carry real traffic, so a TCP-only
        // retry is the last-resort self-heal for dead-traffic tunnels.
        public bool tcp_only_override { get; set; default = false; }
    }
}
