# Release: Android 14 on the internal eMMC (end goal)

**Priority order (owner, 2026-11-24) - guard against scope creep:**
1. Feature-complete ROM on the card (HCT port: keys, Bluetooth, CAN, radio, cameras; GApps; GPS/audio).
2. Release hardening + the eMMC install.
3. Niceties: the launcher (`docs/homescreen.md`): map/media/radar, theming, valet mode, car settings.
4. Long-term blob-free track (end of this file) - only after the above.

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

## Long-term track (after the Android 14 release): blob-free on mainline
Today the hardware layer is blobs: the prebuilt 4.19 kernel (no source), ~580 ELF files in the Android 10 vendor
partition, and the HCT apps. RK3399 is well supported upstream, so most of that has open replacements, the
route GloDroid takes (AOSP on mainline, RK3399 boards among its targets):

| Today | Open replacement |
|---|---|
| kernel 4.19 binary | mainline Linux |
| Mali userspace + `mali_kbase` | Mesa Panfrost (Midgard; confirm the exact GPU: RK3399 ships Mali-T860 MP4, our docs say T620) |
| Rockchip HWC / gralloc | drm_hwcomposer + minigbm/gbm_mesa |
| Rockchip VPU / OMX | hantro / rkvdec V4L2 + Codec2 V4L2 HAL |
| WiFi RTL8188, touch goodix | `rtl8xxxu`, `goodix` |
| audio HAL | ALSA + generic AOSP audio HAL (if the codec has a mainline driver) |
| **mtc drivers (MCU)** | **reverse-engineer the MCU UART protocol** (known so far: the `/dev/mtc-car` ioctl command strings, the 0xFA frame format, the boot reports that power USB, the key path) and reimplement it as a mainline driver or a userspace daemon; tuner, DSP and CAN sit behind the MCU |

First step when this starts: a mainline kernel booting from the SD card under the same card-only safety model,
then measure display, GPU, WiFi, touch, audio, and the MCU protocol one by one.
