namespace PsiphonCliGui {
    public enum ProtocolMode {
        AUTO,
        CONDUIT,
        DIRECT,
        CDN_FRONTING;

        public string label () {
            switch (this) {
                case CONDUIT:
                    return I18n.t ("Conduit");
                case DIRECT:
                    return I18n.t ("Direct");
                case CDN_FRONTING:
                    return I18n.t ("CDN Fronting");
                case AUTO:
                default:
                    return I18n.t ("Auto");
            }
        }

        public string config_value () {
            switch (this) {
                case CONDUIT:
                    return "conduit";
                case DIRECT:
                    return "direct";
                case CDN_FRONTING:
                    return "cdn_fronting";
                case AUTO:
                default:
                    return "auto";
            }
        }

        public static ProtocolMode from_index (uint index) {
            switch (index) {
                case 1:
                    return CONDUIT;
                case 2:
                    return DIRECT;
                case 3:
                    return CDN_FRONTING;
                case 0:
                default:
                    return AUTO;
            }
        }
    }
}
