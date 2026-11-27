# Task (local model): ZLink porting dossier - read-only investigation

Goal: a precise inventory of everything the stock Android 10 firmware does for ZLink (CarPlay / Android Auto by
ZJinnova), so the parent engineer can plan the Android 14 port. **Read-only. No adb, no network, no git, never write
under the repo except the one output file.** Write findings into the output file AS YOU GO (long answers get cut off).

## Inputs (all local, already extracted by the parent engineer)

`/run/media/Daan/Opslagmonster/a14-work/scratch/zlink/`
* `files/` - from the stock system image: `z-link` (11 KB loader), `z-link.sh`, `z-mdnsd`, `mdnsd.rc`, `fscsdkbw123`
  (unrelated BT daemon - ignore), `libsurfaceflinger.so`, `libaudioflinger.so`, `libstagefright.so` (arm64),
  `framework.jar`, `services.jar`, `wifi-service.jar`, and the HCT APKs HCTExtAppDocker, HCTManagerService, HCTCanBus,
  HCTBlueToothManager, HCTCarTouch, HCTFactorySettings.
* `smali/<name>/` - baksmali output of every jar/apk above.
* Stock init: `/run/media/Daan/Opslagmonster/VibeBakingFirmware/analysis/system_init.hct.rc` (lines ~290-310: `carplay.type`
  triggers `z-link.sh`).
* Facts already established (do not re-derive): `carplay.type=1` on this unit starts `z-link.sh`, which insmods
  `/vendor/lib/modules/usb_f_iap2.ko`, creates configfs gadget functions `iap.gs0` and `ncm.gs1`, and loops
  `z-link -c hengchangtong` with `LD_LIBRARY_PATH=/data/data/com.zjinnova.zlink/lib` - the real implementation is the
  ZLink app `com.zjinnova.zlink` (not in the stock system image; it lived in the encrypted /data). On our Android 14 ROM:
  `/dev/zjinnova_iap` and `/dev/usb_accessory` exist, `mtc_mfi_service` (vendor HAL `android.hardware.mtc.mfi@1.0`)
  runs, `persist.sys.zlink.*` / `rw.zlink.*` properties are set, `carplay.type=1`, the ZLink app is NOT installed.

## Questions to answer (with evidence: file + smali class/method, or symbol, or exact string)

1. **Framework hooks**: every smali file in `smali/framework`, `smali/services`, `smali/wifi-service` that mentions
   zlink/zjinnova: class, method, what it does (e.g. a broadcast, a permission bypass, a package whitelist, input/display
   handling). Quote the relevant smali lines (max ~15 per hook).
2. **Native library hooks**: in `libsurfaceflinger.so`, `libaudioflinger.so`, `libstagefright.so`: every string containing
   zlink/zjinnova/carplay (use `strings -n 4` + grep), and the exported/imported symbols near them (`nm -D` /
   `readelf -Ws`). What could each be for (screen capture, audio routing, codec)? Mark guesses as GUESS.
3. **The loader**: `z-link` and `z-mdnsd`: `strings`, `readelf -d` (NEEDED libs), `readelf -Ws` (imports). Which libraries
   does it dlopen / need from `/data/data/com.zjinnova.zlink/lib`? Which device nodes, sockets, properties, config paths?
4. **HCT apps**: in each HCT smali tree, every zlink/zjinnova/carplay reference: what it does (start/stop, intents,
   broadcasts, settings keys, MCU commands like `carplay`/`mfi`, audio channel names). HCTFactorySettings has ~27 files:
   summarise the settings it exposes (carplay type values and their meaning if visible).
5. **Properties**: every `carplay.*`, `*.zlink.*`, `sys.usb.*` property read or written anywhere above, with reader/writer.
6. **Gap list for Android 14**: given the above, what our ROM lacks (e.g. the framework hooks, the service rc entry,
   SELinux domain `shell` for z-link, the configfs gadget functions, the app itself). One line each, with the evidence.

## Output
`/run/media/Daan/Opslagmonster/VibeBakingFirmware/docs/zlink-dossier.md`, sections 1-6 as above, then a 10-line summary.
Write UNKNOWN where the evidence does not answer a question - never guess silently. Final reply: the summary only.
