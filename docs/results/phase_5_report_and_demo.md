# Phase 5: Report and demo, results

Status: in progress (2026-11-18). The report, the demo script and its run sheet, and the series check script are written, the clean-tree checks are done, the matched `final-check` run agrees with the Phase 4 final matrix, and the demo was rehearsed three times. Still to do: the fallback recording and the tag. Plan: [`../plans/plan-5-report-and-demo.md`](../plans/plan-5-report-and-demo.md).

## 1. What was delivered

| Item | Where | State |
|---|---|---|
| Final patch series | `patches/0001` to `0006` | No change from Phase 4 (no patch 0007); applies and builds on a clean `v7.2.15`, see section 2 |
| Series check script | `scripts/check_series.sh` | Written; run on a clean clone (section 2) |
| Report | `docs/report.md` | Written in Markdown from the Phase 0 to 4 results files and logs. Format asked by the course: **unknown**, see section 5 |
| Demo script and run sheet | `scripts/demo.sh`, `docs/demo.md` | Rehearsed three times on the machine, the third time with the stage 4 change (section 4) |
| README, handoff, phase tracker | `README.md`, `docs/handoff.md`, `docs/phases.md` | Updated |
| Tag | `v1.0` | **pending** |

## 2. Checks on a clean tree (done 2026-11-18, not on the PC)

Clean clone: `git clone --depth 1 --branch v7.2.15 https://github.com/gregkh/linux.git`, commit `497791a0a96b`.

| Check | Result |
|---|---|
| `bash scripts/check_series.sh -t <clean clone> -c` | All 6 patches apply in order with `patch -p1` (dry run first). `checkpatch.pl --strict --no-tree` per patch: the `Co-authored-by` signature warning on every patch, the missing `Signed-off-by` on the unsigned files in `patches/`, and three CamelCase checks in 0004 (`IntrMitigate`, `PktCntrDisable`, `CPlusCmd`, register names the driver already uses) |
| `git am` of the six patches on the clean tree, then `git rebase --exec 'git commit --amend --no-edit -s' v7.2.15` and `checkpatch.pl --strict -g` per commit | `git am` clean. After sign-off: 0 errors, 1 warning per commit (the `Co-authored-by` signature), plus the same three CamelCase checks in 0004 |
| The tree after `git am` against the tree after six `patch -p1` runs on pristine copies of the two files | `r8169_main.c` identical |
| `make M=drivers/net/ethernet/realtek modules W=1` (defconfig, `R8169=m`, `DIMLIB=y`, `PROVE_LOCKING=y`, `DEBUG_FS=y`) | `r8169_main.o`, `r8169_firmware.o` and `r8169_phy_config.o` compile with 0 warnings. The module link (modpost) fails with unresolved symbols because no `vmlinux` was built in that tree, as in Phase 3; the PC build in `/usr/src/linux-7.2.15` is the one that links |
| `sparse` | **Not run.** The sparse of the sandbox (0.6.4) is older than the one the kernel build wants ("not available or not up to date"). Run it on the PC if a recent sparse is installed: `make M=drivers/net/ethernet/realtek C=2 CF="-D__CHECK_ENDIAN__" r8169_main.o` |
| Locking notes against the final patch | The series is the same as when `docs/locking.md` was checked (Phase 3), so no change was needed |

The patches in `patches/` carry no `Signed-off-by` (the plan keeps that step for the person who signs). To make a signed copy, run `git rebase --exec 'git commit --amend --no-edit -s' v7.2.15` on a branch with the series applied, as in the table above.

## 3. Numbers check of the final build (`final-check`)

Module under test: srcversion `04E8D19E5DCBE28E8305847` (the frozen build), kernel `7.2.15-netquota`. `bash scripts/check_series.sh -t ~/linux-r8169-clean -c` on the PC gave the same result as in section 2.

### 3.1 First run (`results/phase5/first-check/`)

The command was `scripts/rx_bench.sh -l final-check -p $PEER -w "rr udps" -n 3`. It was written without `-m 100` and without `-o`, and it does not set the adaptive flag, so the flag state was not recorded. The raw files first landed in `results/baseline/final-check/` and were moved to `results/phase5/first-check/`.

| Cell | Result | Phase 4 final matrix |
|---|---|---|
| `rr`, 3 runs | 13,044 +/- 30 transactions/s, mean latency 76.6 us, 2.00 interrupts per transaction | `off` 12,973 +/- 99 and `adaptive` 12,962 +/- 80 transactions/s, 77.1 us; `stock` 13,018 +/- 205, 76.8 us. Agrees |
| `udps` 50M, 100M, 200M | NIC interrupt rate 2,002, 2,003 and 1,988 per second; NET_RX 4,717, 10,104 and 21,830 per second | **Not comparable.** The Phase 4 matrix used `-m 100` (iperf3 pacing timer 100 us). Without it iperf3 sends in 1 ms bursts and the interrupt rate is about 2,000 per second at every rate (Phase 4 calibration, section 3) |

Only the `rr` cell of this run is used. The `udps` cells are kept as raw data and are not quoted.

### 3.2 Matched run (`results/phase5/final-check/`)

`bash scripts/run_matrix.sh -p $PEER -o results/phase5/final-check -c "off adaptive" -w "rr udps" -r "50M 100M" -m 100 -R 1 -V 3 -g performance`: one round, three runs per cell and configuration, 20 s per run, governor `performance` set by the script, the device back to adaptive off and `rx-usecs` 0 at the end. Mean +/- standard deviation of three runs; `Phase 4` is the same quantity in the 12-run final matrix (`results/phase4/final/`).

| Cell | `off` | `adaptive` | Change | Phase 4 final |
|---|---|---|---|---|
| `rr` transactions/s | 13,096 +/- 182 | 13,101 +/- 158 | +0.0%, noise | 12,973 and 12,962, noise |
| `rr` mean latency (us) | 76.3 +/- 1.1 | 76.3 +/- 0.9 | 0.0%, noise | 77.1 and 77.1 |
| `udps` 50M, NET_RX/s | 39,695 +/- 531 | 6,532 +/- 88 | -83.5% | -82.0% |
| `udps` 50M, NIC interrupts/s | 19,675 +/- 521 | 2,810 +/- 37 | -85.7% | 19,876 to 3,119 |
| `udps` 50M, interrupt CPU non-idle (%) | 24.7 +/- 1.0 | 22.0 +/- 1.1 | -10.9% | -15.5% |
| `udps` 50M, jitter (ms) | 0.007 | 0.016 | higher | 0.007 to 0.017 |
| `udps` 100M, NET_RX/s | 39,023 +/- 840 | 9,426 +/- 620 | -75.8% | -76.6% |
| `udps` 100M, NIC interrupts/s | 16,905 +/- 2,766 | 3,240 +/- 92 | -80.8% | 16,871 to 3,288 |
| `udps` 100M, interrupt CPU non-idle (%) | 36.0 +/- 3.2 | 25.4 +/- 1.4 | -29.4% | -30.9% |
| `udps` 100M, jitter (ms) | 0.004 | 0.006 | within noise | no change |

Throughput is the offered rate in every run and loss is 0 except one `off` run at 100M (0.0048%, noise). The result agrees with the Phase 4 final matrix in every cell, inside the spread of three runs; the build is the same. The `rr` interrupt-CPU figure (18.4 +/- 0.7 for `off`, 16.7 +/- 1.7 for `adaptive`) is marked "better" by the summary script, but the difference equals the spread of the adaptive runs and is not claimed.

Latency outliers: in 3 of the 9 `rr` runs of today's sessions (`first-check` runs 2 and 3, `adaptive` run 2) the maximum latency was about 200 ms (one transaction in more than 250,000), with a mean latency that is not affected. The same happens with `stock` and `off` in the Phase 4 final matrix (in 10 of 48 `rr` and `rrp` runs with `stock`, 14 of 48 with `off`, 16 of 48 with `adaptive`), so it is not caused by adaptive mode. The cause was not investigated; 200 ms is the size of the TCP minimum retransmission timeout.

## 4. Demo

Run sheet: [`../demo.md`](../demo.md). Rehearsals at the console of the machine under test (`results/phase5/rehearsal-1/` and `rehearsal-2/` hold the screen output of the two `-y` runs; the two `-t long` runs were interactive and not logged).

| Rehearsal | Date | Runs | Result |
|---|---|---|---|
| 1 | 2026-11-18 | short (`-y`), long | All six stages ran. Burst: level at 400 us with irq/s about 3,200 to 3,430 (about 3,290 on average), against about 19,900 for the same load with adaptive mode off in the Phase 4 matrix; first 0.5 s row 9,658 irq/s (short) and 5,952 (long), the ramp-up. Dips to 200 us in 1 of 16 samples (short) and 4 of 30 (long). Idle: 0 to 12 irq/s, level 0. Request-response: 12,898 and 13,079 transactions/s at level 0 (76 to 78 us); with a fixed 400 us timer 1,548 and 1,597 (626 to 646 us) |
| 2 | 2026-11-18 | short (`-y`), long | Same behaviour. Burst irq/s about 3,170 to 3,480, level at 400 us from the first row, 200 us in 1 of 16 and 6 of 30 samples. Request-response 13,116 and 13,139 transactions/s (76 us); fixed 400 us: 1,660 and 1,626 (602 to 615 us) |
| 3 | 2026-11-18 | short (`-y`), with the stage 4 change | All six stages ran. Burst: level 400 us with 200 us in 5 of 16 samples (the last one is the partial row at the end of the burst), irq/s 3,156 to 3,494 and 1,440 in the partial last row. Stage 4 starts at once: the last row of stage 3 shows 200 us and the first row of stage 4, 0.2 s later, shows 0 us; 0 to 20 irq/s after that. Request-response 12,887 transactions/s at 77.6 us at level 0; fixed 400 us: 1,622 at 616.4 us |

The numbers of all three rehearsals agree with the Phase 4 final matrix (`rr` 12,962 transactions/s and 77.1 us with adaptive on, 1,655 and 604.4 us with a fixed 400 us timer; `udps` 100M interrupt rate 3,288 per second).

**Found in the rehearsals.** In stage 4 the level was already 0 in the first row, because stage 3 ended and the script waited for Enter (or took 0.5 s) before sampling, so the fall could not be seen. Changed in `scripts/demo.sh`: no pause between stages 3 and 4, and stage 4 samples every 0.2 s. The last row of stage 3 is a partial interval (for example 254 irq/s at 0 us) because iperf3 ends inside it; this is expected.

With the change the fall can be seen as a step between two rows (200 us, then 0 us 0.2 s later), but the trace does not resolve its timing: the gap between the last row of stage 3 and the first row of stage 4 is the time iperf3 needs to exit. The measured time is 0.39 s (Phase 3, `decay_timing.sh`).

**Pending:** one recorded fallback session (`script`, run the demo inside it, see the run sheet). The first attempt recorded nothing because the demo was not run inside the session.

## 5. Open items

- The course requirements (report format and length, deadline, who watches the demo) are still unknown. The report is Markdown. If the course asks for a PDF, Word file or slides, make it from `docs/report.md`; the sections are ordered for that.
- `sparse` was never run on the series (Phase 3 and here).
- The fallback recording is not done yet.
- The `v1.0` tag and the final cleanup (`git status` clean, no stray files) wait for the fallback recording.

## 6. Repository state

Private repository `Dhruv0306/r8169-adaptive-rx-dim-private`, `main` includes Phase 4. Phase 5 work is on the branch `Dhruv_Patel/r8169-report-and-demo`. The shared repository `Dhruv0306/r8169-adaptive-rx-dim` stays at the end of Phase 3 and does not receive Phase 4 or 5 work.
