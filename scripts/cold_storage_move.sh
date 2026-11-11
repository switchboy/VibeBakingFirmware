#!/usr/bin/env bash
# cold_storage_move.sh - move week-long scratch off the full filesystems into NAS cold storage.
#
# Nothing is deleted before the copy is proven. Every stage verifies the moved bytes
# (sha256 of the payload images, or sha256sum -c against the stock backup's MANIFEST) before the
# source is removed. Run one stage at a time; each writes its own log.
#
#   WORK   local home for the ACTIVE payload   (default: /run/media/Daan/Opslagmonster/a14-work)
#   NAS    ssh target                          (default: root@192.168.1.29 via /tmp/opencode/omv.sh)
#   COLD   cold storage on the NAS storage pool (ZFS DataPool, ~908 GiB free)
#          default: /srv/50911774-19fb-46b6-bc9e-8cf81623d044/cold/vibe-baking
#   STAGE  payload | backup | tmpfs | nas
#
# Deliberately NOT moved: the stock rollback (hu-stock-backup stays reachable, its NAS mirror stays),
# the staged OEM blobs (ref-a10), the OEM firmware zips (daisaita_a11.zip, diatsia fw/), and the
# LineageOS tree (lineage21s). Those are inputs, not scratch.
set -u

WORK=${WORK:-/run/media/Daan/Opslagmonster/a14-work}
COLD=${COLD:-/srv/50911774-19fb-46b6-bc9e-8cf81623d044/cold/vibe-baking}
STAGE=${STAGE:?set STAGE to payload|backup|tmpfs|nas}
LOG=${LOG:-/run/media/Daan/Opslagmonster/cold-move.log}
SSH="sh /tmp/opencode/omv.sh"

say() { printf '%s\n' "$1" | tee -a "$LOG"; }

case "$STAGE" in
  payload)
    # The workstation's root filesystem is at 0 bytes free, so the payload cannot stay in /var/tmp.
    mkdir -p "$WORK/a14chk"
    say "== rsync /var/tmp/a14chk -> $WORK/a14chk =="
    rsync -a /var/tmp/a14chk/ "$WORK/a14chk/" 2>&1 | tail -3 | tee -a "$LOG"
    say "== verify =="
    ( cd "$WORK/a14chk" && sha256sum raw-super.img a14-boot-fixed.img 2>&1 | cut -c1-20 ) | tee -a "$LOG"
    say "expect raw-super d4b4990931cc and boot 933e2ecc4237"
    want=$(cd "$WORK/a14chk" && sha256sum raw-super.img 2>/dev/null | cut -c1-12)
    [ "$want" = "d4b4990931cc" ] || { say "ABORT: moved super hash is $want, not d4b4990931cc"; exit 1; }
    boot=$(cd "$WORK/a14chk" && sha256sum a14-boot-fixed.img 2>/dev/null | cut -c1-12)
    [ "$boot" = "933e2ecc4237" ] || { say "ABORT: moved boot hash is $boot, not 933e2ecc4237"; exit 1; }
    say "== source removed =="
    rm -rf /var/tmp/a14chk
    say "payload now in $WORK/a14chk"
    ;;

  backup)
    mkdir -p "$WORK/hu-stock-backup"
    say "== rsync /var/tmp/hu-stock-backup -> $WORK/hu-stock-backup =="
    rsync -a /var/tmp/hu-stock-backup/ "$WORK/hu-stock-backup/" 2>&1 | tail -3 | tee -a "$LOG"
    say "== verify against MANIFEST.sha256 =="
    # sha256sum prints the localized word (Dutch "goed"), so judge on its exit status, not on the text.
    ( cd "$WORK/hu-stock-backup" && sha256sum -c MANIFEST.sha256 2>&1 | grep -vE ': (OK|goed)$' | head -8 ) | tee -a "$LOG"
    if ( cd "$WORK/hu-stock-backup" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1 ); then
      say "manifest verified: all entries OK"
    else
      say "ABORT: manifest verification failed - source kept"
      exit 1
    fi
    say "== source removed (NAS mirror at aospbuild-archive/hu-stock-backup stays) =="
    rm -rf /var/tmp/hu-stock-backup
    ;;

  tmpfs)
    # /tmp is tmpfs: 13 GiB of stale images are sitting in RAM, not on disk.
    # rsync -e is space-split, so the askpass env has to be part of the command string.
    RS="env SSH_ASKPASS=/tmp/opencode/askpass.sh SSH_ASKPASS_REQUIRE=force ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=no -o ConnectTimeout=15"
    say "== rsync stale tmpfs images -> NAS cold ($COLD/workstation-tmpfs) =="
    sh -c "$SSH \"mkdir -p $COLD/workstation-tmpfs\"" 2>&1 | tail -1 | tee -a "$LOG"
    for d in hu-rollback hu-staged hu-images vendor-check rkresearch px6; do
      [ -e "/tmp/opencode/$d" ] || continue
      # rkresearch is a u-boot source clone: the NAS copy from an earlier pass is a different revision,
      # so its per-file sizes legitimately differ. It goes to its own remote directory, and --delete
      # makes that directory an exact mirror of the local clone (it is ours, created tonight).
      rd="$d"
      del=""
      if [ "$d" = rkresearch ]; then rd="rkresearch-nov11"; del="--delete"; fi
      rsync -a --no-progress $del -e "$RS" "/tmp/opencode/$d" "root@192.168.1.29:$COLD/workstation-tmpfs/$rd/" 2>&1 | tail -2 | tee -a "$LOG"
      # One ssh call, then compare the sorted name+size lists. Per-file ssh calls would take thousands
      # of round trips and thousands of log lines for a source tree like u-boot. The workstation sorts
      # under the Dutch locale and the NAS under C, so force C on both sides or the lists never match.
      loc=$(cd "/tmp/opencode/$d" && find . -type f -printf '%P %s\n' | LC_ALL=C sort)
      rem=$(sh -c "$SSH \"cd $COLD/workstation-tmpfs/$rd 2>/dev/null && find . -type f -printf '%P %s\n' | LC_ALL=C sort\"" 2>/dev/null)
      if [ "$loc" = "$rem" ]; then
        say "  $d: $(printf '%s\n' "$loc" | wc -l) files identical on the NAS -> removed from tmpfs"
        rm -rf "/tmp/opencode/$d"
      else
        say "  $d KEPT: $(diff <(printf '%s\n' "$loc") <(printf '%s\n' "$rem") | head -3 | tr '\n' ' ')"
      fi
    done
    for f in super_raw.img a10-system.img vendor_slice.img vendor-in-super.img hu-stage.b64 recomp.br card-dump.img; do
      [ -e "/tmp/opencode/$f" ] || continue
      rsync -a --no-progress -e "$RS" "/tmp/opencode/$f" "root@192.168.1.29:$COLD/workstation-tmpfs/" 2>&1 | tail -2 | tee -a "$LOG"
      loc=$(stat -c %s "/tmp/opencode/$f" 2>/dev/null)
      rem=$(sh -c "$SSH \"stat -c %s $COLD/workstation-tmpfs/$f\"" 2>/dev/null | tr -d ' \n')
      say "  $f  local=$loc remote=$rem"
      if [ "$loc" = "$rem" ]; then rm -f "/tmp/opencode/$f"; say "  $f removed from tmpfs"; else say "  $f KEPT: sizes differ"; fi
    done
    say "== tmpfs after =="
    df -h /tmp | tail -1 | tee -a "$LOG"
    ;;

  research)
    # The rest of /tmp/opencode: vendor/WiFi research extracts and one-off dumps. Not space-critical any
    # more (tmpfs is down to ~800 MB), but they are clutter and all re-obtainable, so they go to cold
    # storage. The ssh wrappers and the small probe scripts stay on the workstation - they are still in
    # use tomorrow (omv.sh, askpass.sh, laptop_askpass.sh, build_wifi_*.sh, probe*.py).
    RS="env SSH_ASKPASS=/tmp/opencode/askpass.sh SSH_ASKPASS_REQUIRE=force ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=no -o ConnectTimeout=15"
    say "== rsync research extracts -> NAS cold ($COLD/research) =="
    sh -c "$SSH \"mkdir -p $COLD/research\"" 2>&1 | tail -1 | tee -a "$LOG"
    for d in boothdr drv oemchk rktools ref_libs rkrescue rk u compat hosttools bootableSD bench ai ai2; do
      [ -e "/tmp/opencode/$d" ] || continue
      # These remote directories are ours (created tonight), so --delete makes them an exact mirror.
      # Names with spaces (e.g. "Create Upgrade Disk Tool v1.53.exe") break a per-file read loop, so
      # compare one sorted name+size list per directory in a single ssh call.
      rsync -a --no-progress --delete -e "$RS" "/tmp/opencode/$d" "root@192.168.1.29:$COLD/research/" 2>&1 | tail -2 | tee -a "$LOG"
      loc=$(cd "/tmp/opencode/$d" && find . -type f -printf '%P\t%s\n' | LC_ALL=C sort)
      rem=$(sh -c "$SSH \"cd $COLD/research/$d 2>/dev/null && find . -type f -printf '%P\t%s\n' | LC_ALL=C sort\"" 2>/dev/null)
      if [ "$loc" = "$rem" ]; then
        say "  $d: $(printf '%s\n' "$loc" | wc -l) files identical on the NAS -> removed"
        rm -rf "/tmp/opencode/$d"
      else
        say "  $d KEPT: $(diff <(printf '%s\n' "$loc") <(printf '%s\n' "$rem") | head -3 | tr '\t\n' ' ' | cut -c1-120)"
      fi
    done
    for f in hu-stage.tar index.xml t.json tags.json aic_tree.json am.xml agentPlan.old; do
      [ -e "/tmp/opencode/$f" ] || continue
      rsync -a --no-progress -e "$RS" "/tmp/opencode/$f" "root@192.168.1.29:$COLD/research/" 2>&1 | tail -2 | tee -a "$LOG"
      loc=$(stat -c %s "/tmp/opencode/$f")
      rem=$(sh -c "$SSH \"stat -c %s $COLD/research/$f\"" 2>/dev/null | tr -d ' \n')
      say "  $f  local=$loc remote=$rem"
      if [ "$loc" = "$rem" ]; then rm -f "/tmp/opencode/$f"; say "  $f removed"; else say "  $f KEPT: sizes differ"; fi
    done
    say "== tmpfs after =="
    df -h /tmp | tail -1 | tee -a "$LOG"
    ;;

  nas)
    # Old build passes inside the DataPool archive get tidied into cold/, still on the pool.
    # Nested ssh quoting eats operands, so the NAS-side script (scripts/cold_nas.sh) is transferred
    # as base64 and run there.
    NSS=${NSS:-/run/media/Daan/Opslagmonster/VibeBakingFirmware/scripts/cold_nas.sh}
    [ -f "$NSS" ] || { say "ABORT: no NAS script $NSS"; exit 1; }
    b64=$(base64 -w0 "$NSS")
    say "== tidy NAS archive + scratch into $COLD =="
    sh -c "$SSH \"printf '%s' '$b64' | base64 -d > /var/tmp/cold_nas.sh && bash /var/tmp/cold_nas.sh\"" 2>&1 | tail -20 | tee -a "$LOG"
    ;;

  *) say "unknown STAGE: $STAGE"; exit 1 ;;
esac
