# Docs index — which file is canonical for what

| file | purpose | canonical for |
|---|---|---|
| `docs/decisions.md` | design decisions D1-D25, owner questions, pending Bluetooth route | every DECISION and its reasoning |
| `docs/findings.md` | measured evidence: packaging pass, offline payload audit, no-terminal diagnostics, post-boot probe spec, SD/uboot + AVB measurements | every measurement number and audit result |
| `docs/flash.md` | operator procedure: stick layout, route 1 (signed zip via recovery), route 2 (raw images via adb/root dd), first-boot probe routes, rollback | what to do in the car, and the shas to verify |
| `docs/build-host.md` | build-host (NAS) operations: space, packages, lunch, packaging order, failure post-mortems | how to rebuild anything |
| `docs/head-unit-findings.md` | live-unit measurements (partition map, WiFi/BT chips, daemons, tool availability) | facts about the unit as it boots today |
| `docs/firmware-analysis.md` | Phase 0 inventory of the OEM payload (security posture, boot chain, drivers) | what the shipped firmware actually is |
| `docs/feasibility.md` | version ceiling analysis (VNDK/APEX, KeyMint) | why Android 14 is the ceiling |
| `docs/ota.md` | post-install upgrades once Android 14 runs | future OTA story |
| `docs/plan.md` | milestone history M1-M10 with status | what was tried, in order |
| `docs/termux.md` | Android 10-era shell mechanics (Termux, upload endpoint) | how the old probes reached us |
| `agentPlan.md` | lean index: mission, phases, risk register, D-status, current state | the agent's next move |

Two different report transports, deliberately kept separate:
* Android 10-era probes: token server on port **8765** (`scripts/upload_server.py` + `upload_client.sh`,
  `docs/termux.md`).
* Android 14 `hu_probe.sh`: raw `curl -T` to port **9000** (`nc -l 9000 > report.md`), plus the USB-stick
  copy and `/dev/kmsg` (`docs/flash.md`, "First boot").

Numbers live in `docs/findings.md`; the flashable payload's sha is repeated in `docs/flash.md` because
that is what the operator checks on the stick.
