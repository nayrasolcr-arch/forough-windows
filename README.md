# Forough — Windows Client

<p align="center">
  <img src="docs/hero.png" alt="Forough — a bright window to the open internet" width="560" />
</p>

<p align="center">
  <b>Forough — a bright window to the open internet</b><br/>
  فروغ؛ پنجره‌ای روشن به اینترنت آزاد
</p>

**Forough** is a fast, beautiful desktop VPN client for the open internet — built on the Psiphon network, with a native GTK4 interface, full Persian RTL support, a manual CDN edge scanner, live traffic graph, built-in speed test, a TUN watchdog with auto-restart, and an automatic system-proxy fallback.

This repository holds the **native Windows client**: the same GTK4/libadwaita codebase as [forough-linux](https://github.com/nayrasolcr-arch/forough-linux), compiled for Windows 10/11 (x86_64) with MSYS2 MinGW64 and shipped as a **portable zip** — no installer, no admin rights needed except for TUN mode.

> **Disclaimer:** This application is NOT developed, endorsed, sponsored, or affiliated with Psiphon Inc. in any way. Psiphon is a trademark of Psiphon Inc. — learn more at [psiphon.ca](https://psiphon.ca).

---

## Features

- **One-click connect / disconnect** with live status: active protocol, tunnel state, session duration, exit IP + country flag
- **Protocol selection** mirroring the Android client: *Auto / Conduit (in-proxy) / Direct / CDN fronting*, plus DisableTactics and full CDN-fronting overrides (custom edge IPs + SNI)
- **Personal conduits** — private in-proxy pairing via compartment ID
- **Beast mode** (aggressive establishment: all protocols × all servers, 30+ workers)
- **Egress region selection**, upstream proxy support, LAN sharing mode
- **Whole-device TUN routing** via sing-box (`auto_route` + `strict_route` over wintun) — the desktop equivalent of Android's VPN mode
- **TUN watchdog** — checks the route every 5 seconds, restarts sing-box automatically (with a memory guard), and **falls back to the system proxy** when TUN cannot be established
- **Automatic system-proxy fallback** — WinInet user proxy (`127.0.0.1:8081`) with snapshot/restore on disconnect, no logoff needed
- **Manual CDN edge scanner** — per-edge TCP/TLS latency probe with a helper-worker option (Cloudflare)
- **Live traffic graph** — polls the local sing-box clash API (`/traffic`) every second
- **Built-in speed test** — TTFB + throughput probes through your own tunnel
- **Diagnostics report** — one file with `ipconfig /all`, `route print -4`, registry proxy state, engine logs and more, for support requests
- **In-app server list refresh** and obfuscated server list (OSL) support
- **Persian (RTL) and English interface**, chosen automatically from your Windows display language

## Download

Grab the latest portable build from the [Releases](https://github.com/nayrasolcr-arch/forough-windows/releases) page:

- `Forough-2.0.0-windows-x86_64.zip` — the full portable bundle
- `SHA256SUMS` — verify your download

## Portable install

1. **Unzip** the archive anywhere you like (e.g. `C:\Tools\Forough`). No installer, no registry changes, no services.
2. **Run `forough.exe`**.
3. **TUN mode needs Administrator** on the first run: the wintun virtual adapter can only be created by an elevated process. Right-click `forough.exe` → *Run as administrator* when you want whole-device routing. Without elevation, Forough still connects and **automatically falls back to the system proxy**.
4. Keep the files together: `wintun.dll`, `psiphon-tunnel-core-x86_64.exe` and `sing-box.exe` ship next to `forough.exe` and must stay next to it.
5. Settings are stored under `%LOCALAPPDATA%\Forough` (GLib keyfile backend) — deleting the folder fully resets the app.

Windows 10 1803+ is required (ships `curl.exe`, used for probes; everything degrades gracefully if it is missing).

## How it works

```
┌────────────────────────── forough.exe (GTK4 / libadwaita) ──────────────────────────┐
│                                                                                     │
│  connection panel · settings · scanner · speed test · traffic graph · diagnostics   │
│        │                                                                            │
│        ├── spawns ──► psiphon-tunnel-core-x86_64.exe  (Psiphon network engine)      │
│        │                 · HTTP proxy 127.0.0.1:8081                                │
│        │                 · SOCKS     127.0.0.1:1081                                 │
│        │                                                                            │
│        └── TUN ────► sing-box.exe  (wintun adapter "forough0")                      │
│                          · auto_route + strict_route → whole-device routing         │
│                          · forwards everything into the local SOCKS proxy           │
│                          · clash API 127.0.0.1:9090 → live traffic graph            │
│                                                                                     │
│  fallback: WinInet system proxy (HKCU Internet Settings) → 127.0.0.1:8081           │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

- `psiphon-tunnel-core` (the official Psiphon engine, Forough fork) does all the heavy lifting: meek/fronting transports, obfuscation, region routing, CDN scanning.
- `sing-box` is used **only** as a TUN router: it captures the machine's traffic into the local SOCKS proxy exposed by the engine. On Windows it drives the wintun adapter itself (no `netsh`/`route` surgery by the GUI).
- The GUI supervises both processes: 5-second TUN watchdog with automatic restart, memory guard, end-to-end egress probes, and a WinInet system-proxy fallback when TUN is not available (e.g. non-admin session).

## Build from source (MSYS2)

1. Install [MSYS2](https://www.msys2.org/), then in a **MINGW64** shell:

   ```bash
   pacman -S --needed \
     mingw-w64-x86_64-gtk4 mingw-w64-x86_64-libadwaita mingw-w64-x86_64-json-glib \
     mingw-w64-x86_64-vala mingw-w64-x86_64-gcc mingw-w64-x86_64-binutils \
     mingw-w64-x86_64-meson mingw-w64-x86_64-pkgconf mingw-w64-x86_64-nodejs
   ```

2. Build and stage the GUI:

   ```bash
   cd forough-windows/gui
   meson setup build --prefix="$(pwd -W)/stage" --buildtype=release
   ninja -C build
   ninja -C build install
   ```

3. Place the engines next to `stage/bin/forough.exe`:
   - `psiphon-tunnel-core-x86_64.exe` — build the [Forough tunnel-core fork](https://github.com/nayrasolcr-arch/psiphon-tunnel-core) at rev `90c30c856e` with `GOOS=windows GOARCH=amd64` (the exact recipe, including buildinfo ldflags, lives in [`.github/workflows/build-windows.yml`](.github/workflows/build-windows.yml))
   - `sing-box.exe` — sing-box 1.14.3 built with `-tags "with_gvisor,with_utls,with_clash_api"`
   - `wintun.dll` — from [wintun-0.14.1.zip](https://www.wintun.net/builds/wintun-0.14.1.zip), `bin/amd64/wintun.dll`

   Or simply download the CI bundle from Releases and replace `forough.exe` with your own build.

## Sibling clients

- **Linux (GTK4):** [nayrasolcr-arch/forough-linux](https://github.com/nayrasolcr-arch/forough-linux)
- **Android:** [nayrasolcr-arch/forough-android](https://github.com/nayrasolcr-arch/forough-android)

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). Upstream components keep their own licenses: `psiphon-tunnel-core` (Psiphon Inc. license), `sing-box` (GPL-3.0), `wintun` (wintun.net redistribution terms) — details in [NOTICE](NOTICE).

---

<div dir="rtl">

# فروغ — کلاینت ویندوز

**فروغ** یک کلاینت VPN دسکتاپی سریع و زیبا برای دسترسی آزاد به اینترنت است؛ ساخته‌شده روی شبکه سایفون با رابط بومی GTK4، پشتیبانی کامل راست‌به‌چپ فارسی، اسکنر دستی لبه‌های CDN، نمودار زنده ترافیک، تست سرعت داخلی، نگهبان TUN با ری‌استارت خودکار و مسیر پشتیبان پراکسی سیستم.

این مخزن **کلاینت بومی ویندوز** فروغ است — همان کدبیس GTK4/libadwaita ی [forough-linux](https://github.com/nayrasolcr-arch/forough-linux) — که برای ویندوز ۱۰/۱۱ (x86_64) با MSYS2 MinGW64 کامپایل شده و به‌صورت **زیپ پرتابل** منتشر می‌شود؛ بدون نصب‌کننده و بدون نیاز به دسترسی مدیر، به‌جز حالت TUN.

> **سلب مسئولیت:** این برنامه به هیچ‌وجه توسط Psiphon Inc. توسعه نیافته، تأیید یا حمایت نمی‌شود و وابسته به آن نیست. برای اپ رسمی به [psiphon.ca](https://psiphon.ca) مراجعه کنید.

## قابلیت‌ها

- اتصال/قطع با یک کلیک + وضعیت زنده: پروتکل فعال، حالت تونل، مدت اتصال، IP خروجی و پرچم کشور
- انتخاب پروتکل مطابق اپ اندروید: **خودکار / کانالیوت (in-proxy) / مستقیم / فرونتینگ CDN** + overrides کامل CDN (آی‌پی لبه و SNI دلخواه)
- **کانالیوت شخصی** با شناسهٔ بخش (compartment ID)
- **حالت بیست** (برقراری تهاجمی: همهٔ پروتکل‌ها × همهٔ سرورها با ۳۰+ کارگر)
- انتخاب منطقهٔ خروجی، پروکسی بالادستی، حالت اشتراک LAN
- **مسیریابی TUN کل دستگاه** با sing-box (`auto_route` + `strict_route` روی وین‌تان) — معادل دسکتاپیِ VPN اندروید
- **نگهبان TUN** — بررسی مسیر هر ۵ ثانیه، ری‌استارت خودکار sing-box (به‌همراه نگهبان حافظه) و **بازگشت خودکار به پروکسی سیستم** وقتی TUN برقرار نشود
- **پشتیبان پروکسی سیستم** — پروکسی WinInet (`127.0.0.1:8081`) با اسنپ‌شات و بازگردانی پس از قطع، بدون خروج از ویندوز
- **اسکنر دستی لبه‌های CDN** — تأخیر TCP/TLS هر لبه، با گزینهٔ ورکر کمکی کلادفلر
- **نمودار زندهٔ ترافیک** — پرس‌وجوی هر یک‌ثانیه از clash API محلی sing-box
- **تست سرعت داخلی** — اندازه‌گیری TTFB و پهنای‌باند از مسیر تونل خودتان
- **گزارش عیب‌یابی** — `ipconfig /all`، `route print -4`، وضعیت پروکسی رجیستری، لاگ هسته‌ها و… در یک فایل
- به‌روزرسانی لیست سرور داخل برنامه + پشتیبانی از لیست سرور آشفته (OSL)
- رابط **فارسی (راست‌به‌چپ) و انگلیسی** — انتخاب خودکار بر اساس زبان ویندوز

## دانلود و نصب پرتابل

1. آخرین نسخه را از صفحهٔ [Releases](https://github.com/nayrasolcr-arch/forough-windows/releases) بگیرید (`Forough-2.0.0-windows-x86_64.zip`).
2. زیپ را هر جا خواستید باز کنید — بدون نصب‌کننده، بدون تغییر رجیستری، بدون سرویس.
3. **`forough.exe`** را اجرا کنید.
4. **حالت TUN به دسترسی Administrator نیاز دارد**: ساخت آداپتور مجازی وین‌تان فقط توسط فرآیندِ با دسترسی مدیر ممکن است. برای مسیریابی کل دستگاه، روی `forough.exe` راست‌کلیک و *Run as administrator* را بزنید. بدون این دسترسی هم فروغ وصل می‌شود و **خودکار به پروکسی سیستم برمی‌گردد**.
5. فایل‌ها را کنار هم نگه دارید: `wintun.dll`، `psiphon-tunnel-core-x86_64.exe` و `sing-box.exe` باید کنار `forough.exe` بمانند.
6. تنظیمات در `%LOCALAPPDATA%\Forough` ذخیره می‌شود؛ پاک‌کردن آن پوشه برنامه را کاملاً ریست می‌کند.

ویندوز ۱۰ (نسخهٔ ۱۸۰۳) به بالا لازم است (`curl.exe` برای اندازه‌گیری‌ها؛ در نبودش همه‌چیز با افت کیفیت محترمانه از کار می‌افتد).

## چطور کار می‌کند

- `psiphon-tunnel-core` (هستهٔ رسمی سایفون، فورک فروغ) همهٔ کار سنگین را انجام می‌دهد: ترنسپورت‌های meek/فرونتینگ، مبهم‌سازی، مسیریابی منطقه‌ای و اسکن CDN.
- `sing-box` **فقط** به‌عنوان روتر TUN به‌کار می‌رود: ترافیک کل دستگاه را به پروکسی SOCKS محلیِ هسته می‌فرستد. در ویندوز خودش آداپتور وین‌تان را می‌سازد (GUI هیچ دستکاری `netsh`/`route` نمی‌کند).
- GUI هردو فرآیند را نظارت می‌کند: نگهبان ۵ ثانیه‌ای با ری‌استارت خودکار، نگهبان حافظه، پروب سرتاسری خروجی، و فال‌بک پروکسی WinInet وقتی TUN در دسترس نباشد (مثلاً نشست بدون دسترسی مدیر).

## ساخت از سورس (MSYS2)

در شل **MINGW64**:

```bash
pacman -S --needed mingw-w64-x86_64-{gtk4,libadwaita,json-glib,vala,gcc,binutils,meson,pkgconf,nodejs}

cd forough-windows/gui
meson setup build --prefix="$(pwd -W)/stage" --buildtype=release
ninja -C build && ninja -C build install
```

سپس هسته‌ها را کنار `stage/bin/forough.exe` بگذارید — دستور دقیق ساخت `psiphon-tunnel-core` و `sing-box` در [`.github/workflows/build-windows.yml`](.github/workflows/build-windows.yml) آمده است، یا بستهٔ آمادهٔ Releases را دانلود کنید و فقط `forough.exe` خودتان را جایگزین کنید.

## پروژه‌های خواهر

- **لینوکس (GTK4):** [nayrasolcr-arch/forough-linux](https://github.com/nayrasolcr-arch/forough-linux)
- **اندروید:** [nayrasolcr-arch/forough-android](https://github.com/nayrasolcr-arch/forough-android)

## مجوز

GPL-3.0-or-later — فایل [LICENSE](LICENSE). اجزای بالادستی مجوز خودشان را دارند: `psiphon-tunnel-core` (مجوز Psiphon Inc.)، `sing-box` (GPL-3.0)، `wintun` (شرایط بازنشر wintun.net) — جزئیات در [NOTICE](NOTICE).

</div>
