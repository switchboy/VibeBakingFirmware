#!/usr/bin/env bash
# Attempt $N with the dead-man boot image (attempt 26+): reboot recovery into the card's Android 14 and
# watch 192.168.1.127:5555. Android 14's adbd and the card recovery's adbd answer on the same address, so
# each answer is told apart by ro.build.version.release. If Android 14 answers it disarms the crasher
# (pkill -x hu-crasher) and captures a live snapshot; if the card recovery answers first, the dead-man
# crasher fired (or something else rebooted) and watch.sh's capture is run instead.
set -u
IP=192.168.1.127
export ANDROID_SERIAL=$IP:5555
N=${1:?attempt number}
KEEP=${KEEP:-1}     # 1 = leave Android 14 running after the capture; 0 = reboot it into recovery
D=/home/Daan/vbf-work/a14-work/a14-attempt$N
mkdir -p "$D"
echo "=== $(date +%H:%M:%S) rebooting into the card (epoch $(date +%s)) ==="
adb root >/dev/null 2>&1; adb shell sync >/dev/null 2>&1; adb reboot >/dev/null 2>&1
seen_down=0; t=0
while [ "$t" -lt 90 ]; do      # 15 min
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && p=up || p=--
  (echo >/dev/tcp/"$IP"/5555) 2>/dev/null && a=open || a=----
  [ "$p" = -- ] && seen_down=1
  printf '%s  %3d  ping=%s  5555=%s  down_seen=%s\n' "$(date +%H:%M:%S)" "$t" "$p" "$a" "$seen_down"
  if [ "$a" = open ] && [ "$seen_down" = 1 ]; then
    adb disconnect "$IP:5555" >/dev/null 2>&1; adb connect "$IP:5555" >/dev/null 2>&1; sleep 2
    rel=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
    echo "=== $(date +%H:%M:%S) adb answered: release='$rel' ==="
    if [ "$rel" = 14 ]; then
      # LineageOS gates "adb root"; on this userdebug build with SELinux permissive the shell may set
      # service.adb.root and restart adbd through init, and adbd then starts as root (attempt 29).
      adb shell 'setprop service.adb.root 1; setprop ctl.restart adbd' >/dev/null 2>&1; sleep 6
      adb connect "$IP:5555" >/dev/null 2>&1; sleep 2; echo "adb uid: $(adb shell id -u | tr -d '\r')"
      echo "--- disarming the dead-man crasher"
      adb shell 'ps -A -o PID,NAME | grep -E "hu-crasher|hu-recorder"; pkill -x hu-crasher; sleep 1; ps -A -o PID,NAME | grep -c hu-crasher' 2>&1 | tr -d '\r'
      {
        echo "### live Android 14 capture $(date -u +%FT%TZ)"
        adb shell 'echo "uptime: $(cat /proc/uptime)"; echo "boot_completed: $(getprop sys.boot_completed)"
                   ip -o addr show eth0; dmesg | grep -E "hu-mtc|--mtc @|--mtc b|usb 1-1|ax88179|eth0" | head -40'
      } 2>&1 | tr -d '\r' > "$D/live.txt"
      cat "$D/live.txt"
      adb shell 'dmesg' 2>/dev/null | tr -d '\r' > "$D/dmesg.txt"
      adb logcat -d -b all 2>/dev/null > "$D/logcat.txt"
      ls -l "$D"/dmesg.txt "$D"/logcat.txt
      if [ "$KEEP" = 0 ]; then adb reboot recovery >/dev/null 2>&1; fi
      echo "=== live capture done (KEEP=$KEEP) ==="
      exit 0
    fi
    echo "--- not Android 14: running the recovery capture"
    exec bash /home/Daan/vbf-work/a14-work/watch.sh "$N-rec" --no-reboot
  fi
  t=$((t+1)); sleep 10
done
echo "attempt $N live watch: nothing answered in 15 min"
