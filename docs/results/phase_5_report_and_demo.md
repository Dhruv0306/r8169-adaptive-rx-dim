# Phase 5: Report and demo, results

Status: in progress (2026-11-18). The report, the demo script and its run sheet, and the series check script are written, and the clean-tree checks that do not need the PC are done. Still to do on the machines: the numbers check of the final build (`final-check`), two demo rehearsals, the fallback recording, and the tag. Rows marked **pending** below are filled in after those runs. Plan: [`../plans/plan-5-report-and-demo.md`](../plans/plan-5-report-and-demo.md).

## 1. What was delivered

| Item | Where | State |
|---|---|---|
| Final patch series | `patches/0001` to `0006` | No change from Phase 4 (no patch 0007); applies and builds on a clean `v7.2.15`, see section 2 |
| Series check script | `scripts/check_series.sh` | Written; run on a clean clone (section 2) |
| Report | `docs/report.md` | Written in Markdown from the Phase 0 to 4 results files and logs. Format asked by the course: **unknown**, see section 5 |
| Demo script and run sheet | `scripts/demo.sh`, `docs/demo.md` | Written, `bash -n` and `shellcheck -S warning` clean; not yet run on the machine (**pending**, section 4) |
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

**Pending.** Plan step 1 asks for a short run on the PC with the final build and a comparison with the Phase 4 final matrix:

```bash
bash scripts/rx_bench.sh -l final-check -p $PEER -w "rr udps" -n 3
```

Record here the srcversion of the module that was loaded (the frozen build is `04E8D19E5DCBE28E8305847`; if it differs, the series changed and the affected cells must be rerun), the three runs per cell, and whether they agree with `results/phase4/final/` within the spread.

## 4. Demo

Run sheet: [`../demo.md`](../demo.md). **Pending:** two full rehearsals on the machine at the console, the network setup check, and one recorded fallback session.

| Rehearsal | Date | Length chosen | Result |
|---|---|---|---|
| 1 | | | |
| 2 | | | |

Notes to fill in after the rehearsals (what failed, what was changed in the script, timing).

## 5. Open items

- The course requirements (report format and length, deadline, who watches the demo) are still unknown. The report is Markdown. If the course asks for a PDF, Word file or slides, make it from `docs/report.md`; the sections are ordered for that.
- `sparse` was never run on the series (Phase 3 and here).
- The `v1.0` tag and the final cleanup (`git status` clean, no stray files) wait for the rehearsals.

## 6. Repository state

Private repository `Dhruv0306/r8169-adaptive-rx-dim-private`, `main` includes Phase 4. Phase 5 work is on the branch `Dhruv_Patel/r8169-report-and-demo`. The shared repository `Dhruv0306/r8169-adaptive-rx-dim` stays at the end of Phase 3 and does not receive Phase 4 or 5 work.
