# Phase 5 test guide: report, demo and final checks

Checks of the final deliverables: the patch series on a clean tree, a matched run of the final build, and the live demo. No driver change. Results: [`../results/phase_5_report_and_demo.md`](../results/phase_5_report_and_demo.md). Plan: [`../plans/plan-5-report-and-demo.md`](../plans/plan-5-report-and-demo.md). Demo run sheet: [`../demo.md`](../demo.md). General setup: [`../setup-and-testing.md`](../setup-and-testing.md), Phase 5.

The checks are labelled P5-A to P5-G.

## Conditions

- Final patch series `patches/0001` to `0006`, unchanged since Phase 3 (no patch 0007). Frozen build `srcversion 04E8D19E5DCBE28E8305847`, kernel `7.2.15-netquota`.
- Clean-tree checks use a clean clone of `v7.2.15` (`git clone --depth 1 --branch v7.2.15 https://github.com/gregkh/linux.git ~/linux-r8169-clean`, commit `497791a0a96b`). They do not touch the PC's source tree.
- Matched run and demo use the Phase 4 session conditions (governor `performance`, NIC interrupt pinned, `irqbalance` stopped). Peer runs `iperf3 -s` and `netserver`.

## Checks

| ID | Check | Command | Expected | Result |
|---|---|---|---|---|
| P5-A | Series on a clean tree | `bash scripts/check_series.sh -t ~/linux-r8169-clean -c` | All 6 patches apply in order with `patch -p1` (dry run first); checkpatch only the expected items | Pass |
| P5-B | `git am` and sign-off | `git am` the six patches on the clean tree; `git rebase --exec 'git commit --amend --no-edit -s' v7.2.15`; `checkpatch.pl --strict -g` per commit | `git am` clean; 0 errors, 1 warning per commit | Pass |
| P5-C | `git am` tree equals `patch -p1` tree | Compare `r8169_main.c` after both routes | Identical | Pass |
| P5-D | Build on a clean tree | `make M=drivers/net/ethernet/realtek modules W=1` (defconfig, `R8169=m`, `DIMLIB=y`, `PROVE_LOCKING=y`, `DEBUG_FS=y`) | 0 warnings | Pass for the objects; module link fails (no `vmlinux` in that tree), the PC build is the one that links |
| P5-E | `sparse` | `make M=drivers/net/ethernet/realtek C=2 CF="-D__CHECK_ENDIAN__" r8169_main.o` | No new warnings | **Not run** (sandbox sparse 0.6.4 too old); run on the PC if a recent sparse is installed |
| P5-F | Matched numbers run | See below | Agrees with the Phase 4 final matrix within the spread of three runs | Pass |
| P5-G | Demo rehearsals and fallback | See below | All six stages run; numbers agree with Phase 4 | Pass (3 rehearsals) |

P5-A expected checkpatch output: the `Co-authored-by` signature warning on every patch, the missing `Signed-off-by` on the unsigned files in `patches/`, and three CamelCase checks in 0004 on `IntrMitigate`, `PktCntrDisable`, `CPlusCmd` (register names the driver already uses). Locking notes needed no change because the series equals the one checked in Phase 3.

## P5-F: matched run (`results/phase5/final-check/`)

```bash
cat /sys/module/r8169/srcversion        # must print 04E8D19E5DCBE28E8305847
bash scripts/run_matrix.sh -p $PEER -o results/phase5/final-check -c "off adaptive" -w "rr udps" -r "50M 100M" -m 100 -R 1 -V 3 -g performance
python3 scripts/summarize_results.py -d results/phase5/final-check -r off
```

One round, three runs per cell and configuration, 20 s per run; the script sets the governor and leaves the device at adaptive off and `rx-usecs` 0.

| Cell | `off` | `adaptive` | Change | Phase 4 final |
|---|---|---|---|---|
| `rr` trans/s | 13,096 +/- 182 | 13,101 +/- 158 | +0.0%, noise | 12,973 and 12,962 |
| `rr` mean latency (us) | 76.3 +/- 1.1 | 76.3 +/- 0.9 | 0.0%, noise | 77.1 and 77.1 |
| `udps` 50M NET_RX/s | 39,695 +/- 531 | 6,532 +/- 88 | -83.5% | -82.0% |
| `udps` 50M NIC irq/s | 19,675 +/- 521 | 2,810 +/- 37 | -85.7% | 19,876 to 3,119 |
| `udps` 50M interrupt CPU non-idle (%) | 24.7 +/- 1.0 | 22.0 +/- 1.1 | -10.9% | -15.5% |
| `udps` 50M jitter (ms) | 0.007 | 0.016 | higher | 0.007 to 0.017 |
| `udps` 100M NET_RX/s | 39,023 +/- 840 | 9,426 +/- 620 | -75.8% | -76.6% |
| `udps` 100M NIC irq/s | 16,905 +/- 2,766 | 3,240 +/- 92 | -80.8% | 16,871 to 3,288 |
| `udps` 100M interrupt CPU non-idle (%) | 36.0 +/- 3.2 | 25.4 +/- 1.4 | -29.4% | -30.9% |
| `udps` 100M jitter (ms) | 0.004 | 0.006 | within noise | no change |

Throughput equals the offered rate in every run; loss is 0 except one `off` run at 100M (0.0048%, noise). The `rr` interrupt-CPU figure (18.4 +/- 0.7 off, 16.7 +/- 1.7 adaptive) is flagged "better" by the summary script but equals the spread, so it is not claimed.

### The first, discarded attempt (`results/phase5/first-check/`)

`scripts/rx_bench.sh -l final-check -p $PEER -w "rr udps" -n 3` was written without `-m 100` and without `-o`, and it does not set the adaptive flag, so the flag state was not recorded. Raw files landed in `results/baseline/final-check/` and were moved. Only its `rr` cell is used (13,044 +/- 30 trans/s, 76.6 us, 2.00 interrupts per transaction, in agreement). Its `udps` cells (interrupt rate about 2,000 per second at every rate) are not comparable and are not quoted.

### Latency outliers

In 3 of 9 `rr` runs of that day the maximum latency was about 200 ms (one transaction in more than 250,000) with the mean unaffected. The same happens with `stock` and `off` in the Phase 4 matrix (10 of 48 `rr` and `rrp` runs with `stock`, 14 of 48 with `off`, 16 of 48 with `adaptive`), so adaptive mode is not the cause. Not investigated; 200 ms equals the TCP minimum retransmission timeout.

## P5-G: demo

Setup (at least ten minutes before, because a link-up takes about 35 s to pass traffic): console as root in the clone, frozen module loaded and signed, stock module copy at `~/r8169-stock-src/`, peer running `iperf3 -s` and `netserver`.

```bash
bash scripts/demo.sh -p PEER                                         # 3 minute version, pauses between stages
bash scripts/demo.sh -p PEER -t long                                  # 10 minute version
bash scripts/demo.sh -p PEER -y -o results/phase5/rehearsal-1         # rehearsal, no pauses, screen log kept
```

Stages: (1) module and flag, adaptive off; (2) adaptive on, idle; (3) 100 byte UDP burst at 100M with 100 us pacing, level and interrupt rate shown twice a second; (4) idle again, the level falls (sampled every 0.2 s, no pause after stage 3); (5) request-response with adaptive on, then with a fixed 400 us timer; (6) cleanup to `Adaptive RX: off`, `rx-usecs: 0` (also on Ctrl-C).

| Rehearsal | Date | Runs | Observed |
|---|---|---|---|
| 1 | 2026-11-18 | short (`-y`) and long | Burst at 400 us, irq/s about 3,200 to 3,430 (first row 9,658 short, 5,952 long, the ramp-up); dips to 200 us in 1 of 16 (short) and 4 of 30 (long) samples. Idle 0 to 12 irq/s. RR 12,898 and 13,079 trans/s at 76 to 78 us; fixed 400 us 1,548 and 1,597 (626 to 646 us) |
| 2 | 2026-11-18 | short (`-y`) and long | Burst irq/s about 3,170 to 3,480, 400 us from the first row, 200 us in 1 of 16 and 6 of 30 samples. RR 13,116 and 13,139 at 76 us; fixed 400 us 1,660 and 1,626 (602 to 615 us) |
| 3 | 2026-11-18 | short (`-y`), with the stage 4 change | 400 us with 200 us in 5 of 16 samples (the last one is the partial row), irq/s 3,156 to 3,494. Last row of stage 3 shows 200 us, first row of stage 4, 0.2 s later, shows 0 us. RR 12,887 at 77.6 us; fixed 400 us 1,622 at 616.4 us |

The `-y` runs have screen logs in `results/phase5/rehearsal-1/`, `rehearsal-2/` and `rehearsal-3/` (each holds `demo.log`); the two `-t long` runs were interactive and not logged. All rehearsal numbers agree with the Phase 4 final matrix (`rr` 12,962 trans/s and 77.1 us adaptive, 1,655 and 604.4 us fixed 400 us; `udps` 100M interrupt rate 3,288 per second).

Found in the rehearsals: stage 4 showed level 0 in its first row because the script waited for Enter before sampling, hiding the fall. `scripts/demo.sh` now has no pause between stages 3 and 4 and samples every 0.2 s. The last row of stage 3 is a partial interval (for example 254 irq/s at 0 us) because iperf3 ends inside it. The trace does not resolve the decay time; the measured value is 0.39 s (Phase 3, `decay_timing.sh`).

### Fallback recording

```bash
script -q -T demo-timing.txt -c "bash scripts/demo.sh -p PEER -t long" demo-session.txt     # record
scriptreplay -T results/phase5/fallback/demo-timing.txt -s results/phase5/fallback/demo-session.txt -d 4   # replay four times faster
```

Recorded 2026-11-18 with the same module and kernel. All six stages present: burst at 400 us with 3,054 to 3,460 irq/s after a first row of 15,716, 200 us in 2 of 30 samples; stage 4 shows 0 us from its first row; idle 0 to 12 irq/s (one row of 118); RR 13,107 trans/s at 76.3 us; fixed 400 us 1,614 at 619.4 us. A second fallback is the figure `docs/figures/stepped_adaptive-600M.png` (or a fresh `bash scripts/stepped_load.sh -p PEER`).

## Pitfalls

- Use `-m 100` for any `udps` run, and `-o` so raw data does not land in `results/baseline/`.
- `rx_bench.sh` does not set the adaptive flag; set it with ethtool before the run, or use `run_matrix.sh`, which records it.
- The typescript has CRLF line endings and the timing file counts bytes; the files are marked `-text` in `.gitattributes`. A line-ending conversion breaks the replay.
- Two earlier recording attempts were discarded (the first recorded nothing, the second nested two `script` sessions and wrote a garbled file). Run `script` once, not inside another `script`.
- The patches in `patches/` carry no `Signed-off-by` on purpose; sign with the `git rebase --exec` command in P5-B.
- Live numbers on the day will differ a little from the quoted ones; say so.
- The report is Markdown because the course format is unknown; if a PDF, Word file or slides are required, build them from `docs/report.md`.
