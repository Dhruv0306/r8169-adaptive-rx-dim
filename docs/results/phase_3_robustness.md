# Phase 3: Robustness and locking

Status: in progress (started 2026-11-14). Patch 0006 is written, builds and was loaded on the PC. The table below shows what was measured; F4b, F6, the scripted F9 timing and a loaded F5 are still to do.

Plan: [`../plans/plan-3-robustness.md`](../plans/plan-3-robustness.md). Locking analysis: [`../locking.md`](../locking.md).

## Patch 0006 (against `v7.2.15`, after 0001 to 0005)

`patches/0006-r8169-re-apply-DIM-level-on-restart-link-change-and-.patch`

| Gap found in Phase 2 | Change in 0006 | Plan decision |
|---|---|---|
| `rtl_hw_start()` ends with `IntrMitigate = 0`, so after a reset task DIM kept its level while the timer was off | `rtl_rx_dim_restore()` at the end of `rtl_hw_start()`, just before `rtl_irq_enable()`: under `rx_dim_lock`, DIM state back to `DIM_START_MEASURE` and the current level written | D1 |
| A reset keeps the level, close and suspend start again from level 0 | No new code: `rtl8169_down()` already reset DIM in patch 0003 | D2 |
| A speed change alters the length of a timer unit | `r8169_phylink_handler()` queues `rx_dim_link_work` when the carrier is up; the work writes the level again with the unit of the new speed, `INTT` unchanged | D3 |
| At a slower speed the unit chosen for 1 Gbit/s is longer than a low level | `rtl_rx_dim_units()` no longer rounds up to one whole unit: a level shorter than half a unit gives 0 (no moderation). On the ethtool path `INTT` is chosen for the largest level, so no level rounds to 0 there | D3, new detail |
| The level stayed at 400 us after the load stopped (T7) | `rx_dim_decay` delayed work, armed when a level above 0 is applied; every 200 ms it compares the poll event counter with the previous tick and, if no poll happened, resets DIM and writes level 0 | D4 |
| Work items must not run after teardown or after adaptive mode is turned off | `rtl8169_down()` (after `rtl8169_cleanup()`) and the off path of `rtl_set_coalesce()` cancel the DIM work, then the decay work, then the link work, with no lock held | D5 |

Changes from the plan: none in the design. The poll side reads `profile_ix` with `READ_ONCE()` because the decay work can now write it.

Test hook (D7), not part of the series: `scripts/test-hooks/force_reset.patch` adds `/sys/kernel/debug/r8169_force_reset`; writing `1` runs the reset task, the same path as a transmit timeout or a PCI error. Apply it on top of 0001 to 0006 for F4b only and take it out again afterwards (`patch -R -p1`, rebuild).

### Build and style checks (done 2026-11-14, on a clean `v7.2.15` clone)

- Patches 0001 to 0005, 0006 and the hook apply in order with `patch -p1` (each after `--dry-run`) on a clean tree.
- `r8169_main.c` compiles with no warning at `W=1` (defconfig plus `PROVE_LOCKING`, `DEBUG_ATOMIC_SLEEP`, `DEBUG_MUTEXES`, `DYNAMIC_DEBUG`, `DEBUG_FS`, `R8169=m`), with and without the hook. The link step could not be checked in that tree (no `Module.symvers` without a full kernel build); the PC build is the real one.
- `checkpatch.pl --strict --no-tree` on 0006 and on the hook reports only the missing `Signed-off-by` and the `Co-authored-by` signature.
- `scripts/phase3_tests.sh` and `scripts/stress_f7.sh` pass `bash -n` and `shellcheck -S warning`, and the `f4` and `f9` logic was run once against mocked `ethtool`, `ip` and `iperf3` (not a hardware test).

## Tests (PC, `enp3s0`, lockdep enabled, peer `$PEER`)

Commands are in the plan, section 5; `scripts/phase3_tests.sh DEV TEST` runs F4, F4b, F5, F9, F10 and F11, and `scripts/stress_f7.sh` runs F7. `chk` means the `dmesg` grep for lockdep, `WARNING:`, `BUG:` and `Oops`.

| # | Result | Evidence |
|---|---|---|
| F4 | pass | 10 down/up rounds with adaptive on: after every `up`, `CPlusCmd 0x20e1` (`INTT=1`, `PktCntrDisable=1`) and `IntrMitigate 0x0000` (level 0) |
| F4b | not run | needs the test hook |
| F5 | link change done, conversion not exercised | link went 1000, 100, 1000 Mbit/s with adaptive on and the registers stayed consistent, but the 80M UDP load did not raise the level, so the new unit conversion was not seen. Rerun with a higher rate |
| F6 | not run | manual |
| F7 | pass for hangs and register state | 30 min of adaptive toggling every 100 ms with 161 link bounces, then 20 module reloads: no hang, `rmmod` always returned, registers consistent after the toggling and after every reload. Whether the background loads ran during it is not confirmed (the script hid `iperf3` errors; fixed in the next script commit) |
| F8 | partly done | Build and checkpatch above; no `sparse` run |
| F9 | decay seen, timing not measured by the script | by hand: under 600M UDP the timer field reached 5 and 10 (levels 3 and 4, flapping between them); `rx dim: idle, level 0` was logged about 0.44 s after the last level change. The scripted timing run is still to be done |
| F10 | weak | 9617 transactions per second after a burst, but the level was already 0 before the sparse traffic, so the decay was not what was tested |
| F11 | pass | 60 s of concurrent `adaptive-rx` and `tx-usecs` changes under load: no hang, final `PktCntrDisable=1`. `tx-usecs 20` reads back as 40 because one timer unit is 40 us at 1 Gbit/s, which is the stock rounding |

Lockdep: `journalctl -k -b` for the whole boot (603 link up/down lines, so the log was complete) contains no lockdep report, `WARNING:`, `BUG:` or `Oops` after the tests above. The first versions of the scripts read `dmesg` by line count, which did not work, so only this journal check counts for F4 to F11.

## Bugs found and fixed during the phase

None yet.

## Known limits

- After a speed change `INTT` stays as it was chosen, so the steps are coarser or finer than ideal until adaptive mode is turned off and on again.
- A reset or resume still clears the TX fields of `IntrMitigate` (stock behaviour); only the RX timer is written again.

## Carried forward

- Phase 4: the 900M UDP dwell at low levels (Phase 2 results) and the high level-change rate.
