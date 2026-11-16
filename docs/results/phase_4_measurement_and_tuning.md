# Phase 4: Measurement and tuning, results

Status: in progress (started 2026-11-16). Calibration, the exploratory matrix, the level traces and the CPU check are done; the table is kept as it is (section 5); the final matrix on the frozen build, the stepped-load run and the figures are next. Plan: [`../plans/plan-4-measurement-and-tuning.md`](../plans/plan-4-measurement-and-tuning.md), runbook in its section 9.

## 1. Work done so far

| Item | What |
|---|---|
| `scripts/rx_bench.sh` | New workloads `rrp` (8 parallel `netperf` TCP_RR, results summed) and `udps` (iperf3 UDP with small datagrams, 100 bytes by default, for a high packet rate); options `-s`, `-r`, `-P`, `-O` (run-number offset for interleaved visits); UDP rows now also record `pps` |
| `scripts/run_matrix.sh` | Interleaved matrix over `off`, `static-L<k>` and `adaptive` with ethtool only (no module swap), reversed order on even rounds, configuration read back after applying and after each visit, optional CPU governor for the session, time estimate |
| `scripts/summarize_results.py` | Knows `rrp` and `udps`, natural label order, and `-r REF` prints a comparison against the reference label where a difference within the larger standard deviation is reported as noise |
| `scripts/stepped_load.sh`, `scripts/sample_level.sh` | Idle, burst, idle cycles with the level sampled at 5 Hz on one clock (`T0`) and burst markers |
| `scripts/dwell_check.sh`, `scripts/level_dwell.py` | Repeated UDP runs with the level trace and the share of time below 200 us, for the 900M question from Phase 2 |
| `scripts/plot_results.py` | Figures for UDP and small-packet UDP, request-response, bulk TCP and the stepped load |

## 2. Configurations and workloads actually used

Session conditions for all runs below: patched module (srcversion `04E8D19E5DCBE28E8305847`) or stock (`A8C76016444D067D3998384`), CPU governor `performance` (the Phase 0 to 3 runs used `powersave`), NIC interrupt pinned to CPU 3, `irqbalance` stopped, 1 Gbit/s link, one peer. Configurations: `stock`, `off` (patched module, adaptive off), `static-L2` (80 us), `static-L4` (400 us), `adaptive` (table 0, 40, 80, 200, 400 us). Workloads: `rr` (1 stream, 64 bytes), `rrp` (8 streams), `tcp` (bulk), `udp` (iperf3, 1448 bytes, 600M and 900M, default pacing) and `udps` (100 byte datagrams, 50M, 100M, 200M, iperf3 pacing timer 100 us). 20 s per run.

Two properties of the measurement matter for reading the numbers:

- iperf3 paces its sending with a 1 ms timer by default, so the packets arrive in bursts and the NIC takes about 2000 interrupts per second at every rate from 25000 to 250000 packets per second. The small-datagram workload therefore uses `--pacing-timer 100` (`-m 100`); section 3.
- This kernel samples `/proc/stat` at the scheduler tick (`CONFIG_IRQ_TIME_ACCOUNTING` is not set). With paced traffic the same load read 0 percent in one run and 86 percent in the next, so the "IRQ CPU busy" and "softirq" percentages are not used for conclusions. The CPU cost is taken from the cpuidle residency of the interrupt CPU ("IRQ CPU non-idle %"), which does not depend on the tick.

## 3. Calibration data and the chosen small-packet rates

Adaptive off, 3 runs per rate, `results/phase4/calibration/`.

| Offered | iperf3 pacing | Received pkt/s | irq/s | NET_RX/s | Loss |
|---|---|---|---|---|---|
| 20M | default (1 ms) | 25,000 | 2002 | 3,200 | 0 |
| 50M | default | 62,500 | 2004 | 3,095 | 0 |
| 100M | default | 125,000 | 2002 | 6,198 | 0.007% |
| 200M | default | 250,003 | 1982 | 21,984 | 0.035% |
| 300M | default | about 266,000 (peer limit) | 17 | 28,632 | 0.23% |
| 50M | 100 us | 62,500 | 19,553 | 39,569 | 0 |
| 100M | 100 us | 125,000 | 16,057 | 37,476 | 0 |
| 150M | 100 us | 187,501 | 9,266 | 36,442 | 0 |
| 200M | 100 us | 250,001 | 3,984 | 31,539 | 0 |

With the default pacing the interrupt rate is set by the sender's bursts, not by the packet rate, and the peer cannot send more than about 266,000 packets per second of 100 byte datagrams (so "300M" is the peer's limit and the receive path is in polling mode, 17 interrupts per second). With the 100 us timer the interrupt rate follows the load and falls as NAPI batches more packets, which is the range where moderation has something to remove. Chosen: 100 byte datagrams, 100 us pacing timer, 50M, 100M and 200M. At 200M some runs of every configuration fall into the polling regime (24 to 43 interrupts per second), so that cell is not used for decisions.

## 4. Exploratory and final tables

### 4.1 Exploratory matrix (`results/phase4/exploratory-1/`, 6 runs per cell, 3 for `stock`)

`adaptive` against `off` (a difference within the larger standard deviation is noise):

| Workload | `adaptive` | `static-L4` (for comparison) |
|---|---|---|
| `rr` | 13,106 against 12,984 trans/s, latency 76.3 against 77.0 us: noise | -87.2% trans/s, +682% latency |
| `rrp` | 68,283 against 70,772 trans/s (-3.5%), latency 117.2 against 113.1 us (+3.6%); NET_RX noise | -77.1% trans/s, +342% latency |
| `tcp` | 941.2 against 941.3 Mbit/s: no difference | no difference |
| `udp` 600M | NET_RX/s -56.9% | -59.5% |
| `udp` 900M | NET_RX/s -15.9%, large spread | -35.7% |
| `udps` 50M / 100M | NET_RX/s -70.5% / -75.8%; irq/s 5,366 (one run stuck at level 0) / 3,238 against 19,825 / 18,512 | -83.8% / -79.3% |
| `udps` 200M | NET_RX/s -15.7% (cell not used for decisions) | -41.3% |

`stock` against `off` is noise in every cell: the patched module with adaptive off behaves like the stock driver. Static timers are not usable for latency traffic: 80 us alone costs 41.9% of `rr` transactions per second.

### 4.2 CPU check (`results/phase4/cpucheck/`, 6 runs per cell)

Share of the time that the interrupt CPU was not in a cpuidle state:

| Cell | `off` | `static-L4` | `adaptive` |
|---|---|---|---|
| `udp` 600M | 26.1 +/- 3.5 | 22.9 +/- 2.7 | 19.3 +/- 2.0 (-26%, better) |
| `udps` 50M | 24.2 +/- 1.7 | 23.1 +/- 0.9 | 22.1 +/- 1.8 (-8.9%, better) |
| `udps` 100M | 37.1 +/- 1.1 | 26.3 +/- 1.4 (-29%) | 25.5 +/- 1.4 (-31%, better) |

### 4.3 Level traces (`results/phase4/dwell/`)

- `rrp`, 3 runs, 637 samples: 93% of the samples at 0 us, 5% at 40 us, 2% at 80 us, none higher. The mean timer is 0.05 * 40 + 0.02 * 80 = 3.6 us, which matches the 4 us rise of the mean latency (113.1 to 117.2 us): the `rrp` cost is the time DIM spends exploring levels 1 and 2.
- `udps` 50M (100 us pacing), 10 runs: nine runs reach about 390 us within the first second and stay there (1.1% of the samples below 200 us); run 1 ramped late (mean 261 us, 31.9% of the samples low). Together with the exploratory run that stayed at level 0 for 20 s, DIM does not always ramp up promptly from a fresh start.
- `udp` 900M, 10 runs: bimodal. Run 1 climbed to the top level (mean 364 us); runs 2, 4 and 9 stayed at level 0 for the whole run (mean 14 to 60 us, 100% low, NET_RX/s 38,283 to 39,685, as with `off`); the other six sat in between (mean 91 to 158 us). Static 400 us reduces NET_RX by 36% here but not the interrupt rate, so the benefit is not visible in the quantities DIM measures (packets, bytes and polls per millisecond); this is a limit of DIM at 900M and not of the table (hypothesis, not tested further).

## 5. Tuning log

| Table version | Levels (us) | What changed | What moved | Raw data |
|---|---|---|---|---|
| v0 (Phase 2 and 3) | 0, 40, 80, 200, 400 | - | exploratory matrix, CPU check and traces in section 4 | `results/phase4/exploratory-1/`, `cpucheck/`, `dwell/` |

Tuning rule of the plan (3.5), checked on v0: (1) `rr` and `rrp` within 5% of `off`: `rr` within noise, `rrp` -3.5% transactions per second and +3.6% latency, inside the limit with a margin of 1.4 points; (2) no throughput or loss regression: none in `tcp`, `udp`, `udps`; (3) lower NET_RX rate and lower interrupt CPU use for `udp` and `udps`: NET_RX/s -57% (`udp` 600M), -82% and -76% (`udps` 50M and 100M), and the interrupt CPU is less busy (4.2).

Decision (2026-11-16): no tuning round. The table passes the rule. The only candidate change, lower values for levels 1 and 2 to shorten the exploration cost in `rrp`, would save at most 2 us of the 4 us, about 1.5% of the transactions per second, which is below what 6 to 12 runs resolve (the standard deviation of `rrp` is 2.2%). The 900M ramp-up behaviour is not a table value and would need a change of the algorithm, which is outside the tuning rule; it is reported as a limitation.

## 6. Frozen table and the reason for each value

Frozen: 0, 40, 80, 200, 400 us (v0), pending the final matrix on this build. Level 0 keeps the latency of `rr` and `rrp`; the top level of 400 us is where the `udps` ramp-up ends and gives the largest NET_RX and CPU saving without a loss; the intermediate levels are what DIM passes through on the way. The measured cost of a static timer for latency traffic (4.1) is why the levels above 0 are only reached by load.

## 7. Figures

To be filled in (`docs/figures/`).

## 8. Findings and conclusion

To be filled in.

## 9. Limitations

One chip variant (RTL8168h), one peer, one link speed (1 Gbit/s); results are not generalised.

## 10. Raw-data folders

To be filled in (`results/phase4/...`).
