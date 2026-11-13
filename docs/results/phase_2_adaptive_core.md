# Phase 2: Adaptive core

Status: patches written and built (compile and `W=1` only). The `static-0us` check is done (below). Patches 0003 and 0004 have not been loaded on the test machine yet; the test table is to be filled in from the PC output.

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

| # | Result |
|---|---|
| T1 to T10 | Not run yet |

## Known gaps carried to Phase 3

- `rtl_reset_work()` (transmit timeout, PCI error) and resume restart the hardware without going through `rtl8169_down()`: `IntrMitigate` becomes 0 while DIM still holds its old level.
- The hardware start path and the work function can write `IntrMitigate` and read `cp_cmd` at the same time (no common lock yet).
- A link-speed change alters the timer unit but the level is not re-applied.
- No idle decay: after traffic stops the level stays where it was.
