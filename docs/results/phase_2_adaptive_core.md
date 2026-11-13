# Phase 2: Adaptive core

Status: patches written and built (compile and `W=1` only). Nothing has been run on the test machine yet; the test table below is to be filled in from the PC output.

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

## Tests

| # | Result |
|---|---|
| T1 to T10 | Not run yet |

## Known gaps carried to Phase 3

- `rtl_reset_work()` (transmit timeout, PCI error) and resume restart the hardware without going through `rtl8169_down()`: `IntrMitigate` becomes 0 while DIM still holds its old level.
- The hardware start path and the work function can write `IntrMitigate` and read `cp_cmd` at the same time (no common lock yet).
- A link-speed change alters the timer unit but the level is not re-applied.
- No idle decay: after traffic stops the level stays where it was.
