# Consolidation plan - what to merge, in what order, and what must never be merged

Plan only. Nothing here deletes or rewrites a doc; every step is executed later with `tools/doc_edit.py`,
one anchor at a time, with `tools/doc_lint.py` and `tools/facts.py check` run before and after.

The point is not to make the docs shorter. It is to make a fact have **one** place to change. Today a
payload sha or a criterion is stated in six files, so the next session can read a stale copy and flash
the wrong image. `facts.tsv` (repo root, built by `tools/facts.py`) is the authority: each fact has one
`canonical_doc`, and `tools/facts.py audit` lists every other file that repeats it.

## What the audit measured today (2026-11-19 evening, re-measured after the Nov 19 live session; earlier passes
were 2026-11-17 and 2026-11-19 daytime)

`python3 tools/facts.py audit` -> 155 registered facts, **236 duplicated mentions**, no fact missing
from its canonical doc. `python3 tools/facts.py check` -> clean: every 64-hex and 12-hex token in the
docs is registered, so a sha cannot drift silently. The Nov 19 evening measurements added the pstore record
digests, the post-L0 screencap digest and four decision records, which is why the count moved from 142 to 155.
One caveat when reading the duplicate count: small integer measurements (`670`, `97,430`) match unrelated
numbers in other files, so numeric facts over-report duplication; the sha and prose facts are exact.

| file | repeated facts | note |
|---|---|---|
| docs/decisions.md | 46 | decision text should carry D-numbers, not the payload values |
| docs/flash.md | 45 | already the canonical home of the operator payload shas |
| docs/findings.md | 34 | holds the Nov 11/Nov 12 staging lists and the Nov 19 record digests, restated later |
| agentPlan.md | 25 | the lean index should point at docs, not restate values |
| docs/reanimation.md | 13 | a run log; it repeats what flash.md owns |
| docs/blind-plan-corrections.md | 13 | the Nov 18 corrections file quotes values owned elsewhere |
| docs/head-unit-findings.md | 12 | live-unit facts duplicated from findings.md; questions 8/12/13/14 are now answered |
| README.md | 11 | the front page repeats payload shas and package paths |
| docs/build-host.md | 10 | NAS paths duplicated from housekeeping.md, plus the `670` numeric coincidence |
| docs/plan.md | 9 | the pre-D52 plan; its criteria list is the superseded D49 wording |
| docs/housekeeping.md | 6 | staging shas duplicated from findings.md |
| docs/feasibility.md | 5 | pre-decision estimates, plus the `670` numeric coincidence |
| docs/index.md | 3 | the map itself quotes a payload sha |
| docs/ota.md | 2 | future OTA story, quotes the payload zip |
| docs/firmware-analysis.md | 1 | Phase 0 inventory repeats a partition fact |
| docs/upstream.md | 1 | the unpublished drafts repeat a payload path |

Docs by size, for context: findings.md 3476, decisions.md 2000, build-host.md 644, flash.md 530,
reanimation.md 374, plan.md 374, head-unit-findings.md 347, upstream.md 285, agentPlan.md 279,
feasibility.md 212, consolidation.md 177, README.md 151, housekeeping.md 133, firmware-analysis.md 122,
ota.md 100, blind-plan-corrections.md 71, termux.md 36, index.md 27 (9338 lines total, `facts.tsv` 155 facts).

Two naming/content fixes the earlier pass noted and they still stand (they are lint findings, not audit rows):
`docs/firmware-analysis.md` has a table column mismatch, and `docs/upstream.md` names the super checker under
`tools/` when the real file lives in `scripts/`.

## Cluster 1 - operator payload shas (canonical: docs/flash.md)

The images an operator must verify are owned by `docs/flash.md`. Every other mention becomes a pointer
("the shape-A pair is in `docs/flash.md`"), never a value:

- `agentPlan.md` 174-176 - shape A super/vendor/boot + the container `d81f913a`
- `agentPlan.md` 198 - shape B `55be70ab`
- `docs/decisions.md` 1748, 1763 - Nov 11 container `d4b49909`, shape-A pair `3cf40129`/`d81f913a`
- `docs/plan.md` 238-239 - `3cf40129`, `455a9ac8`, `933e2ecc`
- `docs/findings.md` 2867-2869, 2905, 2910-2919 - shape B gate block restating the flash.md table
- `docs/housekeeping.md` 31, 46-47 - Nov 11 staging dir contents
- `docs/reanimation.md` 6-7, 11, 53-54 - Nov 8/Nov 11 run-log values
- `docs/index.md` 6 - the map quoting `455a9ac8`
- `README.md` payload lines

Estimated saving: ~30 lines (12-hex abbreviations are one token per mention; where the value sits in
prose, stripping the token saves ~1 line and the pointer costs ~1).

## Cluster 2 - criteria lists (canonical: docs/decisions.md, `criterion.d58.first-boot`)

D58 (Nov 17) is the live list: **not bricked, boots, WiFi associated, screen shows pixels**. D49's list
(`criterion.d49.superseded`) survives only as history.

- `docs/decisions.md` 1578 (D49) stays, marked superseded; 1819 (D58) is canonical.
- `docs/plan.md` 352 - the old D49 list written as if it were current -> replace with one sentence
  naming D58 and pointing at decisions.md.
- `docs/findings.md` 2863-2919 - the shape-B gate restates the criteria; keep the gate's *measurements*,
  drop the criteria prose.
- `agentPlan.md` 15 ("Next moves") and `docs/ota.md` 44 ("State of the OTA path right now") - state
  prose, not criteria; point at D58.

Estimated saving: ~12 lines, and it removes the risk of a session treating GPS/sound-input as blocking.

## Cluster 3 - live head-unit facts (canonical: docs/head-unit-findings.md)

Partition sizes, the group maximum, connector/power observations belong to
`docs/head-unit-findings.md`; `docs/findings.md` quotes them in the Nov 11/Nov 12 sections.

- `docs/head-unit-findings.md` 237-240 - **the same open question is numbered 1 twice** (doc_lint flags
  it at 239). Merge into one item.
- `docs/findings.md` 1074-1105, 1870-1871 - baseline/backup facts repeated from the unit doc.

Estimated saving: ~10 lines.

## Cluster 4 - NAS and work-directory paths (canonical: docs/housekeeping.md, docs/build-host.md)

- `README.md` 48, `docs/build-host.md` 13 repeat `path.nas.build-tree` (canonical housekeeping.md).
- `docs/decisions.md` 1086, `docs/findings.md` 415/2601, `docs/flash.md` 396, `docs/reanimation.md` 50
  repeat the archive root; `docs/findings.md` 2601 repeats the gate scratch dir.
- `a14-work/*` staging dirs are repeated eight times in `docs/findings.md` - they are one fact each.

Estimated saving: ~14 lines. Paths are the cheapest to fix and the most dangerous when wrong: a wrong
archive path sends a session looking for a rollback image in the cold storage.

## Cluster 5 - state and next-move prose

`docs/build-host.md` 81 ("Host state Nov 15"), `docs/findings.md` 1308 ("Queued for the morning"),
`docs/ota.md` 44, `agentPlan.md` 70 ("Current state") and 194 ("Next moves") all describe the same
moment from different angles. Target: `agentPlan.md` is the only place that states the current state;
the others become dated notes ("state as of Nov 15; see agentPlan.md").

Estimated saving: ~15 lines. Do not merge the dated evidence under them - the dates are the value.

## Target layout after consolidation

| kind | canonical home |
|---|---|
| operator payload shas, sizes of staged images | `docs/flash.md` |
| measurements of the unit itself | `docs/head-unit-findings.md` |
| offline measurements, evidence tables | `docs/findings.md` |
| decisions and criteria (D1-D58) | `docs/decisions.md` |
| NAS paths, cold storage, scratch dirs | `docs/housekeeping.md` |
| build host, mirror checkout, build commands | `docs/build-host.md` |
| current state and the agent's next move | `agentPlan.md` |
| the map of which doc owns what | `docs/index.md` (updated to name the registry) |

`docs/index.md` should point at `facts.tsv` and say: change a value in its canonical doc, then run
`tools/facts.py audit`.

## Defects to fix while consolidating (from `tools/doc_lint.py`, 20 findings today)

These are real markdown bugs, not style complaints - an unbalanced `**` swallows bold for the rest of
the block, and a table row with the wrong cell count renders as garbage:

| file:line | rule | fix |
|---|---|---|
| docs/decisions.md 1067-1079 | bold-unbalanced (5 markers) | close the bold opened in that block |
| docs/decisions.md 51-52 | table-columns (3 cells vs 2-cell header) | drop the extra column or widen the header |
| docs/findings.md 2366-2371 | bold-unbalanced (1 marker) | stray backtick is swallowing the closing `**` |
| docs/findings.md 2852-2858 | bold-unbalanced (7 markers) | `****D19**` at 2852 |
| docs/findings.md 2042 | broken-path | device/rk3399-px6-hct4/vendor_build_wins.txt exists only on the NAS mirror - mark it as such |
| docs/firmware-analysis.md 74-77 | table-columns (2 vs 3) | same table, header at 65 |
| docs/head-unit-findings.md 239 | num-order | the duplicate item 1 (cluster 3) |
| docs/head-unit-findings.md 264-267 | bold-unbalanced (3 markers) | close the bold |
| docs/plan.md 141, 152 | broken-path | tools/mk_update_zip.py and docs/release.md do not exist |
| docs/reanimation.md 264 | heading-jump (h3 after h1) | insert the missing h2 |
| docs/reanimation.md 344 | broken-path | scripts/restore_stock_backup.sh does not exist |
| docs/upstream.md 267 | broken-path | should be `scripts/check_super.py` |
| docs/upstream.md 57 | broken-path | docs/board/rockchip/rockchip.html does not exist |

**Nov 18: every row above is fixed** and `tools/doc_lint.py` reports zero findings. The dead references were
resolved by pointing at the real file where one exists (`scripts/restore_oem_android10.sh`,
`scripts/check_super.py`, `docs/ota.md`) and by dropping the path shape where the file was never written, so
history stays in prose instead of a broken link. The duplicate numbered item and the unbalanced `**` blocks
are closed as well.

Dead references are history: either point at the real file, or say in prose that the script was never
written. Do not delete a sentence that records a decision.

## Order of execution

1. `python3 tools/doc_lint.py` - fix the 20 findings; the linter must be clean before anything else.
2. One cluster at a time, smallest first (cluster 4, then 3, 2, 1, 5), with `tools/doc_edit.py`:
   `--replace --anchor ... --end-anchor ...` for a block, `--delete-block --end ...` for a restated
   list, `--num-replace` for the duplicated numbered item.
   Run `doc_lint.py` after each edit; a cluster is done when `doc_lint` is clean and `facts.py audit`
   shows one fewer duplicate.
3. After all clusters: `python3 tools/facts.py audit && python3 tools/facts.py check`.
   Expect the duplicate count to fall from 180; the registered facts must not change value.
4. `bash scripts/repo_update.sh --dry-run` (mirror + verification, NAS untouched), then the real run
   with `--message`. `repo_update.sh` aborts if `doc_lint` fails, so an unbalanced bold never reaches
   the NAS copy.

## What must not be consolidated

- Decision rationale. D1-D58 prose stays in `docs/decisions.md`; only the *values* inside it move out.
- Dated evidence and timestamps - the date is the fact, so merging two dated observations loses data.
- Brick-risk reasoning and rollback instructions: repetition there is intentional redundancy, since an
  operator reads one file at a time. Keep the payload sha in `docs/flash.md` AND in the card manifest
  (`scripts/write_rescue_sd.sh`); those are two media, not two copies of one doc.
- `facts.tsv` rows whose notes say NOT CONFIRMED: the full sha exists only outside this repo
  (`a14-work/hu-stock-backup-refresh/MANIFEST.sha256`). Do not invent a value to make a row complete;
  register the prefix and keep the note.
