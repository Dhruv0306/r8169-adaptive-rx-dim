# Adaptive receive interrupt moderation for the Realtek r8169 driver (RTL8111/8168) on Linux 7.2.15

Course: Advanced Operating Systems (CS G623), coursework project: enhancing an existing driver
Author: Dhruv
Target kernel: 7.2.15 (all source references below were checked against the `v7.2.15` tag)
Files in scope: `drivers/net/ethernet/realtek/r8169_main.c`, `drivers/net/ethernet/realtek/Kconfig`, plus test and measurement scripts
Decision: the professor reviewed this idea and replied that it looks good.

## 1. Summary

The Gigabit Ethernet controller in my PC is a Realtek RTL8111/8168 (PCI `03:00.0`, driver `r8169`). It can delay its receive interrupts in hardware, so that one interrupt covers several packets. The driver already lets the user set that delay by hand with `ethtool -C`, and it starts with the delay switched off. It has no adaptive mode: nothing adjusts the delay as the traffic changes.

The project adds one. It uses the kernel's existing dynamic interrupt moderation library (DIM, `include/linux/dim.h`), which watches packet and interrupt rates and moves between a small set of moderation levels. The goal is quick response at light load and fewer interrupts at heavy load, switched on and off with `ethtool -C <dev> adaptive-rx on|off`.

This is a performance change to an existing driver. It is measured on real hardware, with a second machine as the traffic source.

## 2. What exists today (v7.2.15)

| Item | Finding |
|---|---|
| Coalescing control | `rtl_get_coalesce()` and `rtl_set_coalesce()`, static values only (`r8169_main.c` lines 2088 and 2149) |
| What ethtool may set | `rx-usecs`, `rx-frames`, `tx-usecs` and `tx-frames`; no adaptive setting is advertised |
| Hardware register | `IntrMitigate` (0xe2), 16 bits: RX frames in bits 3:0, RX timer in bits 7:4, TX frames in bits 11:8, TX timer in bits 15:12 |
| Frame limit | A field value of `n` means `4n` frames, so 0 to 60 frames in steps of 4 |
| Timer unit | The timer field is 0 to 15 units; the unit is chosen by link speed and the two `INTT` bits in `CPlusCmd`, and is shared by RX and TX. For 8168-family chips at 1000 Mbit/s the unit can be 5, 40, 80 or 160 µs |
| Start-up | `rtl_hw_start_8168()` and `rtl_hw_start_8169()` write `IntrMitigate = 0`, so coalescing is off after every hardware start |
| RTL8125 (2.5G) | `rtl_get_coalesce()` and `rtl_set_coalesce()` return `-EOPNOTSUPP`; those chips are not covered |
| Receive path | One RX queue and one NAPI context; `rtl8169_poll()` calls `rtl_tx()` and `rtl_rx()`, then re-enables interrupts after `napi_complete_done()` |
| Existing helper | The DIM library in `lib/dim/`, used for example by `drivers/net/virtio_net.c`; `r8169` does not use it |

## 3. Goals and non-goals

Goals:

1. `ethtool -C <dev> adaptive-rx on` turns on adaptive receive moderation, and `off` returns to the static settings.
2. At light load, latency stays close to the no-moderation case. At heavy load, the interrupt rate and CPU use fall compared with no moderation.
3. With adaptive mode off, behaviour is identical to the stock driver.
4. The change is small and reviewable, in the form of a kernel patch series.

Non-goals:

- RTL8125 and other chips that reject coalescing in the current driver.
- Adaptive transmit moderation. Only the RX fields of `IntrMitigate` are touched.
- Changes to the NAPI budget, ring sizes or any other part of the data path.
- Other Realtek drivers.

## 4. Design

### 4.1 Integration with the DIM library

Following the pattern in `virtio_net.c`:

- Add `select DIMLIB` to the `R8169` entry in the Kconfig.
- Add a `struct dim` and a few fields to `struct rtl8169_private`: an adaptive flag, local RX counters, and a poll counter.
- In `rtl8169_poll()`, after `rtl_rx()`, build a sample with `dim_update_sample()` and call `net_dim()` when the adaptive flag is set.
- When DIM decides to change level, it schedules the driver's work function. The work function reads the new level, converts it to a timer value, writes `IntrMitigate`, and sets `dim->state = DIM_START_MEASURE`.

Existing receive statistics are per-CPU (`dev_sw_netstats_rx_add()`), which are awkward to read from the poll function. The driver therefore keeps its own packet and byte counters, updated only in the NAPI context. Because there is one NAPI context, no lock is needed for them.

### 4.2 Hardware mapping

DIM moves a level index between 0 and 4 (`NET_DIM_PARAMS_NUM_PROFILES`). The driver supplies its own five-level table, because the library's default values do not fit this hardware. The first version uses timer-only levels (frame limit 0). That keeps the work function simple, but the static path also sets or clears the `PktCntrDisable` bit in `CPlusCmd` depending on whether frame limits are used (on 8168evl and newer), so I need to check whether timer-only operation depends on that bit before I rely on it. (Checked in Phase 0: the stock timer-only path runs with the bit set, and the registers confirm it; see `results/phase_0_environment_and_baseline.md`.)

The table has to fit a 4-bit timer field at one chosen unit. The unit also has to suit both ends of the range:

| Unit (1000 Mbit/s, 8168 family) | Largest timer | Step |
|---|---|---|
| 5 µs | 75 µs | 5 µs |
| 40 µs | 600 µs | 40 µs |

A full-rate 1500-byte stream is about 81,000 packets per second. A 75 µs timer allows at most about 13,000 interrupts per second, and a 600 µs timer about 1,700. The right table will be chosen from measurement. Level 0 is always "no moderation" (timer 0).

### 4.3 Concurrency

`ethtool` operations run under the RTNL lock. The reset task (`rtl_task()` and `rtl_reset_work()`) does not take it, and as far as I can tell from reading the code, both paths write `CPlusCmd` through the shared `tp->cp_cmd` field with no other lock. The DIM work function would be a third writer, so:

- the work function writes only `IntrMitigate` and never touches `cp_cmd`;
- the unit (the `INTT` bits) is chosen once, on the ethtool path when adaptive mode is turned on, and again from a link-change hook;
- the work is cancelled with `net_dim_work_cancel()` when adaptive mode is turned off or the device is brought down.

Because the work function must not take RTNL while the close path holds it and waits for the work, a plain `cancel_work_sync()` under RTNL could deadlock. The exact locking is something to settle by reading the code in Phase 0 and to check with lockdep, which is enabled on my kernel.

### 4.4 State that hardware loses

`IntrMitigate` is zeroed by every hardware start (open, reset after a transmit timeout, resume). The current level must therefore be written again at the end of the hardware start path when adaptive mode is on. A link-speed change alters the timer unit, so the level is also converted again then.

### 4.5 ethtool interface

- Add `ETHTOOL_COALESCE_USE_ADAPTIVE_RX` to `supported_coalesce_params`.
- `rtl_get_coalesce()` reports `use_adaptive_rx_coalesce` from the flag. Because it reads the register back, `ethtool -c` shows the live value, which gives a free view of the level while DIM is running.
- `rtl_set_coalesce()` turns the flag on or off. Turning it off restores the last static settings.

## 5. Test and measurement plan

### 5.1 Setup

A second machine on the same network, or on a direct cable if the second machine has an Ethernet port, acts as the traffic source and sink. Tools: `iperf3` (throughput and UDP loss), `netperf` or `sockperf` (request-response latency), `ping`, `mpstat` (CPU), and `/proc/interrupts` and `/proc/softirqs` (interrupt and receive-softirq rates). All runs use the same kernel build, because comparisons between builds would not be fair.

### 5.2 Configurations compared

| Name | Setting |
|---|---|
| Stock | Unmodified driver, defaults (no coalescing) |
| Static low | Modified driver, adaptive off, a small fixed `rx-usecs` |
| Static high | Modified driver, adaptive off, a large fixed `rx-usecs` |
| Adaptive | Modified driver, `adaptive-rx on` |

The two static values come from the profile table once it exists.

### 5.3 Workloads

| Workload | Measures |
|---|---|
| Idle: no traffic | Interrupt rate with nothing to receive |
| Request-response: small messages (`netperf` TCP_RR; `ping` cannot be used, the test network drops ICMP) | Latency and interrupts per transaction |
| Small-packet UDP at a high packet rate, and several parallel TCP_RR streams (added after the Phase 0 baseline) | Interrupt rate, NET_RX rate and the CPU that takes the interrupts, under a heavier receive load |
| Bulk TCP stream | Throughput, CPU, interrupts per second |
| UDP at several fixed rates, including overload | Packet loss and CPU |
| Stepped load: idle, bulk, idle, repeated | How fast the level follows the load, using `ethtool -c` sampled several times a second |

Every cell is repeated several times, and the report gives the mean and the spread, not a single number.

### 5.4 Functional and robustness tests

| # | Test | Expected |
|---|------|----------|
| F1 | `ethtool -C adaptive-rx on` and `off`, and `ethtool -c` after each | The flag is reported correctly; off restores the previous static values |
| F2 | Invalid combinations, and use on a chip without support | A proper error, as the stock driver gives |
| F3 | Adaptive off compared with stock | Same `ethtool -c` output and same results within noise |
| F4 | `ip link set <dev> down` then `up` under adaptive mode | The level is written again after the hardware start |
| F5 | Link speed change (for example 1000 to 100 Mbit/s), if the link partner allows it | The timer in microseconds stays sensible after the change |
| F6 | Suspend and resume (s2idle), if supported | Adaptive mode still works afterwards |
| F7 | Stress: traffic running while a loop toggles adaptive mode and the link state, and the module is reloaded 20 times | No lockdep warning, no oops, no `WARN` |
| F8 | `scripts/checkpatch.pl --strict`, `sparse`, `make W=1` | No new warnings |

### 5.5 Success criteria

The result is reported as it comes out. A good result is lower interrupt rate and CPU use under bulk load, with no meaningful latency loss at light load, compared with no moderation. If the measurements show little or no benefit, the report says so and explains why, which is an acceptable outcome for the project.

## 6. Open points to verify before coding

Answered in Phase 0 except the second machine setup details; see `docs/results/phase_0_environment_and_baseline.md`. The original list follows.

Commands to run on the machine (as root where needed):

- `dmesg | grep r8169`, `ethtool -i <dev>` and `lspci -nn -s 03:00.0`: the exact chip variant. This decides whether coalescing is supported and which timer-unit table applies.
- `ethtool -c <dev>`: the current coalescing settings. Then try `ethtool -C <dev> rx-usecs 50` and read it back, to confirm the hardware accepts static settings on this chip.
- `ethtool <dev>`: link speed.
- `grep -E 'CONFIG_DIMLIB|CONFIG_R8169|CONFIG_LOCKDEP' /usr/src/linux-7.2.15/.config`: whether the DIM library is built, and whether `r8169` is a module.
- A backup copy of the installed stock `r8169` module, so it can always be loaded again.
- Whether a second machine with `iperf3` and `netperf` is available.

Open design choices: the five-level table and the timer unit; whether a frame limit is needed at all, and whether timer-only operation needs `PktCntrDisable` set; how to take care of the locking in section 4.3.

## 7. Risks and limits

- The NIC is my machine's only network connection. A bad module could cut it off. The stock module is kept as a backup, and I will work at the console or over a phone tether, not over a network session.
- NAPI already limits the interrupt rate under load, so the gain from hardware moderation may be smaller than expected on a fast CPU. The plan measures this and does not assume it.
- The hardware allows only coarse settings (a 4-bit timer and a shared unit), so the five levels are a rough fit to what DIM expects.
- Coalescing is lost at every hardware start, which makes the re-apply step in 4.4 essential.
- The change depends on the chip variant of this machine. Other variants of the family are not tested.
- The change is not written for upstream submission and no maintainer has reviewed it.

## 8. Schedule

The phases are in order. Fit them to the deadline.

1. Phase 0: environment checks (section 6), second machine, baseline measurements for the stock driver.
2. Phase 1: Kconfig, structure fields and the ethtool plumbing; no behaviour change yet.
3. Phase 2: counters, DIM sampling, work function and the profile table.
4. Phase 3: re-apply after hardware start and link change, cancel on down, locking review.
5. Phase 4: full measurement matrix and tuning of the table.
6. Phase 5: report and demo.

## 9. Deliverables

- A patch series against v7.2.15 produced with `git format-patch`.
- Test and measurement scripts, each starting with the SPDX line.
- A report: the design, the hardware limits, the measurements with graphs, and the conclusion, including any negative result.
- A demo on the real machine: the stepped load with `ethtool -c` showing the level change.
- Raw logs from the baseline and final runs.
