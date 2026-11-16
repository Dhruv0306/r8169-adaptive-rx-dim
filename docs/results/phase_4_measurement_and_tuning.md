# Phase 4: Measurement and tuning, results

Status: in progress (started 2026-11-16). The measurement scripts are written and were tested against stand-in `netperf`, `iperf3` and `ethtool` programs and against the Phase 0 to 3 data; nothing has been measured on the machine yet. Plan: [`../plans/plan-4-measurement-and-tuning.md`](../plans/plan-4-measurement-and-tuning.md), runbook in its section 9.

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

To be filled in with the sessions.

## 3. Calibration data and the chosen small-packet rates

To be filled in.

## 4. Exploratory and final tables

To be filled in (output of `summarize_results.py`).

## 5. Tuning log

| Table version | Levels (us) | What changed | What moved | Raw data |
|---|---|---|---|---|
| v0 (Phase 2 and 3) | 0, 40, 80, 200, 400 | - | - | to be filled in |

## 6. Frozen table and the reason for each value

To be filled in.

## 7. Figures

To be filled in (`docs/figures/`).

## 8. Findings and conclusion

To be filled in.

## 9. Limitations

One chip variant (RTL8168h), one peer, one link speed (1 Gbit/s); results are not generalised.

## 10. Raw-data folders

To be filled in (`results/phase4/...`).
