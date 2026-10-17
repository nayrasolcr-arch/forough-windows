namespace PsiphonCliGui {
    /**
     * Cloudflare integration (v1.5.0) — the "panel-style" token workflow.
     *
     * Panels such as BPB take a Cloudflare API token and deploy a Worker via
     * the Cloudflare REST API; this service does the same for a small
     * *helper* worker used by the client:
     *
     *   - /probe returns JSON { ok, colo, ip, ts } where colo is the
     *     Cloudflare data center the request landed on — a live signal of
     *     which edge POP the user's network path reaches, shown in the CDN
     *     scanner and useful when picking scan scopes.
     *
     * Honest scope note (also surfaced in the UI): Psiphon's meek/CDN
     * fronting domains are controlled server-side by the Psiphon
     * infrastructure — a personal Worker cannot become a Psiphon fronting
     * endpoint the way panels create VLESS entries backed by the user's own
     * VPS. The helper is for edge probing/monitoring and connectivity
     * checks only.
     *
     * All calls shell out to curl (already a runtime dependency for the
     * performance probe) and parse JSON with Json.Parser; the API token is
     * never logged.
     */
    public class CloudflareService : Object {
        public const string WORKER_NAME = "forough-edge-helper";

        public signal void deploy_finished (bool ok, string worker_url, string message);
        public signal void probe_finished (bool ok, string colo, uint ms, string message);

        private bool busy = false;

        private const string WORKER_SCRIPT = """
// Forough edge helper — colo/latency probe endpoint.
addEventListener('fetch', (event) => {
  event.respondWith(handle(event.request));
});
async function handle(request) {
  const url = new URL(request.url);
  if (url.pathname === '/probe') {
    const body = JSON.stringify({
      ok: true,
      colo: (request.cf && request.cf.colo) || '',
      ip: request.headers.get('cf-connecting-ip') || '',
      ts: Date.now()
    });
    return new Response(body, {
      headers: {
        'content-type': 'application/json',
        'access-control-allow-origin': '*',
        'cache-control': 'no-store'
      }
    });
  }
  return new Response('forough edge helper\n', {
    headers: { 'content-type': 'text/plain' }
  });
}
""";

        public bool is_busy () {
            return busy;
        }

        /** Verify token, resolve the account, deploy/patch the helper worker. */
        public void deploy_helper (string token) {
            if (busy || token.strip ().length == 0) {
                return;
            }
            busy = true;
            try {
                new GLib.Thread<void*> ("cf-deploy", () => {
                    string url = "";
                    string message = "";
                    bool ok = run_deploy (token.strip (), out url, out message);
                    Idle.add (() => {
                        busy = false;
                        deploy_finished (ok, url, message);
                        return false;
                    });
                    return null;
                });
            } catch (Error e) {
                busy = false;
                deploy_finished (false, "", e.message);
            }
        }

        private bool run_deploy (string token, out string worker_url, out string message) {
            worker_url = "";
            message = "";

            // 1) Token must be valid.
            Json.Node? verify;
            if (!cf_request ("GET", "https://api.cloudflare.com/client/v4/user/tokens/verify",
                token, null, out verify) || !json_success (verify)) {
                message = I18n.t("Token verification failed");
                return false;
            }

            // 2) First account.
            Json.Node? accounts;
            if (!cf_request ("GET", "https://api.cloudflare.com/client/v4/accounts",
                token, null, out accounts) || !json_success (accounts)) {
                message = I18n.t("Could not list accounts");
                return false;
            }
            string? account_id = null;
            try {
                var arr = accounts.get_object ().get_array_member ("result");
                if (arr.get_length () == 0) {
                    message = I18n.t("No Cloudflare account on this token");
                    return false;
                }
                account_id = arr.get_object_element (0).get_string_member ("id");
            } catch (Error e) {
                message = I18n.t("Unexpected accounts response");
                return false;
            }

            // 3) Ensure a workers.dev subdomain exists.
            string subdomain = "";
            Json.Node? sub;
            if (cf_request ("GET",
                "https://api.cloudflare.com/client/v4/accounts/%s/workers/subdomain".printf (account_id),
                token, null, out sub) && json_success (sub)) {
                try {
                    subdomain = sub.get_object ().get_object_member ("result").get_string_member ("subdomain");
                } catch (Error e) {
                    subdomain = "";
                }
            }
            if (subdomain.length == 0) {
                string proposed = "skh-%s".printf (random_suffix ());
                var body_obj = new Json.Object ();
                body_obj.set_string_member ("subdomain", proposed);
                Json.Node? created;
                if (!cf_request ("PUT",
                    "https://api.cloudflare.com/client/v4/accounts/%s/workers/subdomain".printf (account_id),
                    token, json_body (body_obj), out created) ||
                    !json_success (created)) {
                    message = I18n.t("Could not create a workers.dev subdomain");
                    return false;
                }
                subdomain = proposed;
            }

            // 4) Upload the helper script (legacy single-script upload).
            Json.Node? uploaded;
            if (!cf_request_raw ("PUT",
                "https://api.cloudflare.com/client/v4/accounts/%s/workers/scripts/%s".printf (account_id, WORKER_NAME),
                token, "application/javascript", WORKER_SCRIPT, out uploaded) || !json_success (uploaded)) {
                message = I18n.t("Worker upload failed (need Workers Scripts:Edit permission)");
                return false;
            }

            // 5) Enable on workers.dev.
            var enable = new Json.Object ();
            enable.set_boolean_member ("enabled", true);
            enable.set_boolean_member ("previews_enabled", false);
            Json.Node? enabled;
            if (!cf_request ("PUT",
                "https://api.cloudflare.com/client/v4/accounts/%s/workers/scripts/%s/subdomain".printf (account_id, WORKER_NAME),
                token, json_body (enable), out enabled)) {
                // Non-fatal: may already be enabled.
            }

            worker_url = "https://%s.%s.workers.dev".printf (WORKER_NAME, subdomain);
            message = I18n.t("Helper worker deployed");
            return true;
        }

        /** GET {worker_url}/probe — returns colo + round-trip ms. */
        public void probe (string worker_url) {
            if (busy || worker_url.strip ().length == 0) {
                probe_finished (false, "", 0, I18n.t("No helper worker configured"));
                return;
            }
            string url = worker_url.strip ();
            if (!url.has_suffix ("/")) {
                url += "/";
            }
            url += "probe";
            try {
                new GLib.Thread<void*> ("cf-probe", () => {
                    int64 t0 = GLib.get_monotonic_time ();
                    string stdout_buf = "";
                    int status = run_curl ("GET", url, null, null, null, out stdout_buf);
                    uint ms = (uint) ((GLib.get_monotonic_time () - t0) / 1000);
                    string colo = "";
                    bool ok = status == 0 && stdout_buf.contains ("\"ok\": true") ||
                              status == 0 && stdout_buf.contains ("\"ok\":true");
                    if (ok) {
                        try {
                            var parser = new Json.Parser ();
                            parser.load_from_data (stdout_buf);
                            colo = parser.get_root ().get_object ().get_string_member ("colo");
                        } catch (Error e) {
                            ok = false;
                        }
                    }
                    string msg = ok ? "ok" : I18n.t("Probe failed (HTTP/worker error)");
                    Idle.add (() => {
                        probe_finished (ok, colo, ms, msg);
                        return false;
                    });
                    return null;
                });
            } catch (Error e) {
                probe_finished (false, "", 0, e.message);
            }
        }

        // ----- HTTP plumbing (curl subprocess) -----

        private bool cf_request (string method, string url, string token,
            string? body, out Json.Node? response) {
            response = null;
            string stdout_buf = "";
            int status = run_curl (method, url, token, "application/json", body, out stdout_buf);
            if (status != 0 || stdout_buf.length == 0) {
                return false;
            }
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (stdout_buf);
                response = parser.get_root ();
                return true;
            } catch (Error e) {
                return false;
            }
        }

        private bool cf_request_raw (string method, string url, string token,
            string content_type, string body, out Json.Node? response) {
            response = null;
            string stdout_buf = "";
            int status = run_curl (method, url, token, content_type, body, out stdout_buf);
            if (status != 0 || stdout_buf.length == 0) {
                return false;
            }
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (stdout_buf);
                response = parser.get_root ();
                return true;
            } catch (Error e) {
                return false;
            }
        }

        private int run_curl (string method, string url, string? token,
            string? content_type, string? body, out string stdout_buf) {
            stdout_buf = "";
            string[] argv = { "curl", "-sS", "--max-time", "20", "-X", method };
            if (token != null) {
                argv += "-H";
                argv += "Authorization: Bearer " + token;
            }
            if (content_type != null) {
                argv += "-H";
                argv += "Content-Type: " + content_type;
            }
            if (body != null) {
                argv += "--data-binary";
                argv += body;
            }
            argv += url;

            string stderr_buf = "";
            int status;
            try {
                Process.spawn_sync (null, argv, null,
                    SpawnFlags.SEARCH_PATH, null,
                    out stdout_buf, out stderr_buf, out status);
            } catch (Error e) {
                return -1;
            }
            if (status != 0) {
                warning ("cloudflare curl failed: %s", stderr_buf.slice (0, int.min (200, stderr_buf.length)));
            }
            return status;
        }

        private string json_body (Json.Object obj) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (obj);
            var gen = new Json.Generator ();
            gen.set_root (node);
            return gen.to_data (null);
        }

        private bool json_success (Json.Node? response) {
            if (response == null || response.get_object () == null) {
                return false;
            }
            try {
                return response.get_object ().get_boolean_member ("success");
            } catch (Error e) {
                return false;
            }
        }

        private string random_suffix () {
            uint32 r = GLib.Random.int_range (0, 1679616); // 36^4
            return "%04x".printf (r);
        }
    }
}
