# r8169-adaptive-rx-dim

Adaptive receive interrupt moderation for the Linux `r8169` driver (Realtek RTL8111/8168 Gigabit Ethernet), built on the kernel's DIM library and switched with `ethtool -C <dev> adaptive-rx on|off`.

Coursework project for Advanced Operating Systems (CS G623), BITS Pilani Goa. Target kernel: Linux 7.2.15.

> **Status:** Phase 0 (environment and baseline) and Phase 1 (plumbing: Kconfig, state and the ethtool flag) are done. The adaptive behaviour itself (Phase 2 onwards) is not written yet, so everything below under "Planned behaviour" describes the intended result, not a finished feature. Phase results are in [`docs/results/`](docs/results/).

## Why

The RTL8111/8168 can hold back receive interrupts in hardware so that one interrupt covers several packets. Today the driver only lets the user set that delay by hand with `ethtool -C`, and it starts with the delay switched off. Nothing adjusts it as traffic changes.

This project adds an adaptive mode: little or no delay when the link is quiet (low latency), more delay when it is busy (fewer interrupts, less CPU). The kernel already has a library for this, DIM (`include/linux/dim.h`), used by drivers such as `virtio_net`. `r8169` does not use it yet.

## Planned behaviour

- `ethtool -C <dev> adaptive-rx on` turns on adaptive receive moderation. `off` returns to the static settings.
- With adaptive mode off, behaviour is identical to the stock driver.
- DIM picks one of five levels. The driver turns the level into a timer value and writes it to the `IntrMitigate` register (RX timer field only).
- The first version uses timer-only levels (frame limit 0) and a driver-supplied five-level table, because the library's default values do not fit this hardware's 4-bit fields.
- `ethtool -c <dev>` reads the register back, so it shows the live level while DIM runs.
- RX only. The TX fields of `IntrMitigate` are not touched.

## Design in short

| Piece | Plan |
|---|---|
| Kconfig | `select DIMLIB` on the `R8169` entry |
| State | `struct dim`, an adaptive flag, and driver-owned RX packet and byte counters in `struct rtl8169_private` |
| Sampling | `rtl8169_poll()` builds a sample after `rtl_rx()` and calls `net_dim()` when adaptive mode is on |
| Applying a level | The DIM work function writes `IntrMitigate` only, never `CPlusCmd`, so it is not a third writer next to the ethtool and reset paths |
| Timer unit | Chosen on the ethtool path and again on a link change |
| After a hardware start | The current level is written again, because the start path zeroes `IntrMitigate` |
| Teardown | `net_dim_work_cancel()` when adaptive mode is turned off or the device goes down, with the locking checked under lockdep |

The full design, including open choices such as the level table and whether timer-only operation needs `PktCntrDisable`, is in [`docs/plan.md`](docs/plan.md). Project context and the checklist of things already verified in the source are in [`docs/handoff.md`](docs/handoff.md).

## Baseline findings so far

Measured on the target machine (RTL8168h at 1 Gbit/s, one peer, 5 runs of 20 seconds per cell; tables in [`docs/results/phase_0_environment_and_baseline.md`](docs/results/phase_0_environment_and_baseline.md)):

- The Phase 1 module with adaptive off matches the stock module to about 1.3% in throughput, latency and interrupt figures.
- Bulk TCP at 941 Mbit/s takes about 2 interrupts per second with the stock driver, so there is almost nothing for moderation to remove.
- Request-response takes 2 interrupts per transaction in every configuration, and a static timer only adds latency (+42 microseconds for 50, +187 for 200). The adaptive mode has to stay at its lowest level there.
- UDP at fixed rates shows fewer NET_RX softirqs with a timer (for example -17% at 600 Mbit/s with 50 microseconds) and no packet loss in either case.
- A small or negative gain from adaptive moderation is a likely outcome on this link, and the project reports whatever it finds.

## Scope and limits

- Chips that the driver already treats as coalescing-capable. RTL8125 (2.5G) chips return `-EOPNOTSUPP` from the coalescing functions and are out of scope.
- The hardware timer is 4 bits wide and its unit is shared by RX and TX, so five levels are a rough fit.
- NAPI already limits the interrupt rate under load, so the gain on a fast CPU may be small. The project measures this and reports whatever comes out, including a small or negative result.
- Results depend on the chip variant of the test machine and are not generalised to others.
- Not written for upstream submission, and no maintainer has reviewed it.

## Measurement plan

Four configurations are compared on the same kernel build: stock driver, modified driver with a low static `rx-usecs`, modified driver with a high static `rx-usecs`, and adaptive mode.

| Workload | Measures |
|---|---|
| Steady `ping` at light load | Latency |
| Request-response, small messages | Latency, interrupts per transaction |
| Bulk TCP stream | Throughput, CPU, interrupts per second |
| UDP at fixed rates including overload | Packet loss, CPU |
| Stepped load (idle, bulk, idle, repeated) | How fast the level follows the load, via `ethtool -c` sampled several times a second |

Tools: `iperf3`, `netperf` or `sockperf`, `ping`, `mpstat`, `/proc/interrupts`, `/proc/softirqs`. Each cell is repeated several times and reported as mean and spread.

Functional and robustness tests cover on/off toggling, invalid settings, adaptive-off parity with stock, interface down/up, link speed change, suspend/resume, a stress loop with module reloads, and `checkpatch.pl --strict`, `sparse` and `make W=1`.

## Building and testing (proposed, not yet run)

These steps are a proposal and the paths are assumptions for the author's machine.

```bash
cd /usr/src/linux-7.2.15
grep -E 'CONFIG_DIMLIB|CONFIG_R8169' .config
make modules_prepare
make M=drivers/net/ethernet/realtek modules
modinfo -F vermagic drivers/net/ethernet/realtek/r8169.ko   # must match `uname -r`
```

Back up the installed stock module first, then:

```bash
sudo rmmod r8169 && sudo insmod drivers/net/ethernet/realtek/r8169.ko
ethtool -c <dev>
sudo ethtool -C <dev> adaptive-rx on
```

If `CONFIG_DIMLIB` is off in the running kernel, the new module cannot load until the library is built too.

**Warning:** on the test machine the NIC is the only network connection. Do not test over a network session into the same machine, keep a console or phone tether ready, and always keep a copy of the stock `r8169` module.

## Applying the patches

Patches are produced with `git format-patch` against `v7.2.15` and applied with `git am`. If the kernel tree is a plain tarball rather than a git repository, use:

```bash
patch -p1 < 0001-<name>.patch
```

On Windows, clone or pull on the Linux machine rather than copying files across, since CRLF line endings break `patch`.

## Repository layout (planned)

```
docs/        plan.md, phases.md, handoff.md (context for a new chat), locking.md (Phase 3), final report
docs/results/ one file per phase: phase_<number>_<title>.md
patches/     git format-patch series against v7.2.15
scripts/     rx_bench.sh, read_intrmit.sh, summarize_results.py (each starts with an SPDX line)
results/     raw logs from the baseline and final runs
```

## Plan

Six phases, each ending with something that builds and loads. Full detail (tasks, files, tests, exit criteria, risks) is in [`docs/phases.md`](docs/phases.md).

| Phase | Goal | Output | Done when |
|---|---|---|---|
| 0. Environment and baseline | Answer the open questions (chip variant, link speed, `DIMLIB`, second machine), back up the stock module, measure the stock driver | Updated handoff, baseline logs, repository | Every unknown is recorded and the unmodified module builds with a matching vermagic |
| 1. Plumbing | `select DIMLIB`, new struct fields, `adaptive-rx` flag in ethtool, no hardware effect | Patches 0001 and 0002 | The flag is accepted and reported, and the driver behaves exactly like stock |
| 2. Adaptive core | RX counters, DIM sampling in `rtl8169_poll()`, work function writing `IntrMitigate`, first level table | Patch 0003 | The level rises under bulk load and falls at idle, with no warnings |
| 3. Robustness | Re-apply after hardware start and link change, cancel on down, locking review under lockdep | Patch 0004, `docs/locking.md` | Down/up, speed change, resume and a stress loop pass with no lockdep report or oops |
| 4. Measurement and tuning | Four configurations across all workloads, repeated runs, table tuned from data | Raw logs, graphs, patch 0005 if the table changed | Every cell has repeated runs and the conclusion matches the numbers |
| 5. Report and demo | Final patch series, report, demo on the real machine | `patches/`, report, demo script | A clean tree plus the patches builds, loads and runs the demo |

Results of each phase are recorded in `docs/results/phase_<number>_<title>.md` (see [phase 0](docs/results/phase_0_environment_and_baseline.md) and [phase 1](docs/results/phase_1_plumbing.md)). Dates are left open until the course deadline is known; a tracker table is at the end of `docs/phases.md`.

## Conventions

- Branches: `Dhruv_Patel/<feature or fix name>`, merged branches are kept.
- Commits and patches: author is Dhruv Rakeshbhai Patel, with a `Co-authored-by: Claude <noreply@anthropic.com>` trailer.
- New source files start with `// SPDX-License-Identifier: GPL-2.0-only`. Python and shell scripts use `# SPDX-License-Identifier: GPL-2.0-only` as the first line after the shebang. The existing driver file keeps its own header.

## License

GPL-2.0-only, matching the Linux kernel. See `LICENSES/GPL-2.0` once added.

## Author

Dhruv Rakeshbhai Patel, M.E. Computer Science, BITS Pilani Goa.
