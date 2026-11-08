# usb_dongle - Rockchip's USB mode-switch helper, rebuilt for Android 14 (**D23**)

The staged Android 11 blob `/vendor/bin/usb_dongle` cannot load on this ROM. It is a 64-bit ELF whose
`DT_NEEDED` names `libsysutils.so`, and it needs five symbols that Android 14's libsysutils does not
export for `/vendor/lib64`:

```
_ZN14SocketListener13startListenerEv      SocketListener::startListener()
_ZN14SocketListenerD2Ev                   ~SocketListener()
_ZN12NetlinkEvent9findParamEPKc           NetlinkEvent::findParam(const char*)
_ZN15NetlinkListenerC2Ei                  NetlinkListener::NetlinkListener(int)
_ZN15NetlinkListener15onDataAvailableEP12SocketClient   NetlinkListener::onDataAvailable(SocketClient*)
```

(`tools/vendor_abi_check.py` reports exactly these five; Android 14 installs only the 32-bit
`/vendor/lib/libsysutils.so`, which happens to export all of them - the 64-bit vendor copy is missing.)

Rebuilding is cheaper than shimming: Android 14's own headers still declare the same API
(`system/core/libsysutils/include/sysutils/SocketListener.h:42` `int startListener();`,
`NetlinkListener.h:37` `NetlinkListener(int socket)`, `NetlinkListener.h:45`
`bool onDataAvailable(SocketClient*)`), and the published sources compile against them unchanged.
So this folder builds Android 14's own `vendor/bin/usb_dongle` + `vendor/etc/init/usb_dongle.rc`, and
the blob copies of both paths are dropped (`vendor_dest_skip_extra.txt`).

**What the binary does** (unchanged): binds a `NETLINK_KOBJECT_UEVENT` socket, cold-boots
`/sys/block`, then for every uevent whose subsystem is `usb` or `scsi_device` it runs

```
/vendor/bin/usb_modeswitch -W -v %04x -p %04x -c /vendor/etc/usb_modeswitch.d/%04x_%04x &
```

for the vendor/product pair in the event - only when that config file exists - and re-runs it once on
the matching `scsi_device` event. On start it also tries `/sys/bus/usb/devices/1-1`'s own id. Then it
`pause()`s forever, like the blob.

**Provenance.** Rockchip ships this in its BSP as `external/usb_modeswitch/usb_dongle`. Published
mirror used here: `gitlabhost.argos-navy.ru/rockchip/firefly/rk3588_android12`, commit
`e12ba531a1ef63b99ce4d8b17b9daf2ea30f69ec`, path `external/usb_modeswitch/usb_dongle` (13 files:
`Android.mk`, `main.cpp`, `NetlinkManager.{cpp,h}`, `NetlinkHandler.{cpp,h}`, `MiscManager.{cpp,h}`,
`Misc.{cpp,h}`, `G3Dev.{cpp,h}`, `usb_dongle.rc`). Every file carries the Apache-2.0 AOSP header, so
the vendored code is **Apache-2.0**. `usb_modeswitch` itself - the program this helper shells out to,
never linked - is GPLv2 from upstream (`usb-modeswitch.org`, mirror
`github.com/gfcitani/usb-modeswitch`); Android 14 builds it from `device/generic/car/emulator/usbpt/
bluetooth/usb_modeswitch`, which is already requested in `device.mk`.

This mirror is the same code the blob was built from, not a lookalike: the blob's strings name
`external/usb_modeswitch/usb_dongle/main.cpp` and `.../NetlinkManager.cpp`, the exact
`/vendor/bin/usb_modeswitch -W -v %04x -p %04x -c %s &` command line, `/vendor/etc/usb_modeswitch.d/
%04x_%04x`, `=== current usb device: %04X/%04X ===`, `=== config_file is: %04x_%04x`,
`=== USB Switch: %s`, `Vendor path: %s`, `DEVTYPE`, `usb_device`, `/idVendor`, `/idProduct`, and the
MiscManager messages `Unable to create/start MiscManager` - all of which appear in these sources.
Its `Android.mk` sets `-DUSE_USB_MODE_SWITCH`, which is why the blob has the MiscManager branch.

**Adaptations** (only these; the uevent logic and the invocation are byte-for-byte):

| file | change | why |
|---|---|---|
| `Android.bp` | replaces the BSP's `Android.mk` (`BUILD_EXECUTABLE`, `LOCAL_PROPRIETARY_MODULE := true`, `LOCAL_INIT_RC := usb_dongle.rc`) with a Soong `cc_binary`, `proprietary: true`, `compile_multilib: "64"`, `-DUSE_USB_MODE_SWITCH` | Android 14 builds this tree with Soong; `compile_multilib: "64"` matches the blob's ELF class so `/vendor/bin/usb_dongle` is the only installed binary |
| `Android.bp` shared_libs | drops `libbinder` and `libhwbinder` from the BSP's eight libraries | Soong forbids the link outright: `system/libhwbinder/Android.bp:105` restricts visibility to its own subtree plus `//vendor/...`, so a vendor module under `device/rockchip/rk3399` cannot depend on it (Make had no visibility rule, which is how the blob built). Nothing in this code calls binder or HIDL - `nm -D --undefined-only` on the blob names no binder symbol either - so the two sonames were dead weight. |
| `Android.bp` cflags | adds `-Wno-unused-*`, `-Wno-unused-private-field`, `-Wno-format`, `-Wno-misleading-indentation` to the BSP's three flags | clang 17 flags fields and variables the published code never reads (`NetlinkManager::mBroadcaster`, `main.cpp`'s `fstab`/`sehandle`, `pid_t status`, `bool hit`), the published `sprintf` argument widths, and the tab-indented `pid_t status;` after `if( devtype!=NULL && ... )`; `-Werror` would turn those into a build failure |
| `Misc.cpp`, `G3Dev.cpp` | the two garbled comments (mojibake GBK in the mirror) are rewritten in English | comments only; no code change |
| `G3Dev.cpp` | `#include <limits.h>` added for `PATH_MAX` | `PATH_MAX` is not reachable through the headers the published file includes on Android 14's sysroot |

`#if PLATFORM_SDK_VERSION >= 16` in `G3Dev.cpp` is kept as published. Soong does not define that
macro, so the block is skipped; the `LOGV..LOGE` macros it defines are unused in this file (the code
logs through `SLOGD`/`SLOGW`), so skipping it changes nothing.

**Not restored:** the HIDL WiFi service and `librkwifi-ctrl.so` stay declared deviations
(`vendor_dest_deviations.txt`). `usb_dongle` is not a gap - it runs here, it just runs Android 14's
own build.

## Verified on the build host (Nov 8, `hu-d23-build`, exit 0)

| destination | before | after |
|---|---|---|
| `/vendor/bin/usb_dongle` | blob copy, 29,872 B | module output, 135,344 B |
| `/vendor/etc/init/usb_dongle.rc` | blob copy, 70 B | module output, 69 B - same three lines, only the blob's trailing blank line differs |
| `/vendor/lib64/libsysutils.so` | not installed | 134,944 B (Soong installs it as `usb_dongle`'s dependency; `libsysutils.vendor`) |

The rebuilt binary still names the five legacy symbols (`nm -D --undefined-only`:
`_ZN12NetlinkEvent9findParamEPKc`, `_ZN14SocketListener13startListenerEv`, `_ZN14SocketListenerD2Ev`,
`_ZN15NetlinkListenerC2Ei`, `_ZN15NetlinkListener15onDataAvailableEP12SocketClient`) and Android 14's
`/vendor/lib64/libsysutils.so` defines all five - 0 unresolved symbols. Its strings carry the same
behaviour markers as the blob: `/vendor/etc/usb_modeswitch.d/%04x_%04x`,
`/vendor/bin/usb_modeswitch -W -v %04x -p %04x -c %s &`, `DEVTYPE`, `usb_device`, `idVendor`,
`idProduct`, `No subsystem found in netlink event`, `Unable to bind uevent socket`.
`tools/consumer_abi_check.py ... libsysutils.so` reports 1 consumer (`bin/usb_dongle`), 0 unresolved.

`/vendor/bin/sh` exists (339,792 B, built by Android 14), which is what the published `system()` call
runs, and `/vendor/etc/usb_modeswitch.d/` still holds the staged configs.
