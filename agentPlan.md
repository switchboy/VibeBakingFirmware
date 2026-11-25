# Agent plan — Android 14 on the PX6 (RK3399 / HCT4) head unit

Mission: a fully open, reproducible LineageOS 21 (Android 14) ROM for this MTC-family head unit that keeps the
car hardware working (MCU, keys, radio, CAN, Bluetooth, cameras, GPS), developed on an SD card and, once feature
complete, installed on the internal eMMC as a full replacement of the stock ROM. The repo is a DIY kit: recipe
+ tools that bake a ROM from the user's own unit firmware (`README.md`).

Canonical detail lives elsewhere; this file is the index, the way of working and the live risks. Numbers and
shas belong in `docs/findings.md` (attempt-by-attempt lab notebook, checked by `tools/facts.py`), decisions in
`docs/decisions.md`, the end goal and checklists in `docs/release.md`, the launcher design in
`docs/homescreen.md`, the doc map in `docs/index.md`. If this file and `docs/findings.md` disagree, findings.md
is right.

## Priority order (owner) - guard against scope creep
1. Feature-complete ROM on the card (HCT framework port, GApps, GPS/audio).
2. Release hardening + eMMC install (`docs/release.md`).
3. Niceties: the launcher (`docs/homescreen.md`).
4. Long-term blob-free mainline track (end of `docs/release.md`).

## State (Nov 24, attempt 33 prepared)
Working on the card: boot to the launcher, display, touch, ethernet (USB dongle), root adb over the network,
WiFi (WPA2), stay-awake, three-button navigation bar, the back key; HCT framework layer step 1 (`android.microntek.*`
on the boot classpath) and step 2 (`carservice` running inside HCTManagerService). Open: other hardware keys
(the kernel drops them unless a sink is registered - being traced), HCT Bluetooth + CAN bus (attempt 33 restores
`mtcser` and `HCTCanBus`), AV-in/DVD video (`libcvbs_jni.so`), GApps (super resize + MindTheGapps prepared),
GPS. Latest entries in `docs/findings.md` are the truth.

## Hard rules
* **The eMMC is never written** until the release install. All writes go to the card (`mmcblk1`), digest-checked
  before and after; the eMMC partition heads are re-hashed around every write. Resolve devices by size/type,
  never by name (**D76**).
* Owner decisions stay the owner's: anything outward-facing (GPL requests, publishing), the NTFS data drive
  (`/dev/sda2`: read-only, it has corruption), removing features, hardware changes.
* No UART. NAS credentials never in argv, docs or the repo. Never redistribute proprietary files.
* Destructive actions: look at the target first; keep every change reversible and recorded (what was removed,
  its sha, how to restore).
* **Never run `getevent` (or anything that queries every input device's name) on the unit:** an HCT input device
  has an invalid name pointer and the kernel panics (Nov 25, findings). Avoid broad device probes on the live unit
  without knowing the driver; read the saved kernel logs instead.
* Launcher test installs: only through `a14-work/deploy-launcher.sh` (tests, build must succeed, APK must contain
  `classes.dex`); never `adb install` a hand-built APK whose build log was not checked.

## How we work (the loop)
1. **Build** the change on image copies in `/home/Daan/vbf-work/a14-work/super9/`: edit ext4 with `debugfs`
   (keep mode, owner and the `security.selinux` xattr incl. its trailing NUL; use `rm`, not `unlink`, to delete),
   `e2fsck -fn` must return 0; splice into super with `tools/splice_super.py splice` (verifies every byte outside
   the replaced extents), list changed 4 MiB chunks with `diffchunks`.
2. **Write**: from the card recovery (Android 14 holds super open, so reboot first; a plain `reboot` lands in the
   card recovery because the wrapper armed the card BCB): `scripts/write_card_chunked.sh` with `ONLY_CHUNKS`,
   then `scripts/flash_card_a14.sh bcb-clear`.
3. **File before you boot**: findings entry + `tools/facts.py add` for every new sha, `facts.py check` clean,
   commit, push.
4. **Boot and observe**: `scripts/watch_live_a14.sh N` reboots into the card. If Android 14 answers it gets root
   adb (`setprop service.adb.root 1; setprop ctl.restart adbd`), disarms the dead-man crasher (`pkill -x
   hu-crasher`, or `setprop hu.disarm 1`) and captures dmesg + logcat; if the recovery answers (the 600 s
   dead-man fired or the boot died) it pulls pstore and the card log. The PID-1 wrapper (`tools/hu_card_arm.c`)
   records kmsg for the whole boot to the card, so even a cold reset leaves a log; crash records survive in the
   card's `/data/tombstones` and `/data/system/dropbox` (mount f2fs `ro,norecovery` from recovery).
5. **Analyse**: `tools/digest_recorder.py` for the card log; tombstones/dropbox for crashes; hand large dumps to
   a local subagent (below). Then the next single change.
* One logical change per boot where practical; independent fixes may be bundled if each is separately visible
  in the logs.
* Live fixes on a running unit (permission grants, appops, settings, `pm disable-user`) persist in `/data` and
  are recorded in findings; they must later move into the image or a first-boot step (`docs/release.md`).
* The owner tests on the unit and reports; keep the unit running for them (KEEP=1) and batch reboots.

## Offloading to local subagents
A local model runs as a `general` subagent (`ollama-local/qwen3.8-flash-next-gyro-gyro-s`). It is slow but
cheap; use it for token-heavy work, keep judgment and integration yourself, and **review everything before it
touches the unit**.

Good tasks: reading large dumps (58k-line logcats, tombstones, dropbox) into dense digests; surveys of
decompiled code (smali trees, `strings`, symbol tables); mechanical smali/dex edits with a precise spec;
writing a tool + its pytest test; downloading and unpacking a package into an install plan; disassembly of a
named function.

How to write the task:
* **Constrained scope**: exact input paths, exact output paths, a work directory of its own; "read-only", "no
  adb", "never write under /run/media" spelled out.
* **Clear, testable goals**: e.g. "`tools/dex_api_check.py ... --app X` must print an empty MISSING list",
  "pytest must pass", "no instruction may reference ...".
* **Deliverable spec**: file names, format, what the final answer must contain and its maximum length; ask it to
  append findings to a report file **as it goes** (long answers get truncated - this lost one trace).
* **Give it the facts already established** (live measurements, addresses, known constraints) so it does not
  rediscover or contradict them.
* Ask for exact evidence (log lines, file:line, addresses) rather than conclusions.

Review checklist for its output (each item caught a real defect this session): inverted conditions in patched
code (a registration guard skipped exactly when needed); removed-API calls left in code it was told not to touch;
claims that rest on its own collection artefact (a "duplicate" rc service that was one file globbed twice);
verify the headline claim yourself with one cheap command before building on it.

## Live risks
| Risk | Mitigation |
|---|---|
| Card super has three stuck-at-zero bits (**D102**) | keep those bytes between extents when re-placing/resizing partitions (`tools/repack_super_place.py --avoid`) |
| Kernel is a prebuilt binary without the mtc driver source | reverse engineer what is needed (kallsyms from the live kernel + disassembly); GPL source request is the owner's call |
| HCT code uses Android 10 APIs removed in Android 14 | `tools/dex_api_check.py` on every HCT dex before it ships; stub or redirect each missing call (a `NoSuchMethodError` is an Error and passes `catch (Exception)`) |
| Unsigned modified system APKs | accepted by Android 14 for `/system/priv-app` (attempt 32); for release, rebuild the patches as scripts applied to the user's own files |
| Boot-classpath changes | append BOOTCLASSPATH-only after `core-icu4j.jar` so the boot image stays a valid prefix; first boot recompiles (`odrefresh`) and is slow |
| A boot that hangs or loops | dead-man crasher + armed card BCB return every boot to the networked recovery with logs |
| Bricking the unit | eMMC untouched; stock backup (**D40**); the card can always be pulled |
