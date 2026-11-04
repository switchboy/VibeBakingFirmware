# device/ — device tree for this unit

Target: an AOSP/LineageOS `device/rockchip/rk3399-px6-hct4/` tree that reuses the shipped vendor
image (kernel + HAL blobs) and replaces only the framework partitions.

Planned contents:
- `Android.mk`, `device.mk`, `BoardConfig.mk` (dynamic partitions, boot header v2, no AVB, FCM target-level 4)
- `manifest.xml` (+ `<kernel target-level=.../>`, KeyMint entry), `compatibility_matrix.device.xml`
- `overlay/` for super-partition sizing
- `sepolicy/` vendor policy: domains for the HCT services (CAN, tuner, AMP, CarPlay bridges)
- `radio/`, `gps/`, `audio/` config referencing `/dev/mtc-*` and `/dev/ttyS*`

Nothing here is buildable yet; see `docs/feasibility.md` for the prerequisites.
