# Phase 3: Robustness and locking

Status: in progress (started 2026-11-14). Patch 0006 is written, builds and was loaded on the PC. The table below shows what was measured; F7 has to be rerun with the traffic counted. F4b to F6 and F9 to F11 are done.

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
| F4b | pass at the register level; RX stall found, not caused by 0006 | with the hook and 600M UDP load at level 4: the kernel log shows `TEST restore: level 4, IntrMitigate 0x00a0` right after the reset, so the level was written again and the register was not left at 0. The same forced reset with adaptive mode off (no DIM, no restore) stops RX in the same way, see "RX stops after a forced reset" below. No lockdep, `WARNING`, `BUG` or `Oops` in either run |
| F5 | pass for the unit at 100 Mbit/s; the link work itself is not separately visible | 1000, 100, 1000 Mbit/s, no lockdep. At 100 Mbit/s under a 90M load of 64 byte payloads the level rose to `rx-usecs: 82` with `IntrMitigate 0x0040` (`rx_timer=4`): 4 units of 20.48 us, level 2 at the 100 Mbit/s unit, so the conversion is right. After the link returned to 1000 Mbit/s the registers read `IntrMitigate 0x0000` and `Adaptive RX: on`. The level reaches 0 while the link is down (decay), so the link work normally finds level 0 when the link comes up |
| F6 | pass | `rtcwake -m mem -s 30`: the machine resumed with the link up, `Adaptive RX: on` was kept, `IntrMitigate` read `0x0000` right after resume, and under 600M UDP the timer fields 5 and 10 appeared (3 and 20 samples at 0.5 s); no lockdep, `WARNING`, `BUG` or `Oops` in `journalctl -k` since before the suspend |
| F7 | no hang and consistent registers; traffic during the run not confirmed | 30 min of adaptive toggling every 100 ms with 161 link bounces, then 20 module reloads: `rmmod` always returned and the registers matched the flag afterwards. The script of that run hid `iperf3` and `netperf` results, so it is not known how much traffic ran. `stress_f7.sh` now counts the rounds; rerun |
| F8 | partly done | Build and checkpatch above; no `sparse` run |
| F9 | pass | `decay_timing.sh` on the saved CSV: 0.39 s from the last packet seen at level above 0 to level 0 (expected about 0.4 s or less, +/- 0.1 s); 15 samples saw background packets after the level was 0, which do not take part in the decay |
| F10 | pass, no regression | adaptive on: 9646, 9435, 9297 transactions per second; adaptive off, same session: 9599 and 9100 (the first off run failed to connect to netserver). The two sets overlap, the spread between runs is about 5 percent |
| F11 | pass | 60 s of concurrent `adaptive-rx` and `tx-usecs` changes under load: no hang, final `PktCntrDisable=1`. `tx-usecs 20` reads back as 40 because one timer unit is 40 us at 1 Gbit/s, which is the stock rounding |

Lockdep: `journalctl -k -b` for the whole boot (603 link up/down lines, so the log was complete) contains no lockdep report, `WARNING:`, `BUG:` or `Oops` after the tests above. The first versions of the scripts read `dmesg` by line count, which did not work, so only this journal check counts for F4 to F11.

## RX stops after a forced reset (finding, outside 0006)

Two runs of F4b with the hook and 600M UDP load, `rx_packets` and the RX timer field sampled every 0.1 s:

| Run | What happened |
|---|---|
| Adaptive on, level 4 | `TEST restore: level 4, IntrMitigate 0x00a0`, then `rx_packets` flat from 0.02 s after the reset. The iperf3 receiver got 0 bytes from the second after the reset until about 20 s later, when data came back by itself. `rx dim: idle, level 0` was logged because no poll happened for 200 ms, as designed. Turning adaptive off 6 s after the reset did not bring RX back |
| Adaptive off | `rx_packets` flat from 0.02 s after the reset; 600 Mbit/s for 4 s, then 461 packets, then nothing for the remaining 25 s of the load |

So the stall does not depend on adaptive mode, on the restore, or on a nonzero RX timer (the probe ruled that out). With adaptive mode off, the only code of patches 0001 to 0006 in the reset path is a call that returns at once, so the stall is very probably the behaviour of the unmodified reset path on this NIC under heavy receive load. That is not proven: it was not run on an unpatched driver. It does not change what 0006 has to do, and the restore itself is confirmed by the logged register value. It does mean that a forced reset under load cannot show the level climbing again afterwards, because there is no traffic to poll.

Not investigated (outside the scope of the project): whether the stall is the chip not receiving or NAPI not polling. `ip -s link` (`rx_missed_errors`, `rx_fifo_errors`) and the interrupt count in `/proc/interrupts` during the stall would tell the two apart.

## Bugs found and fixed during the phase

None yet.

## Known limits

- A forced reset (the same path as a transmit timeout) under 600M receive load leaves RX dead for 20 s or more on this machine, with adaptive mode on or off; see the finding above.
- A speed change always drops the link for a second or more, so the idle decay has already set the level to 0 when the link returns; the link work (conversion with the new unit) is a safety net for flaps shorter than the decay period and cannot be observed on hardware by changing the speed.
- After a speed change `INTT` stays as it was chosen, so the steps are coarser or finer than ideal until adaptive mode is turned off and on again.
- A reset or resume still clears the TX fields of `IntrMitigate` (stock behaviour); only the RX timer is written again.

## Carried forward

- Phase 4: the 900M UDP dwell at low levels (Phase 2 results) and the high level-change rate.
