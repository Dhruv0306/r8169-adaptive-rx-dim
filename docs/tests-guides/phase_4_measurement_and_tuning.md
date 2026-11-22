# Phase 4 test guide: measurement and tuning

Every measurement of Phase 4. No driver change was made. Results: [`../results/phase_4_measurement_and_tuning.md`](../results/phase_4_measurement_and_tuning.md). Plan: [`../plans/plan-4-measurement-and-tuning.md`](../plans/plan-4-measurement-and-tuning.md) (runbook in section 9). General setup: [`../setup-and-testing.md`](../setup-and-testing.md), Phase 4.

Phase 4 has no numbered tests. The steps are labelled P4-A to P4-H in the order they were run.

## Session conditions (differ from Phases 0 to 3)

- Patched module `srcversion 04E8D19E5DCBE28E8305847` (the frozen build) or stock (`A8C76016444D067D3998384`).
- CPU governor `performance` (set and restored by `run_matrix.sh -g performance`), NIC interrupt pinned to CPU 3, `irqbalance` stopped, 1 Gbit/s link, one peer. Phase 0 to 3 runs used `powersave`, so Phase 4 numbers must not be compared with them.
- Configurations: `stock`, `off` (patched module, adaptive off), `static-L2` (80 us), `static-L4` (400 us), `adaptive` (table 0, 40, 80, 200, 400 us). Switched with ethtool only, no module swap, except `stock`.
- Workloads (20 s per run): `rr` (1 stream, 64 bytes), `rrp` (8 parallel TCP_RR streams, summed), `tcp` (bulk), `udp` (iperf3, 1448 bytes, 600M and 900M, default pacing), `udps` (100 byte datagrams, 50M, 100M, 200M, iperf3 pacing timer 100 us, option `-m 100`).
- CPU cost is the cpuidle residency of the interrupt CPU ("IRQ CPU non-idle %"). The `/proc/stat` percentages are sampled at the scheduler tick on this kernel (`CONFIG_IRQ_TIME_ACCOUNTING` not set); the same load read 0% in one run and 86% in the next, so they are not used for conclusions.
- Run scripts as root, then `chown -R <user>:<user> results` before committing. Compare labels only within one session and one directory. Read `warnings.txt` after each matrix.

## Steps

| ID | Step | Command | Result |
|---|---|---|---|
| P4-A | Peer notes | On the peer: `uname -r; lspci \| grep -i ethernet; ethtool -i <dev>; iperf3 --version; netperf -V`, saved as `results/phase4/peer.txt` | Recorded (closes the Phase 0 item) |
| P4-B | Calibrate the small-packet load | `ethtool -C enp3s0 adaptive-rx off rx-usecs 0`; `bash scripts/rx_bench.sh -l calib -p $PEER -o results/phase4/calibration -w udps -r "20M 50M 100M 200M 300M" -n 3 -t 15`; again with `-m 100` | Chosen: 100 byte datagrams, 100 us pacing, 50M, 100M, 200M |
| P4-C | Plan only | `bash scripts/run_matrix.sh -p $PEER -o results/phase4/exploratory-1 -n` | Lists configurations, cells, runs, time estimate; runs nothing |
| P4-D | Exploratory matrix | `bash scripts/run_matrix.sh -p $PEER -o results/phase4/exploratory-1 -R 2 -V 3 -c "off static-L2 static-L4 adaptive" -r "50M 100M 200M" -m 100 -g performance` | About 6 runs per cell (3 for `stock`) |
| P4-E | Stock at both ends | `rmmod r8169; modprobe r8169`, wait 40 s, `bash scripts/rx_bench.sh -l stock -p $PEER -o results/phase4/exploratory-1 -n 5 -w "rr rrp tcp udp udps" -u "300M 600M 900M" -r "50M 100M 200M" -m 100`; reload the patched module | `stock` label in the same directory |
| P4-F | CPU check and level traces | `run_matrix.sh` into `results/phase4/cpucheck` (6 runs per cell); `bash scripts/dwell_check.sh -p $PEER -n 10 -r 900M -a on` and `-a off` as control; same for `udps` 50M with pacing 100 us and for `rrp` | Sections below |
| P4-G | Final matrix | As P4-D with `-R 4 -V 3` (12 runs per cell) on the frozen build, `stock` run 6 times before and 6 after | `results/phase4/final/` with `matrix.log` and `warnings.txt` |
| P4-H | Stepped load and figures | `bash scripts/stepped_load.sh -p $PEER -a on` and `-a off`; `python3 scripts/plot_results.py -d results/phase4/final -o docs/figures --stepped results/phase4/stepped/adaptive-600M` | Level against time; PNG files in `docs/figures/` |

Summaries: `python3 scripts/summarize_results.py -d <dir> -r off` prints tables and a noise-aware comparison against `off` (a difference within the larger standard deviation is reported as noise). Matrix visits are interleaved, with reversed order on even rounds, and the configuration is read back after applying it and after each visit.

## P4-B: calibration data (adaptive off, 3 runs per rate)

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

With the default pacing the interrupt rate is set by the sender's 1 ms bursts (about 2000 per second at every rate), and the peer cannot send more than about 266,000 packets per second of 100 byte datagrams. With a 100 us pacing timer the interrupt rate follows the load. At 200M some runs of every configuration fall into the polling regime (24 to 130 interrupts per second), so that cell is not used for decisions.

## P4-D and P4-E: exploratory matrix

`adaptive` against `off` (a difference inside the larger standard deviation is noise):

| Workload | `adaptive` | `static-L4` for comparison |
|---|---|---|
| `rr` | 13,106 against 12,984 trans/s, 76.3 against 77.0 us: noise | -87.2% trans/s, +682% latency |
| `rrp` | 68,283 against 70,772 trans/s (-3.5%), 117.2 against 113.1 us (+3.6%) | -77.1% trans/s, +342% latency |
| `tcp` | 941.2 against 941.3 Mbit/s | no difference |
| `udp` 600M | NET_RX/s -56.9% | -59.5% |
| `udp` 900M | NET_RX/s -15.9%, large spread | -35.7% |
| `udps` 50M, 100M | NET_RX/s -70.5%, -75.8% | -83.8%, -79.3% |
| `udps` 200M | NET_RX/s -15.7% (not used for decisions) | -41.3% |

`stock` against `off` is noise in every cell. The `rrp` -3.5% did not reproduce in the final matrix (-0.1%), so it counts as run-to-run variation. Static 80 us alone costs 41.9% of `rr` trans/s.

## P4-F: CPU check (6 runs per cell, interrupt CPU not in a cpuidle state, %)

| Cell | `off` | `static-L4` | `adaptive` |
|---|---|---|---|
| `udp` 600M | 26.1 +/- 3.5 | 22.9 +/- 2.7 | 19.3 +/- 2.0 (-26%) |
| `udps` 50M | 24.2 +/- 1.7 | 23.1 +/- 0.9 | 22.1 +/- 1.8 (-8.9%) |
| `udps` 100M | 37.1 +/- 1.1 | 26.3 +/- 1.4 | 25.5 +/- 1.4 (-31%) |

## P4-F: level traces

- `rrp`, 3 runs, 637 samples: 93% at 0 us, 5% at 40 us, 2% at 80 us, none higher. Mean timer 3.6 us, matching the 4 us rise in mean latency (113.1 to 117.2 us); the exploratory `rrp` cost is the time DIM spends exploring levels 1 and 2.
- `udps` 50M (100 us pacing), 10 runs: nine reach about 390 us within the first second and stay (1.1% of samples below 200 us); run 1 ramped late (mean 261 us, 31.9% low). With the exploratory run that stayed at level 0 for 20 s, DIM does not always ramp up promptly from a fresh start.
- `udp` 900M, 10 runs: bimodal. Run 1 reached the top level (mean 364 us); runs 2, 4 and 9 stayed at level 0 (mean 14 to 60 us, NET_RX/s 38,283 to 39,685, as with `off`); the other six sat in between (mean 91 to 158 us). Static 400 us cuts NET_RX by 36% there but not the interrupt rate, so the benefit is not in the quantities DIM measures (a limit of DIM at 900M, hypothesis, not tested further).

## P4-G: final matrix (12 runs per cell)

`adaptive` against `off`:

| Workload | `adaptive` against `off` |
|---|---|
| `rr` | trans/s -0.1%, latency +0.1%, interrupt CPU +2.8%: noise |
| `rrp` | trans/s -0.1%, latency +0.1%, NET_RX/s -1.6%: noise |
| `tcp` | 941.2 Mbit/s in every configuration; NET_RX/s -0.4%; interrupt-CPU +2.7%, noise |
| `udp` 600M | NET_RX/s -55.5%, interrupt-CPU non-idle -21.7% (20.3 against 25.9%) |
| `udp` 900M | NET_RX/s -19.8%, non-idle -18.2% (25.2 against 30.8%) |
| `udps` 50M | NET_RX/s -82.0%, non-idle -15.5%, irq/s 3,119 against 19,876 |
| `udps` 100M | NET_RX/s -76.6%, non-idle -30.9%, irq/s 3,288 against 16,871 |
| `udps` 200M | NET_RX/s -18.5%, non-idle -9.6%; loss 0.0146% against 0.0037% (noise, one run lost 0.126%) |

Mean values (NET_RX/s unless stated):

| Cell | `stock` | `off` | `static-L2` | `static-L4` | `adaptive` |
|---|---|---|---|---|---|
| `rr` trans/s | 13,018 +/- 205 | 12,973 +/- 99 | 7,553 +/- 71 | 1,655 +/- 32 | 12,962 +/- 80 |
| `rr` latency (us) | 76.8 +/- 1.2 | 77.1 +/- 0.6 | 132.4 +/- 1.3 | 604.4 +/- 11.7 | 77.1 +/- 0.5 |
| `rrp` trans/s | 69,057 +/- 1,448 | 69,436 +/- 1,227 | 65,793 +/- 755 | 17,963 +/- 1,212 | 69,394 +/- 1,401 |
| `rrp` latency (us) | 115.9 +/- 2.4 | 115.2 +/- 2.0 | 121.6 +/- 1.4 | 447.2 +/- 32.5 | 115.3 +/- 2.4 |
| `udp` 600M | 25,307 | 25,569 +/- 782 | 21,973 +/- 900 | 10,992 +/- 2,154 | 11,375 +/- 1,596 |
| `udp` 900M | 39,845 | 39,926 +/- 410 | 38,001 +/- 51 | 25,374 +/- 2,340 | 32,025 +/- 5,208 |
| `udps` 50M | 39,590 | 39,885 +/- 283 | 20,279 +/- 183 | 6,413 +/- 180 (10 runs) | 7,176 +/- 1,820 |
| `udps` 100M | 39,232 | 38,568 +/- 1,600 | 23,504 +/- 540 | 8,179 +/- 413 (10 runs) | 9,017 +/- 387 |
| `udps` 200M | 31,459 | 31,537 +/- 849 | 28,827 +/- 525 | 20,774 +/- 3,914 (9 runs) | 25,716 +/- 3,379 |

Interrupt CPU not in a cpuidle state (%):

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

Packet delay is the price of the high levels: `udps` jitter rises from 0.007 to 0.017 ms at 50M (`static-L4` 0.021 ms) and does not change at 100M (0.005 against 0.006 ms).

### Data cleaning rule

In round 2 the `static-L4` visit was disturbed: `NETDEV WATCHDOG: transmit queue 0 timed out 5416 ms` at 18:25:25, `udps` 200M run 4 failed after 114.75 s, and the device then read `rx-usecs=0` (a hardware reset drops a static timer, as in the stock driver). The failed run and runs 5 and 6 of that visit were removed from `static-L4/summary.csv` (raw logs kept, visit listed in `warnings.txt`), leaving 10, 10 and 9 runs in the three `udps` `static-L4` cells. Adaptive mode was off in that visit, so the adaptive code was not involved.

## P4-H: stepped load (`results/phase4/stepped/adaptive-600M/`)

Three cycles of 10 s idle and 10 s of 600 Mbit/s UDP, level sampled at 5 Hz on one clock with burst markers.

- Level above 0 within 0.08 to 0.20 s of each burst start and at 400 us within the same sampling interval.
- Back at 0 after 0.77, 1.31 and 0.76 s from the end of the burst (the marker is taken after iperf3 returns, so this includes a few hundred ms of slack).
- Samples: 54% at 0 us, 6% at 200 us, 41% at 400 us, 0.5 level changes per second.
- Control with adaptive off: 0 us in all 317 samples.

## Tuning rule and decision

Rule (plan 3.5): (1) `rr` and `rrp` within 5% of `off`; (2) no throughput or loss regression; (3) lower NET_RX and CPU for the UDP cells. All three hold on the final matrix, so the table `0, 40, 80, 200, 400` us was frozen on 2026-11-16 with no tuning round. A change would be tested with `run_matrix.sh -c "off adaptive" -T "<new table>"` into a new directory.

## Pitfalls

- iperf3 paces sending with a 1 ms timer by default, so the NIC takes about 2000 interrupts per second at any rate. Use `-m 100` for small-packet tests; without it the interrupt rate says nothing about moderation. (The first Phase 5 check made this mistake.)
- The all-CPU and tick-sampled softirq percentages are unreliable on this kernel; use the cpuidle figure.
- `rx_bench.sh` refuses to append to a CSV with an older column layout; use a new label or directory.
- Read `warnings.txt` after every matrix: a visit with a transmit timeout or a changed configuration must be handled before the numbers are used.
- Compare only within the session. The `stock` runs at both ends of the session act as a drift check.
- The 900M ramp-up bimodality is reported but not explained beyond the hypothesis; effects below about 1.5% cannot be resolved with 12 runs (`rrp` standard deviation is 2%).
- Limits: one chip variant (RTL8168h), one peer, one link speed (1 Gbit/s). One TX watchdog timeout and reset happened in one visit (static timer, adaptive off) and was not investigated.
