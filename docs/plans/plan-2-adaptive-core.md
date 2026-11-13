# Plan for Phase 2: Adaptive core

Status: patches 0003 and 0004 written, tests pending. Depends on Phase 0 and Phase 1 (done). High-level summary: [`../phases.md`](../phases.md), Phase 2. Results go in `docs/results/phase_2_adaptive_core.md`.

Machine tags used below: **[Claude]** work done in the chat, **[PC]** the machine under test (root shell, at the console), **[PEER]** the second machine, **[repo]** the project repository. Set `PEER=<peer address>` in every PC terminal first.

## 1. Goal and scope

Make `ethtool -C enp3s0 adaptive-rx on` move the hardware RX timer with the load, using the DIM library, timer-only levels and a driver-supplied level table.

In scope: RX counters, DIM sampling in the poll function, the work function, the level table, the ethtool semantics of the flag, a minimal teardown so the work can never run after the device stops, and the tools to watch the level.

Not in scope (Phase 3): re-applying the level after a hardware start, link-speed changes, idle decay, the full locking review. Not in scope at all: TX moderation, RTL8125.

Patch series: 0003 (counters, sampling, work function that only logs) and 0004 (level table, apply to hardware, ethtool semantics). The split lets DIM's behaviour be seen with no hardware risk first.

## 2. Facts this phase builds on

- One NAPI context. `rtl8169_poll()` runs `rtl_tx()`, `rtl_rx()`, then `napi_complete_done()` and `rtl_irq_enable()`. At line rate TCP the baseline shows about 32,500 NET_RX per second but only about 2 interrupts per second, so the poll often keeps going without completing.
- DIM (`lib/dim/net_dim.c`, `include/linux/dim.h`): `net_dim()` only runs its algorithm once 64 events (`DIM_NEVENTS`) have passed since the last sample. It compares bytes per ms first, then packets per ms (a change above 10% counts), then events per ms (fewer is better). It starts parked at level 0, steps one level at a time, and turns back when the result is not better. The level is `dim->profile_ix`, 0 to 4.
- Reference integration: `drivers/net/virtio_net.c` (`virtnet_rx_dim_update()` builds the sample, `virtnet_rx_dim_work()` applies the level under a mutex and sets `DIM_START_MEASURE`, `net_dim_work_cancel()` before stopping).
- Hardware (Phase 0): `IntrMitigate` has the RX timer in bits 7:4. At 1000 Mbit/s the timer unit for `INTT` 0, 1, 2, 3 is 5, 40, 80, 160 microseconds (at 100 Mbit/s 2.56, 20.48, 40.96, 81.92; at 10 Mbit/s 40.96 and up). A timer-only setting runs with `PktCntrDisable` set. `rx-usecs 50` and `200` were measured as static baselines.
- Baseline numbers to beat or match: request-response 9213 transactions per second and 108 microseconds with no moderation; a static 50 microsecond timer adds 42 microseconds, 200 adds 187; UDP at 600 Mbit/s: NET_RX falls 17% with 50 and 41% with 200.

## 3. Design decisions

| # | Decision | Reason and alternatives |
|---|---|---|
| D1 | An event is one call of `rtl8169_poll()`. `net_dim()` is called at the end of every poll that received packets, not only when `napi_complete_done()` succeeds | virtio_net samples at completion, but at line rate this poll may never complete, so DIM would not run when it matters most. The cost per call is one comparison until 64 events have passed |
| D2 | Level table in microseconds at a fixed `INTT`: `{0, 40, 80, 200, 400}`. Converted to timer units at apply time: `units = min(15, round(us * 1000 / scale_ns))` | Includes the 200 microsecond point already measured. Level 0 is no moderation. The first table is a starting guess; Phase 4 tunes it |
| D3 | `INTT` is chosen when adaptive mode is turned on, with `rtl_coalesce_choose_scale()` for the largest level (400): that gives the 40 microsecond unit at 1000 Mbit/s | Keeps the only write of `CPlusCmd` on the ethtool path, which already writes it. The work function never touches `cp_cmd` |
| D4 | Timer-only: while adaptive is on, the RX frame limit is forced to 0 and a non-zero TX frame limit is refused with `-EINVAL` and an extack message. `PktCntrDisable` ends up set, as in the static timer-only path | The measured state of a timer-only setting. A frame limit would clear the bit, a state not tested with DIM |
| D5 | One mutex `rx_dim_lock` protects `rx_dim_enabled`, the saved static settings and the register update. The work function takes only this mutex, never RTNL. Order: RTNL, then `rx_dim_lock`; nothing takes RTNL while holding it | `net_dim_work_cancel()` is `cancel_work_sync()`. Called under RTNL it is safe only if the work never waits for RTNL. Same pattern as `virtio_net` |
| D6 | ethtool semantics. `ethtool -c` shows the live register value (needed for the demo). Off to on: save the static RX settings and start DIM at level 0. On to on: ignore `rx-usecs` and `rx-frames` in the request (they are echoes of the live level; ethtool merges the current values into every set), TX settings still apply. On to off: restore the saved static RX settings and ignore the values in the request | Without this, `adaptive-rx off` would freeze the last DIM level as a static setting, or `adaptive-rx on` would race with the level changing between ethtool's get and set. A user who wants other static values runs a second command |
| D7 | The work function does a read-modify-write of the RX bits of `IntrMitigate` only, so the TX timer and frame fields that ethtool may set are kept | Plan rule: no `CPlusCmd` writes from the work |
| D8 | Minimal teardown in 0003: in `rtl8169_down()`, after `rtl8169_cleanup()` (NAPI disabled and interrupts masked, so the poll cannot schedule the work again), call `net_dim_work_cancel()` | The work must never run after the device is stopped or the module is removed. Placing the cancel before `napi_disable` would allow a rescheduled work. Phase 3 reviews it |
| D9 | Visibility: `netdev_dbg()` on every level change, and `scripts/sample_level.sh` that prints the register-level state a few times a second | `read_intrmit.sh` already decodes the registers; the sampler loops it with a timestamp and the interrupt count |

## 4. Work steps

1. **[PC] `static-0us` check** (carried forward from Phase 0, item 1). Commands are in the Phase 0 results file. It settles whether the "no moderation" level, which goes through the ethtool path and sets `PktCntrDisable`, matches a freshly loaded module. If it does not, level 0 must clear the bit and D4 changes.
2. **[Claude] Write patch 0003.** Changes: `u16 rx_dim_events` and `struct mutex rx_dim_lock` in `struct rtl8169_private`; probe: `mutex_init()`, `INIT_WORK()`, `rx_dim.mode`; `rtl_rx()` counts packets and bytes next to `dev_sw_netstats_rx_add()`; `rtl8169_poll()` counts the event and calls DIM (D1); the work function logs the new level and sets `DIM_START_MEASURE`; the flag change in `rtl_set_coalesce()` resets the DIM state; D8. Deliver as a patch file, tested with `patch -p1` on the files of the series so far.
3. **[PC] Apply, build, load.** In `/usr/src/linux-7.2.15`: `patch -p1 --dry-run < <patch>`, then `patch -p1 < <patch>`, then `make M=drivers/net/ethernet/realtek modules W=1 2>&1 | tee ~/r8169-build.log`, sign a copy and load it (recipe in `docs/results/phase_1_plumbing.md`). Paste any compiler message. A helper `scripts/build_sign_load.sh` (new, root, console only) will do build, sign and swap in one command.
4. **[PC] Test 0003 with the log only:** enable dynamic debug for the module (`echo 'module r8169 +p' > /sys/kernel/debug/dynamic_debug/control`; if the kernel has no dynamic debug, `grep DYNAMIC_DEBUG /usr/src/linux-7.2.15/.config` tells, and the fallback is `trace_printk()`), then `ethtool -C enp3s0 adaptive-rx on`, run traffic from the peer and watch `dmesg -w`. Expected: level changes are logged under traffic and none at idle, and the register does not change.
5. **[Claude] Write patch 0004:** the level table and conversion, `rtl_rx_dim_apply()`, the `rtl_set_coalesce()` semantics of D3, D4, D6, D7, and the get side unchanged (live register).
6. **[PC] Apply, build, sign, load 0004.** Same recipe. Then the tests of section 5.
7. **[PC] Observe the idle behaviour.** After UDP load stops, read the level. DIM only runs from the poll function, so with no traffic the level should stay where it was (expected: it stays high). Record it; Phase 3 adds idle decay.
8. **[Claude] Update `docs/results/phase_2_adaptive_core.md`** from the pasted output, the tracker in `phases.md`, and the handoff, and deliver them as plain files or a repo-update patch.

## 5. Tests (all on the PC unless stated; peer servers up: `iperf3 -s`, `netserver`)

| # | Test | Commands | Expected |
|---|---|---|---|
| T1 | Flag round trip | `ethtool -C enp3s0 adaptive-rx on`, `ethtool -c enp3s0 \| grep Adaptive`, `bash scripts/read_intrmit.sh enp3s0`, then `adaptive-rx off` | `Adaptive RX: on`, registers `0x20e1` with `INTT=1` and `PktCntrDisable=1`, `IntrMitigate 0x0000`; after off the previous static values are back |
| T2 | Saved static settings | `ethtool -C enp3s0 rx-usecs 50`, `adaptive-rx on`, run load, `adaptive-rx off`, `ethtool -c` | `rx-usecs` back to 50 |
| T3 | Refused combinations | `ethtool -C enp3s0 adaptive-rx on tx-frames 8` | `-EINVAL` with a message, state unchanged |
| T4 | Open-loop load | `bash scripts/sample_level.sh enp3s0 > /tmp/level_udp.csv &` then `iperf3 -c $PEER -R -u -b 600M -t 30` | Level rises above 0 within a few seconds; NET_RX per second below `patched-off`; no loss |
| T5 | Closed-loop load | sampler running, `netperf -H $PEER -t TCP_RR -l 30 -P 0 -- -r 64,64` | Level stays at or near 0; transactions per second within 5% of `patched-off` (about 9,300) |
| T6 | Bulk TCP | `iperf3 -c $PEER -R -t 30` | 941 Mbit/s unchanged; record the level |
| T7 | Idle decay observation | After T4, stop traffic and sample for 30 seconds | Record whether the level stays high (expected, input for Phase 3) |
| T8 | No regression with adaptive off | `bash scripts/rx_bench.sh -l patched-off-2 -p $PEER -w "rr tcp"` and `python3 scripts/summarize_results.py patched-off patched-off-2` | Within noise of the earlier `patched-off` |
| T9 | Build quality | `make M=drivers/net/ethernet/realtek modules W=1`; `perl scripts/checkpatch.pl --strict --no-tree` on the patches (the script is in the kernel tree) | No warning from `r8169_main.c`; checkpatch reports only the missing `Signed-off-by` and the `Co-authored-by` trailer |
| T10 | Unload safety | With adaptive on and traffic running: `ip link set enp3s0 down`, `rmmod r8169`, reload, repeat 5 times | No oops, `WARN` or lockdep report in `dmesg` |

Run the interface and module tests at the console or on the phone tether, because the NIC is the only connection.

## 6. Acceptance criteria

- Patches 0003 and 0004 build with no warning from `r8169_main.c` and apply with `patch -p1` on the series so far.
- T1 to T3 and T8 to T10 pass.
- T4 shows the level moving up under open-loop load and T5 shows closed-loop latency within 5% of no moderation. If T5 fails (DIM raises the level and transactions per second fall), the phase is not done: record it, and consider a cap on the level or a different table before Phase 3.
- The decisions D1 to D9 are written in the results file with what changed from this plan.

## 7. Risks and fallbacks

| Risk | Fallback |
|---|---|
| DIM oscillates or stays high under request-response traffic | Lower the top levels, cap the level, or tune the table; record the data either way |
| `rx-usecs` echoes make `ethtool -C` behave unexpectedly | D6 can be reduced to "refuse changes of `rx-usecs` and `rx-frames` while adaptive is on" |
| Locking mistake leaves the module stuck on unload | Keep the stock module backup and a console; lockdep is enabled, so read `dmesg` after every test |
| Poll overhead from calling DIM on every poll shows in the CPU figure | Compare `irq_cpu_busy_pct` between `patched-off` and adaptive at line rate; if it matters, sample only every 8th poll |
| No dynamic debug in the kernel | Use `trace_printk()` or a counter read through `read_intrmit.sh` |

## 8. Results file outline (`docs/results/phase_2_adaptive_core.md`)

Status and date; patch table (0003, 0004) with what each changes; build and load notes; decisions D1 to D9 with changes from this plan; tests T1 to T10 with the pasted outputs summarised; the level traces for T4 to T6 (small table or figure); observations on idle behaviour; issues and fixes; carried-forward items for Phase 3.

## 9. Open questions to settle during the phase

- Is the first table right? Check the level distribution in T4 to T6 before Phase 4 tunes it.
- Does the `static-0us` check change level 0? Answered: no (0.5% difference, inside the spread); see the Phase 2 results file.
- Is `ethtool -c` showing the live level confusing enough to prefer reporting the saved static values and exposing the live level through the sampler only?
