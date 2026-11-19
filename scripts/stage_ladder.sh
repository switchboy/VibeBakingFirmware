#!/usr/bin/env sh
# stage_ladder.sh - build the boot-only ladder images (D62) from the stock capture, offline.
#
#   sh scripts/stage_ladder.sh                      # builds into $LADDER_DIR (default a14-work/ladder)
#   CAPTURE=<boot.bin> LADDER_DIR=<dir> sh scripts/stage_ladder.sh
#
# What it builds, in ladder order:
#   L0-stock.img            the stock capture repacked through tools/rebuild_boot_faithful.py with no content
#                           change. It must be byte-identical to the capture (identity gate check 1, D67), and
#                           flashing it also repairs partition 7, which today still holds payload padding in
#                           27,406,336..28,233,728 (D66).
#   L1-<token>.img          L0 plus ONE diagnostic cmdline token (printk.devkmsg=on, panic=12, loglevel=8,
#                           androidboot.init_fatal_reboot_target=bootloader). One variable per flash is the rule;
#                           the token is written into the header's 512-byte cmdline field by
#                           tools/patch_boot_cmdline.py, which moves no component.
#
# The token set is verified against the ramdisk's own init by `strings` (D62 demands this, because an unverified
# token is a silent no-op). Measured Nov 19 on the extracted stock Android 10 ramdisk and the payload ramdisk:
# both contain `androidboot.init_fatal_reboot_target=` and the values `bootloader` and `recovery`, and neither
# contains `init_fatal_panic` - so that token was dropped and replaced by the reboot-target one. `recovery` is
# deliberately NOT used: it writes the boot control block in `misc`, a write surface D30 forbids without the
# owner's go.
#
# It never touches the unit, the NAS or the stick. It refuses to run if the capture is not the byte-exact
# Nov 17 image (EXPECTED_SHA), because staging from a stale capture would produce an image nobody can trace.
# Every output is verified: the only bytes that may differ from the capture are inside the cmdline field, the
# tail resource header must still be at 32,092,160, and the three DTB copies must still be where they are.
set -u

CAPTURE=${CAPTURE:-/run/media/Daan/Opslagmonster/a14-work/hu-stock-backup-refresh/boot.bin}
EXPECTED_SHA=${EXPECTED_SHA:-4121b58f77598d73b1b7958c36d1c5a81c8b82ba176cce9f6863b67992ce5b3d}
LADDER_DIR=${LADDER_DIR:-/run/media/Daan/Opslagmonster/a14-work/ladder}
REPO=$(cd "$(dirname "$0")/.." && pwd)
TOKENS=${TOKENS:-printk.devkmsg=on panic=12 loglevel=8 androidboot.init_fatal_reboot_target=bootloader}

[ -f "$CAPTURE" ] || { echo "no capture at $CAPTURE" >&2; exit 1; }
got=$(sha256sum "$CAPTURE" | cut -d' ' -f1)
if [ "$got" != "$EXPECTED_SHA" ]; then
  echo "capture digest $got is not the expected $EXPECTED_SHA - refusing to stage from an image we cannot trace" >&2
  exit 1
fi
mkdir -p "$LADDER_DIR" || exit 1
if ! : > "$LADDER_DIR/.probe" 2>/dev/null; then
  echo "cannot write to $LADDER_DIR (set LADDER_DIR to a writable directory)" >&2
  exit 1
fi
rm -f "$LADDER_DIR/.probe"

verify() {  # $1 = image, $2 = label; prints the byte ranges that differ from the capture and PASS/FAIL
  python3 - "$CAPTURE" "$1" "$2" <<'PY'
import re, struct, sys
cap, img, label = sys.argv[1], sys.argv[2], sys.argv[3]
a = open(cap, 'rb').read(); b = open(img, 'rb').read()
if len(a) != len(b):
    print(f"FAIL {label}: length {len(b):,} vs capture {len(a):,}"); sys.exit(1)
rs = []; i = 0
while i < len(a):
    if a[i] != b[i]:
        j = i
        while j < len(a) and a[j] != b[j]: j += 1
        rs.append((i, j - 1)); i = j
    else:
        i += 1
bad = [r for r in rs if not (64 <= r[0] and r[1] <= 575)]
res = b.find(b'RSCE', 27407104)
dtbs = [m.start() for m in re.finditer(re.escape(b'\xd0\x0d\xfe\xed'), b)
        if struct.unpack_from('>I', b, m.start() + 4)[0] and m.start() + struct.unpack_from('>I', b, m.start() + 4)[0] <= len(b)]
print(f"{label}: {len(b):,} B, differs from capture in {len(rs)} ranges {rs[:6]}{' ...' if len(rs) > 6 else ''}")
print(f"  tail resource header @{res:,}, DTBs at {sorted(dtbs)}")
if bad:
    print(f"FAIL {label}: changed outside the cmdline field (64..575): {bad}"); sys.exit(1)
if res != 32092160 or sorted(dtbs) != [26482688, 32093696, 32636928]:
    print(f"FAIL {label}: tail resource/DTB positions are not the capture's"); sys.exit(1)
print(f"PASS {label}: only the cmdline field changed; kernel, second, ramdisk, tail resource and DTBs byte-identical")
PY
}

echo "== L0: identity repack of the stock capture (D67 check 1) =="
python3 "$REPO/tools/rebuild_boot_faithful.py" "$CAPTURE" "$CAPTURE" "$LADDER_DIR/L0-stock.img" | sed 's/^/  /' || exit 1
verify "$LADDER_DIR/L0-stock.img" L0 || exit 1

echo "== L1: one cmdline token per image =="
for token in $TOKENS; do
  name="L1-$(printf '%s' "$token" | tr -c 'a-z0-9' '-' | sed 's/-*$//')"
  cp "$LADDER_DIR/L0-stock.img" "$LADDER_DIR/$name.img" || exit 1
  python3 "$REPO/tools/patch_boot_cmdline.py" "$LADDER_DIR/$name.img" --add "$token" | sed 's/^/  /' || exit 1
  verify "$LADDER_DIR/$name.img" "$name" || exit 1
done

echo "== manifest =="
MAN="$LADDER_DIR/MANIFEST.sha256"
{
  printf '# ladder images staged offline Nov 19 from capture %s\n' "$EXPECTED_SHA"
  printf '# rule: one variable per flash (D62); rollback is the capture itself, dd of all 33,554,432 B (D66)\n'
  printf '# nothing here is flashed; owner approval is required for each step (D38/D40)\n'
  for f in "$LADDER_DIR"/L*.img; do sha256sum "$f"; done
} > "$MAN"
cat "$MAN"
