# Release: Android 14 on the internal eMMC (end goal)

The end goal (owner, 2026-11-24): once the card build is feature complete, run it from the unit's internal
eMMC as a full replacement of the stock ROM. Until then the eMMC is never written; the card is the test bed.

## Gate: feature complete on the card
- [ ] HCT framework port: hardware keys, radio, CAN bus, HCT Bluetooth (calls, phonebook), front/rear camera
      (incl. reverse-gear trigger), AV-in/DVD video (`libcvbs_jni.so`), MFI/CarPlay bridge if wanted
- [ ] GApps (Play services, Play Store, Maps)
- [ ] The home screen / launcher (`docs/homescreen.md`), incl. valet mode and the car settings
- [ ] GPS, audio paths, sensors checked
- [ ] Several days of daily use on the card without regressions

## Release hardening
- [ ] SELinux **enforcing**, with policy for the HU additions (`hu-mtc-param`, `hu-netbpfload`, `carservice`,
      HCT apps, the ttyV/mtc device nodes)
- [ ] LineageOS Trust warnings back on (delete the `trust_warnings` row in `content://lineagesettings/secure`)
- [ ] `ro.adb.secure=1` and adb over TCP off by default (developer option to enable)
- [ ] The PID-1 wrapper (`hu-card-arm`) and the boot crasher removed from the release boot image
- [ ] Remove the bring-up workarounds that only made logging possible; keep the real fixes (MCU boot reports,
      WiFi/VINTF, ueventd, bpf loader, composer, cgroups)
- [ ] Bring-up settings applied by hand moved into the image or a first-boot step (permission grants,
      appops, navbar, status bar icons, stay-awake policy)

## eMMC install path
- [ ] Byte-exact stock backup verified and stored (exists, **D40**; re-verify before the install)
- [ ] Boot image with the eMMC first-stage fstab (eMMC partitions keep their own names `super`/`metadata`,
      no `androidboot.super_partition` override)
- [ ] A recovery for the unit that can install update zips (a LineageOS recovery built from the device tree)
- [ ] The eMMC super sized for the payload incl. GApps (the stock eMMC super is 3.1 GB)
- [ ] Install procedure written and rehearsed (write order, verification, rollback with the stock backup, the
      MCU/bootloader left untouched)
- [ ] Rollback rehearsed: restore stock Android 10 from the backup
