# Housekeeping - keeping the project from becoming a storage black hole

**Status: adopted Nov 27 (owner approved).**

Why: by Nov 27 the project had spread over ~350 GB in five places (home dir, `/tmp` tmpfs, Opslagmonster, NAS
`/tmp`, NAS build tree), with up to nine copies of one image and a chain of 3 GB super images per attempt. Four
work folders were lost and the only copies of the rollback captures sat in RAM-backed `/tmp`. These rules keep
one copy of what matters in a known place and let everything else go on a schedule.

## 1. Where things live (and nowhere else)

| What | Where | Synced to git? |
|---|---|---|
| Repo (code, docs, facts) | `/run/media/Daan/Opslagmonster/VibeBakingFirmware` | yes |
| Stock inputs (`update.zip`, `diatsia fw/`) and `analysis/` dumps incl. the full eMMC snapshot `analysis/gpt/disk.img` | inside the repo, git-ignored | no |
| Logs and device captures | `<repo>/log/` (`log/attemptN/`, `log/launcher-*.txt`, ...) | no, never (git-ignored, not in any rsync) |
| Current images (the card's state + the one being built) | `a14-work/images/attemptN/` | no |
| Cold storage: latest verified stock backup, current card boot/recovery | `a14-work/cold/` | no |
| Built artefacts that went into the current image (shims, overlays, launcher APK) | `a14-work/staging/` | no |
| Temporary work (unpacked APKs, screenshots, splice inputs) | `a14-work/scratch/` | no |
| Small tools (smali, test keys, avbtool) | `a14-work/tools/` | no |
| Off-machine copy of `cold/` (the only NAS cold store) | NAS DataPool `/srv/50911774-19fb-46b6-bc9e-8cf81623d044/cold/vibe-baking/current/` | no |
| NAS build tree (only `lineage21s` + `out/soong`, `out/host`) | `/srv/dev-disk-by-label-SSData/aospbuild/` | no |
| NAS access | `~/.config/vbf/` (`omv.sh`, `askpass.sh`, `nas.env` mode 600) | no, never |

`a14-work` = `/run/media/Daan/Opslagmonster/a14-work` (btrfs). **Never** the home dir, and **never `/tmp`** for
anything that must survive: `/tmp` is tmpfs and is wiped on reboot. Scripts take these paths from the repo, not from
memory.

History of earlier moves: `docs/housekeeping-history.md`.

## 2. Keep only the latest

* **Images**: keep the current card state and the attempt being built. When attempt N is on the card and boots,
  delete `images/attempt(N-1)/`. Never keep a chain of super images (3 GB each); a finding plus the sha in
  `facts.tsv` is the record of an old attempt.
* **Cold storage**: exactly two places hold the same set - `a14-work/cold/` and its NAS mirror `cold/vibe-baking/current/`
  (different machines, so one disk failure loses nothing). The set: one verified stock backup (with `MANIFEST.sha256`, checked with `sha256sum -c` after every move)
  and the current card boot/recovery. A new backup replaces the old one after it verifies; never two.
* **Staging**: replaced on every rebuild; holds only what is in the current image.
* **One copy per sha**: before copying an image, check whether that sha already exists (`MANIFEST.sha256`). Never
  scatter `cp` copies "to be safe".

## 3. Lifetimes

| Item | Lives until |
|---|---|
| `scratch/` contents, screenshots | end of the session (scratch is empty when a session ends) |
| `log/attemptN/` captures | the finding for that attempt is filed and committed; keep the last 3 attempts |
| Evidence a finding cites by path (e.g. `log/panic-20261125/`) | the issue is resolved; listed in `log/KEEP` with the reason |
| NAS `/tmp/hu-*`, `/tmp/vbl-build` build scratch | outputs are pulled into `staging/` and their sha is recorded |
| NAS logs | not kept on the NAS: pull what is needed into `log/`, delete the rest |
| Old build outputs (`out/`, image chains, unpacked packages) | superseded: they are reproducible from the recipe |

## 4. Budgets (checked at the end of each session)

* `a14-work` excluding `cold/`: at most 15 GB (one image set is ~5 GB).
* `log/`: at most 1 GB.
* NAS SSData: at least 15 GB free before any soong run (graph regeneration needs ~3.6 GB plus outputs).
* Home dir and `/tmp`: no project files at all.

## 5. Deleting safely

* Look at the target first (`ls`, `du`, sha); delete by explicit name, never by broad globs on shared places (NAS `/tmp`).
* Before deleting anything whose sha is in `facts.tsv` as a rollback or stock image, confirm a verified copy exists
  in `cold/` or `analysis/`.
* Record bulk removals in `docs/findings.md` (what, size, where the surviving copy is).
* Optional, cheap on btrfs: a read-only snapshot of `a14-work` before a destructive step
  (`btrfs subvolume snapshot -r`), deleted when the step succeeded. Needs `a14-work` to be a subvolume.

## 6. End-of-session checklist

1. `scratch/` empty; screenshots gone.
2. Images: only the current and in-progress attempts.
3. New captures in `log/`, older than the last 3 attempts removed (except `log/KEEP` entries).
4. NAS `/tmp` build scratch pulled and cleaned.
5. `du -sh a14-work/* log` within budget; nothing new in `~` or `/tmp`.

## 7. One-time cleanup of the NAS cold store (approved Nov 27)

What is there now (Nov 27), all from passes that have been superseded:

| NAS path (DataPool unless noted) | Size | Proposal |
|---|---|---|
| `cold/vibe-baking/aosp-out-nov15`, `nas-tree-images-nov22` | 13 + 5.3 GB | delete: old LineageOS build outputs, rebuilt by any `make` |
| `cold/vibe-baking/workstation-tmpfs`, `nas-var-tmp`, `research` | 15 + 1.8 + 0.3 GB | delete: Nov 11 scratch and research extracts |
| `cold/vibe-baking/nas-archive` (old passes, `vibe-rescue`, `update.zip`) | 8.2 GB | delete: superseded; `update.zip` is in the repo dir |
| `cold/vibe-baking/hu-wrap-nov22`, `hu-card-p8-nov23*`, `recovery-patched` | 1.6 + 0.2 GB | delete: superseded by the current card boot/recovery in `cold/card-current` |
| `/srv/cold/vibe-baking/recovery-patched` (NAS root disk) | 38 MB | delete: duplicate of the one above |
| `aospbuild-archive/hu-stock-backup` (Nov 11) | 3.3 GB | delete after the Nov 17 backup is mirrored (it is the older of the two) |
| `aospbuild-archive/hucheck`, `ref-a10`, `ref-a10-live`, `daisaita_a11.zip` | 7.7 GB | delete: gate scratch and reference extracts, reproducible from the OEM packages in the repo dir |
| new: `cold/vibe-baking/current/` | 3.4 GB | mirror of `a14-work/cold/` (stock backup Nov 17 + card p7/p8), checked with `sha256sum -c` |

Net: about 56 GB freed on the DataPool (98 % full), one verified off-machine copy of the cold set kept.
