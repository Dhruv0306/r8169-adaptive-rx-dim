# Plan for Phase 4: Measurement and tuning

Status: not started. Depends on Phase 3 (a stable module). High-level summary: [`../phases.md`](../phases.md), Phase 4. Results go in `docs/results/phase_4_measurement_and_tuning.md`, raw logs in `results/`.

Machine tags: **[Claude]** work in the chat, **[PC]** machine under test (root, at the console), **[PEER]** second machine, **[repo]** project repository.

## 1. Goal and scope

Measure whether adaptive moderation helps, with the same rigour as the Phase 0 baseline, tune the level table from the data, freeze it, and report the result whatever it is. A small or negative gain is an acceptable outcome (plan.md, section 5.5).

Patch series: 0006, only if tuning changes the table.

## 2. What the Phase 0 baseline already says (so the matrix is aimed well)

- Bulk TCP at 941 Mbit/s: about 2 interrupts per second already. Nothing to reduce there; the aim is only "no regression".
- Request-response: 2 interrupts per transaction in every configuration, and a static timer only adds latency (+42 microseconds for 50, +187 for 200). The adaptive mode has to stay near level 0 here.
- UDP with 1448 byte datagrams: about 2000 interrupts per second regardless of rate (probably iperf3's 1 ms pacing bursts, not confirmed). A timer lowers NET_RX (-17% at 600 Mbit/s with 50 microseconds, -41% with 200) at no loss.
- The all-CPU busy figure could not tell the configurations apart. This phase uses the busy and softirq share of the CPU that takes the NIC interrupts (`irq_cpu_busy_pct`, `irq_cpu_softirq_pct`).
- The test network drops ICMP; the peer is on the same LAN. Governor was `powersave`.

Because the baseline workloads leave little to win, this phase first adds workloads that load the receive path harder.

## 3. Design of the measurement

### 3.1 Configurations

| Label | Setting |
|---|---|
| `stock` | Installed stock module (rerun with the updated script, so it has the per-CPU columns) |
| `off` | Final module, adaptive off, no static timer (equivalent to `patched-off`; used for interleaving without module swaps) |
| `static-L1` to `static-L4` | Final module, adaptive off, fixed `rx-usecs` equal to each non-zero table level (40, 80, 200, 400 with the first table) |
| `adaptive` | Final module, `adaptive-rx on` |

### 3.2 Workloads

| Workload | Command shape (peer sends to the PC) | Why |
|---|---|---|
| `idle` | no traffic, 20 s | idle interrupt rate |
| `rr` | `netperf -t TCP_RR -- -r 64,64` | latency and interrupts per transaction |
| `rrp` (new) | 8 parallel `netperf` TCP_RR instances | more events per second with many flows, closed loop |
| `tcp` | `iperf3 -R` | line-rate bulk, no-regression check |
| `udp` | `iperf3 -u -R -b 100M/300M/600M/900M` | open loop, large packets |
| `udps` (new) | `iperf3 -u -R -l 100 -b <rate>` at several rates | high packet rate with small packets, the case most likely to show a gain. Rates calibrated first (3.3) |
| stepped load (new) | idle 10 s, bulk UDP 10 s, idle 10 s, repeated, with the level sampled at about 5 Hz | how quickly the level follows the load; the demo |

### 3.3 Calibration (first measurement session)

Find the offered rates for `udps` where the stock driver is under real load: raise `-b` in steps (20M, 50M, 100M, 200M, 300M) and record per step: packets per second, `irq_cpu_busy_pct`, `irq_cpu_softirq_pct` and loss. Choose three or four rates from "visible load" to "just before loss". Record the choice and the data.

### 3.4 Method

- Interleave configurations in rounds (for example `off, static-L2, adaptive, off, static-L2, adaptive`, 3 runs per workload per visit, 4 rounds) so that time of day and peer state do not line up with one configuration. Stock is measured at the start and the end of the session.
- At least 10 runs per cell for the final comparison; 5 for exploratory runs. Report mean, standard deviation and the number of runs; use the spread to decide what counts as a difference (a difference below one standard deviation is not reported as a gain).
- Fix the CPU governor for the session (record it) and keep other load off both machines.
- Never change settings inside a labelled run.

### 3.5 Tuning rule

Objective, in order: (1) `rr` and `rrp` transactions per second and latency within 5% of `off`; (2) no throughput or loss regression anywhere; (3) lower interrupt or NET_RX rate and lower `irq_cpu_softirq_pct` for `udp` and `udps`. Change one thing at a time (a level value, the number of levels in use, or the top cap), rerun only the affected workloads, keep every table version and its raw logs, and stop after at most three tuning rounds. Freeze the table, then run the full matrix once on the frozen build.

## 4. Work steps

1. **[Claude] Extend `scripts/rx_bench.sh`** with `rrp` and `udps` workloads (and a `-l`-style option for the datagram size), and write `scripts/stepped_load.sh` and `scripts/sample_level.sh` (the latter exists from Phase 2), plus `scripts/run_matrix.sh` that does the interleaving of 3.4. Test locally; deliver as plain files or a repo-update patch.
2. **[PEER] and [PC] Prepare.** Same preparation as Phase 0 (servers, firewall, address). Load the final signed module. Record the peer's kernel and NIC in the setup notes.
3. **[PC] Calibration run** (3.3) and **[Claude]** picks the rates from the CSV.
4. **[PC] Exploratory matrix** with 5 runs per cell: `bash scripts/run_matrix.sh` (arguments defined in step 1). Paste or push the results; **[Claude]** summarises with `scripts/summarize_results.py`.
5. **[Claude] and [PC] Tuning rounds** (3.5). Each round: Claude proposes a table change as a patch (0006 candidates), the PC rebuilds and reruns the affected cells.
6. **[PC] Final matrix** on the frozen build: 10 runs per cell, interleaved, with `stock` at both ends.
7. **[PC] Stepped-load run** with the sampler for the demo and the figure: `bash scripts/stepped_load.sh -p $PEER` (at the console).
8. **[Claude] Graphs and tables.** Generate the figures from the CSV files (script `scripts/plot_results.py`, matplotlib): interrupts per second and softirq share versus offered load for each configuration; request-response latency and transactions per second; the level trace of the stepped load. Write the results file.

## 5. Tests and checks in this phase

| Check | How | Expected |
|---|---|---|
| Parity of `off` with `stock` after the final build | Compare in the final matrix | Within noise (as in Phase 0) |
| Raw data integrity | `grep -c ',ok,' results/<dir>/*/summary.csv` equals the number of runs; no `fail(`; no `parse_error` | All runs ok |
| Level trace sanity | Stepped load plot | Level rises within a few hundred milliseconds of the load starting and returns to 0 after it stops (idle decay) |
| Repeatability | One cell run twice on different days if time allows | Within the standard deviation |

## 6. Acceptance criteria

- Every cell of the matrix has at least 10 runs for the final comparison (5 for exploratory ones), with mean, spread and run count, and all raw logs are in the repository.
- The level table is frozen, with every earlier version and its data kept, and the final build was measured as it is reported.
- The conclusion is stated as the data gives it: benefit, no benefit or trade-off, with the numbers, the workloads where it holds and the limits (one chip variant, one peer, one link speed).
- Patch 0006 exists if the table changed.

## 7. Risks and fallbacks

| Risk | Fallback |
|---|---|
| No workload shows a difference (the likely case for bulk TCP) | Report it; the small-packet and parallel workloads are the ones that can show a gain, and the stepped-load figure still shows the mechanism |
| Noise swamps small effects (the Phase 0 CPU figure did) | Use the per-CPU columns, more runs, longer runs (60 s), and interleaving |
| The peer limits the offered load (Wi-Fi, slow NIC) | Record the peer's limits; scale the rates; mention it in the limitations |
| A tuning round takes too long | Stop at three rounds; the first table is acceptable if it passes the tuning rule |
| The PC loses its network during module swaps | Use `off` for interleaving and swap modules only for the `stock` runs at the two ends |

## 8. Results file outline (`docs/results/phase_4_measurement_and_tuning.md`)

Status and dates; configurations and workloads actually used; calibration data and the chosen rates; the exploratory and final tables (from `summarize_results.py`); the tuning log (table versions, what changed, what moved); the frozen table with the reason for each value; figures; findings and conclusion; limitations; the list of raw-data folders.
