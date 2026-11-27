#!/usr/bin/env bash
# Attempt $N, fully remote. Reboot Android 10 into the card; the wrapper arms the card BCB, and 60 s later
# its child dumps the task backtraces, copies the pstore records into the card's unpartitioned head at
# 2 MiB, and crashes the boot so panic=10 reboots in software. Whatever boots next answers on adb, and
# this pulls BOTH log channels: the pstore records (survive a software reboot) and the card copy (survives
# any reset, so it works even after the owner's button press).
set -u
IP=${HU_IP:-192.168.1.127}   # override: HU_IP=192.168.1.128 when DHCP hands out another address
export ANDROID_SERIAL=$IP:5555
N=${1:?attempt number}
D=/run/media/Daan/Opslagmonster/VibeBakingFirmware/log/attempt$N
mkdir -p "$D"

seen_down=0
if [ "${2:-}" = --no-reboot ]; then
  echo "=== $(date +%H:%M:%S) capture only (already rebooted) ==="; seen_down=1
else
echo "=== $(date +%H:%M:%S) rebooting Android 10 into the card (epoch $(date +%s)) ==="
adb root >/dev/null 2>&1
adb shell 'sync' >/dev/null 2>&1
adb reboot >/dev/null 2>&1
fi

t=0
while [ "$t" -lt 75 ]; do          # 8 min
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && p=up || p=--
  (echo >/dev/tcp/"$IP"/5555) 2>/dev/null && a=open || a=----
  [ "$p" = -- ] && seen_down=1
  printf '%s  %3d  ping=%s  5555=%s  down_seen=%s\n' "$(date +%H:%M:%S)" "$t" "$p" "$a" "$seen_down"
  if [ "$a" = open ] && [ "$seen_down" = 1 ]; then
    echo "=== $(date +%H:%M:%S) answered - capturing both log channels ==="
    adb connect "$IP:5555" >/dev/null 2>&1; sleep 2
    adb root >/dev/null 2>&1; sleep 3
    {
      echo "### captured $(date -u +%FT%TZ)"
      adb shell 'echo "fingerprint: $(getprop ro.build.version.release) $(getprop ro.build.version.incremental)"
                 echo "boot_completed: $(getprop sys.boot_completed)"
                 echo "uptime: $(cat /proc/uptime)"
                 echo "cmdline: $(cat /proc/cmdline)"
                 echo "--- card state"
                 printf "card present: "; grep -E "[ ]mmcblk1\$" /proc/partitions | awk "{print \$3 \" blocks\"}"
                 printf "card p7:      "; sha256sum /dev/block/mmcblk1p7 | cut -c1-12
                 printf "card BCB:     "; dd if=/dev/block/mmcblk1 bs=1 skip=16777216 count=2048 2>/dev/null | sha256sum | cut -c1-12
                 echo "--- pstore"
                 ls -l /sys/fs/pstore/ 2>&1'
    } 2>&1 | tr -d '\r' > "$D/state.txt"
    cat "$D/state.txt"
    for f in $(adb shell 'ls /sys/fs/pstore/ 2>/dev/null' | tr -d '\r'); do
      echo "--- pulling pstore/$f"
      adb exec-out "toybox dd if=/sys/fs/pstore/$f bs=65536 2>/dev/null" > "$D/$f"
      ls -l "$D/$f"
    done
    echo "--- pulling the card log copy (bytes 2,097,152..7,340,032)"
    adb exec-out 'toybox dd if=/dev/block/mmcblk1 bs=1024 skip=2048 count=5120 2>/dev/null' > "$D/card-log.bin"
    ls -l "$D/card-log.bin"
    head -c 64 "$D/card-log.bin" | tr -d '\0' | tr -c '[:print:]\n' '.'; echo
    ( cd "$D" && sha256sum ./* > MANIFEST.sha256 2>/dev/null; ls -la )
    echo "=== capture done ==="
    break
  fi
  t=$((t+1)); sleep 10
done
echo "attempt $N watch finished at tick $t"
L=$D/card-log.bin
if [ -s "$L" ]; then
  echo "=== heartbeat ==="; head -c 64 "$L" | tr -d '\0'; echo
  n=$(head -c 64 "$L" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')
  head -c $((64 + ${n:-0})) "$L" | tail -c "${n:-0}" | tr -d '\0' > "${L%.bin}-regionA.txt"
  echo "=== last 60 recorder lines (region A, $n B) ==="; tail -60 "${L%.bin}-regionA.txt"
fi
echo "=== previous-boot pstore region (6..7 MiB) ==="
adb exec-out 'toybox dd if=/dev/block/mmcblk1 bs=1024 skip=6144 count=1024 2>/dev/null' > $D/card-prev.bin
head -c 64 $D/card-prev.bin | tr -d '\0'; echo
