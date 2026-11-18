# Phase 5: Report and demo, results

Status: in progress (2026-11-18). The report, the demo script and its run sheet, and the series check script are written, the clean-tree checks are done, and the demo was rehearsed twice (a short and a long run each). Still to do on the machines: the matched `final-check` run (the first one used the wrong pacing, see section 3), one more rehearsal after the stage 4 fix, the fallback recording, and the tag. Rows marked **pending** below are filled in after those runs. Plan: [`../plans/plan-5-report-and-demo.md`](../plans/plan-5-report-and-demo.md).

## 1. What was delivered

| Item | Where | State |
|---|---|---|
| Final patch series | `patches/0001` to `0006` | No change from Phase 4 (no patch 0007); applies and builds on a clean `v7.2.15`, see section 2 |
| Series check script | `scripts/check_series.sh` | Written; run on a clean clone (section 2) |
| Report | `docs/report.md` | Written in Markdown from the Phase 0 to 4 results files and logs. Format asked by the course: **unknown**, see section 5 |
| Demo script and run sheet | `scripts/demo.sh`, `docs/demo.md` | Rehearsed twice on the machine (section 4). Stage 4 was changed afterwards (see section 4), so one more rehearsal is **pending** |
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

### 3.2 Matched run

**Pending.** Both configurations in one session, with the same pacing as the Phase 4 final matrix, with the governor set and restored by the script:

```bash
bash scripts/run_matrix.sh -p $PEER -o results/phase5/final-check -c "off adaptive" -w "rr udps" -r "50M 100M" -m 100 -R 1 -V 3 -g performance
python3 scripts/summarize_results.py -d results/phase5/final-check -r off
```

What to expect if the build is the same as in Phase 4 (`results/phase4/final/`, section 4.4 of the Phase 4 results file): `rr` unchanged between `off` and `adaptive`; `udps` 50M NET_RX about -82% and NIC interrupt rate about 3,100 per second against about 19,900; `udps` 100M about -77% and 3,300 against 16,900. With three runs per cell, only a difference larger than the spread is a disagreement.

## 4. Demo

Run sheet: [`../demo.md`](../demo.md). Rehearsals at the console of the machine under test (`results/phase5/rehearsal-1/` and `rehearsal-2/` hold the screen output of the two `-y` runs; the two `-t long` runs were interactive and not logged).

| Rehearsal | Date | Runs | Result |
|---|---|---|---|
| 1 | 2026-11-18 | short (`-y`), long | All six stages ran. Burst: level at 400 us with irq/s about 3,200 to 3,430 (about 3,290 on average), against about 19,900 for the same load with adaptive mode off in the Phase 4 matrix; first 0.5 s row 9,658 irq/s (short) and 5,952 (long), the ramp-up. Dips to 200 us in 1 of 16 samples (short) and 4 of 30 (long). Idle: 0 to 12 irq/s, level 0. Request-response: 12,898 and 13,079 transactions/s at level 0 (76 to 78 us); with a fixed 400 us timer 1,548 and 1,597 (626 to 646 us) |
| 2 | 2026-11-18 | short (`-y`), long | Same behaviour. Burst irq/s about 3,170 to 3,480, level at 400 us from the first row, 200 us in 1 of 16 and 6 of 30 samples. Request-response 13,116 and 13,139 transactions/s (76 us); fixed 400 us: 1,660 and 1,626 (602 to 615 us) |

The numbers agree with the Phase 4 final matrix (`rr` 12,962 transactions/s and 77.1 us with adaptive on, 1,655 and 604.4 us with a fixed 400 us timer; `udps` 100M interrupt rate 3,288 per second).

**Found in the rehearsals.** In stage 4 the level was already 0 in the first row, because stage 3 ended and the script waited for Enter (or took 0.5 s) before sampling, so the fall could not be seen. Changed in `scripts/demo.sh`: no pause between stages 3 and 4, and stage 4 samples every 0.2 s. The last row of stage 3 is a partial interval (for example 254 irq/s at 0 us) because iperf3 ends inside it; this is expected.

**Pending:** one rehearsal with the fixed script (`results/phase5/rehearsal-3/`) and one recorded fallback session (`script`, see the run sheet).

## 5. Open items

- The course requirements (report format and length, deadline, who watches the demo) are still unknown. The report is Markdown. If the course asks for a PDF, Word file or slides, make it from `docs/report.md`; the sections are ordered for that.
- `sparse` was never run on the series (Phase 3 and here).
- The matched `final-check` run (section 3.2), the rehearsal with the fixed script and the fallback recording are not done yet.
- The `v1.0` tag and the final cleanup (`git status` clean, no stray files) wait for the items above.

## 6. Repository state

Private repository `Dhruv0306/r8169-adaptive-rx-dim-private`, `main` includes Phase 4. Phase 5 work is on the branch `Dhruv_Patel/r8169-report-and-demo`. The shared repository `Dhruv0306/r8169-adaptive-rx-dim` stays at the end of Phase 3 and does not receive Phase 4 or 5 work.
