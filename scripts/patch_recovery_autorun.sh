#!/usr/bin/env bash
# patch_recovery_autorun.sh - builds recovery-patched.img from the stock recovery.bin.
#
# Partition 8 (recovery) is not part of the boot chain, so writing it cannot break normal boot
# (D18/D19 hold: uboot/trust/dtb/dtbo/vbmeta/security/GPT are never touched). The patch adds three
# files to the recovery ramdisk and appends one service block to init.recovery.rk30board.rc:
#   /sbin/hu-install.sh                - the card-driven installer (inert without hu-install.flag)
#   /sbin/make_f2fs.oem                - stock Android 10 mkfs, the one proven on this 4.19 kernel
#   /init.recovery.rk30board.rc        - stock content + the hu_install service, started on `on boot`
#
# repack_bootimg only rewrites the ramdisk, so kernel / second bootloader / recovery_dtbo and every
# header field must survive unchanged - this script proves that by unpacking both images and
# comparing them, and proves the ramdisk itself by extracting it and hashing each injected file.
#
# Host tools live on the NAS build tree, so the heavy lifting runs there. The NAS root filesystem
# has room (/tmp, 11 GiB free); SSData is full and must not be used for scratch. Everything the
# ssh sessions print lands in the log file, because this environment returns no stdout.
set -u

NAS=root@192.168.1.29
BIN='/srv/dev-disk-by-label-SSData/aospbuild/lineage21s/out/host/linux-x86/bin'
REPO=/run/media/Daan/Opslagmonster/VibeBakingFirmware
WORK=/run/media/Daan/Opslagmonster/a14-work
STOCK="$WORK/hu-stock-backup"
OUTDIR="$WORK/recovery-patched"
LOG="$OUTDIR/patch.log"
W=/tmp/recwork

RS="env SSH_ASKPASS=$HOME/.config/vbf/askpass.sh SSH_ASKPASS_REQUIRE=force ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=no -o ConnectTimeout=15"

mkdir -p "$OUTDIR/inject"
: > "$LOG"
say() { printf '%s\n' "$1" >> "$LOG"; }
# Run one command on the NAS and append its output to the log.
nas() { sh $HOME/.config/vbf/omv.sh "$1" 2>&1 | tee -a "$LOG" > /dev/null; }

say "=== 1. NAS working dir ==="
nas "mkdir -p $W/inject; ls -l $W 2>&1; df -h /tmp | tail -1"

if ! nas "stat -c '%s' $W/recovery.bin 2>&1" ; then :; fi
# Push the stock recovery if the NAS copy is not there (the log line above shows the size).
if ! grep -q '^100663296$' "$LOG"; then
  say "recovery.bin missing on NAS - pushing it"
  rsync -a --no-progress -e "$RS" "$STOCK/recovery.bin" "$NAS:$W/" 2>&1 | tee -a "$LOG" > /dev/null
  nas "stat -c '%n %s' $W/recovery.bin"
fi

say "=== 2. push the injected files, under the names the ramdisk needs ==="
mkdir -p "$OUTDIR/inject"
cp "$REPO/scripts/hu_recovery_install.sh" "$OUTDIR/inject/hu-install.sh"
cp "$REPO/scripts/hu_recovery_init_append.rc" "$OUTDIR/inject/init.recovery.rk30board.rc"
cp "$STOCK/make_f2fs" "$OUTDIR/inject/make_f2fs.oem"
rsync -a --no-progress -e "$RS" "$OUTDIR/inject/" "$NAS:$W/inject/" 2>&1 | tee -a "$LOG" > /dev/null
nas "ls -l $W/inject"
nas "sha256sum $W/inject/hu-install.sh $W/inject/make_f2fs.oem $W/inject/init.recovery.rk30board.rc"
sha256sum "$OUTDIR/inject/hu-install.sh" "$OUTDIR/inject/make_f2fs.oem" \
  "$OUTDIR/inject/init.recovery.rk30board.rc" >> "$LOG" 2>/dev/null

say "=== 3. splice the new ramdisk in (repack_recovery_python.py, not repack_bootimg) ==="
# repack_bootimg is a frozen binary that shells out to mkbootimg, and Lineage's mkbootimg refuses
# this stock header (version 2 + recovery_dtbo + dtb size 0): it died after writing a 1,648-byte
# image. The splice tool keeps kernel/second/dtbo bytes and every header field verbatim and only
# updates ramdisk_size and recovery_dtbo_offset, so the patched image differs from the stock one
# exactly where the ramdisk got bigger.
rsync -a --no-progress -e "$RS" "$REPO/scripts/repack_recovery_python.py" "$NAS:$W/" 2>&1 | tee -a "$LOG" > /dev/null
nas "$BIN/unpack_bootimg --boot_img $W/recovery.bin --out $W/unpacked --format info > $W/info-stock.txt 2>&1; \
  dtbo=\$(stat -c %s $W/unpacked/recovery_dtbo); \
  echo \"recovery dtbo size from the unpacked file: \$dtbo\"; \
  rm -rf $W/rd-src && cp -a $W/rd $W/rd-src && \
  cp $W/inject/hu-install.sh $W/rd-src/sbin/hu-install.sh && chmod 755 $W/rd-src/sbin/hu-install.sh && \
  cp $W/inject/make_f2fs.oem $W/rd-src/sbin/make_f2fs.oem && chmod 755 $W/rd-src/sbin/make_f2fs.oem && \
  cp $W/inject/init.recovery.rk30board.rc $W/rd-src/init.recovery.rk30board.rc && chmod 755 $W/rd-src/init.recovery.rk30board.rc && \
  python3 $W/repack_recovery_python.py $W/recovery.bin $W/rd-src $W/recovery-patched.img 100663296 \$dtbo 2>&1 | tail -12; \
  stat -c '%n %s' $W/recovery-patched.img"

say "=== 4. header fields: only ramdisk size and dtbo offset may differ ==="
nas "$BIN/unpack_bootimg --boot_img $W/recovery.bin --out $W/unpacked --format info > $W/info-stock.txt 2>&1; \
  rm -rf $W/unpacked-patched; \
  $BIN/unpack_bootimg --boot_img $W/recovery-patched.img --out $W/unpacked-patched --format info > $W/info-patched.txt 2>&1; \
  diff $W/info-stock.txt $W/info-patched.txt; echo 'diff rc='\$?"

say "=== 5. kernel / second / recovery_dtbo must be byte-identical ==="
nas "for f in kernel second recovery_dtbo; do \
  a=\$(sha256sum $W/unpacked/\$f 2>/dev/null | cut -d' ' -f1); \
  b=\$(sha256sum $W/unpacked-patched/\$f 2>/dev/null | cut -d' ' -f1); \
  if [ \"\$a\" = \"\$b\" ]; then s=same; else s=CHANGED; fi; \
  printf '%-14s %s %s %s\n' \$f \"\$a\" \"\$b\" \$s; \
done"

say "=== 6. the patched ramdisk: no duplicate entries, injected files intact ==="
nas "gzip -dc $W/unpacked-patched/ramdisk | cpio -it 2>/dev/null | LC_ALL=C sort | uniq -d; \
  echo 'duplicate archive entries listed above (nothing listed = clean)'; \
  rm -rf $W/rd-patched; mkdir -p $W/rd-patched; cd $W/rd-patched && \
  gzip -dc $W/unpacked-patched/ramdisk | cpio -i -d 2>&1 | tail -2; \
  ls -l $W/rd-patched/sbin/hu-install.sh $W/rd-patched/sbin/make_f2fs.oem $W/rd-patched/init.recovery.rk30board.rc; \
  for f in sbin/hu-install.sh sbin/make_f2fs.oem init.recovery.rk30board.rc; do \
    a=\$(sha256sum $W/rd-patched/\$f 2>/dev/null | cut -d' ' -f1); \
    b=\$(sha256sum $W/inject/\${f##*/} 2>/dev/null | cut -d' ' -f1); \
    if [ \"\$a\" = \"\$b\" ]; then s=intact; else s=MISMATCH; fi; \
    printf '%-30s %s %s\n' \$f \"\$a\" \$s; \
done"

say "=== 7. the appended rc block must be present exactly once ==="
nas "printf 'hu_install service lines: '; grep -c 'service hu_install' $W/rd-patched/init.recovery.rk30board.rc; \
  printf 'start hu_install lines: '; grep -c 'start hu_install' $W/rd-patched/init.recovery.rk30board.rc; \
  printf 'stock console service lines: '; grep -c 'service console' $W/rd-patched/init.recovery.rk30board.rc; \
  printf 'stock usb controller line still there: '; grep -c 'sys.usb.controller' $W/rd-patched/init.recovery.rk30board.rc"

say "=== 8. pull the patched image back and hash both ==="
sh $HOME/.config/vbf/omv.sh "base64 -w0 $W/recovery-patched.img" 2>/dev/null | tee "$OUTDIR/recovery-patched.b64" > /dev/null
base64 -d "$OUTDIR/recovery-patched.b64" > "$OUTDIR/recovery-patched.img" 2>/dev/null
printf 'pulled %s B\n' "$(stat -c %s "$OUTDIR/recovery-patched.img" 2>/dev/null)" >> "$LOG"
rm -f "$OUTDIR/recovery-patched.b64"
sha256sum "$STOCK/recovery.bin" "$OUTDIR/recovery-patched.img" >> "$LOG" 2>/dev/null

echo "see $LOG"
