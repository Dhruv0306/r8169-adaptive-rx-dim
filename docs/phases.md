# Phase-by-phase plan

Detailed plan for adaptive receive interrupt moderation in `r8169` on Linux 7.2.15. The design is in [`plan.md`](plan.md) and the project context in [`handoff.md`](handoff.md). This page turns them into ordered work: what to do in each phase, which files change, what is delivered, and when a phase counts as done.

Nothing here has been built or run yet. Commands are proposals and paths are assumptions for the author's machine.

## How the phases fit together

| Phase | Name | Output | Changes driver behaviour? |
|---|---|---|---|
| 0 | Environment and baseline | Answers to the open questions, baseline logs, repository | No |
| 1 | Plumbing | Kconfig, struct fields, ethtool flag | No |
| 2 | Adaptive core | Counters, DIM sampling, work function, level table | Yes, only with adaptive on |
| 3 | Robustness | Re-apply after hardware start and link change, cancel on down, locking | Yes, only with adaptive on |
| 4 | Measurement and tuning | Full matrix, tuned table, graphs | Table values only |
| 5 | Report and demo | Report, demo script, final patch series | No |

Each phase ends with something that builds and loads, so a problem can always be traced to the last phase that was added.

## Working rules for every phase

- Branch name: `Dhruv_Patel/<feature or fix name>`, for example `Dhruv_Patel/r8169-adaptive-plumbing`. Merged branches are kept.
- Commit and patch author: Dhruv Rakeshbhai Patel <dpatel5469@gmail.com>, with the trailer `Co-authored-by: Claude <noreply@anthropic.com>`. Claude is never the author.
- New `.c` or `.h` files start with `// SPDX-License-Identifier: GPL-2.0-only`. Python and shell scripts use `# SPDX-License-Identifier: GPL-2.0-only` as the first line after the shebang. The existing `r8169_main.c` keeps its own header.
- Patches are produced with `git format-patch` against `v7.2.15` and applied to the kernel tarball tree with `patch -p1`.
- Before any module load: the stock `r8169` module is backed up, and a console or phone tether is ready, because the NIC is the machine's only network connection.
- Every phase ends with `scripts/checkpatch.pl --strict` on the new patches, and a clean `make W=1` build of the module.
- At the end of each phase, write its results to `docs/results/phase_<number>_<title>.md`: what was done, the commands and outputs, the test results, deviations from the plan, gaps and open items. The files are `phase_0_environment_and_baseline.md`, `phase_1_plumbing.md`, `phase_2_adaptive_core.md`, `phase_3_robustness.md`, `phase_4_measurement_and_tuning.md` and `phase_5_report_and_demo.md`. A phase is not done until its results file exists.
- `docs/handoff.md` is only for moving context into a new chat. It is not a results log. Phase results go in `docs/results/`, and the handoff points to them.

---

## Phase 0: Environment checks and baseline

**Goal.** Replace every "not yet known" about the machine with a recorded fact, and record what the unmodified driver does on this machine.

**Tasks**

1. Identify the chip and link:
   - `lspci -nn -s 03:00.0`, `ethtool -i <dev>`, `ethtool <dev>`, and `su -` then `dmesg | grep r8169`.
   - Note the exact variant and the link speed. The variant decides whether coalescing is supported and which timer-unit table applies.
2. Check that static coalescing works on this chip:
   - `ethtool -c <dev>` for the current values.
   - `sudo ethtool -C <dev> rx-usecs 50`, then read it back. Put the value back afterwards.
3. Check the kernel configuration:
   - `grep -E 'CONFIG_DIMLIB|CONFIG_R8169|CONFIG_LOCKDEP' /usr/src/linux-7.2.15/.config`.
   - Note whether `r8169` is a module and whether `DIMLIB` is `y`, `m` or off. If it is off, decide now how to handle it (build `dimlib.ko`, or rebuild the kernel).
4. Make the safety backup: copy the installed stock module from `/lib/modules/$(uname -r)/kernel/drivers/net/ethernet/realtek/` (it may be compressed) to a safe place, and write down how to restore it.
5. Check the build path once with an unmodified tree: `make modules_prepare`, `make M=drivers/net/ethernet/realtek modules`, and `modinfo -F vermagic` against `uname -r`. Load nothing yet.
6. Arrange the second machine: how it connects, which `iperf3`, `netperf` or `sockperf` versions it has, and whether the link can be forced to 100 Mbit/s for the speed-change test.
7. Create the repository layout and the first branch. Add the measurement scripts as stubs, each with the SPDX line.
8. Take the baseline for the stock driver (the measurement matrix in `plan.md` section 5, stock row only). Keep raw logs in `results/baseline/`.
9. Read `rtl_set_coalesce()` and the hardware start code again for the open question: does timer-only operation depend on `PktCntrDisable`? Write down the answer with line numbers.

**Files touched.** None in the kernel. New files: measurement scripts and `results/baseline/`.

**Deliverables.** `docs/results/phase_0_environment_and_baseline.md` with all the machine unknowns answered, baseline logs, the stock-module backup path, the repository with a first branch.

**Done when.** The chip variant, link speed, `DIMLIB` state and second-machine setup are recorded, a baseline exists for every workload, and the unmodified module builds with a matching vermagic.

**Risks.** The chip may reject static coalescing, which would force a change of scope. Stop and discuss with the professor if that happens. `DIMLIB` being off means a longer setup path.

---

## Phase 1: Plumbing, no behaviour change

**Goal.** Add the build and ethtool hooks so the driver knows about adaptive mode, while the stock behaviour is untouched.

**Tasks**

1. `drivers/net/ethernet/realtek/Kconfig`: add `select DIMLIB` to the `R8169` entry.
2. `struct rtl8169_private`: add a `struct dim`, an adaptive flag, driver-owned RX packet and byte counters, and the current level. Nothing reads them yet.
3. ethtool:
   - Add `ETHTOOL_COALESCE_USE_ADAPTIVE_RX` to `supported_coalesce_params`.
   - `rtl_get_coalesce()` reports `use_adaptive_rx_coalesce` from the flag.
   - `rtl_set_coalesce()` stores the flag. For now the flag has no effect on the hardware.
4. Keep the RTL8125 behaviour unchanged (`-EOPNOTSUPP`).

**Files touched.** `Kconfig`, `r8169_main.c`.

**Tests.** F1 (flag is reported on and off), F2 (invalid combinations and unsupported chips behave as before), F3 (adaptive off matches stock output), F8 (checkpatch, sparse, `W=1`).

**Deliverables.** Patch 0001 (Kconfig and fields) and patch 0002 (ethtool plumbing), each building and loading on its own.

**Done when.** `ethtool -C <dev> adaptive-rx on` is accepted and reported by `ethtool -c`, `off` returns to the previous output, and the module loads and passes traffic exactly like stock.

**Risks.** Getting `DIMLIB` into the build of the running kernel (see Phase 0). Keep the two patches small so a bisect is easy.

---

## Phase 2: Adaptive core

**Goal.** Make adaptive mode actually move the hardware timer with the load.

**Tasks**

1. Counters: increment the driver-owned RX packet and byte counters in the NAPI context only, in or next to `rtl_rx()`. One NAPI context means no lock is needed for them.
2. Sampling: in `rtl8169_poll()`, after `rtl_rx()`, when the adaptive flag is set, build a sample with `dim_update_sample()` and call `net_dim()`. Follow `virtio_net.c` (`virtnet_rx_dim_update()` and `virtnet_rx_dim_work()`) as the reference.
3. Work function: read the level DIM chose, look it up in the driver's five-level table, convert to a timer value for the current unit, write only `IntrMitigate` (RX timer field, frame limit 0), then set `dim->state = DIM_START_MEASURE`.
4. Level table: first draft with level 0 as timer 0 (no moderation) and four increasing timers. Pick the timer unit from the options in `plan.md` section 4.2. This is a starting guess that Phase 4 will tune.
5. Decide, from the Phase 0 reading, whether timer-only operation needs `PktCntrDisable`, and implement the answer.
6. Add a debug aid that is cheap to remove later (for example a trace of level changes under `CONFIG_DEBUG_FS`, which is enabled on this kernel).

**Files touched.** `r8169_main.c`.

**Tests.** Short manual checks first: with `adaptive-rx on`, run `ping` at light load and a bulk `iperf3`, and watch `ethtool -c` change with the load. Then F1 and F3 again, and F8.

**Deliverables.** Patch 0003 (counters, sampling, work function, table). `docs/results/phase_2_adaptive_core.md` with the table and unit chosen and why.

**Done when.** The level visibly rises under bulk load and falls back at idle, with no kernel warnings, and adaptive-off behaviour is unchanged.

**Risks.**
- The work function and the ethtool and reset paths all touch coalescing state. The rule is that the work function writes only `IntrMitigate` and never `cp_cmd`.
- A badly chosen unit can make the range too coarse. Expect to revise the table in Phase 4.

---

## Phase 3: Robustness and locking

**Goal.** Make adaptive mode survive everything the hardware and the stack do to it.

**Tasks**

1. Re-apply the level at the end of the hardware start path, because `rtl_hw_start_8168()` and `rtl_hw_start_8169()` write `IntrMitigate = 0`. This covers open, reset after a transmit timeout, and resume.
2. Link change: re-choose the timer unit and convert the current level again, since a speed change alters the unit.
3. Teardown: call `net_dim_work_cancel()` when adaptive mode is turned off and when the device is brought down. A plain `cancel_work_sync()` under RTNL can deadlock if the work function needs RTNL, so settle the exact locking by reading the code and checking with lockdep.
4. Turning adaptive off restores the last static settings.
5. Review the reset task (`rtl_task()`, `rtl_reset_work()`), which does not take RTNL, against the ethtool path and the work function, and write the result down in `docs/locking.md`.

**Files touched.** `r8169_main.c`, new `docs/locking.md`.

**Tests.** F4 (down then up under adaptive mode), F5 (speed change), F6 (suspend and resume, if supported), F7 (stress loop: traffic running while adaptive mode and link state toggle, and 20 module reloads), F8. Run all with lockdep enabled and read `dmesg` (`su -`) after each.

**Deliverables.** Patch 0004 (re-apply, link change, cancel) and `docs/locking.md`.

**Done when.** F4 to F7 pass with no lockdep report, no oops and no `WARN`, and the level is correct after every hardware restart.

**Risks.** Deadlocks and races are the main risk of the project. Do this phase slowly, and keep the console ready, since a bad state can take the only network link down.

---

## Phase 4: Measurement and tuning

**Goal.** Measure all four configurations on all workloads and tune the level table from data.

**Tasks**

1. Pick the two static values (low and high `rx-usecs`) from the current table.
2. Run the full matrix from `plan.md` section 5.3 for Stock, Static low, Static high and Adaptive: idle `ping`, request-response, bulk TCP, UDP at several rates including overload, and the stepped load.
3. Repeat each cell several times. Record mean and spread, not single numbers. Collect `mpstat`, `/proc/interrupts` and `/proc/softirqs` per run.
4. For the stepped load, sample `ethtool -c` several times a second and plot level against time to show how fast the level follows the load.
5. Tune the table and the unit from the results. After each change, rerun only the affected workloads, and keep the raw logs of every table version.
6. Write down any result honestly, including a small or negative gain. NAPI already reduces interrupts under load, so a modest result is a valid outcome.

**Files touched.** The level table in `r8169_main.c`, scripts, `results/`.

**Deliverables.** Raw logs in `results/`, graphs, a results table, patch 0005 (tuned table) if the table changed.

**Done when.** Every cell of the matrix has repeated runs, the table is frozen, and the conclusion (benefit, no benefit, or trade-off) is supported by the numbers.

**Risks.** Noise from other load on either machine, and results that depend on this chip variant. Note both in the report and do not generalise.

---

## Phase 5: Report and demo

**Goal.** Package the work so it can be read, reproduced and shown.

**Tasks**

1. Final patch series against `v7.2.15` with `git format-patch`, checked with `checkpatch.pl --strict`, `sparse` and `make W=1`. Test that it applies on a clean tree with `patch -p1`.
2. Report: the design, the hardware limits (4-bit timer, shared unit), the measurements with graphs, the locking notes, and the conclusion including any negative result.
3. Demo script for the real machine: stepped load with `ethtool -c` showing the level change. Rehearse it once from the console, not over the network.
4. Tidy the repository: final README, `docs/` up to date, raw logs from the baseline and final runs in `results/`, merged branches kept.

**Deliverables.** `patches/`, the report, the demo script, raw logs.

**Done when.** A clean tree plus the patches builds and loads, the demo runs end to end, and the report matches the logs.

---

## Patch series plan

| Patch | Content | Phase |
|---|---|---|
| 0001 | Kconfig `select DIMLIB`, new fields in `struct rtl8169_private` | 1 |
| 0002 | ethtool `adaptive-rx` flag, no hardware effect | 1 |
| 0003 | RX counters, DIM sampling, work function, level table | 2 |
| 0004 | Re-apply after hardware start and link change, cancel on down | 3 |
| 0005 | Tuned level table (only if tuning changed it) | 4 |

## Phase tracker

Fill in the dates once the course deadline is known.

| Phase | Planned finish | Actual finish | Notes |
|---|---|---|---|
| 0 | | | |
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
