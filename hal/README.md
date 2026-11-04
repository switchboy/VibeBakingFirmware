# hal/ — wrappers and shims for the legacy vendor blobs

Purpose: let Android-10-era Rockchip/HCT binaries keep working under Android 12–14 without
touching the blobs.

Planned components:
- `libhardware_legacy/` — Android-10 legacy HAL loader (audio/ril/…) rebuilt for vendor, so
  `audio.primary.rk30board.so` can still be dlopened by the audio@5.0 impl.
- `libion/` — small ion client (`/dev/ion` ioctls) for `libgralloc_drm.so`; Android 12 dropped libion.
- `hwc-adapters/` — vendor copies of `libhwc2on1adapter.so` / `libhwc2onfbadapter.so`.
- `libchrome/` — vendor copy of the Android-10 libchrome used by `camera.rk30board.so`.
- `keymint/` — KeyMint service: software implementation first, later a wrapper over
  `keystore.rk30board.so` (keymaster 3.0).
- `broadcastradio/` (optional) — wrap `/dev/mtc-radio` / `/dev/mtc-dab` into `broadcastradio@2.0`.
- `mtc/` — userspace helpers for `/dev/mtc-car` (CAN) if we ever replace `hctcanbusservice`.
