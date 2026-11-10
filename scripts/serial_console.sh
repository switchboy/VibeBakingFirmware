#!/usr/bin/env bash
# Serial console capture / interactive shell for the bench (docs/reanimation.md §3, §5).
#
#   scripts/serial_console.sh check              # what the OS sees on the port
#   scripts/serial_console.sh log <name>         # read-only, timestamped, tees to <name>.log
#   scripts/serial_console.sh shell              # interactive (typed input reaches the unit)
#
# PORT=... BAUD=... overrides. Default 115200 8N1, which is what this board's console=ttyFIQ0 uses.
# Read-only mode is what you want during a first power-on: it never sends anything to the unit.
# Interactive mode uses socat; Ctrl-] quits it (Ctrl-C kills the pipeline instead).
set -u

PORT=${PORT:-/dev/ttyUSB0}
BAUD=${BAUD:-115200}
MODE=${1:-log}
NAME=${2:-serial-$(date +%Y%m%d-%H%M)}

say() { printf '%s\n' "$1"; }

if [ ! -e "$PORT" ]; then
  say "ABORT: $PORT does not exist. Plug in the fob and check dmesg | tail for the bridge chip driver."
  say "If it lists a device on another port, rerun with PORT=/dev/ttyUSB1 ..."
  exit 1
fi

# 3.3 V logic only; never a 5 V TTL bridge on these pads.
stty -F "$PORT" "$BAUD" raw -echo cs8 -cstopb -parenb min 1 time 0 2>&1 || {
  say "ABORT: stty refused $PORT"; exit 1;
}

case "$MODE" in
  check)
    say "--- port $PORT at $BAUD"
    stty -F "$PORT" -a | tr ' ' '\n' | grep -E '^(speed|cs8|raw|-parenb|-cstopb)' | head -6
    say "--- recent kernel messages about serial"
    dmesg 2>/dev/null | grep -iE 'ttyUSB|uart|ftdi|ch34|cp21' | tail -6
    ;;
  log)
    OUT="$NAME.log"
    { printf '=== capture %s on %s at %s 8N1 ===\n' "$(date -Iseconds)" "$PORT" "$BAUD"; } > "$OUT"
    say "recording to $OUT (Ctrl-C to stop; nothing is sent to the unit)"
    # Timestamps: Android/Rockchip boot logs have no time stamps of their own on this console.
    cat "$PORT" | python3 -u -c '
import sys, time
for line in sys.stdin:
    sys.stdout.write("[%s] %s" % (time.strftime("%H:%M:%S"), line))
    sys.stdout.flush()
' | tee -a "$OUT"
    ;;
  shell)
    OUT="$NAME.log"
    { printf '=== interactive %s on %s at %s 8N1 ===\n' "$(date -Iseconds)" "$PORT" "$BAUD"; } >> "$OUT"
    say "interactive on $PORT -> $OUT (Ctrl-] quits socat)"
    command -v socat >/dev/null || { say "ABORT: socat not installed; use 'log' mode instead"; exit 1; }
    socat -t0 "PTY,raw,echo=0,escape=0x1d" "$PORT,raw,echo=0,b$BAUD" | tee -a "$OUT"
    ;;
  *)
    say "usage: $0 [check|log <name>|shell]"; exit 1
    ;;
esac
