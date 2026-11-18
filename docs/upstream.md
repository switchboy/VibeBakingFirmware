# Upstream candidates — register, not a TODO list of PRs

Written Nov 9. **Nothing here has been submitted.** No Gerrit change, no PR, no fork push. The point is
to separate work that would help other Rockchip/LineageOS/AOSP users from work that only makes *our*
head unit run, and to record what upstream would demand before any of it is presentable.

Two research passes produced this: one inventorying the repo (candidate by file), one checking upstream
facts online. URLs below were opened by that pass on Nov 9; where it could not verify something that is
said plainly. Nov 14 added candidates **21** and **22** (kernel-side bugs found on the live unit) and a
drafted issue text. On Nov 15 the owner answered: **nothing is posted** - the kernel candidates stay
draft-only here (**D45**), so this file remains a register, not a submission queue.

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
* **U-Boot / SD-boot docs** belong in mainline U-Boot (`board/rockchip/rockchip.html` upstream — RK3399,
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
| 21 | Vendor `gt9xx.c` stores `input_dev->phys` in a **stack array**, so the pointer dangles and a re-opened touch device panics the kernel | nothing in our repo - the bug is in `drivers/input/touchscreen/gt9xx/gt9xx.c` | generic for every board using this driver | GitHub issue on `rockchip-linux/kernel` (issues enabled, 274 open, default branch `develop-6.1`); the fix itself is a 1-line patch to that repo | bug fix | **high** - the defect is visible by reading the source, and is present in `develop-4.4`, `develop-4.19`, `develop-6.1` and `master` |
| 22 | Rockchip's `rtl8188eu` fork warns (`rtw_warn_on(1)`) when power-save leave times out, tainting the kernel on every occurrence | nothing in our repo - we load the fork's `8188eu.ko` | generic for RK boards using this fork | `rockchip-linux/kernel` issue only: mainline **deleted** `drivers/staging/r8188eu/*` (both paths return 404 on `torvalds/linux` master), so `torvalds` cannot take it | bug report (not a patch) | medium - mainline removed the driver entirely, so the audience is the fork's maintainer |

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
* **21** is the only candidate here that we hit in production: it panicked our board on Nov 13
  (`docs/findings.md`). It is generic - the same three lines are in all four branches - and it carries no
  OEM content, so it is upstreamable as a bug report *and* as a patch. The home is `rockchip-linux/kernel`
  (GitHub issues enabled; the repo is active, last push 2026-08-28). Lineage cannot take it: there is no
  RK3399 kernel repo in the LineageOS org, and Lineage forbids prebuilt kernels anyway. We do **not** fix
  it ourselves right now either - the owner accepted the inherited risk (**D45**), because the driver is
  built into the kernel and the vendor kernel source is not in hand.
* **22** must be phrased as a fork-specific report, not a mainline one: `drivers/staging/r8188eu/*` is
  gone upstream (404 on torvalds master), so the only audience is `rockchip-linux/kernel`. Keep it short -
  the ask is "a timing timeout should not `warn_on()`, it taints every boot".

## Drafted Nov 14, NOT posted (owner declined Nov 15 — **D45**)

### Candidate 21 — issue text for `rockchip-linux/kernel`

Nothing below names our board, our OEM firmware, our adb access or our build host; it quotes upstream
source only. Kept here so it can be pasted verbatim if the owner ever decides to publish it.

> **Title:** `gt9xx`: `input_dev->phys` points at a stack buffer, so re-opening the device panics the kernel
>
> **Affected:** `drivers/input/touchscreen/gt9xx/gt9xx.c`, `gtp_request_input_dev()`. Verified on
> `develop-4.4` (lines 2047 / 2092 / 2094), `develop-4.19`, `develop-6.1` and `master` (all
> 2066 / 2111 / 2113).
>
> ```c
> static s8 gtp_request_input_dev(struct i2c_client *client, struct goodix_ts_data *ts)
> {
>     s8 ret = -1;
>     s8 phys[32];                       /* on the stack */
>     ...
>     ts->input_dev = devm_input_allocate_device(&client->dev);   /* outlives this function */
>     ...
>     sprintf(phys, "input/ts");
>     ts->input_dev->name = goodix_ts_name;
>     ts->input_dev->phys = phys;        /* dangling: phys dies with this stack frame */
>     ...
>     ret = input_register_device(ts->input_dev);
> ```
>
> `devm_input_allocate_device()` gives the `input_dev` the lifetime of the I2C client, but `phys` is a
> local array. Anything that reads `dev->phys` later - `evdev`'s `EVIOCGPHYS` via `str_to_user()`,
> `input_dev_uevent()`, `/proc/bus/input/devices` - reads memory that is no longer the driver's.
>
> Two symptoms, same root cause:
> * `/proc/bus/input/devices` prints the device with a `P: Phys=` field containing raw non-string bytes,
>   because whatever now occupies that stack region gets copied as if it were a string.
> * A fatal fault when the pages are gone. On an arm64 board with `CONFIG_VMAP_STACK=y` the fault address
>   sits in the vmalloc area (thread stacks) with `pte=0`, i.e. an unmapped stack page:
>
> ```
> Unable to handle kernel paging request at virtual address ffffff8009d73c70
> pgd/pud/pmd present, pte=0000000000000000
> Internal error: Oops: 96000007 [#1] PREEMPT SMP
> pc : __pi_strlen+0x60/0x84   lr : str_to_user+0x24/0xf8
> Comm: InputReader            Tainted: G W
> Call trace:
>   __pi_strlen+0x60/0x84
>   evdev_ioctl_handler+0x1174/0x16b8
>   evdev_ioctl+0x10/0x18
>   do_vfs_ioctl+0xbc/0xda8
>   ksys_ioctl+0x84/0x98
>   __arm64_sys_ioctl+0x18/0x28
>   el0_svc_common.constprop.0+0xb8/0x178
> Kernel panic - not syncing: Fatal exception
> ```
>
> `EVIOCGPHYS` is issued by any userspace that opens an input device - Android's `EventHub` does it on
> every device open, so a framework restart re-opens `/dev/input/event*` and the fault fires. It is
> intermittent because it only faults once the freed stack page has been unmapped or reused.
>
> **Mainline contrast:** `drivers/input/touchscreen/goodix.c` assigns string literals -
> `input->phys = "input/pen"` (line 339) and `ts->input_dev->phys = "input/ts"` (line 1147) - and is not
> affected. The lifetime rule is stated by Dmitry Torokhov on LKML in "[syzbot] [input?] KASAN:
> slab-use-after-free Read in input_dev_uevent" (Aug 23 2023): `input_dev->name`/`phys`/`uniq` must not
> point at memory that is freed.
>
> **Proposed fix** (one line, drops the array entirely):
>
> ```diff
> --- a/drivers/input/touchscreen/gt9xx/gt9xx.c
> +++ b/drivers/input/touchscreen/gt9xx/gt9xx.c
> @@ static s8 gtp_request_input_dev(struct i2c_client *client,
>                                  struct goodix_ts_data *ts)
>  {
>      s8 ret = -1;
> -    s8 phys[32];
>      ...
> -    sprintf(phys, "input/ts");
>      ts->input_dev->name = goodix_ts_name;
> -    ts->input_dev->phys = phys;
> +    ts->input_dev->phys = "input/ts";
>      ts->input_dev->id.bustype = BUS_I2C;
> ```
>
> The same pattern should be checked for the driver's other input devices (`pen_dev` sets `name` from a
> literal and does not set `phys`, so it is clean today) and for the other vendor touch drivers under
> `drivers/input/touchscreen/` in these branches.
>
> **How to reproduce without any vendor binary:** boot any board with this driver built in
> (`CONFIG_TOUCHSCREEN_GT9XX`/`CONFIG_TOUCHSCREEN_PROPERTIES=y`, no `gt9xx.ko`), read
> `/proc/bus/input/devices` (garbage `P: Phys=` is already the bug), then open the device's evdev node a
> second time after its probe worker thread has exited and call `ioctl(fd, EVIOCGPHYS, buf)`; with
> `CONFIG_VMAP_STACK=y` that faults once the stack page is unmapped.

### Candidate 22 — short note for the same tracker

> **Title:** `rtl8188eu` (Rockchip fork): `rtw_lps_state_chk()` `warn_on()`s on a timeout, tainting the kernel
>
> `hal/hal_com.c` `rtw_lps_state_chk()` (line 12035 on `develop-4.19`) polls `REG_TCR`'s `BIT_PWRBIT_OW_EN`
> for `LPS_ACTIVE_TIMEOUT` ms; if the chip never clears it it prints `PS_MODE_ACTIVE check failed` and then
> `rtw_warn_on(1)` (line 12050), which emits a full `WARNING:` backtrace and taints the kernel `W` on every
> power-save transition that is slow. Reached via `HW_VAR_LPS_STATE_CHK` (`hal_com.c:12410-12412`) from
> `rtw_set_ps_mode()` (`core/rtw_pwrctrl.c:1004`). A timeout is an expected condition on real hardware, so
> `RTW_ERR()` plus a return is enough; the `warn_on()` only makes every later oops report say
> `Tainted: G W`. Mainline cannot take this: `drivers/staging/r8188eu/*` no longer exists upstream.

## Do NOT upstream

* HCT/Microntek APKs and OEM binaries/libs (`device/.../apps/**`, `hu_system/bin/*`, `hu_system/lib*/`,
  `hct.rc`, `privapp-permissions-hct.xml`) — OEM binaries without redistribution rights; re-signing
  third-party APKs with `certificate: "platform"` (`apps/Android.bp:13-23`) is precisely what review
  rejects.
* The staged Daisaita Android 11 vendor blob tree, OEM kernel, dtb and RSCE logo
  (`prebuilt_vendor.sh` output `vendor/hct4/**`, `TARGET_PREBUILT_KERNEL`, `BOARD_PREBUILT_DTBIMAGE_DIR`,
  `boot_second_logo.bin`) — proprietary, and Lineage requires an extraction script, not committed blobs.
  **This also means our crash record must not be attached to an upstream report as-is**: the RAMoops dump
  names our board (`Rockchip RK3399 HCT  Board (DT)`), our kernel build (`#190`) and our loaded modules.
  Only the generic fault signature belongs in the issue text above.
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
* `docs/build-host.md:420` pointed at a `check_super.py` under `tools/`; the live file is `scripts/check_super.py`
  (used by `scripts/verify_artifacts.sh:75`) — fixed.
* `hu_system/bin/hu_probe.sh` claimed `ro.adb.secure=0`; `device.mk:95` keeps `ro.adb.secure=1` (assigned
  by `build/make/core/main.mk`) and relies on the injected public key — comment fixed.
* If we ever upstream the bring-up recipe, the adb key must leave the tree and become a local build input.

## When we start submitting (order, not yet started)

1. `rockchip-linux/kernel` GitHub issue: candidate **21** (draft above, generic, no CLA needed - issues are
   not a contribution). Then the short **22** note. Both await the owner's go-ahead; nothing is posted yet.
2. Lineage wiki note: EOCD-comment recovery signature + `signapk -w` behaviour (docs only, Gerrit).
3. Lineage device-tree fix: `update_engine_sideload` (+ the fstab `/recovery`/`/misc`/`cache` shape if a
   generic home exists; upstream has no RK3399 tree, so `device/lineage` is the realistic host).
4. AOSP Gerrit: releasetools `zip -y` / target-files-zip dependency, and the `ifdef` recovery_dtbo bug —
   after re-checking AOSP `main`.
5. AOSP/Lineage: generic `libwifi-hal` 32-bit (as a Soong config variable), and drop our vendored
   `wifi_hal/` in favour of `LineageOS/android_hardware_realtek`.
6. freedesktop/drm: only if we can justify the `AddFB2_ext` compat shim without HU prose.
7. Mainline U-Boot docs / Radxa wiki: Rockchip SD-boot + AVB-lock notes (documentation only).
