#!/usr/bin/env python3
"""Make a harness-only copy of the payload's first-stage init that can NEVER reach second stage.

  python3 tools/patch_init_second_stage_stub.py <init> <out>

Why: run inside the namespace harness that **D59** froze, Android 14's init mounts the virtual partitions and then
execve's "/system/bin/init" to become second-stage init. Second stage starts services (zygote,
surfaceflinger, ...), and those services reach GLOBAL kernel state that a mount namespace does NOT
isolate - /sys/power/state writes, binder, GPU/panel nodes. On the head unit that meant a
suspend/crash and a reboot into Android 10 mid-run.

The binary holds exactly one null-terminated "/system/bin/init" (offset found empirically on the
Nov 18 payload capture). Changing the 'i' of "init" to 'z' ("init" -> "zint") keeps the string
length identical and makes the execve fail with ENOENT, so first-stage init logs its mount results,
then aborts cleanly. Services never start, nothing global is touched. The payload boot images are
NOT modified; only the harness copy of /init is patched.
"""
import sys

PAT = b"/system/bin/init\x00"
# Same byte length: "init" -> "zint". A different 4-char tail keeps the string the same size.
TARGET = b"/system/bin/zint\x00"


def main():
    src, dst = sys.argv[1], sys.argv[2]
    d = open(src, "rb").read()
    hits = []
    i = 0
    while True:
        j = d.find(PAT, i)
        if j < 0:
            break
        hits.append(j)
        i = j + 1
    if len(hits) != 1:
        raise SystemExit("expected exactly one null-terminated '/system/bin/init', found %d at %s"
                         % (len(hits), hits[:10]))
    off = hits[0]
    out = d[:off] + TARGET + d[off + len(PAT):]
    assert len(out) == len(d)
    open(dst, "wb").write(out)
    print("patched execve path at byte %d ('/system/bin/init' -> '/system/bin/zint'), size %d B, out %s"
          % (off, len(out), dst))


if __name__ == "__main__":
    main()
