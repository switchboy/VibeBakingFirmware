# rom/ — ROM-level configuration and packaging

Contents (to be created):
- `sepolicy/` — vendor SELinux policy rewrite: dedicated domains for `hctcanbusservice`,
  `gocsdk*`/`sdsdk*`/`blueletd`/`brlinktd`, tuner/AMP nodes, no `u:r:shell:s0` root services,
  device-node permissions (0600/0660 instead of 0777).
- `props/` — hardened property list (no `androidboot.selinux=permissive`, no ADB-over-TCP,
  no third-party OTA host).
- `partitions/` — `dynamic_partitions_op_list` variants for the Android 14 image sizes.
- `packaging/` — build the flashable `Update.zip`: re-encode partitions with brotli +
  blockimgdiff transfer lists (`tools/reassemble.py` is the inverse), reuse/replace the
  Rockchip `update-binary`, re-sign with our own key, keep `RKLoader.bin`/`uboot`/`trust`/`dtbo`.
- `release/` — changelog, supported-unit matrix, rollback instructions.
