# Phase 2: Adaptive core

Status: patches 0003 and 0004 built, signed and loaded on the test machine (`srcversion 0D34392FEBFC36E8A0E688E`, 2026-11-14). T1 to T4, T6 to T10 pass. **T5 fails by a small margin** (transactions per second 5.8% below adaptive-off, limit 5%); a decision on the fallback in plan section 7 is pending, so the phase is not done.

Plan: [`../plans/plan-2-adaptive-core.md`](../plans/plan-2-adaptive-core.md).

## Patches (against `v7.2.15`, after 0001 and 0002)

| Patch | Change |
|---|---|
| 0003 | RX packet and byte counters in `rtl_rx()`, poll-event counter, `net_dim()` called from `rtl8169_poll()` after every poll that received packets while the flag is on, work function that only logs the level (`netdev_dbg`) and restarts the measurement, `rx_dim_lock`, DIM reset on enable, cancel on disable, `net_dim_work_cancel()` and DIM reset in `rtl8169_down()` after `rtl8169_cleanup()` |
| 0004 | Level table `{0, 40, 80, 200, 400}` microseconds, `rtl_rx_dim_apply()` (read-modify-write of the RX fields of `IntrMitigate`), `rtl_write_coalesce()` shared by all `ethtool -C` paths, ethtool semantics for off to on, on to on and on to off, TX frame limit refused while adaptive |

Build check on a clean `v7.2.15` tree: all four patches apply with `patch -p1`; `r8169_main.c` compiles with no warning at `W=1` (defconfig plus `PROVE_LOCKING`, `DYNAMIC_DEBUG`, `DEBUG_FS`); `checkpatch.pl --strict --no-tree` reports only the missing `Signed-off-by` and the `Co-authored-by` trailer (and CamelCase notes on register names in the 0004 message).

## Decisions D1 to D9 as implemented

- D1 as planned: event = poll that received packets.
- D2: table `{0, 40, 80, 200, 400}`; units = `clamp(round(us * 1000 / scale), 1, 15)`, 0 for level 0.
- D3: `INTT` chosen on the ethtool path for the largest level (40 us unit at 1000 Mbit/s).
- D4: RX frame limit forced to 0, non-zero TX frame limit gives `-EINVAL` with an extack message.
- D5: `rx_dim_lock` mutex; the work never takes RTNL; ethtool holds it while writing registers.
- D6: as planned. Off to on saves the RX values of the request (checked first so they can be restored); on to off restores them. The apply happens while the flag is still on, then the flag is cleared, so a failed restore leaves adaptive mode untouched.
- D7: work writes only `IntrMitigate`, RX fields only.
- D8: as planned, plus a DIM reset to level 0 in `rtl8169_down()` because the hardware start clears `IntrMitigate`.
- D9: `netdev_dbg()` on every applied level, `scripts/sample_level.sh`, `scripts/build_sign_load.sh`.

Changes from the plan: the DIM state is reset before the flag is set (NAPI never touches DIM while the flag is off), and disabling calls `synchronize_net()` before `net_dim_work_cancel()` so no poll can queue the work afterwards.

## `static-0us` check (Phase 0 carry-forward, done 2026-11-13)

Question: does the "no moderation" level, which goes through the ethtool path and sets `PktCntrDisable`, behave like a module that was just loaded (bit clear)? Module under test: the installed stock module (`Adaptive RX: n/a`); the static path is the same as in the Phase 1 module.

Registers (`scripts/read_intrmit.sh`), after `ethtool -C enp3s0 rx-usecs 50` and then `rx-usecs 0 rx-frames 1`:

| Step | `CPlusCmd` | `IntrMitigate` |
|---|---|---|
| Start, before any change | `0x2061` (`INTT` 1, `PktCntrDisable` 0) | `0x0000` |
| `rx-usecs 50` | `0x20e0` (`INTT` 0, `PktCntrDisable` 1) | `0x00a0` |
| `rx-usecs 0 rx-frames 1` | `0x20e0` | `0x0000` |

Benchmark, 5 runs each (`rx_bench.sh`, 64 byte TCP_RR and bulk TCP):

| Configuration | RR trans/s | RR latency us | RR irq/s | TCP Mbit/s | TCP irq/s |
|---|---|---|---|---|---|
| `stock` (Phase 0 session) | 9213 +/- 93 | 108.4 +/- 1.1 | 18384 +/- 179 | 941.2 | 1.8 |
| `stock-again` (same session, bit clear) | 9519 +/- 147 | 105.0 +/- 1.6 | 19001 +/- 289 | 941.2 | 1.3 |
| `static-0us` (bit set) | 9563 +/- 133 | 104.5 +/- 1.5 | 19087 +/- 266 | 941.3 | 1.7 |

Result: `static-0us` against `stock-again` differs by 0.5% in transactions per second, 0.5 us in latency and 0.5% in interrupts per second, all inside the run-to-run spread. Bulk TCP is the same. Level 0 may therefore go through the ethtool path with `PktCntrDisable` set, and D4 stays as written.

Lessons recorded:

- **A first attempt tested nothing.** `ethtool -C enp3s0 rx-usecs 0 rx-frames 1` when those are already the current values is a no-op: ethtool sees no change and never calls the driver, so the registers stayed at `0x2061` and the run was a stock-configuration run. That run was kept as `stock-again`. To force a driver call, change a value first (here `rx-usecs 50`).
- **Session drift.** `stock` (earlier session) and `stock-again` differ by 3.3% in transactions per second, more than the spread inside one session (1.6%). Compare configurations that were measured in the same session.
- **`INTT` survives a module reload.** The start state was `0x2061` because an earlier `rx-usecs 100` test left `INTT` 1 in the chip, and probe reads `CPlusCmd & CPCMD_MASK`, which includes `INTT`. `PktCntrDisable` is not in the mask, so reloading the module clears it. A reboot clears both.

## Tests

Test machine: RTL8168h on `enp3s0`, 1 Gbit/s, peer 10.8.1.53, lockdep enabled. `chk` below means the `dmesg` grep for lockdep, `WARNING:`, `BUG:` and `Oops` (boot banners excluded).

| # | Result | Evidence |
|---|---|---|
| T1 | Pass | On: `Adaptive RX: on`, rx-usecs 0, rx-frames 1, `CPlusCmd` `0x20e1` (`INTT` 1, `PktCntrDisable` 1), `IntrMitigate` `0x0000`. Off: `0x20e0`, `0x0000`. |
| T2 | Pass | `rx-usecs 50` gave `0x20e0` / `0x00a0`; after adaptive on, a 300M UDP run (0 loss) and adaptive off, `rx-usecs` read 50 again and the registers were `0x20e0` / `0x00a0`. |
| T3 | Pass | `ethtool -C enp3s0 adaptive-rx on tx-frames 8` gave `r8169: TX frame limit is not supported with adaptive-rx` and `Invalid argument`; `Adaptive RX: off`, `tx-frames` unchanged. |
| T4 | Pass | Under 600M UDP the timer field went to 5 (200 us) and 10 (400 us); see the loss note below. NET_RX per second fell from 20872 (adaptive off) to 3792 (adaptive on). |
| T5 | **Fail (by 0.8 points)** | 8794 +/- 113 trans/s against 9340 +/- 115 (adaptive off, same session): -5.8%. Latency 113.6 us against 107.0 us. See below. |
| T6 | Pass | 941.2 Mbit/s against 941.3, 0 retransmits in the 30 s run. |
| T7 | Observed | After the load stopped the level stayed at the top: `tail` of the trace showed timer field 10 (400 us) and about 4 interrupts per second. Confirms the missing idle decay (Phase 3). |
| T8 | Pass | `patched-off-2` against `patched-off`: 9340 +/- 115 against 9330 +/- 140 trans/s, 107.0 against 107.1 us, TCP 941.3 both, UDP loss 0.0007% against 0.0017% at 900M. |
| T9 | Pass | No compiler warning at `W=1`; `checkpatch --strict --no-tree` reports only the missing `Signed-off-by`, the `Co-authored-by` signature and CamelCase notes on register names. |
| T10 | Pass | Five rounds of adaptive on, UDP load, `ip link set down`, `rmmod`, `insmod`: no hang, `chk` empty. End state `0x2061` / `0x0000` (`INTT` 1 survives the reload). |

`chk` was empty after T2, T4, T6, T8 and T10.

### Same-session comparison (`rx_bench.sh`, 5 runs each, adaptive off against adaptive on)

| Workload | Metric | adaptive off (`patched-off-2`) | adaptive on |
|---|---|---|---|
| RR 64 B | trans/s | 9340 +/- 115 | 8794 +/- 113 |
| RR 64 B | mean latency us | 107.0 +/- 1.3 | 113.6 +/- 1.5 |
| RR 64 B | irq/s | 18637 +/- 237 | 17536 +/- 216 |
| RR 64 B | NET_RX/s | 28078 +/- 343 | 26452 +/- 331 |
| TCP bulk | Mbit/s | 941.3 | 941.2 |
| TCP bulk | NET_RX/s | 32504 +/- 175 | 33439 +/- 1611 (one outlier run) |
| UDP 600M | loss % | 0.0000 | 0.0000 |
| UDP 600M | NET_RX/s | 20872 +/- 1904 | 3792 +/- 268 |
| UDP 600M | jitter ms | 0.016 | 0.007 |
| UDP 900M | loss % | 0.0007 | 0.0000 |
| UDP 900M | NET_RX/s | 36801 +/- 358 | 21510 +/- 2707 |
| UDP 900M | jitter ms | 0.048 | 0.010 |

Reading: bulk traffic gets 5.5 times fewer receive softirq runs at 600M and 1.7 times fewer at 900M with no loss and lower jitter; hardware interrupts per second stay near 2000 in every UDP run, since the existing software coalescing already limits them. Request-response pays for it: DIM spends part of the time above level 0 even though every poll carries one packet.

### Level traces (`sample_level.sh`, 0.2 s interval)

Timer field 0, 1, 2, 5, 10 means 0, 40, 80, 200, 400 us. Samples per field:

| Run | 0 | 1 | 2 | 5 | 10 |
|---|---|---|---|---|---|
| T4 (30 s UDP load, then 30 s idle) | 58 | 8 | 1 | 108 | 208 |
| T5 (TCP_RR) | 74 | 38 | 2 | 0 | 3 |
| T6 (bulk TCP) | 46 | 16 | 47 | 3 | 10 |

`dmesg` showed 523 `rx dim:` lines in the T4 run, about 17 level changes per second, so DIM keeps stepping up and down under steady load.

### Loss at 600M UDP

The T4 run lost 59 of 1553877 datagrams (0.0038%), at seconds 7 to 9, with the sampler running. In the five-run benchmark with adaptive on there was no loss at 600M or 900M. Two further 30 s runs gave 0 and 10 lost datagrams. In the run that lost 10, `UdpRcvbufErrors` and `UdpInErrors` both rose by 10 and the interface `missed` counter stayed at 110: the datagrams were dropped by the receive socket buffer of the test machine, not by the NIC. With adaptive off one of ten benchmark runs also lost datagrams (0.0037% at 900M). Conclusion: occasional tiny socket-buffer loss of the same size with or without adaptive mode; not attributed to the driver. If it matters later, repeat with a larger receive buffer (`iperf3 -w`).

### Why T5 fails and what the plan allows

The closed-loop run leaves level 0 about a third of the time (T5 trace above). The cheapest non-zero level is 40 us (one hardware unit at `INTT` 1), and a request-response reply that waits for the timer pays most of it. The plan says: if T5 fails, record it and consider a cap or a different table before Phase 3. Candidate fixes, decision pending:

1. A table with a smaller first step. The hardware unit is 5 us at `INTT` 0, so the top level would be capped at 75 us, which gives up much of the 600M UDP gain.
2. Let DIM see only polls that received two or more packets, so single-packet traffic stays at level 0. It needs a rule that lets the level fall again, otherwise a high level can stick.
3. Accept the 5.8% and tune in Phase 4.

## Known gaps carried to Phase 3

- `rtl_reset_work()` (transmit timeout, PCI error) and resume restart the hardware without going through `rtl8169_down()`: `IntrMitigate` becomes 0 while DIM still holds its old level.
- The hardware start path and the work function can write `IntrMitigate` and read `cp_cmd` at the same time (no common lock yet).
- A link-speed change alters the timer unit but the level is not re-applied.
- No idle decay: after traffic stops the level stays where it was (T7: stays at 400 us).
- DIM changes level about 17 times per second under steady load (T4 log); consider a longer measurement window in Phase 4.
