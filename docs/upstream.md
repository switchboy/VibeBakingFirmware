# Upstream candidates — register, not a TODO list of PRs

Written Nov 9. **Nothing here has been submitted.** No Gerrit change, no PR, no fork push. The point is
to separate work that would help other Rockchip/LineageOS/AOSP users from work that only makes *our*
head unit run, and to record what upstream would demand before any of it is presentable.

Two research passes produced this: one inventorying the repo (candidate by file), one checking upstream
facts online. URLs below were opened by that pass on Nov 9; where it could not verify something that is
said plainly.

## What upstream actually requires (verified Nov 9)

* **Lineage review is Gerrit, not GitHub.** `review.lineageos.org`; Contributor Agreement first, then
  `repo start` + `repo upload`. Device/vendor/wiki repos have GitHub PRs disabled.
  <https://wiki.lineageos.org/how-to/submitting-patches>, <https://wiki.lineageos.org/contributing.html>
* **Lineage device trees are per-project repos** (`android_device_<vendor>_<codename>`, ~1493 repos;
  `android_kernel_*`, ~597). There is **no** `LineageOS/android_devices` umbrella, and **zero RK3399
  repos in the LineageOS org** — so there is no upstream Rockchip device tree or kernel to inherit into.
  A generic change would land in `device/lineage/*` or `vendor/lineage/config/*`
  (`LineageOS/android_device_lineage_car` has `lineage_car.mk` + `lineage_car_vendor.mk`, inherited by
  `vendor/lineage/config/common_car.mk` → `common.mk`, fetched on branch `lineage-21.0`).
* **Lineage charter** gates everything: SELinux **enforcing**, no prebuilt kernel (non-GKI), no blobs
  committed (a working extraction script is mandatory), no modified prebuilt vendor image,
  `lineage.dependencies` may not point outside the LineageOS org, Android contributions Apache-2.0 and
  **Category A, never Category X**, new files copyright "(C) [YEAR] The LineageOS Project" (additive,
  never removing upstream copyrights). Deviations must be documented on the device's wiki page.
  <https://raw.githubusercontent.com/LineageOS/charter/main/device-support-requirements.md>,
  <https://wiki.lineageos.org/proprietary_blobs.html>
* **AOSP** still takes contributions via CLA + Gerrit (`android-review.googlesource.com`, OWNERS-guarded;
  `build/make` and `tools/releasetools`/`tools/signapk` have OWNERS files). Feature-release-flags are not
  accepted. For `external/*` projects AOSP says **fix upstream first**, then tell the Android maintainers.
  <https://source.android.com/docs/setup/contribute>,
  <https://source.android.com/docs/setup/contribute/submit-patches>,
  <https://source.android.com/docs/setup/contribute/contribute-upstream>,
  <https://source.android.com/docs/setup/contribute/licenses>
* **libdrm ownership**: upstream is freedesktop/drm (`https://gitlab.freedesktop.org/mesa/drm`), AOSP
  imports it (`platform/external/libdrm`, `METADATA` = `third_party { license_type: NOTICE }`).
  Upstream and AOSP **already export** `drmModeAddFB2` and `drmModeAddFB2WithModifiers`.
  `LineageOS/android_external_libdrm` exists but is dead (one branch `lineage-15.1`, last push 2018-07-14,
  PRs disabled) — Lineage 21 builds libdrm from the AOSP import, so a libdrm patch cannot go to Lineage.
* **Realtek WiFi HAL is already upstream in Lineage**: `LineageOS/android_hardware_realtek`
  `wlan/wifi_hal/Android.bp` has `libwifi-hal-rtk` with `vendor_available: true` and
  `compile_multilib: "both"`, SPDX Apache-2.0 header, repo active (pushed 2026-09-05). AOSP has no
  Realtek HAL at all (`platform/hardware/realtek` → 404) and its generic `libwifi-hal` is
  `compile_multilib: "first"`.
* **Docs homes**: Lineage wiki is a Gerrit-reviewed repo (`LineageOS/lineage_wiki`, push
  `HEAD:refs/for/main`, BuildKite votes Verified with a preview link) —
  <https://wiki.lineageos.org/contributing_wiki.html>. Its page inventory has **no** page about zip
  EOCD-comment signature checks or Rockchip AVB; the nearest existing pages are *Signing Builds* and
  *Verifying Build Authenticity*, and there is a "quirks" precedent (`/quirks/snet/`). AOSP normative
  references: <https://source.android.com/docs/core/ota/sign_builds> (recovery checks `/res/keys`, system
  checks `/system/etc/security/otacerts.zip`, `PRODUCT_EXTRA_RECOVERY_KEYS`),
  <https://source.android.com/docs/security/features/verifiedboot/boot-flow>.
  There is no `README.md` in AOSP `tools/releasetools` or `tools/signapk` (both 404).
* **U-Boot / SD-boot docs** belong in mainline U-Boot (`docs/board/rockchip/rockchip.html` — RK3399,
  TF-A `PLAT=rk3399`, SD boot `dd if=u-boot-rockchip.bin of=/dev/sda seek=64`, MaskROM fastboot
  `2207:330c`; the page itself carries a "TODO – Document SPI flash boot"), staged Rockchip commits in
  `github.com/rockchip-linux/u-boot` (active, default `next-dev`), community debrick/maskrom notes on
  Radxa/FriendlyElec wikis. `github.com/rockchip-android` BSP repos are stale (2018).
  <https://docs.u-boot.org/en/latest/board/rockchip/rockchip.html>
* **Not verified**: no written Lineage rule banning committed platform-signed APKs (only blob provenance,
  authorship and licence category are documented); the Apache-2.0 attribution wording above is taken from
  the AOSP licenses page, not from the licence text; no repo named `Rockchip-Debrick`/`rk-debrick` was
  found (search hits only appeared in snippets, not opened).

## Candidate register, ranked

| # | candidate | lives in our repo | generic? | where it would go | kind | acceptance |
|---|---|---|---|---|---|---|
| 1 | `PRODUCT_PACKAGES += update_engine_sideload` for non-A/B recovery | `device.mk:109` | generic | Lineage device tree / `device/lineage` | bug fix | **high** |
| 2 | Realtek WiFi wiring for Android 14 (`BOARD_WLAN_DEVICE := realtek`, quoted `WIFI_DRIVER_MODULE_*`, `WPA_SUPPLICANT_VERSION`, `WIFI_HIDL_UNIFIED_SUPPLICANT_SERVICE_RC_ENTRY`) | `BoardConfig.mk:72-101` | generic | Lineage device tree + wiki bring-up note | device-config + trap doc | medium-high |
| 3 | Loading kernel modules without Rockchip's patched `init` (`init.insmod.cfg` is absent from Lineage init) | `configs/hu_insmod.sh`, `configs/init.hu.rc` | generic pattern | Lineage device tree (`device/rockchip/common` does not exist upstream) + docs | device-config | medium-high |
| 4 | Zip EOCD-comment signature verification by vendor recoveries (`signapk -w`, PKCS#7 not in `META-INF/`) | `scripts/sign_hu_package.sh`, `tools/zip_comment_sig.py`, `docs/flash.md:81-91` | generic trap | Lineage wiki (signing/quirks note) | trap documentation | medium-high as docs, low as code |
| 5 | fstab rows for `/boot`, `/recovery`, `/misc` + a declared `cache` partition (non-A/B OTA: `CheckSize` `KeyError`, `blockimgdiff` cache assert) | `fstab.rk30board`, `BoardConfig.mk:163-169` | generic | Lineage device tree / build docs | bug fix + trap doc | medium-high |
| 6 | Two non-A/B OTA packaging bugs in releasetools: `zip -y` for staging symlinks (Info-ZIP reads the host fs, exit 18); ninja race on `SOONG_ZIP`; target-files zip dependency/passing a dir instead of a zip | `patches/releasetools-zip-store-symlinks.patch`, `patches/releasetools-ota-depend-on-target-files-zip.patch`, `patches/releasetools-ota-target-files-zip.patch` | generic | AOSP `build/make/tools/releasetools/non_ab_ota.py` + `core/Makefile` (Gerrit) | bug fix | medium (check current AOSP `main` first — pre-11 passed the zip, so this may be a regression report) |
| 7 | `libwifi-hal` `compile_multilib: "both"` so a 32-bit vendor binary can link `libwifi-hal.so` | `patches/frameworks-opt-net-wifi-libwifi-hal-32bit.patch` | generic | AOSP `frameworks/opt/net/wifi/libwifi_hal/Android.bp` (currently `"first"`) or Lineage fork | device-config | medium (Lineage's rtk HAL is already `both`, so the ask shrinks to the generic HAL; better pitch: a gated Soong bool) |
| 8 | `ifdef` vs `ifeq` for `BOARD_INCLUDE_RECOVERY_DTBO` → `--recovery_dtbo` emitted even when false | `BoardConfig.mk:112-135` (our workaround) + notes | generic bug in `Makefile` | AOSP `build/make/core/Makefile` | bug fix | medium |
| 9 | Fitting Android 14's five logical partitions (incl. `system_ext`) into an unchanged single super group, no GPT rewrite | `BoardConfig.mk:141-160`, D11/D19 | generic technique | device tree + wiki | device-config + docs | medium |
| 10 | Staging vendor blobs through the build instead of `BOARD_PREBUILT_VENDORIMAGE`, and vendor libs as Android 14's own `<name>.vendor` modules | `scripts/prebuilt_vendor.sh`, `tools/gen_vendor_staging.py`, `device.mk:4-21`, D20 | generic technique | wiki / device-tree tooling (not upstream code) | trap docs + config | medium as docs, low as code |
| 11 | `ADDITIONAL_*_PROPERTIES` duplicate-sysprop traps (`ro.hwui.use_vulkan`, `ro.sf.lcd_density`, `ro.adb.secure` are assigned by `build/make/core/main.mk`) | `device.mk:71-91`, `BoardConfig.mk:53-56`, `docs/build-host.md:182-197` | generic | wiki (maybe a `build/make` warning improvement) | trap doc + config fix (use `TARGET_*`) | medium |
| 12 | `m dist` before `m superimage` (superimage stages stale `IMAGES/`) | `scripts/package.sh` header, `docs/build-host.md:409-416` | generic trap | wiki / build-host notes | trap documentation | medium |
| 13 | AVB lock state on Rockchip (`at-lock-vboot`, `avb_write_lock_state`, `FAILThe device is locked, can not flash!`; lock ⇒ no transport boots Android 14; `ro.boot.vbmeta.device_state` readable without root) | `docs/findings.md:130-156`, `hu_probe.sh:52-57` | generic RK trap | device wiki page + deviation note; AOSP boot-flow stays normative | trap documentation | medium |
| 14 | Deploy/patch preflight helpers: check every `PRODUCT_COPY_FILES` source exists before ninja; idempotent `git apply` (GNU patch 2.8 rejects valid hunks) | `scripts/deploy_device.sh`, `scripts/apply_tree_patches.sh` | generic host-side convention (mirrors trees that ship `apply-patches.sh`) | device-tree tooling / build docs | tooling | medium |
| 15 | Bring-up access pattern: keep `ro.adb.secure=1` and inject the workstation's adb **public** key into `/data/adb/adb_keys`; root comes from `adb root`, not the ROM's `su` | `hu_apps.mk:137-141`, `hu_system/etc/hu_adb_key.pub`, `docs/flash.md` | pattern generic; the shipped key/service is ours | wiki bring-up recipe only | trap documentation | medium as docs, low as code |
| 16 | Boot-time auto-probe service (`/system/etc/init/<name>.rc` root oneshot on `sys.boot_completed` writing a report to `/data/local/tmp` + USB stick + `/dev/kmsg`) | `hu_system/etc/init/hu_probe.rc`, `hu_system/bin/hu_probe.sh` | pattern generic; implementation ours | wiki / device tooling | tooling + docs | low-medium |
| 17 | Verification/gate tooling (`verify_artifacts.sh` design, `vendor_link_closure.py`, `check_super.py`, `hal_gap.py`) | `scripts/`, `tools/` | technique generic | third-party repo, not Lineage (Lineage does not merge loose Python) | tooling | low-medium |
| 18 | `PRODUCT_COPY_FILES += \` glued to a comment silently drops entries (our own regression) | `docs/decisions.md:770-777` | lesson generic, bug ours | wiki note ("check the *deployed* .mk") | trap documentation | low |
| 19 | `drmModeAddFB2_ext` exported by libdrm | `patches/external-libdrm-rockchip-addfb2-ext.patch` (`xf86drmMode.c/.h`) | generic for RK boards | **freedesktop/drm** upstream (AOSP re-imports afterwards); Lineage's libdrm fork is dead so it cannot take it | vendor-compat shim | low |
| 20 | `libwifi-hal-rtk` vendored in our device tree (`wifi_hal/`, 8 `.cpp`, Apache-2.0 headers) | `device/rk3399-px6-hct4/wifi_hal/` | **already upstream** in `LineageOS/android_hardware_realtek` (`compile_multilib: "both"`, `vendor_available`) | nothing to send; instead depend on the upstream module and drop our copy | redundant | high, but a no-op |

## Notes worth keeping per candidate

* **1** is the cleanest contribution we have: recovery's local-update/sideload has nothing to run without
  `update_engine_sideload` (a `recovery: true` module in `system/update_engine/Android.bp`). No OEM
  content in it. Cleanup: delete the HU comment only.
* **2 / 4 / 5 / 12 / 13 / 15 / 18** are documentation-shaped. Lineage takes wiki changes through Gerrit
  (`lineage_wiki`), and the charter *requires* documenting hardware deviations on the device page, so a
  device wiki page is the right home for the Rockchip-specific traps; the generic ones (adb-key bring-up,
  EOCD-comment recoveries, `m dist` ordering) belong in a general page.
* **6 / 8** are real AOSP bug fixes, but the tree we patched is Android 14-era; verify against AOSP `main`
  before writing a Gerrit change, or submit a regression report instead of a patch.
* **7** must be re-pitched generically: Lineage already builds the Realtek HAL for both ABIs, so the only
  remaining ask is the generic `libwifi-hal` (`compile_multilib: "first"`). A gated Soong config variable
  is more likely to survive review than blanket `both`.
* **19** duplicates functionality upstream already provides (`drmModeAddFB2WithModifiers`); the honest
  pitch is a compat alias/shim for vendor blobs that call the Rockchip symbol, or upstreaming the *caller*
  so it uses the existing symbol. Strip the HU provenance prose (`hwcomposer.rk30board.so`, D22).
* **20** means our vendored `wifi_hal/` should become a `lineage.dependencies` entry rather than copied
  source — note `lineage.dependencies` may not reference repos outside the LineageOS org, and
  `github.com/kimocoder/android_wifi_hal` has **no LICENSE file** (unlicensed ⇒ Charter Category X), so it
  stays reference-only, never mergeable.

## Do NOT upstream

* HCT/Microntek APKs and OEM binaries/libs (`device/.../apps/**`, `hu_system/bin/*`, `hu_system/lib*/`,
  `hct.rc`, `privapp-permissions-hct.xml`) — OEM binaries without redistribution rights; re-signing
  third-party APKs with `certificate: "platform"` (`apps/Android.bp:13-23`) is precisely what review
  rejects.
* The staged Daisaita Android 11 vendor blob tree, OEM kernel, dtb and RSCE logo
  (`prebuilt_vendor.sh` output `vendor/hct4/**`, `TARGET_PREBUILT_KERNEL`, `BOARD_PREBUILT_DTBIMAGE_DIR`,
  `boot_second_logo.bin`) — proprietary, and Lineage requires an extraction script, not committed blobs.
* The permissive trust stack: `WITH_PERMISSIVE_SELINUX := true`, `androidboot.selinux=permissive`,
  `veritymode=disabled`, `verifiedbootstate=orange`, `BOARD_AVB_ENABLE := false`, `ueventd` `0666` on
  `/dev/mtc-*`/`ttyS*`, `user root` + `seclabel u:r:shell:s0` services. That is a security regression;
  charter demands enforcing SELinux. (There is no `sepolicy/` dir in our device tree yet — see below.)
* Our payload builder and raw-dd transport: `tools/gen_hu_payload.py`, `scripts/build_hu_package.sh`,
  `scripts/flash_from_android.sh`, `scripts/make_flash_stick.sh`. Device-specific, writes raw partitions,
  assumes the stock `update-binary` and the OEM rollback zip.
* Host specifics: NAS paths (`/srv/dev-disk-by-label-SSData`, `HOME`/`GOCACHE`/`TMPDIR`), `WORK`/`TREE`
  defaults in `check_super.py` and `verify_artifacts.sh`, `upload_client.sh` default host
  `192.168.1.161` and scp path `/run/media/Daan/...`, docker `-j4/-j12` policy, `scripts/archive/*`.
* Our own adb public key (`hu_system/etc/hu_adb_key.pub`) and the probe writing it into
  `/data/adb/adb_keys` — workstation-specific credentials, even the public half.
* HU identity: `PRODUCT_BRAND := HCT`, `PRODUCT_MANUFACTURER := Microntek`, the `ro.product.device` assert
  needed by the OEM rollback zip, `persist.hu.*`, the `hct_dynamic_partitions` group name, `/dev/mtc-*`
  and `force_usb_mode` sysfs writes.
* `BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true` shipped as a default — an escape hatch, not a
  contribution.

## Housekeeping items this review surfaced (repo-side, fixed or to fix)

* `device/rk3399-px6-hct4/README.md` listed a `sepolicy/` directory that does not exist — fixed: the row
  now says permissive comes from `WITH_PERMISSIVE_SELINUX := true` (**D5**) and that a real sepolicy is a
  post-bring-up task.
* `docs/build-host.md:420` pointed at `tools/check_super.py`; the live file is `scripts/check_super.py`
  (used by `scripts/verify_artifacts.sh:75`) — fixed.
* `hu_system/bin/hu_probe.sh` claimed `ro.adb.secure=0`; `device.mk:95` keeps `ro.adb.secure=1` (assigned
  by `build/make/core/main.mk`) and relies on the injected public key — comment fixed.
* If we ever upstream the bring-up recipe, the adb key must leave the tree and become a local build input.

## When we start submitting (order, not yet started)

1. Lineage wiki note: EOCD-comment recovery signature + `signapk -w` behaviour (docs only, Gerrit).
2. Lineage device-tree fix: `update_engine_sideload` (+ the fstab `/recovery`/`/misc`/`cache` shape if a
   generic home exists; upstream has no RK3399 tree, so `device/lineage` is the realistic host).
3. AOSP Gerrit: releasetools `zip -y` / target-files-zip dependency, and the `ifdef` recovery_dtbo bug —
   after re-checking AOSP `main`.
4. AOSP/Lineage: generic `libwifi-hal` 32-bit (as a Soong config variable), and drop our vendored
   `wifi_hal/` in favour of `LineageOS/android_hardware_realtek`.
5. freedesktop/drm: only if we can justify the `AddFB2_ext` compat shim without HU prose.
6. Mainline U-Boot docs / Radxa wiki: Rockchip SD-boot + AVB-lock notes (documentation only).
