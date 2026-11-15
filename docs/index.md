# Docs index — which file is canonical for what

| file | purpose | canonical for |
|---|---|---|
| `docs/decisions.md` | design decisions D1-D43 plus **D44 (OPEN)** and **D45 (decided Nov 15)** (incl. D28 bring-up access via `adbon`, D29 blind rollback, D30 the Nov 9 write outcome, D31 rebuilt rescue payload + SD boot card, D32 the measured defect list, D33 the mixed-generation boot, D34 the missing first-stage fstab, D35 the bench reanimation procedure, D36 the unpopulated debug header + HDMI-looking connector, D37 the rescue-card layout, D38 the board DTB in `boot`'s second stage, D39 recovery via the bootSD card, D40 the byte-exact stock backup, D41 the payload-free fallback zip, D42 the patched recovery partition, D43 the card-driven installer and its manifest contract, D44 the vendor staging source, D45 accepting the Nov 13 kernel panic + keeping the upstream drafts unpublished), owner questions, pending Bluetooth route | every DECISION and its reasoning |
| `docs/findings.md` | measured evidence: packaging pass, offline payload audit, no-terminal diagnostics, SD/uboot + AVB measurements, OEM package identities, **the Nov 9/10 flash attempt log**, **the Nov 10 boot/super/DTB/module measurements and the reconciled outside diagnosis**, **the Nov 10 boot-image provenance (A11 kernel+DTB on an A10 chain)**, **the Nov 10 first-stage fstab finding + the two fixed boot images**, **the Nov 11 stock restore + DTB-in-boot + bootSD recovery**, **the Nov 12 recovery-partition AVB measurement and the patched recovery image**, **the Nov 13 offline logic test of the recovery installer and the two bugs it found**, **the Nov 13/14 live probe and the vendor-blob comparison against both reference images**, **the Nov 13 kernel panic decoded from the RAMoops record (vendor `gt9xx` dangling `input_dev->phys`)**, **the Nov 15 VINTF kernel-requirement measurement (FCM 4 vs 5 against both vendor kernels), the gzip-embedded IKCONFIG correction, and the kernel/module/manifest coupling numbers** | every measurement number and audit result |
| `docs/flash.md` | operator procedure: stick layout, route 1 (signed zip via recovery), route 2 (raw images via TCP-adb root `dd`), first-boot probe routes, rollback (incl. the blind paths) | what to do in the car, and the shas to verify |
| `docs/reanimation.md` | bench guide, standalone: harness power (yellow+red to fused 12 V, black to GND), UART pads + 3.3 V fob wiring, partition sector map, serial reading order, decision tree, write routes (`upgrade_tool` maskrom, TCP adb, SD card), troubleshooting | what to do on the desk bench when nobody is assisting |
| `docs/build-host.md` | build-host (NAS) operations: space, packages, lunch, packaging order, failure post-mortems | how to rebuild anything |
| `docs/head-unit-findings.md` | live-unit measurements (which firmware boots today, partition map, kernel config of the running kernel, input devices and the Nov 13 panic signature, WiFi/BT chips incl. the `iw reg` state, daemons, tool availability) | facts about the unit as it boots today |
| `docs/firmware-analysis.md` | Phase 0 inventory of the OEM payload (security posture, boot chain, drivers) | what the shipped firmware actually is |
| `docs/feasibility.md` | version ceiling analysis (VNDK/APEX, KeyMint), kernel strategy options K1/K2/K3, and the **Nov 15 kernel/vendor coupling risk assessment** (two-agent adversarial pass: which kernel Android 14's VINTF accepts, how kernel/modules/manifest couple) | why Android 14 is the ceiling, and which kernel shape is legal |
| `docs/ota.md` | post-install upgrades once Android 14 runs | future OTA story |
| `docs/plan.md` | milestone history M1-M10 with status, plus **M11 (Nov 15, NOT STARTED)**: proven-kernel shape A / staged A11 shape B / our own kernel build shape C, the kernel-modules-manifest coupling rule, the NAS recipe, and the owner decisions it waits on | what was tried, in order, and what comes next |
| `docs/termux.md` | Android 10-era shell mechanics (Termux, upload endpoint) | how the old probes reached us |
| `docs/upstream.md` | candidate register for upstream contributions (NO PRs submitted), with the verified review/licensing rules | what could go upstream, where, and what cleanup it needs |
| `agentPlan.md` | lean index: mission, phases, risk register, D-status, current state | the agent's next move |

Two different report transports, deliberately kept separate:
* Android 10-era probes: token server on port **8765** (`scripts/upload_server.py` + `upload_client.sh`,
  `docs/termux.md`).
* Android 14 `hu_probe.sh`: raw `curl -T` to port **9000** (`nc -l 9000 > report.md`), plus the USB-stick
  copy and `/dev/kmsg` (`docs/flash.md`, "First boot").

Numbers live in `docs/findings.md`; the flashable payload's sha is repeated in `docs/flash.md` because
that is what the operator checks on the stick.
