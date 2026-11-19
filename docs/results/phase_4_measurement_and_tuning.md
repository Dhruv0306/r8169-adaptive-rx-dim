# Phase 4: Measurement and tuning, results

Status: done (2026-11-16). Calibration, exploratory matrix, level traces, CPU check, the final matrix (12 runs per cell, `stock` at both ends of the session), the stepped-load run and the figures are complete; the first table (0, 40, 80, 200, 400 us) is kept. Plan: [`../plans/plan-4-measurement-and-tuning.md`](../plans/plan-4-measurement-and-tuning.md), runbook in its section 9.

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

The exploratory numbers are kept as recorded. The `rrp` figure below (-3.5%) did not reproduce in the final matrix (4.4: -0.1%, noise), so it counts as run-to-run variation, not as a cost of the algorithm.

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

### 4.4 Final matrix (`results/phase4/final/`, 12 runs per cell)

Frozen build (srcversion `04E8D19E5DCBE28E8305847`), session conditions as in section 2. The configurations were visited in four interleaved rounds (order reversed on even rounds); `stock` was run 6 times before and 6 times after the patched-module runs. Mean +/- standard deviation.

`adaptive` against `off` (a difference within the larger standard deviation is noise):

| Workload | `adaptive` against `off` |
|---|---|
| `rr` | trans/s -0.1%, latency +0.1%, interrupt CPU +2.8%: all noise |
| `rrp` | trans/s -0.1%, latency +0.1%, NET_RX/s -1.6%: noise |
| `tcp` | 941.2 Mbit/s in every configuration; NET_RX/s -0.4%; softirq share by the tick-sampled counters +2.5% (9.4 against 9.2); interrupt-CPU non-idle +2.7%, noise |
| `udp` 600M | NET_RX/s -55.5%, interrupt-CPU non-idle -21.7% (20.3 against 25.9%) |
| `udp` 900M | NET_RX/s -19.8%, interrupt-CPU non-idle -18.2% (25.2 against 30.8%) |
| `udps` 50M | NET_RX/s -82.0%, non-idle -15.5% (22.1 against 26.1%), irq/s 3,119 against 19,876 |
| `udps` 100M | NET_RX/s -76.6%, non-idle -30.9% (25.0 against 36.1%), irq/s 3,288 against 16,871 |
| `udps` 200M | NET_RX/s -18.5%, non-idle -9.6% (45.4 against 50.2%); loss 0.0146% against 0.0037% (noise, one run lost 0.126%) |

`stock` against `off` is noise in every cell (the patched module with adaptive off behaves like the stock driver).

Mean values:

| Cell | `stock` | `off` | `static-L2` | `static-L4` | `adaptive` |
|---|---|---|---|---|---|
| `rr` trans/s | 13,018 +/- 205 | 12,973 +/- 99 | 7,553 +/- 71 | 1,655 +/- 32 | 12,962 +/- 80 |
| `rr` latency (us) | 76.8 +/- 1.2 | 77.1 +/- 0.6 | 132.4 +/- 1.3 | 604.4 +/- 11.7 | 77.1 +/- 0.5 |
| `rrp` trans/s | 69,057 +/- 1,448 | 69,436 +/- 1,227 | 65,793 +/- 755 | 17,963 +/- 1,212 | 69,394 +/- 1,401 |
| `rrp` latency (us) | 115.9 +/- 2.4 | 115.2 +/- 2.0 | 121.6 +/- 1.4 | 447.2 +/- 32.5 | 115.3 +/- 2.4 |
| `udp` 600M NET_RX/s | 25,307 | 25,569 +/- 782 | 21,973 +/- 900 | 10,992 +/- 2,154 | 11,375 +/- 1,596 |
| `udp` 900M NET_RX/s | 39,845 | 39,926 +/- 410 | 38,001 +/- 51 | 25,374 +/- 2,340 | 32,025 +/- 5,208 |
| `udps` 50M NET_RX/s | 39,590 | 39,885 +/- 283 | 20,279 +/- 183 | 6,413 +/- 180 (10 runs) | 7,176 +/- 1,820 |
| `udps` 100M NET_RX/s | 39,232 | 38,568 +/- 1,600 | 23,504 +/- 540 | 8,179 +/- 413 (10 runs) | 9,017 +/- 387 |
| `udps` 200M NET_RX/s | 31,459 | 31,537 +/- 849 | 28,827 +/- 525 | 20,774 +/- 3,914 (9 runs) | 25,716 +/- 3,379 |

Interrupt CPU not in a cpuidle state (percent of the wall time):

| Cell | `stock` | `off` | `static-L2` | `static-L4` | `adaptive` |
|---|---|---|---|---|---|
| `rr` | 17.5 | 17.4 +/- 0.5 | 11.2 | 11.3 | 17.8 +/- 0.5 |
| `rrp` | 43.6 | 44.0 +/- 1.3 | 40.8 | 24.0 | 44.3 +/- 0.8 |
| `tcp` | 14.7 | 14.4 +/- 0.6 | 14.7 | 14.9 | 14.8 +/- 1.1 |
| `udp` 600M | 25.6 | 25.9 +/- 2.1 | 27.2 | 23.9 +/- 4.1 | 20.3 +/- 2.5 |
| `udp` 900M | 30.0 | 30.8 +/- 1.2 | 30.7 | 31.5 +/- 2.2 | 25.2 +/- 1.2 |
| `udps` 50M | 24.9 | 26.1 +/- 1.0 | 19.8 | 22.8 +/- 1.1 | 22.1 +/- 1.3 |
| `udps` 100M | 37.1 | 36.1 +/- 1.8 | 33.7 | 25.8 +/- 1.6 | 25.0 +/- 1.2 |
| `udps` 200M | 48.8 | 50.2 +/- 2.3 | 47.8 | 45.0 +/- 1.7 | 45.4 +/- 1.4 |

Packet delay is the price of the high levels: `udps` jitter rises from 0.007 to 0.017 ms at 50M (`static-L4` 0.021 ms), and no change at 100M (0.005 against 0.006 ms).

Data cleaning: in round 2 the `static-L4` visit was disturbed. The kernel log shows `NETDEV WATCHDOG: transmit queue 0 timed out 5416 ms` at 18:25:25; the `udps` 200M run 4 failed after 114.75 s, and the device then read `rx-usecs=0` (the chip start writes `IntrMitigate = 0`, so a hardware reset drops a static timer, as in the stock driver). The failed run and the `udps` runs 5 and 6 of that visit, which ran with no timer, were removed from `static-L4/summary.csv` (the raw logs are kept; the visit is listed in `warnings.txt`), leaving 10, 10 and 9 runs in the three `udps` cells. Adaptive mode was off in that visit, so the adaptive code was not involved.

### 4.5 Response to a step (`results/phase4/stepped/adaptive-600M/`)

Three cycles of 10 s idle and 10 s of 600 Mbit/s UDP. The level was above 0 within 0.08 to 0.20 s of the start of each burst and at the top level (400 us) within the same sampling interval; it was back at 0 after 0.77, 1.31 and 0.76 s from the end of the burst (the marker is taken after iperf3 returns, so these include a few hundred milliseconds of slack). Of the samples, 54% were at 0 us, 6% at 200 us and 41% at 400 us, with 0.5 level changes per second. The control run with adaptive off stays at 0 us in all 317 samples.

## 5. Tuning log

| Table version | Levels (us) | What changed | What moved | Raw data |
|---|---|---|---|---|
| v0 (Phase 2 and 3) | 0, 40, 80, 200, 400 | - | exploratory (4.1 to 4.3) and final (4.4, 4.5) | `results/phase4/exploratory-1/`, `cpucheck/`, `dwell/`, `final/`, `stepped/` |

Tuning rule of the plan (3.5), checked on the final matrix: (1) `rr` and `rrp` within 5% of `off`: both are noise (trans/s -0.1%, latency +0.1%); (2) no throughput or loss regression: none in `tcp`, `udp` and `udps` (the `udps` 200M loss difference is noise); (3) lower NET_RX rate and lower interrupt CPU use for `udp` and `udps`: NET_RX/s -55% to -82% and interrupt-CPU non-idle -15% to -31% in the 50M, 100M and 600M cells, -18% at 900M.

Decision (2026-11-16): no tuning round. The table passes the rule on the first try. The one candidate, lower values for levels 1 and 2 to shorten the cost of exploring in `rrp` (7% of the samples of an `rrp` trace were at 40 or 80 us), has no cost to recover: the final matrix shows no `rrp` difference, and an effect below about 1.5% cannot be resolved with 12 runs (the `rrp` standard deviation is 2%). The 900M ramp-up behaviour is not a table value and would need a change of the algorithm, which is outside the tuning rule; it is reported as a limitation.

## 6. Frozen table and the reason for each value

Frozen: 0, 40, 80, 200, 400 us (v0), unchanged since Phase 2. Level 0 keeps the latency of `rr` and `rrp` (no measurable difference from `off`); level 400 us, which DIM reaches within one sampling interval under heavy small-packet load, gives the largest NET_RX and CPU saving without a loss; the levels in between are what DIM passes through. The measured cost of a static timer for latency traffic (80 us costs 42% of `rr` transactions per second, 400 us costs 87%) is why the levels above 0 must be reached by load and never set statically.

## 7. Figures

Written by `scripts/plot_results.py` from `results/phase4/final/` and `results/phase4/stepped/adaptive-600M/` into `docs/figures/`:

- `udp_netrx_softirq.png`, `udps_netrx_softirq.png`: NET_RX per second and the tick-sampled softirq share of the interrupt CPU against the offered rate, one line per configuration (error bars are one standard deviation). The softirq share is the tick-sampled figure that section 2 says not to rely on; the cpuidle-based figure is in the tables of 4.4.
- `request_response.png`: transactions per second and mean latency for `rr` and `rrp`.
- `tcp_bulk.png`: throughput and softirq share for bulk TCP.
- `stepped_adaptive-600M.png`: the timer level against time with the bursts shaded, and the NIC interrupt rate.

## 8. Findings and conclusion

1. The adaptive mode does what it was built for. Under heavy small-packet UDP it reaches the top level within one sampling interval and cuts the NET_RX softirq rate by 77 to 82% (`udps` 50M, 100M) and by 55% (`udp` 600M), and the interrupt CPU's non-idle time by 15 to 31%, with no change in throughput or loss. It does about as well as a static 400 us timer in the `udps` cells (CPU -15.5% against -12.7% at 50M, -30.9% against -28.8% at 100M).
2. It does not cost latency traffic anything measurable. `rr` and `rrp` are indistinguishable from `off` in transactions per second and in latency, while a static 80 us timer costs 42% (`rr`) and 5% (`rrp`) and 400 us costs 87% and 74%.
3. With adaptive mode off the patched driver matches the stock driver in every cell.
4. At 900 Mbit/s UDP the result is partial: NET_RX -19.8% and CPU -18.2% on average, but in the level traces the ramp-up is bimodal (1 run of 10 reached the top level, 3 stayed at 0). The benefit there is lower softirq work per packet, which DIM does not observe. It is a limit of the packet, byte and poll counters that DIM uses, not of the table.
5. The interrupt rate itself only falls where the packets are not already bunched into bursts: with iperf3's default pacing the NIC takes about 2000 interrupts per second at any rate, with or without moderation, and the benefit appears as a lower NET_RX rate and CPU use; with a 100 us pacing timer the interrupt rate falls from 16,900 to 3,300 per second at 100M.
6. Possible small cost for bulk TCP at line rate: the tick-sampled softirq share rises by about 0.2 points and the all-CPU figure from 0.91 to 0.97%, while the cpuidle-based figure cannot resolve it (+0.4 points, noise).

## 9. Limitations

- One chip variant (RTL8168h), one peer, one link speed (1 Gbit/s); results are not generalised.
- The CPU figures come from the idle residency of the interrupt CPU (microsecond counters, includes the polling idle state as idle); the `/proc/stat` percentages are sampled at the scheduler tick on this kernel and are shown only for reference.
- iperf3 UDP is paced and the sender cannot exceed about 260,000 packets per second of 100 byte datagrams; the 200M `udps` cell is close to the point where the receive path stays in NAPI polling mode, and some runs of every configuration show 24 to 130 interrupts per second there.
- One TX watchdog timeout and device reset happened in one visit (static timer, adaptive off); it was not investigated further. After a reset a static timer is lost (stock behaviour); the adaptive level is restored by the driver (Phase 3).
- The 900M ramp-up bimodality is reported but not explained beyond the hypothesis in 4.3, and there is no change to address it.
- The CPU governor was `performance` and the NIC interrupt pinned to one CPU during the session; the comparisons are between configurations within the session, not against the Phase 0 to 3 numbers.

## 10. Raw-data folders

- `results/phase4/calibration/`: `udps` calibration, default pacing and 100 us pacing.
- `results/phase4/exploratory-1/`: exploratory matrix (`off`, `static-L2`, `static-L4`, `adaptive`, `stock`).
- `results/phase4/cpucheck/`: first run with the cpuidle-based CPU measure.
- `results/phase4/dwell/`: level traces (`adaptive-50M-p100`, `adaptive-900M`, `rrp-trace`).
- `results/phase4/final/`: final matrix with `matrix.log`, `warnings.txt` and the session files.
- `results/phase4/stepped/`: stepped load with adaptive on and off.
- `docs/figures/`: PNG figures.
