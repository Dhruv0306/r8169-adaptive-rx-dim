# The project explained

This document explains the project in detail: the problem, the background a reader needs, the design, every part of the code, and why each decision was made. It is written for someone who knows C and has met the Linux kernel, but not this driver. Read it with the [diagrams](diagrams/README.md) open: each section names the diagram that draws the part it describes. The measured results are in [results explained](results-explained.md); the file-by-file list of code changes is in [kernel changes](kernel-changes.md).

![Overview](diagrams/img/00-overview.svg)

## 1. The problem

A network card tells the CPU about received packets with an interrupt. At high packet rates one interrupt per packet is too much work: each interrupt has a fixed cost (entering the handler, masking, scheduling the softirq). Cards therefore offer **interrupt moderation**: the card waits a short time after the first packet, and raises one interrupt for everything that arrived in that time.

Moderation is a trade:

| Hold time | Effect when packets arrive fast | Effect when packets arrive one at a time |
|---|---|---|
| Short or none | Many interrupts, much CPU work | Every packet is delivered at once: low latency |
| Long | Few interrupts, less CPU work | Every packet waits up to the hold time: high latency |

No fixed setting is right for both. The `r8169` driver (Realtek RTL8111/8168/8211/8411 Gigabit Ethernet) lets the user set a fixed hold time with `ethtool -C`, and starts with none. The project makes the hold time follow the traffic.

## 2. Background

### 2.1 The receive path of r8169

The card has one receive queue and one NAPI context. NAPI is the kernel's polling scheme for network drivers: an interrupt only starts a poll, and the poll then takes packets from the ring until it runs out of packets or budget.

1. A packet arrives and the card writes it into the receive descriptor ring.
2. After the card's moderation timer, the card raises an interrupt. `rtl8169_interrupt()` masks the card's interrupts and schedules NAPI.
3. `rtl8169_poll()` runs in softirq context. It calls `rtl_tx()` and `rtl_rx()`, and when it received less than its budget it calls `napi_complete_done()` and `rtl_irq_enable()`, which lets the card interrupt again.

Under a very heavy load NAPI already limits the interrupt rate by itself, because the poll keeps running and the interrupt stays masked. Moderation matters in the middle range, where packets come fast enough to cause many interrupts but the poll still ends between them. See [diagram 1](diagrams/01-poll-and-sampling.md).

### 2.2 The IntrMitigate register

The card has a 16 bit register `IntrMitigate` (offset 0xe2):

| Bits | Field |
|---|---|
| 3:0 | RX frame count (a value `n` means `4n` frames) |
| 7:4 | RX timer, in units |
| 11:8 | TX frame count |
| 15:12 | TX timer, in units |

The length of a unit is not fixed. It depends on the link speed and on the `INTT` bits of another register, `CPlusCmd`, and it is shared by RX and TX. At 1 Gbit/s on this chip family the unit is 5, 40, 80 or 160 microseconds depending on `INTT`. A timer field is 4 bits wide, so it holds at most 15 units. The hardware needs a timer whenever a frame count is set. The stock driver's `rtl_set_coalesce()` writes these fields from `ethtool -C`. RTL8125 chips (2.5 Gbit/s) return `-EOPNOTSUPP` from the coalescing functions, so they are out of scope.

On the author's chip (RTL8168h, XID 541) timer-only operation keeps the `PktCntrDisable` bit of `CPlusCmd` set, as the stock timer-only path does; a frame limit clears it. This was confirmed on the hardware in Phase 0.

### 2.3 DIM

DIM (`include/linux/dim.h`, `lib/dim`) is the kernel's library for dynamic interrupt moderation. The driver gives it samples (packets, bytes and events counted so far) by calling `net_dim()`. After 64 events DIM compares the interval with the previous one and moves one level up, one level down, or parks. When the level changes it queues a work item, and the driver's work function applies the new level. `virtio_net` is the reference integration. See [diagram 2](diagrams/02-dim-decision.md).

## 3. The approach

1. Use DIM instead of writing an algorithm: it is the established mechanism, and it keeps the change small.
2. Support receive only. The receive fields of `IntrMitigate` can be changed without touching the transmit fields.
3. Give DIM a table of five levels in microseconds, `{0, 40, 80, 200, 400}`, converted to timer units for the current link speed. The library's own tables assume counts that a 4 bit field cannot hold.
4. Timer-only levels: the frame limit stays 0.
5. Make it a switch: `ethtool -C <dev> adaptive-rx on|off`. With it off the driver is the stock driver.
6. Build it in six patches, so that DIM's behaviour was visible before any register was touched (see [diagram 8](diagrams/08-series-and-build.md)).

## 4. Architecture

[Diagram 0](diagrams/00-overview.md) shows six boxes. This section walks through them in the order data flows.

## 5. Box B: receive poll and sampling ([diagram 1](diagrams/01-poll-and-sampling.md))

**Counters.** The kernel's receive statistics are per CPU, so the driver keeps its own totals: `rx_dim_packets` and `rx_dim_bytes` in `struct rtl8169_private`, added to at the end of `rtl_rx()`. They are written and read only in NAPI context, so they need no lock.

**What is an event.** One event is one call of `rtl8169_poll()` that received at least one packet. The poll function calls `rtl_rx_dim_update()` right after `rtl_rx()`, in every such poll, and not only when `napi_complete_done()` succeeds, because at line rate a poll may never complete and DIM would starve.

**The single-packet guard** (patch 0005). `rtl_rx_dim_update()` returns without calling DIM when the poll received fewer than two packets and the level is 0. A single packet in a poll means the CPU kept up with the card, so a longer timer would only add latency, and request-response traffic looks exactly like that. Above level 0 every poll is shown to DIM, so DIM can always step back down, for example when bulk traffic is followed by request-response traffic. Without the guard, DIM kept leaving level 0 on statistics noise, and one request-response stream lost 5.8% of its transactions per second.

**The sample.** `dim_update_sample()` builds a `struct dim_sample` from the event counter (`rx_dim_events`, incremented per fed poll), the packet counter and the byte counter; `net_dim()` takes it.

## 6. Box C: the DIM decision ([diagram 2](diagrams/02-dim-decision.md))

`net_dim()` stores a start sample, and when 64 events have passed it computes bytes, packets and events per millisecond for the interval and compares them with the previous interval: bytes per millisecond first, then packets per millisecond (a difference of about 10 percent or more is significant), then events per millisecond (fewer is better). DIM starts parked on top at level 0. It leaves the parking when the statistics change, and then moves one level per decision; when a move does not improve things it turns around, and it parks at either end of the table or after about ten steps in a row. When the level (`dim->profile_ix`) changes, DIM schedules the work item.

The driver reads `profile_ix` as the current level; there is no separate variable.

DIM sees only packets, bytes and polls. That is why the result at 900 Mbit/s of large datagrams is unreliable: those counters barely change between levels there.

## 7. Box D: applying a level ([diagram 3](diagrams/03-apply-level.md))

`rtl_rx_dim_work()` runs on the system workqueue and may sleep. It takes `rx_dim_lock`, checks that adaptive mode is still on, and calls `rtl_rx_dim_apply()`:

1. `rtl_coalesce_info()` gives the table of timer unit lengths for this chip.
2. The unit for the current link speed and `INTT` bits is looked up (`scale_nsecs`).
3. `rtl_rx_dim_units()` turns the level's microseconds into a field value: `DIV_ROUND_CLOSEST(us * 1000, scale)`, capped at 15. A level shorter than half a unit gives 0 (no moderation) instead of one whole unit; this only happens after a speed change to a slower link.
4. The register is read, the RX timer and RX frame fields are cleared, the new RX timer field is put in, and the register is written and committed (`rtl_pci_commit()`).
5. `rtl_rx_dim_arm_decay()` starts the idle watch if the level is above 0, and the DIM state returns to start-measure.

At 1 Gbit/s with `INTT` 1 (a 40 microsecond unit) the levels become fields 0, 1, 2, 5 and 10.

**What is not written.** The TX fields are kept as they are. `CPlusCmd` is never written by the work function: the ethtool path and `rtl_hw_start()` stay its only writers, so the work function is not a third writer next to them. This is also why the `INTT` unit is chosen once on the ethtool path (for the longest level, 400 us) and kept across link-speed changes.

## 8. Box A: the control path ([diagram 4](diagrams/04-ethtool-control.md))

`rtl_set_coalesce()` was split: its old body became `rtl_write_coalesce()`, which now takes an `adaptive` argument. With `adaptive` false it is the stock behaviour. With it true the RX frame limit is 0, the RX timer is the current DIM level and the `INTT` unit is the one that fits the longest level.

| Transition | What happens |
|---|---|
| off to on | The static RX settings are checked, then saved (`rx_static_usecs`, `rx_static_frames`); DIM is reset to level 0; the register is written for the adaptive state; `rx_dim_enabled` is set |
| on to on | `rx-usecs` and `rx-frames` in the request are ignored, because they are what `rtl_get_coalesce()` reported for the live level and not the user's wish. TX settings still apply |
| on to off | The saved static RX settings are restored; the flag is cleared; the lock is released; `synchronize_net()` waits for any poll that saw the flag on; then the DIM, decay and link work are cancelled |
| TX frame limit with adaptive on | Refused with `EINVAL` and a message |

`rtl_get_coalesce()` reads the live register and reports the flag, so `ethtool -c` shows the current level.

## 9. Box E: lifecycle and robustness ([diagram 5](diagrams/05-lifecycle.md))

The chip-specific start code writes `IntrMitigate = 0`, DIM only runs when polls happen, the timer unit changes with the link speed, and work items can outlive the device state. Patch 0006 handles four cases:

| Case | Code | What it does |
|---|---|---|
| Hardware start | `rtl_rx_dim_restore()`, called at the end of `rtl_hw_start()` before `rtl_irq_enable()` | Writes the level DIM holds into the register again and arms the idle watch. After open or resume DIM is at level 0 (reset by `rtl8169_down()`); after a reset task it keeps its level |
| Link speed change | `rtl_rx_dim_link_work()`, scheduled by `r8169_phylink_handler()` | Writes the level again with the timer unit of the new speed. It is a work item because the PHY handler holds the PHY lock |
| Idle | `rtl_rx_dim_decay_work()`, a delayed work every 200 ms while the level is above 0 | If no poll happened since the last tick, resets DIM and writes level 0. Measured: 0.39 s from the last packet to level 0 |
| Down | `rtl8169_down()` | After `rtl8169_cleanup()` has stopped NAPI, cancels the DIM work, the decay work and the link work, in that order, with no lock held, then resets DIM |

## 10. Box F: locking ([diagram 6](diagrams/06-locking.md))

There are four contexts: the NAPI poll (softirq), ethtool and open and close (process context under RTNL), the PHY state machine (PHY lock), and the workqueue. One new mutex, `rx_dim_lock`, protects the flag, the saved static settings and the adaptive writes to `IntrMitigate`.

Lock order: RTNL, then PHY lock, then `rx_dim_lock`. The rule that makes it deadlock-free: the work items take only `rx_dim_lock`, never RTNL or the PHY lock. So `rtl8169_down()`, which runs under RTNL, can call `cancel_work_sync()` on them without waiting for something that waits for RTNL, the same pattern `virtio_net` uses. The poll function never takes the mutex. The flag is written with `WRITE_ONCE()` under the lock and read with `READ_ONCE()` in the poll. The few remaining races end with the register and DIM agreeing after the queued work ran; they are listed in [`locking.md`](locking.md).

## 11. How it was verified

| Phase | Verification | Details |
|---|---|---|
| 0 | Baseline of the stock driver, validation of the interrupt counter | [phase 0 results](results/phase_0_environment_and_baseline.md) |
| 1 | The flag round trip; the mode off matches stock | [phase 1 results](results/phase_1_plumbing.md) |
| 2 | Tests T1 to T11; T5 failed and led to patch 0005 | [phase 2 results](results/phase_2_adaptive_core.md) |
| 3 | Down and up, forced reset, speed change, suspend, 36 minute stress, concurrent ethtool, all with lockdep | [phase 3 results](results/phase_3_robustness.md) |
| 4 | Final matrix of 5 configurations by 8 cells, 12 runs per cell, level traces, stepped load | [phase 4 results](results/phase_4_measurement_and_tuning.md) |
| 5 | Clean-tree check, matched re-run, demo rehearsals | [phase 5 results](results/phase_5_report_and_demo.md) |

How to repeat each of these is in [setup and testing](setup-and-testing.md); what the numbers mean is in [results explained](results-explained.md).

## 12. Design decisions and why

| Decision | Why |
|---|---|
| Use the DIM library | Established mechanism, small change, a model to follow (`virtio_net`) |
| RX only | Keeps the first version small; the RX fields can change without touching TX |
| Own level table in microseconds, converted at apply time | The library's defaults do not fit a 4 bit field; microseconds survive a speed change |
| Levels 0, 40, 80, 200, 400 us | At 1 Gbit/s the 400 us top needs the 40 us unit; the 200 us point was measured in Phase 0 |
| Timer-only levels | The hardware needs a timer whenever a frame limit is set; the stock timer-only path runs with `PktCntrDisable` set |
| `INTT` chosen once on the ethtool path | Keeps the work function away from `CPlusCmd` |
| DIM is called on every poll, not only at completion | At line rate a poll may never complete |
| Single-packet guard | Request-response lost 5.8% without it |
| One mutex; work items take only that mutex | Allows cancelling work under RTNL without a deadlock |
| Idle decay | DIM only runs when polls happen; the level stayed at 400 us after a burst |
| Mode off is the default and equals stock | The change only acts when the user asks for it |
| No change to the level table after Phase 4 | The first table passed the plan's tuning rule: request-response within 5%, no throughput or loss regression, lower NET_RX and CPU |

## 13. The repository

| Path | Content |
|---|---|
| `patches/` | The six patches against `v7.2.15` |
| `docs/` | This documentation; `plan.md` and `plans/` (the plans), `results/` (one file per phase), `locking.md`, `report.md`, `handoff.md`, `diagrams/`, `figures/` |
| `scripts/` | Benchmark, matrix, sampling, stress, demo and check scripts, and `test-hooks/` |
| `results/` | Raw logs of every run |

The map of documents is in [`README.md`](README.md).

## 14. Glossary

| Term | Meaning |
|---|---|
| NAPI | The kernel's polling scheme for network receive |
| Softirq, NET_RX | The deferred-work context in which the poll runs; `/proc/softirqs` counts NET_RX runs |
| Interrupt moderation, coalescing | Delaying the interrupt so that one covers several packets |
| DIM | Dynamic interrupt moderation library in the kernel |
| `IntrMitigate`, `CPlusCmd` | Card registers: the moderation fields, and the control register that holds the timer unit (`INTT`) |
| `INTT` | The two bits of `CPlusCmd` that select the unit of the timer fields |
| Level | One of five DIM settings, here 0, 40, 80, 200 and 400 microseconds |
| RTNL | The global lock around network configuration changes |
| Lockdep | The kernel's lock-order checker |
| Request-response | Traffic of one small request and one small reply at a time (`netperf` TCP_RR) |
