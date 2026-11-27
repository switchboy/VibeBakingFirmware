# ZLink porting dossier (Android 10 stock firmware -> Android 14 plan)

Read-only investigation of `/run/media/Daan/Opslagmonster/a14-work/scratch/zlink/` (`files/`, `smali/`)
plus `analysis/system_init.hct.rc`. Tools used: `strings`, `readelf`, `nm`, `grep`, baksmali output as text.
No adb, no network, no git, no writes outside this file. Evidence format: file + smali class/method + line,
or `strings`/`nm`/`readelf` output. `UNKNOWN` = the inputs do not answer it; `GUESS` = interpretation.

Known facts supplied by the parent engineer (not re-derived here): `carplay.type=1` triggers `z-link.sh`
from stock init (insmod `usb_f_iap2.ko`, configfs functions `iap.gs0` + `ncm.gs1`, then loops
`z-link -c hengchangtong` with `LD_LIBRARY_PATH=/data/data/com.zjinnova.zlink/lib`); the real implementation
is the app `com.zjinnova.zlink` (encrypted /data, not in the stock system image). On the A14 ROM:
`/dev/zjinnova_iap` + `/dev/usb_accessory` exist, `mtc_mfi_service` runs, `persist.sys.zlink.*` /
`rw.zlink.*` are set, `carplay.type=1`, ZLink app NOT installed.

## 1. Framework hooks (framework.jar / services.jar / wifi-service.jar)

(IN PROGRESS - appended as investigated.)
