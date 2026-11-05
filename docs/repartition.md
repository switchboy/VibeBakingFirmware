# M2b - repartitioning the eMMC (D8)

Goal: `super` 3,263,168,512 -> **8,589,934,592** B and `userdata` 58,844,495,360 ->
**53,517,729,280** B, so Android 14 has room (the vendor's Android 11 package needs a 4,890,558,464 B
group, which does not fit today - that is the flash warning the owner saw).

## What the table change does

- `p1..p13` keep their exact LBAs, so uboot/trust/misc/dtb/dtbo/vbmeta/boot/recovery/backup/security/
  cache/metadata/frp stay byte-identical and the bootloader keeps working.
- `super` grows in place; `userdata` starts later by exactly the growth amount and keeps its last LBA,
  so the disk's tail reserve (backup GPT area) does not move.
- `userdata` content is discarded by design - the owner accepts a factory reset (D8/D10).

## Build the blobs (on the NAS)

    scripts/repartition_gpt.sh analysis/hu_partition_offsets.txt analysis/gpt

Input is the probe section "Partition offsets for repartitioning" (`disk sectors:` plus
`mmcblk2pN first_lba last_lba`, sysfs, no root needed). The script uses `sgdisk`, so the header and
entry CRCs are computed by a real GPT implementation; it then extracts:

- `gpt_head.bin` - protective MBR + primary header + 128 entries (34 LBAs, 17,408 B)
- `gpt_tail.bin` - backup entries + backup header (33 LBAs, 16,896 B)

Both blobs live entirely in the GPT areas, so writing them cannot touch any partition payload.
The script prints the new table and refuses if super/userdata would overlap.

## Applying it (needs a root shell: Rockchip Boot-ADB, or rkflash)

1. Backup first: save the current head/tail bytes and p1-p13 (`dd` of the first 8 MiB, the last
   16,896 B, and each of p1-p13). This is the restore path; losing accounts/apps is fine (D10).
2. `dd if=gpt_head.bin of=/dev/block/mmcblk2 bs=1 count=17408 conv=notrunc`
3. `dd if=gpt_tail.bin of=/dev/block/mmcblk2 bs=1 seek=<disk_bytes - 16896> conv=notrunc`
4. Reboot so the kernel re-reads the table, confirm sizes via sysfs (no root needed), then
   `mkfs.f2fs /dev/block/by-name/userdata`.
5. Flash `super.img` (from `out/`, contains system/vendor/product/system_ext/odm as logical
   partitions), then `boot.img` and `recovery.img`.

Nothing in an ordinary upgrade touches the GPT: later updates are logical partitions only (D10).

## Alternative: skip the repartition for the first flash

`super` as it exists today (3,263,168,512 B, group 3,258,974,208) already holds our Android 14
images: `system` 922.4 MB + `vendor` 292.3 MB + `product` 456.1 MB + `system_ext` 384.7 MB +
`odm` 0.8 MB = **2,056.4 MB**, ~1.2 GB of headroom. The stock Android 10 rollback zip uses exactly
that group size, so it is the layout the unit is known to boot from.

That means M2b can be done in two steps instead of one:

| step | writes | risk |
|---|---|---|
| **First flash** | `super.img` + `boot.img` + `recovery.img` only, GPT untouched | no GPT rewrite, so a bad image is recoverable by re-flashing; the A10 zip still installs afterwards |
| **Repartition, later** | GPT head/tail + resized `super.img` + new `userdata` | the risky part, done only once Android 14 boots and the rollback is proven |

To build for the untouched layout, set the commented fallback sizes in `BoardConfig.mk`
(`BOARD_SUPER_PARTITION_SIZE := 3263168512`, `BOARD_HCT_DYNAMIC_PARTITIONS_SIZE := 3258974208`) and
re-run `m superimage` - no full rebuild. Flashing an 8 GiB `super.img` into the 3.26 GiB partition
would leave super's metadata claiming a group bigger than the partition, and Android would not boot.

## Restore path if this goes wrong

Write the saved head/tail blobs back, then re-flash p1-p13 and the old `super` from the backup, or
install the owner's Daisaita Android 10 package. The unit goes to factory settings either way.
