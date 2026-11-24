#!/usr/bin/env python3
"""digest_recorder.py - condense a head-unit boot-log capture into a short report.

  python3 tools/digest_recorder.py /home/Daan/vbf-work/a14-work/a14-attempt28-rec

Reads <dir>/card-log.bin, the hu-card-arm recorder's /dev/kmsg dump: text records of the form
`PRI,SEQ,USEC,-;MESSAGE` glued between NUL bytes and binary junk, so the printable runs are pulled
out the way `strings -n 6` does and only the lines that look like a kmsg record survive. When the
capture directory also holds `console-ramoops-0` (pstore console, `[  295.531371] MESSAGE`) that file
is reported as a second section of the same shape.

Reads files only - nothing here touches the head unit, adb or the NAS. stdout is deliberately terse:
counts, the event lines the boot is worth reading, the hu-diag GPIO/USB/net snapshots and the busiest
init services.
"""

import re
import sys
from collections import Counter
from pathlib import Path

# The recorder writes kmsg records into the first part of the region; everything past that is padding.
KMSG_RECORD = re.compile(r"^(\d+),(\d+),(\d+),-;(.*)$")
PRINTABLE_RUN = re.compile(rb"[\x20-\x7e]{6,}")  # what `strings -n 6` yields
RAMOOPS_LINE = re.compile(r"^\[\s+(\d+\.\d+)\]\s?(.*)$")

MSG_WIDTH = 160

# Case-sensitive. One line per record that matches any of these, consecutive repeats collapsed.
EVENT_PATTERNS = [re.compile(p) for p in [
    r"hu-mtc:",
    r"--mtc @ ",
    r"--mtc b ",
    r"usb 1-1",
    r"ax88179",
    r"eth0",
    r"PM: suspend",
    r"PM: resume",
    r"mtc_lcd_dis",
    r"mtc_lcd_en",
    r"Service 'zygote' .*signal",
    r"Service 'system_server'",
    r"processing action \(sys\.boot_completed=1\) from \(/system/etc/init/hw/init\.rc",
    r"sys\.powerctl",
    r"reboot",
    r"hu-card-arm:",
    r"crasher",
    r"Kernel panic",
    r"Unable to handle",
]]

DIAG_LINE = re.compile(r"^hu-diag\[([^\]]+)\]: (.*)$")
DIAG_GPIO_TOKENS = ("otg_drv", "sdio_en", "host_drv", "mac_pwr")
SERVICE_START = re.compile(r"init: starting service '([^']*)'")


class Record:
    """One kmsg record: timestamp in microseconds, the message text, and where it came from."""

    __slots__ = ("seq", "usec", "msg")

    def __init__(self, seq, usec, msg):
        self.seq = seq
        self.usec = usec
        self.msg = msg.rstrip()

    @property
    def seconds(self):
        return self.usec / 1_000_000


def kmsg_records(data: bytes) -> list:
    """kmsg records in file order, from a binary blob full of NULs and junk."""
    out = []
    for run in PRINTABLE_RUN.findall(data):
        m = KMSG_RECORD.match(run.decode("latin-1"))
        if m:
            out.append(Record(int(m.group(2)), int(m.group(3)), m.group(4)))
    return out


def ramoops_records(text: str) -> list:
    """pstore console lines as records. `[  295.531371] msg` has no seq, so seq is 0."""
    out = []
    for line in text.splitlines():
        m = RAMOOPS_LINE.match(line.rstrip())
        if m:
            out.append(Record(0, round(float(m.group(1)) * 1_000_000), m.group(2)))
    return out


def events_section(records: list) -> list:
    """The interesting lines, consecutive identical messages merged into one with (xN)."""
    rows = []
    for rec in records:
        if not any(p.search(rec.msg) for p in EVENT_PATTERNS):
            continue
        if rows and rows[-1][1] == rec.msg:
            rows[-1][2] += 1
            continue
        rows.append([rec.seconds, rec.msg, 1])
    return [
        "%7.1f  %s%s" % (ts, msg[:MSG_WIDTH], " (x%d)" % n if n > 1 else "")
        for ts, msg, n in rows
    ]


def diag_section(records: list) -> list:
    """Per hu-diag tag: the GPIO lines that matter, the USB block, and everything after == net.

    hu-diag output interleaves with other kmsg records, so the section is tracked per tag by its
    `== marker` lines; the regulator dump and the port1 readback are not reported.
    """
    seen = {}   # tag -> {"gpio": [...], "usb": [...], "net": [...]}
    state = {}  # tag -> section the following hu-diag lines belong to
    for rec in records:
        m = DIAG_LINE.match(rec.msg)
        if not m:
            continue
        tag, body = m.group(1), m.group(2)
        if body.startswith("== "):
            marker = body[3:].strip()
            state[tag] = marker if marker in ("gpio", "usb", "net") else None
            continue
        section = state.get(tag)
        if section is None:
            continue
        if section == "gpio" and not any(t in body for t in DIAG_GPIO_TOKENS):
            continue
        rows = seen.setdefault(tag, {"gpio": [], "usb": [], "net": []})
        rows[section].append("%7.1f  %s" % (rec.seconds, body[:MSG_WIDTH]))
    out = []
    for tag, rows in seen.items():
        for section, label in (("gpio", "gpio (otg_drv|sdio_en|host_drv|mac_pwr)"),
                               ("usb", "usb: == usb .. == usb1 port1"),
                               ("net", "net: == net onward")):
            if rows[section]:
                out.append("  [ %s ] %s" % (tag, label))
                out.extend("    " + line for line in rows[section])
    return out


def services_section(records: list) -> list:
    """Top 8 init services by `init: starting service 'NAME'` count."""
    counts = Counter(m.group(1) for rec in records for m in [SERVICE_START.search(rec.msg)] if m)
    return ["   %4d  %s" % (n, name) for name, n in
            sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:8]]


def section(title: str, records: list) -> list:
    if not records:
        return ["== %s: no kmsg records" % title]
    head = "== %s: %d records, %.1f s .. %.1f s" % (
        title, len(records), records[0].seconds, records[-1].seconds)
    out = [head, "events:", *events_section(records)]
    diag = diag_section(records)
    if diag:
        out += ["diag:", *diag]
    services = services_section(records)
    if services:
        out += ["top repeating services:", *services]
    return out


def report(rec_dir: Path) -> str:
    """Full report for a capture directory: card-log.bin, plus console-ramoops-0 when present."""
    log = rec_dir / "card-log.bin"
    if not log.is_file():
        raise SystemExit("no card-log.bin in %s - nothing to digest" % rec_dir)
    lines = section(log.name, kmsg_records(log.read_bytes()))
    ramoops = rec_dir / "console-ramoops-0"
    if ramoops.is_file():
        lines += ["", *section(ramoops.name, ramoops_records(ramoops.read_text("latin-1", "replace")))]
    return "\n".join(lines)


def main(argv: list) -> int:
    if len(argv) != 2:
        raise SystemExit("usage: digest_recorder.py <capture-dir>")
    print(report(Path(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
