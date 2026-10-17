namespace PsiphonCliGui.Constants {
    public const string APPLICATION_ID = "io.github.nayrasolcr.Forough";
    public const string SETTINGS_SCHEMA_ID = "io.github.nayrasolcr.Forough";

    public const string APP_NAME = "Forough";

#if WINDOWS
    public const string PSIPHON_BIN = "psiphon-tunnel-core-x86_64.exe";
    public const string SING_BOX_BIN = "sing-box.exe";
#else
    public const string PSIPHON_BIN = "psiphon-tunnel-core-x86_64";
    public const string SING_BOX_BIN = "sing-box";
#endif
    public const string SING_BOX_CONFIG_FILE = "sing-box.json";
    public const string SING_BOX_PID_FILE = "sing-box.pid";
    public const string SING_BOX_TUN_INTERFACE = "forough0";
    public const string CONFIG_FILE = "psiphon.config";
    public const string STATS_FILE = "stats.json";
    public const string PID_FILE = "psiphon.pid";
    public const string LOG_FILE = "psiphon.log";
    public const string SERVER_LIST_FILE = "remote_server_list";

    public const int HTTP_PROXY_PORT = 8081;
    public const int SOCKS_PROXY_PORT = 1081;
    public const uint STATS_UPDATE_MS = 2000;

#if WINDOWS
    // Loopback-only clash API endpoint exposed by the Windows sing-box
    // config; the live traffic graph polls /traffic here. (On Linux the
    // graph reads the TUN interface counters from /sys instead.)
    public const string CLASH_API_CONTROLLER = "127.0.0.1:9090";
#endif

    // Protocol selections mirror the Psiphon Android client
    // (app/src/main/java/com/psiphon3/psiphonlibrary/TunnelManager.java,
    // CONDUIT_TUNNEL_PROTOCOLS / CDN_FRONTING_TUNNEL_PROTOCOLS /
    // DIRECT_TUNNEL_PROTOCOLS) so desktop and Android behave the same.
    public string[] direct_protocols () {
        return {
            "SSH",
            "OSSH",
            "TLS-OSSH",
            "UNFRONTED-MEEK-OSSH",
            "UNFRONTED-MEEK-HTTPS-OSSH",
            "UNFRONTED-MEEK-SESSION-TICKET-OSSH",
            "QUIC-OSSH",
            "SHADOWSOCKS-OSSH",
            "FRONTED-MEEK-OSSH",
            "FRONTED-MEEK-CDN-OSSH",
            "FRONTED-MEEK-HTTP-OSSH",
            "FRONTED-MEEK-CDN-HTTP-OSSH",
            "FRONTED-MEEK-QUIC-OSSH",
            "FRONTED-MEEK-CDN-QUIC-OSSH"
        };
    }

    public string[] conduit_protocols () {
        return {
            "INPROXY-WEBRTC-SSH",
            "INPROXY-WEBRTC-OSSH",
            "INPROXY-WEBRTC-TLS-OSSH",
            "INPROXY-WEBRTC-UNFRONTED-MEEK-OSSH",
            "INPROXY-WEBRTC-UNFRONTED-MEEK-HTTPS-OSSH",
            "INPROXY-WEBRTC-UNFRONTED-MEEK-SESSION-TICKET-OSSH",
            "INPROXY-WEBRTC-FRONTED-MEEK-OSSH",
            "INPROXY-WEBRTC-FRONTED-MEEK-HTTP-OSSH",
            "INPROXY-WEBRTC-QUIC-OSSH",
            "INPROXY-WEBRTC-FRONTED-MEEK-QUIC-OSSH",
            "INPROXY-WEBRTC-SHADOWSOCKS-OSSH"
        };
    }

    public string[] cdn_fronting_protocols () {
        return {
            "FRONTED-MEEK-CDN-OSSH",
            "FRONTED-MEEK-CDN-HTTP-OSSH",
            "FRONTED-MEEK-CDN-QUIC-OSSH"
        };
    }

    public string default_config_dir () {
#if WINDOWS
        // %LOCALAPPDATA%\Forough (g_get_user_data_dir returns LOCALAPPDATA
        // on Windows). Per-user, no admin rights needed, survives upgrades.
        return Path.build_filename (Environment.get_user_data_dir (), "Forough");
#else
        return Path.build_filename (Environment.get_home_dir (), ".config", "forough");
#endif
    }
}
