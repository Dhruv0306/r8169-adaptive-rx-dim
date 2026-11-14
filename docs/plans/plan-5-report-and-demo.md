# Plan for Phase 5: Report and demo

Status: not started. Depends on Phase 4 (frozen table, final data). High-level summary: [`../phases.md`](../phases.md), Phase 5. Results go in `docs/results/phase_5_report_and_demo.md`.

Machine tags: **[Claude]** work in the chat, **[PC]** machine under test (root, at the console), **[PEER]** second machine, **[repo]** project repository.

## 1. Goal and scope

Package the work so it can be read, reproduced and shown: the final patch series checked on a clean tree, the report, a rehearsed demo on the real machine, and a tidy repository.

No new features and no new measurements, except re-measuring if the final series differs from the build that was measured in Phase 4. Whatever the report states must come from the final code.

## 2. Inputs

- Final patches 0001 to 0007 (0007 only if tuning changed the table), built and measured in Phase 4.
- `docs/results/phase_0` to `phase_4`, `docs/locking.md`, raw logs in `results/`.
- The course requirements for the report and the demo (format, length, date, who watches the demo). These are not known yet; ask the professor or read the course page before step 2.

## 3. Work steps

1. **[Claude] Final patch series check on a clean tree.**
   - **[PC]** make a clean working copy of the kernel: `git clone --depth 1 --branch v7.2.15 https://github.com/gregkh/linux.git ~/linux-r8169-clean` (about 1 GB; once).
   - Apply the series with `git am` (or `patch -p1` if the files are plain patches) and add `Signed-off-by` with `git rebase -x 'git commit --amend --no-edit -s' <base>`.
   - Run `perl scripts/checkpatch.pl --strict -g HEAD~N..HEAD` (with the tree, now that it is a git tree), `make W=1`, and `sparse` if installed.
   - Build in the real build tree (`/usr/src/linux-7.2.15`) by copying the two changed files over or applying the series with `patch -p1` on a fresh copy of the two files, sign, load, and run a short check: `bash scripts/rx_bench.sh -l final-check -p $PEER -w "rr udp" -n 3`. The numbers must agree with the Phase 4 final matrix within the spread. If they do not, rerun the affected cells and report.
2. **[Repo]** Copy the final series into `patches/` (replace the Phase 1 names if the commit messages changed), keep the numbering, and check that `patch -p1 --dry-run` succeeds on pristine copies of the two files.
3. **[Claude] Write the report** (`docs/report.md`, and a PDF or Word copy if the course asks; the format question of section 2 decides). Outline:

   | Section | Content |
   |---|---|
   | Summary | Goal, what was built, the main numbers, the conclusion in plain words |
   | Background | The r8169 receive path, NAPI, the `IntrMitigate` register, what DIM does |
   | Design | Decisions D1 to D9 of Phase 2 and D1 to D7 of Phase 3, and why |
   | Implementation | The patch series, file by file |
   | Locking | Condensed from `docs/locking.md` |
   | Method | Machines, tools, configurations, workloads, runs, metrics (and why the all-CPU busy figure was dropped) |
   | Results | The tables and figures of Phase 4, the baseline, the stepped-load figure |
   | Discussion | Where adaptive moderation helps, where it does not, why bulk TCP leaves nothing to win, the latency cost of static timers, limits |
   | Limitations | One chip variant, one peer, one link speed, 1 Gbit/s, powersave governor, number of runs |
   | Conclusion and future work | RTL8125, TX moderation, tuning per CPU, upstream submission would need review |
   | Appendix | Commands to reproduce, repository layout, raw-data folders |

4. **[Claude] Demo script** `scripts/demo.sh`, a stepped load with the level shown live, and a short written run sheet `docs/demo.md`:
   - Show the stock module state (`Adaptive RX: n/a`), then the final module with adaptive off.
   - `ethtool -C enp3s0 adaptive-rx on`, and a terminal running `scripts/sample_level.sh` (or `watch -n 0.2 bash scripts/read_intrmit.sh enp3s0`).
   - On the PEER the audience sees the load start (`iperf3` UDP burst), the level rise, the load stop and the level fall.
   - Show request-response staying at level 0 (`netperf` TCP_RR) and the numbers next to the static timers.
   - Keep to the time the course allows; prepare a version of about 3 minutes and one of 10.
5. **[PC] and [PEER] Rehearse the demo twice** at the console, as it will be shown. Check the network setup (cable or LAN), the signed module, the servers on the PEER and the phone tether. Record a terminal session as a fallback (for example `script` or `asciinema`) and keep screenshots of the stepped-load figure.
6. **[Repo] Tidy and tag.** Final README (status, results, how to reproduce), `docs/` in sync, handoff updated, tracker complete, no stray files (`git status`), all merged branches kept (`Dhruv_Patel/<name>`), then tag the repository: `git tag -a v1.0 -m "Adaptive RX moderation for r8169, final"` and push the tag.
7. **[Claude] Final results file** `docs/results/phase_5_report_and_demo.md`: what was delivered, the checks run on the clean tree, the rehearsal notes, anything left out and why.

## 4. Tests and checks

| Check | How | Expected |
|---|---|---|
| Series applies on pristine files | `patch -p1 --dry-run` per patch, in order, on fresh copies of `r8169_main.c` and `Kconfig` | All clean |
| Series builds | `make M=drivers/net/ethernet/realtek modules W=1` on the clean working tree | No warning from `r8169_main.c` |
| Style | `checkpatch.pl --strict -g` over the series | Clean apart from items explained in the report |
| Module loads and behaves | Load signed copy; `T1` to `T3` of Phase 2 and `F4` of Phase 3 once more | All pass |
| Numbers match | `final-check` run against Phase 4 | Within the spread |
| Report matches logs | Spot check five numbers against `summary.csv` | Identical |
| Demo | Two full rehearsals on the real machine | Runs end to end without edits |
| Repository | Fresh `git clone` of GitHub, then follow the README to rebuild the tables with `scripts/summarize_results.py` | Works |

## 5. Acceptance criteria

- The patch series is complete, signed off, checked, and applies on `v7.2.15`.
- The report exists in the format the course asks for and every number in it can be traced to a raw log in the repository.
- The demo runs on the real machine and a fallback recording exists.
- The repository is tagged, tidy and reproducible from a fresh clone.
- Negative or small results are reported as they are, with the reasons.

## 6. Risks and fallbacks

| Risk | Fallback |
|---|---|
| A late bug is found in the final build | Fix it, rerun the affected cells, and say so in the report; do not report numbers from an older build |
| The demo fails in front of the audience (network, module, signing) | Fallback recording and the stepped-load figure; keep the stock module backup and the tether ready |
| The course format asks for something the plan lacks (slides, a paper template) | Make a slide deck or a formatted document from `docs/report.md`; the content is already structured for it |
| Time is short | Cut order: optional figures first, then discussion length; never cut the limitations, the method or the raw data |

## 7. Results file outline (`docs/results/phase_5_report_and_demo.md`)

Status and date; the final patch list with the checks run; the clean-tree build log summary; the final check numbers; report and demo status (formats, where the files are); rehearsal notes; repository state (tag, branches); remaining known issues and ideas for future work.
