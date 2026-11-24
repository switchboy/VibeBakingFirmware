#!/usr/bin/env python3
"""tests/test_digest_recorder.py - behaviour tests for tools/digest_recorder.py.

Run:  python3 -m pytest -q tests/test_digest_recorder.py

The capture is synthetic: NULs and binary junk around a handful of kmsg records, one hu-diag block
and two identical consecutive hu-mtc lines. Only the two knobs the report is worth are checked - the
consecutive-duplicate collapse in the events table and the GPIO filter in the diag section. Nothing
here reads a real capture or touches the head unit.
"""

import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))

import digest_recorder as D  # noqa: E402


def _capture(tmp_path):
    """A tiny card-log.bin: records interleaved with NUL padding and non-printable junk."""
    records = [
        b"6,0,0,-;Booting Linux on physical CPU 0x0",
        b"4,1,1000000,-;hu-mtc: link up",
        b"4,2,2000000,-;hu-mtc: link up",
        b"12,3,3000000,-;hu-card-arm: recorder started",
        b"12,4,4000000,-;hu-diag[boot]: == gpio",
        b"12,5,4100000,-;hu-diag[boot]:  gpio-155 (                    |otg_drv ) out lo",
        b"12,6,4200000,-;hu-diag[boot]:  gpio-152 (                    |wlan_pwr ) out lo",
        b"12,7,4300000,-;hu-diag[boot]: == regulators",
        b"12,8,4400000,-;hu-diag[boot]:  vdd_log 0 22 0 902mV",
        b"12,9,4500000,-;hu-diag[boot]: == usb",
        b"12,10,4600000,-;hu-diag[boot]: usb1 1d6b:0002",
        b"14,11,4700000,-;init: unrelated noise between usb lines",
        b"12,12,4800000,-;hu-diag[boot]: == usb1 port1",
        b"12,13,4900000,-;hu-diag[boot]: cat: .../usb1-port1/disable: No such file",
        b"12,14,5000000,-;hu-diag[boot]: == net",
        b"12,15,5100000,-;hu-diag[boot]: lo",
        b"14,16,5200000,-;init: starting service 'adbd'...",
        b"14,17,5300000,-;init: starting service 'adbd'...",
        b"14,18,5400000,-;init: starting service 'zygote'...",
    ]
    junk = b"\x00\x00\x00\x01\xff junk that is not a record \x00\x00"
    data = b"\x00" * 8 + junk + b"\n".join(records) + b"\x00\x00\x00\x00"
    (tmp_path / "card-log.bin").write_bytes(data)
    return tmp_path


def test_report(tmp_path):
    out = D.report(_capture(tmp_path))
    lines = out.splitlines()

    assert "== card-log.bin: 19 records, 0.0 s .. 5.4 s" in lines

    # Two identical consecutive hu-mtc lines collapse into one row with a count.
    events = lines[lines.index("events:") + 1:lines.index("diag:")]
    mtc = [line for line in events if "hu-mtc: link up" in line]
    assert mtc == ["    1.0  hu-mtc: link up (x2)"], mtc
    assert events == ["    1.0  hu-mtc: link up (x2)", "    3.0  hu-card-arm: recorder started"], events

    # diag: GPIO keeps only the regulator-relevant pins, usb keeps the == usb..== usb1 port1 span,
    # the regulator dump and the port1 readback are dropped, net survives.
    diag = lines[lines.index("diag:") + 1:lines.index("top repeating services:")]
    joined = "\n".join(diag)
    assert "gpio-155" in joined and "otg_drv" in joined
    assert "wlan_pwr" not in joined
    assert "vdd_log" not in joined
    assert "usb1 1d6b:0002" in joined
    assert "usb1-port1/disable" not in joined
    assert "net: == net onward" in joined
    assert diag[-1] == "        5.1  lo", diag[-1]
    assert "unrelated noise" not in joined

    assert "   2  adbd" in out


def test_ramoops_is_a_second_section(tmp_path):
    rec_dir = _capture(tmp_path)
    (rec_dir / "console-ramoops-0").write_text(
        "[  295.531371] hu-mtc: link up\n[  295.531372] hu-mtc: link up\n"
        "not a pstore line\n[  600.100000] PM: suspend of pid 1\n",
        encoding="utf-8",
    )
    out = D.report(rec_dir)
    assert "== console-ramoops-0: 3 records, 295.5 s .. 600.1 s" in out.splitlines()
    assert "hu-mtc: link up (x2)" in out
    assert "PM: suspend of pid 1" in out
    assert out.index("card-log.bin") < out.index("console-ramoops-0")
