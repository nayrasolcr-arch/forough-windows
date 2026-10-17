namespace PsiphonCliGui {
    /**
     * Lightweight dictionary-based i18n for the Forough desktop client.
     *
     * English source strings are the keys; Persian (fa) is the only full
     * translation for now. The UI language is resolved once at startup:
     *   - GSettings key "language": "system" (default) | "fa" | "en"
     *   - when "system", LANG/LANGUAGE environment is inspected for fa-*
     *
     * When fa is active, GTK default direction is set to RTL by main().
     */
    public class I18n : Object {
        private static bool fa_active = false;
        private static HashTable<string, string> fa;

        public static bool is_rtl () {
            return fa_active;
        }

        public static string current_lang () {
            return fa_active ? "fa" : "en";
        }

        public static void init () {
            string pref = "system";
            try {
                var settings = new Settings (Constants.SETTINGS_SCHEMA_ID);
                pref = settings.get_string ("language").strip ();
                if (pref.length == 0) {
                    pref = "system";
                }
            } catch (Error e) {
                // schema not available yet (e.g. first run before schema install)
                pref = resolve_system_lang ();
            }

            if (pref == "system") {
                pref = resolve_system_lang ();
            }

            fa_active = (pref == "fa");
            load_fa ();
        }

        private static string resolve_system_lang () {
            string[] vars = { "LC_ALL", "LC_MESSAGES", "LANG", "LANGUAGE" };
            foreach (string name in vars) {
                string? v = Environment.get_variable (name);
                if (v != null && v.down ().has_prefix ("fa")) {
                    return "fa";
                }
            }
#if WINDOWS
            // Windows does not set POSIX locale variables. g_win32_getlocale
            // maps the user's default LCID to a Unix-style locale string
            // ("fa_IR", "en_US", …) so Persian Windows users get the fa UI.
            string? wloc = GLib.Win32.getlocale ();
            if (wloc != null && wloc.down ().has_prefix ("fa")) {
                return "fa";
            }
#endif
            return "en";
        }

        public static string t (string s) {
            if (!fa_active) {
                return s;
            }
            string? v = fa.lookup (s);
            return v != null ? v : s;
        }

        private static void load_fa () {
            fa = new HashTable<string, string> (str_hash, str_equal);
            fa.insert ("Forough", "فروغ");
            fa.insert ("Forough — Psiphon VPN client", "فروغ — کلاینت سایفون");
            fa.insert ("Connect", "اتصال");
            fa.insert ("Disconnect", "قطع اتصال");
            fa.insert ("Ready to connect", "آمادهٔ اتصال");
            fa.insert ("Connecting...", "در حال اتصال…");
            fa.insert ("Disconnecting...", "در حال قطع اتصال…");
            fa.insert ("Reconnecting...", "در حال اتصال مجدد…");
            fa.insert ("Connected in %.1fs", "متصل شد در %.1f ثانیه");
            fa.insert ("About", "درباره");
            fa.insert ("Connection settings", "تنظیمات اتصال");
            fa.insert ("Psiphon core logs", "لاگ‌های هستهٔ سایفون");
            fa.insert ("sing-box logs", "لاگ‌های sing-box");
            fa.insert ("No sing-box output yet. Enable TUN routing and connect to populate this log.", "هنوز خروجی sing-box وجود ندارد. برای پر شدن این لاگ، مسیریابی TUN را فعال کنید و متصل شوید.");
            fa.insert ("sing-box logs", "لاگ‌های sing-box");
            fa.insert ("sing-box error: %s", "خطای sing-box: %s");
            fa.insert ("Connect, view stats, and inspect tunnel logs.", "اتصال، مشاهدهٔ آمار و بررسی لاگ‌های تونل.");
            fa.insert ("Live stats", "آمار زنده");
            fa.insert ("Status", "وضعیت");
            fa.insert ("Protocol", "پروتکل");
            fa.insert ("Tunnel", "تونل");
            fa.insert ("Uptime", "مدت اتصال");
            fa.insert ("Proxies", "پروکسی‌ها");
            fa.insert ("Regions", "منطقه‌ها");
            fa.insert ("Beast mode", "حالت بیست");
            fa.insert ("Traffic", "ترافیک");
            fa.insert ("Tunnel logs", "لاگ‌های تونل");
            fa.insert ("Connection", "اتصال");
            fa.insert ("Routing", "مسیریابی");
            fa.insert ("Interface", "رابط کاربری");
            fa.insert ("Advanced", "پیشرفته");
            fa.insert ("Maintenance", "نگهداری");
            fa.insert ("Protocol, region, and proxy options used on connect.", "گزینه‌های پروتکل، منطقه و پروکسی که هنگام اتصال استفاده می‌شوند.");
            fa.insert ("Auto", "خودکار");
            fa.insert ("Conduit", "کانالیوت");
            fa.insert ("Direct", "مستقیم");
            fa.insert ("CDN Fronting", "فرونتینگ CDN");
            fa.insert ("Auto, Conduit, Direct, or CDN Fronting", "خودکار، کانالیوت، مستقیم یا فرونتینگ CDN");
            fa.insert ("Region", "منطقه");
            fa.insert ("Egress country for the tunnel", "کشور خروجی تونل");
            fa.insert ("Upstream proxy", "پروکسی بالادستی");
            fa.insert ("Beast mode", "حالت بیست");
            fa.insert ("Aggressive establishment: try all protocols on all servers", "برقراری تهاجمی: امتحان همهٔ پروتکل‌ها روی همهٔ سرورها");
            fa.insert ("Enable either or both. Each runs independently after connect.", "یک یا هر دو را فعال کنید. هر کدام مستقلاً پس از اتصال اجرا می‌شوند.");
            fa.insert ("System proxy", "پروکسی سیستم");
            fa.insert ("Set desktop proxy settings to the local tunnel ports", "تنظیم پروکسی دسکتاپ روی پورت‌های محلی تونل");
            fa.insert ("TUN routing (experimental)", "مسیریابی TUN (تجربی)");
            fa.insert ("Route all traffic through sing-box into the local SOCKS proxy", "مسیریابی کل ترافیک از sing-box به پروکسی SOCKS محلی");
            fa.insert ("TUN mode requires the sing-box binary with CAP_NET_ADMIN (set by the RPM post-install script).", "حالت TUN به باینری sing-box با CAP_NET_ADMIN نیاز دارد (توسط اسکریپت پس از نصب RPM تنظیم می‌شود).");
            fa.insert ("sing-box path", "مسیر sing-box");
            fa.insert ("Browse for sing-box", "انتخاب sing-box");
            fa.insert ("Core binary path", "مسیر باینری هسته");
            fa.insert ("Browse for psiphon-tunnel-core", "انتخاب psiphon-tunnel-core");
            fa.insert ("Config directory", "پوشهٔ تنظیمات");
            fa.insert ("Browse for config directory", "انتخاب پوشهٔ تنظیمات");
            fa.insert ("Enable LAN", "فعال‌سازی LAN");
            fa.insert ("Listen on 0.0.0.0 instead of 127.0.0.1", "گوش دادن روی 0.0.0.0 به جای 127.0.0.1");
            fa.insert ("Enable timeout", "فعال‌سازی زمان قطع");
            fa.insert ("Use the establish-tunnel timeout from psiphon.config", "استفاده از مهلت برقراری تونل از psiphon.config");
            fa.insert ("Server list", "لیست سرورها");
            fa.insert ("Download the latest official Psiphon server list.", "دانلود آخرین لیست رسمی سرورهای سایفون.");
            fa.insert ("Downloading the latest official Psiphon server list…", "در حال دانلود آخرین لیست رسمی سرورهای سایفون…");
            fa.insert ("Refresh", "به‌روزرسانی");
            fa.insert ("Downloading…", "در حال دانلود…");
            fa.insert ("Server list saved to %s", "لیست سرورها در %s ذخیره شد");
            fa.insert ("Downloading server list…", "در حال دانلود لیست سرورها…");
            fa.insert ("Cancel", "انصراف");
            fa.insert ("Save", "ذخیره");
            fa.insert ("Language", "زبان");
            fa.insert ("Interface language (takes effect after restart)", "زبان رابط کاربری (پس از راه‌اندازی مجدد اعمال می‌شود)");
            fa.insert ("System", "سیستم");
            fa.insert ("English", "انگلیسی");
            fa.insert ("Persian", "فارسی");
            fa.insert ("Personal conduit compartment ID", "شناسهٔ بخش شخصی کانالیوت");
            fa.insert ("Used for private in-proxy pairing. Leave empty to use public conduits.", "برای جفت‌سازی خصوصی in-proxy استفاده می‌شود. برای کانالیوت عمومی خالی بگذارید.");
            fa.insert ("Conduit mode", "حالت کانالیوت");
            fa.insert ("Personal conduits (compartment ID) or public conduits", "کانالیوت‌های شخصی (شناسهٔ بخش) یا کانالیوت‌های عمومی");
            fa.insert ("About Forough", "دربارهٔ فروغ");
            fa.insert ("Forough is a fast, beautiful desktop VPN client for the open internet — built on the Psiphon network, with a native GTK4 interface, full Persian RTL support, a manual CDN edge scanner, live traffic graph, built-in speed test, a TUN watchdog with auto-restart, and an automatic system-proxy fallback.\n\nUnofficial project — not affiliated with Psiphon Inc. Learn more at psiphon.ca.", "فروغ یک کلاینت VPN دسکتاپی سریع و زیبا برای دسترسی آزاد به اینترنت است؛ ساخته‌شده روی شبکه سایفون با رابط بومی GTK4، پشتیبانی کامل راست‌به‌چپ فارسی، اسکنر دستی لبه‌های CDN، نمودار زنده ترافیک، تست سرعت داخلی، نگهبان TUN با ری‌استارت خودکار و مسیر پشتیبان پراکسی سیستم.\n\nپروژه‌ای غیررسمی است — وابسته به Psiphon Inc. نیست. بیشتر در psiphon.ca.");
            fa.insert ("TUN mode", "حالت TUN");
            fa.insert ("System proxy", "پروکسی سیستم");
            fa.insert ("System proxy was set for the desktop session.", "پروکسی سیستم برای نشست دسکتاپ تنظیم شد.");
            fa.insert ("System proxy settings were restored.", "تنظیمات پروکسی سیستم بازگردانی شد.");
            fa.insert ("Failed to update system proxy settings.", "به‌روزرسانی تنظیمات پروکسی سیستم ناموفق بود.");
            fa.insert ("Failed to restore system proxy settings.", "بازگردانی تنظیمات پروکسی سیستم ناموفق بود.");
            fa.insert ("Stop the tunnel before changing the config directory.", "پوشهٔ تنظیمات را فقط پس از قطع تونل تغییر دهید.");
            // Beast mode / CDN scan status strings (Psiphon Android client parity)
            fa.insert ("active · %s workers", "فعال · %s کارگر");
            fa.insert ("connected · %s attempts · %s servers", "متصل شد · %s تلاش · %s سرور");
            fa.insert ("CDN scan", "اسکن CDN");
            fa.insert ("scan active — %s mode, %s workers", "اسکن CDN فعال است — حالت %s، %s کارگر");
            fa.insert ("scan: %s attempts, working: %s", "اسکن CDN: %s تلاش، فعال: %s");
            fa.insert ("scan finished after %s attempts, working: %s", "اسکن CDN پس از %s تلاش تمام شد، فعال: %s");
            fa.insert ("scan found %s + %s", "اسکن CDN %s + %s را پیدا کرد");
            fa.insert ("scan found a working route", "اسکن CDN یک مسیر کارآمد پیدا کرد");
            fa.insert ("no SNI", "بدون SNI");
            // End-to-end traffic verification (probe through the local proxy)
            fa.insert ("online", "آنلاین");
            fa.insert ("no traffic", "بدون ترافیک");
            fa.insert ("checking traffic…", "در حال بررسی ترافیک…");
            fa.insert ("restarting tunnel…", "در حال راه‌اندازی مجدد تونل…");
            fa.insert ("Traffic is not going through — restarting the tunnel automatically (%d/%d)",
                      "ترافیک از تونل عبور نمی‌کند — تونل به‌طور خودکار دوباره راه‌اندازی می‌شود (%d/%d)");
            // System proxy status on KDE sessions
            fa.insert ("System proxy active (GNOME + KDE)", "پروکسی سیستم فعال (GNOME + KDE)");
            fa.insert ("System proxy: GNOME settings only (KDE apps may ignore — use browser proxy or TUN)",
                      "پروکسی سیستم: فقط تنظیمات GNOME (برنامه‌های KDE ممکن است نادیده بگیرند — از پروکسی مرورگر یا حالت TUN استفاده کنید)");
            fa.insert ("TUN routing (recommended)", "مسیریابی TUN (پیشنهادی)");
            fa.insert ("Route all traffic through sing-box into the local SOCKS proxy — the desktop equivalent of Android's VPN mode",
                      "مسیریابی تمام ترافیک از طریق sing-box به پروکسی SOCKS محلی — معادل دسکتاپی حالت VPN اندروید");
            // CDN fronting settings group
            fa.insert ("CDN fronting", "فرونتینگ CDN");

            // v1.5.0 — manual CDN scanner, Cloudflare helper, speed test
            fa.insert ("Scan CDN edges and pick the fastest (manual IP scanner)", "اسکن لبه‌های CDN و انتخاب سریع‌ترین (اسکنر دستی IP)");
            fa.insert ("Run speed test now (result goes to logs and diagnostics)", "اجرای تست سرعت (نتیجه در لاگ و گزارش عیب‌یابی ثبت می‌شود)");
            fa.insert ("Speed test running — numbers land in the log and diagnostics", "تست سرعت در حال اجراست — اعداد در لاگ و گزارش عیب‌یابی ثبت می‌شوند");
            fa.insert ("CDN edges updated", "لبه‌های CDN به‌روز شد");
            fa.insert ("CDN IP Scanner", "اسکنر IP هر CDN");
            fa.insert ("Scan scope", "گسترهٔ اسکن");
            fa.insert ("Random samples from the same CDN ranges the tunnel scanner knows", "نمونه‌های تصادفی از همان رنج‌های CDNی که اسکنر تونل می‌شناسد");
            fa.insert ("Cloudflare", "کلادفلر");
            fa.insert ("15 ranges — the main Psiphon CDN fronting network", "۱۵ رنج — شبکهٔ اصلی فرونتینگ CDN سایفون");
            fa.insert ("Fastly", "فستلی");
            fa.insert ("19 ranges", "۱۹ رنج");
            fa.insert ("Akamai", "آکامای");
            fa.insert ("Curated edges + Iranian fronting SNIs", "لبه‌های گزینش‌شده + SNIهای فرونتینگ ایرانی");
            fa.insert ("CloudFront", "کلادفرانت");
            fa.insert ("AWS edge prefixes", "پیشوندهای لبهٔ AWS");
            fa.insert ("Bunny CDN", "بانی CDN");
            fa.insert ("Edge POPs used by the Android client", "لبه‌هایی که کلاینت اندروید استفاده می‌کند");
            fa.insert ("Sample size", "اندازهٔ نمونه");
            fa.insert ("How many random IPs to probe", "چند IP تصادفی بررسی شود");
            fa.insert ("Concurrency", "تعداد هم‌زمان");
            fa.insert ("Parallel probes — raise on fast connections", "بررسی‌های موازی — روی اینترنت سریع بیشتر کنید");
            fa.insert ("Custom ranges (optional)", "رنج‌های دلخواه (اختیاری)");
            fa.insert ("Custom SNI (optional)", "SNI دلخواه (اختیاری)");
            fa.insert ("Overrides the built-in fronting SNI names for this scan", "به‌جای SNIهای داخلی برای این اسکن استفاده می‌شود");
            fa.insert ("Cloudflare helper (optional)", "کمکی کلادفلر (اختیاری)");
            fa.insert ("Token + one-click worker deploy (panel style). The helper reports your nearest Cloudflare data center — it probes edges, it does not carry the tunnel: Psiphon fronting domains are managed on Psiphon servers.", "توکن + دیپلوی یک‌کلیکی ورکر (به سبک پنل‌ها). این کمکی نزدیک‌ترین دیتاسنتر کلادفلر شما را گزارش می‌دهد — فقط لبه‌ها را می‌سنجد و تونل را حمل نمی‌کند: دامنه‌های فرونتینگ سایفون روی سرورهای سایفون مدیریت می‌شوند.");
            fa.insert ("Cloudflare API token", "توکن API کلادفلر");
            fa.insert ("Token needs Account:Read + Workers Scripts:Edit. Stored locally, never sent anywhere but Cloudflare.", "توکن به Account:Read و Workers Scripts:Edit نیاز دارد. فقط محلی ذخیره می‌شود و جایی جز کلادفلر ارسال نمی‌شود.");
            fa.insert ("Helper worker", "ورکر کمکی");
            fa.insert ("Not deployed yet", "هنوز مستقر نشده");
            fa.insert ("Verify & deploy", "تأیید و استقرار");
            fa.insert ("Probe", "اندازه‌گیری");
            fa.insert ("Measure latency and data-center through the helper", "سنجش تأخیر و دیتاسنتر از طریق کمکی");
            fa.insert ("Verifying token and deploying…", "تأیید توکن و استقرار…");
            fa.insert ("Worker upload failed (need Workers Scripts:Edit permission)", "آپلود ورکر شکست خورد (مجوز Workers Scripts:Edit لازم است)");
            fa.insert ("Token verification failed", "تأیید توکن شکست خورد");
            fa.insert ("Could not list accounts", "دریافت حساب‌ها ممکن نشد");
            fa.insert ("No Cloudflare account on this token", "این توکن حساب کلادفلری ندارد");
            fa.insert ("Could not create a workers.dev subdomain", "ساخت زیردامنهٔ workers.dev ممکن نشد");
            fa.insert ("Helper worker deployed", "ورکر کمکی مستقر شد");
            fa.insert ("Deploy the helper worker first", "اول ورکر کمکی را مستقر کنید");
            fa.insert ("Probing…", "در حال اندازه‌گیری…");
            fa.insert ("Probe failed (HTTP/worker error)", "اندازه‌گیری شکست خورد (خطای HTTP/ورکر)");
            fa.insert ("Scan", "اسکن");
            fa.insert ("Start scan", "شروع اسکن");
            fa.insert ("Stop", "توقف");
            fa.insert ("Progress", "پیشرفت");
            fa.insert ("Idle", "بی‌کار");
            fa.insert ("alive", "زنده");
            fa.insert ("A scan is already running", "یک اسکن در حال اجراست");
            fa.insert ("No scan scope selected", "هیچ گستره‌ای برای اسکن انتخاب نشده");
            fa.insert ("No candidate IPs generated", "هیچ IP کاندیدی ساخته نشد");
            fa.insert ("Alive edges", "لبه‌های زنده");
            fa.insert ("Checked edges are dialed first on the next connect (fastest measured tunnel wins)", "لبه‌های علامت‌خورده در اتصال بعدی اول امتحان می‌شوند (سریع‌ترین تونل اندازه‌گیری‌شده برنده است)");
            fa.insert ("Select all", "انتخاب همه");
            fa.insert ("Check every alive edge", "علامت‌زدن همهٔ لبه‌های زنده");
            fa.insert ("Export config", "خروجی کانفیگ");
            fa.insert ("Save a shareable JSON with the selected edges", "ذخیرهٔ JSON قابل‌اشتراک با لبه‌های انتخاب‌شده");
            fa.insert ("%u selected", "%u انتخاب‌شده");
            fa.insert ("Use selected", "استفاده از انتخاب‌شده‌ها");
            fa.insert ("Scan finished: %u alive of %u probed", "اسکن تمام شد: %u زنده از %u بررسی‌شده");
            fa.insert ("%u edges applied — reconnect to use them", "%u لبه اعمال شد — برای استفاده دوباره وصل شوید");
            fa.insert ("Select at least one edge to export", "برای خروجی حداقل یک لبه انتخاب کنید");
            fa.insert ("Config exported", "کانفیگ خروجی گرفته شد");
            fa.insert ("%d saved candidate(s) active", "%d کاندید ذخیره‌شده فعال است");

            // v1.5.0 — Fake-IP default flip
            fa.insert ("Fake-IP DNS experiment under TUN", "آزمایش DNS فیک-IP زیر TUN");

            fa.insert ("Custom IP candidates for the built-in CDN scan (used in CDN Fronting mode)", "لیست IPهای دلخواه برای اسکن داخلی CDN (در حالت فرونتینگ CDN استفاده می‌شود)");
            fa.insert ("IP candidates", "کاندیدهای IP");
            fa.insert ("IPv4 or CIDR, separated by space, comma, or semicolon", "IPv4 یا CIDR، جدا‌شده با فاصله، ویرگول یا نقطه‌ویرگول");
            fa.insert ("Custom SNI", "SNI دلخواه");
            fa.insert ("Hostname used for scanning and edge overrides; leave empty to use the IP", "نام میزبان برای اسکن و Overrideهای لبه؛ برای استفاده از IP خالی بگذارید");
            // OSL (obfuscated server list) root URLs
            fa.insert ("OSL server list URLs", "آدرس‌های لیست سرور OSL");
            fa.insert ("Obfuscated server list root URLs — adds protocol-specific server buckets (incl. CDN fronting); leave empty to use the standard list", "آدرس‌های ریشه لیست سرورهای مبهم‌شده — باکت‌های سرور مخصوص هر پروتکل (از جمله فرونتینگ CDN) را اضافه می‌کند؛ برای استفاده از لیست استاندارد خالی بگذارید");
            // Stats panel: public IP + routing delivery
            fa.insert ("Public IP", "آی‌پی عمومی");
            fa.insert ("Routing", "مسیریابی");
            // Routing delivery states (Android parity: connect must carry app traffic)
            fa.insert ("No routing — apps bypass the tunnel", "بدون مسیریابی — ترافیک برنامه‌ها از تونل عبور نمی‌کند");
            fa.insert ("The tunnel is connected, but no routing method is enabled. Turn on TUN or the system proxy in Settings so browser traffic rides the tunnel.",
                      "تونل وصل است ولی هیچ روش مسیریابی‌ای فعال نیست. در تنظیمات، TUN یا پروکسی سیستم را روشن کنید تا ترافیک مرورگر از تونل عبور کند.");
            fa.insert ("TUN: preparing…", "TUN: در حال آماده‌سازی…");
            fa.insert ("TUN unavailable (sing-box not found)", "TUN در دسترس نیست (sing-box پیدا نشد)");
            fa.insert ("TUN blocked — admin permission not granted", "TUN مسدود شد — دسترسی مدیر تأیید نشد");
            fa.insert ("sing-box needs CAP_NET_ADMIN for whole-device routing. Approve the permission prompt, or run: sudo setcap cap_net_admin+ep '%s'",
                      "sing-box برای مسیریابی کل سیستم به CAP_NET_ADMIN نیاز دارد. پنجرهٔ درخواست دسترسی را تأیید کنید، یا اجرا کنید: sudo setcap cap_net_admin+ep '%s'");
            fa.insert ("TUN active", "TUN فعال");
            fa.insert ("TUN failed", "TUN ناموفق بود");
            fa.insert ("TUN interface missing", "اینترفیس TUN وجود ندارد");
            fa.insert ("TUN route not captured (default via %s)", "مسیر پیش‌فرض توسط TUN گرفته نشده (از طریق %s)");
            fa.insert ("TUN verified", "TUN تأیید شد");
            fa.insert ("TUN is up but traffic does not pass", "TUN بالا آمده ولی ترافیک عبور نمی‌کند");
            fa.insert ("The TUN device is up and owns the default route, but a probe packet did not come back. Try reconnecting, or report the session log.",
                      "دستگاه TUN بالا آمده و مسیر پیش‌فرض را در اختیار دارد، ولی بستهٔ آزمایشی برنگشت. اتصال را قطع و دوباره وصل کنید، یا لاگ نشست را گزارش دهید.");
            fa.insert ("sing-box was not found — this session routes through the system proxy only",
                       "sing-box پیدا نشد — این نشست فقط از طریق پروکسی سیستم مسیریابی می‌شود");
            fa.insert ("IPv6 route not captured — DNS may bypass the tunnel",
                       "مسیر IPv6 گرفته نشده — ممکن است DNS از تونل خارج شود");
            // Header bar: diagnostics bundle
            fa.insert ("Copy diagnostics report", "کپی گزارش عیب‌یابی");
            fa.insert ("Copy diagnostics report to clipboard (share it when reporting connection problems)",
                       "کپی گزارش عیب‌یابی در کلیپ‌بورد (هنگام گزارش مشکل اتصال، آن را بفرستید)");
            fa.insert ("Diagnostics copied to clipboard — also saved to %s",
                       "گزارش عیب‌یابی کپی شد — همچنین در %s ذخیره شد");
            // Settings: fast DNS (Fake-IP)
            fa.insert ("Fast DNS (Fake-IP)", "DNS سریع (Fake-IP)");
            fa.insert ("Answer DNS instantly and resolve domains at the tunnel exit — like Android. Turn off only if an app misbehaves",
                       "پاسخ DNS آنی و تحلیل نام دامنه در سرور خروجی تونل — مثل اندروید. فقط اگر برنامه‌ای ناسازگاری نشان داد خاموشش کنید");
            // TUN watchdog (v1.5.1): sing-box supervision + system-proxy fallback
            fa.insert ("TUN routing lost", "مسیریابی TUN از دست رفت");
            fa.insert ("TUN routing lost — sing-box is no longer running (%s)",
                       "مسیریابی TUN از دست رفت — sing-box دیگر اجرا نمی‌شود (%s)");
            fa.insert ("no exit details", "بدون جزئیات خروج");
            fa.insert ("TUN interface vanished — restarting sing-box",
                       "اینترفیس TUN ناپدید شد — sing-box دوباره راه‌اندازی می‌شود");
            fa.insert ("the system took the TUN route back — reapplying it",
                       "سیستم مسیر TUN را پس گرفت — دوباره اعمال می‌شود");
            fa.insert ("%s — restarting sing-box (%d/%d)",
                       "%s — راه‌اندازی مجدد sing-box (%d/%d)");
            fa.insert ("sing-box memory usage is high (%s MB) — restarting it cleanly",
                       "مصرف حافظهٔ sing-box بالاست (%s مگابایت) — به‌صورت تمیز راه‌اندازی مجدد می‌شود");
            fa.insert ("TUN could not be restored — switching to the system proxy so traffic keeps flowing",
                       "TUN بازگردانده نشد — برای ادامهٔ جریان ترافیک به پروکسی سیستم سوئیچ می‌شود");
            fa.insert ("System proxy fallback (TUN lost)", "پروکسی سیستم جایگزین (TUN از دست رفت)");
            fa.insert ("TUN could not be restored and the system proxy failed: %s",
                       "TUN بازگردانده نشد و پروکسی سیستم هم شکست خورد: %s");
            // Scanner (v1.5.1 fixes)
            fa.insert ("Scan stopped", "اسکن متوقف شد");
            fa.insert ("TCP + TLS handshake succeeded", "اتصال TCP و دست‌دادن TLS موفق بود");
            fa.insert ("TCP opened but the TLS handshake failed — not usable for fronting",
                       "TCP باز شد ولی دست‌دادن TLS شکست خورد — برای فرونتینگ قابل استفاده نیست");
            fa.insert ("TLS failed", "TLS ناموفق");
            // Windows port
            fa.insert ("%s was not found. Put it next to the app, install it on PATH, or set a custom core path.",
                       "%s پیدا نشد. آن را کنار برنامه بگذارید، روی PATH نصب کنید، یا مسیر دلخواه هسته را تنظیم کنید.");
            fa.insert ("Failed to start sing-box: %s. On Windows, TUN mode requires running Forough as Administrator (wintun adapter creation) and wintun.dll next to sing-box.exe.",
                       "شروع sing-box ناموفق بود: %s. در ویندوز، حالت TUN به اجرای فروغ با دسترسی Administrator نیاز دارد (ساخت آداپتور wintun) و wintun.dll باید کنار sing-box.exe باشد.");
            fa.insert ("Route all traffic through sing-box into the local SOCKS proxy — requires running Forough as Administrator (wintun)",
                       "مسیریابی کل ترافیک از sing-box به پروکسی SOCKS محلی — نیاز به اجرای فروغ با دسترسی Administrator دارد (wintun)");
            fa.insert ("TUN mode on Windows needs Administrator — right-click Forough and choose “Run as administrator”, or enable the system proxy instead",
                       "حالت TUN در ویندوز به دسترسی Administrator نیاز دارد — روی فروغ راست‌کلیک کنید و «Run as administrator» را انتخاب کنید، یا به‌جای آن پروکسی سیستم را فعال کنید");
        }
    }
}
