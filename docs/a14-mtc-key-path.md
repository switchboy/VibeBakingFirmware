# A14 kernel MTC "car" driver — why ordinary keys (0x111/0x119/0x128/0x136) deliver nothing

Extracted Android 14 arm64 kernel Image (`keys/work/kernel.img`, 0x187b808 bytes), symbols from the
live `/proc/kallsyms` (`keys/kallsyms.txt`, absolute VAs). VA ↔ file mapping `file_off = VA - 0xffffff8008080000`
(`_text`), verified against `printk`/`memcpy`/`strcmp` call sites and rodata strings (`--mtc key %04x\n`
at `0xffffff80092e0100`). Disassembly: page-aligned slice start + `llvm-objcopy -I binary -O elf64-littleaarch64`
+ `llvm-objdump -D --triple=aarch64 --adjust-vma=<page-aligned start> --section=.data` (without
`--adjust-vma` adrp/bl targets are garbage). Whole-text dump: `/tmp/opencode/all.s`.
Helper scripts: `keys/work/dis.py` (annotated dis, kallsyms bisect), `keys/work/scan.py` (register provenance scanner).

Note on data: absolute pointers are not present in the `.data` pages of the raw Image (they read as
zero there); they live in an absolute-relocation table at static VAs ~`0x9603c00..0x9604700`, laid out as
16-byte `(destination, value)` pairs. Reading that table gives every static initialisation of the MTC
driver objects — that is how `car_dev`, `s_vs_cb`, `car_fops`, `vs_uart_driver` were resolved.

## Objects (runtime VAs)

| Symbol | VA | Meaning |
|---|---|---|
| `mtc_cmd_process` | `0xffffff8008aad858` (T) | RX dispatcher, called only from `rev_thread_func` |
| `rev_thread_func` | `0xffffff8008abb7d0` (t) | decodes the DMA ring (`arm_rev_buff` `0x9b25630`, `arm_rev_read` `0x9b23d70`, `dec.30166`), sleeps on `car_dev+0x8` = `rev_wq` (`0x98505d0`) |
| `car_dev` | `0xffffff80098505c0` (D) | dispatcher object; **statically initialised** (`reloc pair` at static `0x9604250`: dest `car_dev+0`, value `s_car_dev` = `0xffffff8009b29638`) → never NULL |
| `car_dev->+0x00..+0x78` | | 16 subsystem callback slots, written only by `mtc_dev_register` |
| `mtc_dev_register` | `0xffffff8008abb568` (T) | `mtc_dev_register(const char *name, struct mtc_cb *cb)` |
| `s_vs_cb` | `0xffffff8009850418` (d) | the "vs" callback struct handed to slot `+0x38`; `+0x8` = handler, `+0x10` = raw handler |
| `vs_send_func` | `0xffffff8008abb178` (t) | handler stored at `s_vs_cb+0x8` |
| `vs_send_raw_func` | `0xffffff8008aba5a0` (t) | handler stored at `s_vs_cb+0x10` |
| `vs_driver` / `vs_uart_driver` | `0x9850240` / `0x9850320` | platform driver `mtc-vs`; uart `dev_name`/`cons_name` = `"ttyV"` (`0x92e1bf0`), 8 ports |
| `vs_of_match` | `0x9850430` | compatible `"mtc,vs"` (literal found at `0x9850470`) |
| `vss[]` | `st_car+0xc60+0x8` = `0x9b23528` | array of 8 `uart_port*`; `vss[3]` (`+0x18`) is the one the key path uses |
| `vs_init_flag` | `0x9b23520` | set to 1 by `vs_probe` (`0x8abb0cc`) |
| car misc device | `0x984ffb0` | name `"mtc-car"` → `/dev/mtc-car`; `car_fops`: read=`car_read`, write=`car_write`, ioctl/compat=`car_ioctl`, open=`car_open` |
| platform driver | `0x984fc00` | name `"mtc-car"`, probe `0x8aac198`; sysfs attrs `bt_power, wlan_power, wlan_chip, usb_touch, mfi, tmode, display_mode, otg_port, board, gps_type, org_res` |
| ctx (frame state) | `[car+0xbe0]` → base `0xffffff8008f934d8` | flags at `+0xe0f`, `+0xe06/0xe08/0xe0a`, `+0xdca`, `+0xdfc` (temp), `+0xe10` (timer ms), `+0x352` |
| car input_dev | `[st_car+0x110+0x48]` = `0x9b23158` | device used by all `input_event()` paths in `mtc_cmd_process` |

## Frame format (what the MCU sends)

`mtc_cmd_process(x0=buf, w1=len)` — `keys/work/mtc_full.s`, entry at `0x8aad858`:

```
0x8aad878: and w22,w1,#0xffff ; cmp w22,#3 ; b.ls ret          -> need len>3
0x8aad898: w20 = buf[3]<<8 | buf[2]  (sxth, masked) -> w24      -> u16 "body length"
0x8aad8b4: cmp w23(=len-4), w24 ; b.ne ret                     -> buf[2..3] MUST equal len-4
0x8aad8f0: w26=buf[0], w25=buf[1], x27=buf+4
0x8aad8fc: cmp w26,#0xff ; cmp w25,#0x0 / #0x10
```

* `buf[0]=0xff`, `buf[1]=0x10` → **key/command path**: `printk("--mtc key %04x\n")` prints the u16 read from
  `buf[4..5]` (`0x8aaf9ec..0x8aafa0c`); `w21 = key & 0xffff`.
* bit 3 of the key is the auto-repeat flag: `and w20,w20,#0xfffffff7` (`0x8aafe34`) folds `0x111/0x112/0x113/0x119` onto `0x111`.
* `buf[1]` = other command bytes (2,3,4,5,6,7,8,0xa,0xb,0xf,0x11,0x56,0x57,0x64,0x65,0x67,0x70,0x71, range `0x1c..0xdf`) select the
  other dispatch branches below.

## Q1 — who writes `car_dev->+0x38`, and under what condition

`mtc_dev_register` is the only writer of the slots (`keys/work/mtc_dev_register.s`), and each branch does
`x0 = car_dev; str x20,[x0,#slot]` with `x20` = the `cb` argument:

| name | slot | VA of store |
|---|---|---|
| `touch` | `+0x10` | `0x8abb6e8` |
| `ftest` | `+0x18` | `0x8abb700` |
| `usb` | `+0x08` | `0x8abb710` |
| `dab` | `+0x20` | `0x8abb728` |
| `bl` | `+0x30` | `0x8abb738` |
| `serial` | `+0x28` | `0x8abb748` |
| **`vs`** | **`+0x38`** | **`0x8abb758`** |
| `dvd` | `+0x40` | `0x8abb768` |
| `bma` | `+0x48` | `0x8abb778` |
| `bview` | `+0x50` | `0x8abb788` |
| `acodec` | `+0x58` | `0x8abb798` |
| `tve` | `+0x60` | `0x8abb7a8` |
| `hdmi` | `+0x68` | `0x8abb7b8` |
| `i2s` | `+0x70` | `0x8abb7c8` |
| anything else (default, `radio`) | `+0x78` | `0x8abb6c0` |

Slot `+0x38` is written **only** by `vs_probe` (`0x8abaf78`), at:

```
0x8abb0c8: add x1, x21, #0x1d8   -> &s_vs_cb (page 0x9850000 + 0x418)   [x21 = page+0x240 = vs_driver]
0x8abb0cc: strb w2, [x3,#0x520]  -> vs_init_flag = 1
0x8abb0d0: add x0, x0, #0x940    -> "vs" (0xffffff80092f2940)
0x8abb0d8: bl mtc_dev_register (0x8abb568)
```

Conditions, in order (`vs_probe` body):
1. matched only by DT compatible `"mtc,vs"` (`vs_of_match`), driver name `mtc-vs`;
2. `mutex_lock(&vss_lock)` (`vs_driver+0xc0`);
3. if `vs_init_flag` already set → skip `uart_register_driver`; else `uart_register_driver(&vs_driver)`
   (`0x8abb114`), failure → printk `"...:%d"` and return with the slot **not** registered;
4. loop ports 0..7: `kmem_cache_alloc_trace(0x228)`, `str x3,[vss,i]`, `port->index=i` (`str w27,[x3,#0x124]`),
   `port+0x220 = 0`, `port+0x1fc = 0`, `port+0x1b8 = 0`, then `uart_add_one_port(&vs_driver, port)` (`0x8abb080`);
   allocation failure → `_dev_warn` + return `-12` (slot never registered);
5. only after all 8 ports succeed: `vs_init_flag = 1`, `port->ops->...` bookkeeping and the `mtc_dev_register("vs", &s_vs_cb)`.

So while the vs node is absent / probe fails, `car_dev->+0x38` stays NULL and every dispatch branch hits
`cbz x0, <epilogue>` and returns without any output — the silent-drop mechanism.

## Q2 — what `[sink+8]` points to

`sink = car_dev->+0x38 = &s_vs_cb` (`0x9850418`). The static initialisation (reloc pairs, static
`0x9604220`/`0x9604238`) gives:

```
s_vs_cb + 0x08 -> vs_send_func      (0xffffff8008abb178)   <- the pointer every key branch calls
s_vs_cb + 0x10 -> vs_send_raw_func  (0xffffff8008aba5a0)
```

Call sites in `mtc_cmd_process`: `ldr x4,[x0,#8]; blr x4` with `w0`=0x16(22)/0x12(18)/0x13(19),
`w1`=subcmd (0x4e=78 keys, 0x43=67, 0x42=66, 0x48=72, 0x51=81, -0x5e, -0x60, -0x6e), `x2`=body ptr, `w3`=body len;
and `ldr x3,[x0,#0x10]; blr x3` with `w0`=3/5, `x1`=buf, `w2`=len.

`vs_send_func(w0,w1,w2=data,w3=len)` (`0x8abb178`) — the actual delivery:

```
0x8abb190: ldrb w0,[vs_init_flag] ; cbz -> ret            (probe never ran -> drop)
0x8abb1a8: ldr x19,[vss+0x18]      -> uart_port vss[3]    (hard-wired port index 3)
0x8abb1ac: ldr w0,[x19,#0x220]     ; cbz -> ret          (set only by vs_startup, i.e. tty opened)
0x8abb1b4: ldr w0,[x19,#0x1b8]     ; cbz -> ret          (set only by vs_startup: workqueue ready)
0x8abb1e8: kmalloc(len+5); buf = {0xfa, w0, w1, len:u16}
0x8abb228..: copy payload
0x8abb270/0x8abb2b0: uart_insert_char(port, 0, 4, c, 0) per byte, tty_flip_buffer_push every 16 bytes
```

`vs_shutdown` zeroes `port+0x220` (`0x8aba8f4`) and `vs_stop_rx` zeroes `port+0x1b8` (`0x8aba4a8`), so once
the tty is closed every frame is dropped again. Because the port array index is fixed at 3 and
`vs_uart_driver.dev_name = "ttyV"` (`0x92e1bf0`), the sink is **`/dev/ttyV3`** — userspace bytes arrive as
`0xfa 0x16 <subcmd> <len:u16> <payload>`, payload = `buf+4` of the MCU frame (key u16 at payload[0..1]).

## Q3 — `[ctx+0xe0f]==1`, and the 0x134/0x135 paths

Key-path decision (`keys/work/mtc_full.s`, page-aligned base `0x8aad800`):

```
0x8aafa0c: printk("--mtc key %04x\n", w21)
0x8aafa10: cmp w21,#0x134 ; b.eq 0x8ab00a4
0x8aafa18: cmp w21,#0x135 ; b.eq 0x8ab0044
0x8aafa20: ldr x0,[x28,#0xbe0] ; ldrb w1,[x0,#0xe0f] ; cmp #1 ; b.eq 0x8aafe34
0x8aafa30: car_dev->+0x38 ; cbz ret ; [sink+8]=vs_send_func(0x16, 0x4e, buf+4, len-4)
```

* **`0x134` → `0x8ab00a4`**: `dev = [st_car+0x110+0x48]`, `cbz` → ret, then
  `input_event(dev, EV_KEY, 158 /*KEY_BACK*/, 1)` / `EV_SYN` / `input_event(dev, EV_KEY, 158, 1)` / `EV_SYN`
  (four calls, `0x8ab00c0..0x8ab00fc`). This is the "back" key that works — it needs no vs slot, only the car input device.
* **`0x135` → `0x8ab0044`**: same shape with code **139 (`KEY_FRONT`)** (`0x8ab0060..0x8ab009c`).
* **`ctx+0xe0f == 1` → `0x8aafe34`**: `and w20,w20,#0xfffffff7` (clear bits 0,1,3 = repeat/variant bits),
  `cmp w20,#0x111`:
  - if the key is in the `0x111` family (volume keys: `0x111`, `0x112`, `0x113`, `0x119`) the key is **consumed** —
    it adjusts the test timer `ctx+0xe10` (`+0xe10 += 5000`, or `-= 5000` when `> 0x101c137`) and prints
    `--mtc Test Temp( %d ) %d` / `loga(...)` using `ctx+0xdfc` (temperature). **Nothing is dispatched.**
  - if `w21 == 0x111` exactly (`0x8aafea4`) the same temp path runs with a cap check (`0x101c137`).
  - otherwise it falls through to the generic dispatch at `0x8aafa30` (`vs_send_func`, subcmd `0x4e`).
  - the sibling block at `0x8aaf558` (`ctx+0xe0a` = raw key byte, `strb w2,[ctx,#0xe0a]`) dispatches subcmd `0x48`
    (`0x8aaf540..0x8aaf550`), and `0x8aafecc` dispatches `0x43` + `send_vs_car`.
* Other key-related branches: `0x8aaf9b0` → subcmd `0x51` when `ctx+0xe05`==0; `0x8aadf04` (cmd 0x11) →
  subcmd `0x12`/w0=`0x12`; `0x8abbb00` → `vs_send_func(0x13, 0x12, stack u16, 2)`.

**Who sets `ctx+0xe0f`**: only two `strb` sites, both inside `mtc_ioctl` (`0x8ab03a0`):

```
0x8ab6e74: strb w3(=2), [ctx,#0xe0f]         (temp report branch, printk ' undefined!' / 'Error]Keys undefined!')
0x8ab6ec0: strb w5(=1), [ctx,#0xe0f]; str w4(=60000), [ctx,#0xe10]
```

Nothing on the RX path (`rev_thread_func`, `mtc_cmd_process`) ever sets it, so it stays 0 unless userspace
calls that ioctl/sysfs entry. With the flag 0, `0x111/0x119` take the plain `vs_send_func(0x16,0x4e,...)` route
instead of being swallowed.

## Q4 — what userspace must do, and over which device/channel

Keys only ever arrive from the MCU: `mtc_cmd_process` has exactly one caller, `rev_thread_func`
(`bl 0x8aad858` at `0x8abba64`), which decodes the DMA ring and waits on `rev_wq`. Userspace cannot inject
them: `car_write` (`0x8aab5a0`) is a stub `mov x0,#0; ret` (it silently consumes writes) and `car_open`
(`0x8aab598`) is a stub returning 0.

For an ordinary key (`0x111`, `0x119`, `0x128`, `0x136`, …) the **only** delivery route is slot `+0x38`, so:

1. **The vs driver must have probed.** DT node compatible `"mtc,vs"` / platform driver `mtc-vs`; check
   `/sys/bus/platform/drivers/mtc-vs/`. Without it `car_dev->+0x38` is NULL and every branch `cbz`-returns.
2. **`/dev/ttyV3` must be open.** `vs_send_func` hard-wires `vss[3]` and refuses unless
   `port+0x220` and `port+0x1b8` are non-zero; those are set only in `vs_startup` (`0x8abb3d0`, reached from
   `uart_open` → `ops->startup`) and cleared in `vs_shutdown`/`vs_stop_rx`. So opening (and keeping open)
   `/dev/ttyV3` is what makes delivery happen; ports `ttyV0/1/2/4..7` are registered but never used by the key path.
3. **Parse the framing** on that tty: `0xfa 0x16 <subcmd=0x4e> <len:u16> <payload>`; the payload is the MCU
   frame body (`buf+4`), whose first two bytes are the u16 key code (bit 3 = auto-repeat).
4. **Do not expect `/dev/input/*`** for volume keys: the only `input_event()` paths are `0x134→KEY_BACK(158)`,
   `0x135→KEY_FRONT(139)` and the `buf[1]` command-byte table (`0x56→code 63`, `0x64/0x65/0x67/0x70/0x71→…`,
   `0x71→KEY_ENTER(28)`) on the car input device `st_car+0x110+0x48`. There is no `input_event` for `0x111/0x119/0x128/0x136`.
5. **Keep `ctx+0xe0f` 0.** A test-mode ioctl (`mtc_ioctl`, values 1/2) turns the `0x111` family into
   temperature logging and drops the key entirely.
6. `car_read` (`0x8acb98`) also dispatches slot `+0x38` and `input_event` (`0x8aad160..0x8aad19c`), and
   `car_ioctl` (`0x8ab7a28`) plus the `mtc-car` sysfs attrs are the control side; `/dev/mtc-car` is the misc node.

## Verdict

Ordinary keys are dropped because delivery is gated on **`car_dev->+0x38` != NULL** (needs `mtc-vs` probe)
and on **uart port `vss[3]` being started** (`port+0x220`/`port+0x1b8`, set only by `vs_startup`, i.e. only while
`/dev/ttyV3` is open). `0x134/0x135` work because they bypass the slot entirely and call `input_event()` on the
car input device. If a test ioctl set `ctx+0xe0f=1`, `0x111/0x119` additionally get swallowed into the
temp-report path (`0x8aafe34`) before any dispatch.
