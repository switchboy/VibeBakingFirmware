# Getting a shell on the head unit (Termux)

Play-Store Termux refuses to install on these head units (Google's compatibility filter uses the
device's reported features/ABI, and HU firmware reports odd values). Sideloading a **GitHub/F-Droid
build** bypasses that filter.

Downloads are kept **outside the repo** in `/run/media/Daan/Opslagmonster/termux-apks/`
(verify against the published sha256: `termux-app_v0.118.3+github-debug_sha256sums`).

| APK | Target | When to use |
|---|---|---|
| `termux-app_v0.118.3+github-debug_arm64-v8a.apk` (35 MB) | Android 7+, arm64-v8a only | first choice on a PX6 (arm64) |
| `termux-app_v0.118.3+github-debug_universal.apk` (112 MB) | Android 7+, all ABIs | if the unit reports the wrong ABI |
| `com.termux_108.apk` (F-Droid, ~90 MB) | older build, multi-ABI | if 0.118.x is rejected or its bootstrap fails |
| `com.termux_104.apk` (F-Droid, ~85 MB) | very old, multi-ABI | last resort for ancient ROMs |

## Install
1. Copy the APK + `allinone.sh` onto a USB stick or SD card (FAT32).
2. On the unit: open the file manager → tap the APK → allow "unknown sources" if asked.
   (These ROMs usually have no Play Store; sideload is the only route.)
3. First launch downloads the Termux bootstrap — the unit needs internet (its WiFi usually has it,
   that is also how the OTA/update checks work). If the bootstrap download fails, the older F-Droid
   builds above are the fallback; if the unit has no internet at all, use adb instead
   (`adb push allinone.sh` + `adb shell sh /sdcard/allinone.sh`).

## Run the probe
```sh
sh allinone.sh      # writes probe.md next to the script, uploads to 192.168.1.161:8765
```
Termux on Android 10 needs `termux-setup-storage` once if you want the report on shared storage;
without it the report lands in Termux's private home and is uploaded over LAN anyway.

## Notes
- Termux is not rooted and never roots the device; the probe runs as `untrusted_app`. Sections that
  need privileges will fail unless the firmware is permissive/rooted — that is expected.
- Keep these APKs out of git (they are not part of the firmware work).
