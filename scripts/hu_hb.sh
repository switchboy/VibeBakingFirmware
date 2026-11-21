#!/sbin/sh
# hu-hb.sh - heartbeat. One "alive up=<uptime>" line every 5 s for 20 min: proves slow-vs-stuck
# without blocking anything else. The line is written BEFORE the stop flag is checked, so a
# teardown always leaves at least one heartbeat line behind - that is what distinguishes "stopped
# on request" from "never started". Teardown request = /cache/hu-net.stop, or a NEW nonce written
# to /cache/hu-net.request (hu-net.sh handles the nonce side itself).
. /sbin/hu-h-common.sh
cache_ready || { say "heartbeat: cache not mounted, giving up"; exit 1; }
ticks=${HB_TICKS:-240}   # 240 * 5 s = 20 minutes on the unit; overridable for offline tests only
i=0
while [ "$i" -lt "$ticks" ]; do
  say "alive up=$(uptime_s)"
  i=$((i + 1))
  [ -f "$CACHE/hu-net.stop" ] && { say "heartbeat: stop flag seen, exiting at tick $i"; exit 0; }
  $BB sleep 5
done
say "heartbeat: window complete ($ticks ticks)"
exit 0
