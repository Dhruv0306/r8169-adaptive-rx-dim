# Handoff: r8169 adaptive receive interrupt moderation

The state of the project as of 2026-11-11. It tells a newcomer (a new chat, or a new reader) what the project is, how the work is meant to be done, and where things stand. It is only for moving context between chats and is not a results log: what each phase did and found is in `docs/results/phase_<number>_<title>.md`, the phase summary is in `docs/phases.md`, and the detailed plan for each remaining phase is in `docs/plans/plan-<number>-<title>.md`. The original design is in `docs/plan.md`.

## 1. What this is

A course project for Advanced Operating Systems (CS G623): change an existing Linux device driver for real hardware. The driver is `r8169`, for the Realtek RTL8111/8168 Gigabit Ethernet controller in the project owner's PC (PCI `03:00.0`, chip RTL8168h).

The change adds an adaptive receive interrupt moderation mode, built on the kernel's DIM library, switched with `ethtool -C <dev> adaptive-rx on|off`. Before this work the driver could only be given fixed coalescing values by hand, and it starts with coalescing off.

## 2. State at a glance

| Item | State |
|---|---|
| Professor's decision | He reviewed the idea and replied that it looks good |
| Design | `docs/plan.md`, refined while writing the phase plans (section 3) |
| Source checked | Yes, against the `v7.2.15` tag (section 4) |
| Code written | Phase 1 patches 0001 and 0002 (Kconfig and state, ethtool flag with no hardware effect), applied to the PC's tree, built, signed and loaded |
| Planned series | 0003 counters and DIM sampling, 0004 level table and ethtool semantics (Phase 2); 0005 re-apply, link change, idle decay, teardown (Phase 3); 0006 tuned table (Phase 4, only if the table changes) |
| Measured | The Phase 0 baseline of four configurations on the real link; no adaptive code exists yet |
| Repository | https://github.com/Dhruv0306/r8169-adaptive-rx-dim |
| Phase results | `docs/results/phase_0_environment_and_baseline.md` (done), `docs/results/phase_1_plumbing.md` (done) |
| Plans for the remaining phases | `docs/plans/plan-2-adaptive-core.md`, `plan-3-robustness.md`, `plan-4-measurement-and-tuning.md`, `plan-5-report-and-demo.md` |
| Next | Phase 2: apply 0003 and 0004 on the PC and run tests T1 to T10 (`static-0us` check done, no difference) |

## 3. Intended behaviour (as refined in the phase plans)

- `select DIMLIB` in the `R8169` Kconfig entry; `struct rtl8169_private` holds a `struct dim`, an adaptive flag, driver-owned RX packet and byte counters, a poll-event counter and a mutex `rx_dim_lock`.
- An event is one call of `rtl8169_poll()`. `net_dim()` is called at the end of every poll that received packets (not only when `napi_complete_done()` succeeds, because at line rate the poll may not complete).
- DIM chooses one of five levels. The driver's table maps them to timer values in microseconds, first guess `{0, 40, 80, 200, 400}`, converted to timer units for the current link speed, timer-only (frame limit 0, `PktCntrDisable` set as in the stock timer-only path). Phase 4 tunes the table.
- The `INTT` unit bits are chosen once, on the ethtool path when adaptive mode is turned on, for the largest level. The work function does a read-modify-write of the RX bits of `IntrMitigate` only, takes only `rx_dim_lock` (never RTNL), and never writes `CPlusCmd`.
- The level is written again at the end of `rtl_hw_start()` (before `rtl_irq_enable()`), a separate work item recomputes the timer units after a link-speed change, a 200 ms delayed work sets the level to 0 when no polls happened (DIM never runs without packets), and the work items are cancelled in `rtl8169_down()` after `rtl8169_cleanup()`.
- ethtool: `ethtool -c` shows the live register value. Off to on saves the static RX settings and starts DIM at level 0; on to on ignores `rx-usecs` and `rx-frames` in the request (they are echoes of the live level); on to off restores the saved static RX settings. While adaptive is on a non-zero TX frame limit is refused.

## 4. What was checked in the 7.2.15 source

All of this was read from the `v7.2.15` tag of the stable tree, not from the machine. Line numbers refer to the unpatched file; patches 0001 and 0002 shift later lines.

| Finding | Where |
|---|---|
| Static coalescing only: `rtl_get_coalesce()` and `rtl_set_coalesce()`; no adaptive flag advertised | `r8169_main.c` lines 2088, 2149, 2420 |
| `IntrMitigate` layout: RX frames 3:0, RX timer 7:4, TX frames 11:8, TX timer 15:12; a frame field value `n` means `4n` frames | lines 304 to 312, 2192 to 2198 |
| Timer unit set by link speed and the `INTT` bits of `CPlusCmd`, shared by RX and TX; 8168-family unit at 1000 Mbit/s is 5, 40, 80 or 160 µs | lines 2042 to 2147 |
| The static path sets or clears `PktCntrDisable` (8168evl and newer) depending on frame limits, and requires a timer if a frame limit is set | `rtl_set_coalesce()` |
| RTL8125 chips return `-EOPNOTSUPP` from both coalescing functions | lines 2088 and 2149 |
| `rtl_hw_start_8168()` and `rtl_hw_start_8169()` write `IntrMitigate = 0` | lines 4083 and 4101 |
| One RX queue and one NAPI context; the poll function runs `rtl_tx()` and `rtl_rx()` then `napi_complete_done()` and `rtl_irq_enable()` | `rtl8169_poll()` |
| The interrupt handler disables interrupts and schedules NAPI | `rtl8169_interrupt()` |
| RX statistics are per-CPU (`dev_sw_netstats_rx_add()` in `rtl_rx()`), so the driver needs its own counters for DIM | `rtl_rx()` |
| The reset task (`rtl_task()`, `rtl_reset_work()`) does not take RTNL; ethtool operations run under it | `rtl_task()`, `rtl_reset_work()` |
| DIM API: `net_dim(struct dim *, const struct dim_sample *)`, `dim_update_sample()`, `net_dim_work_cancel()`, `DIM_START_MEASURE`, five profile levels | `include/linux/dim.h` |
| Reference integration to follow: `virtio_net.c` (`virtnet_rx_dim_update()` feeds the sample, `virtnet_rx_dim_work()` applies the level, `select DIMLIB`) | `drivers/net/virtio_net.c`, `drivers/net/Kconfig` |
| The library's default RX profiles are 2 to 64 µs with 64 to 256 packets, or 1 to 256 µs with the packet count taken from the event | `lib/dim/net_dim.c` |
| `rtl_hw_start()` writes `CPlusCmd = tp->cp_cmd` first, runs the chip-specific start (which zeroes `IntrMitigate`) and ends with `rtl_set_rx_mode()` and `rtl_irq_enable()`; it is reached through `rtl_reset_work()` from `rtl8169_up()` (RTNL held) and from `rtl_task()` (workqueue, no lock) | `rtl_hw_start()`, `rtl_reset_work()` |
| `rtl8169_down()` is shared by close and suspend; it runs `rtl8169_cleanup()` (NAPI disabled, interrupts masked). Reset causes: transmit timeout and PCI error | `rtl8169_down()`, `rtl8169_pcierr_interrupt()` |
| DIM runs its algorithm only once 64 events have passed (`DIM_NEVENTS`), compares bytes per ms, then packets per ms (10% counts), then events per ms (fewer is better), and moves one level at a time from a parked start at level 0 | `lib/dim/net_dim.c`, `lib/dim/dim.c` |

## 5. The machine and the workflow

Known from the earlier part of the course project and from the logs the owner supplied:

| Item | Value |
|---|---|
| Machine | A Lenovo desktop, Intel Alder Lake-S, user `aoscsg623` |
| NIC | Realtek RTL8111/8168/8211/8411, PCI revision 15, driver `r8169`, `03:00.0` |
| Running kernel | Custom `7.2.15-netquota`, built from `/usr/src/linux-7.2.15` (a tarball, not a git repository, `.config` present, identical to `/boot/config`). It includes the owner's network-quota system call patches |
| Kernel options seen | `CONFIG_DEBUG_FS=y`, `CONFIG_LOCKDEP=y`; `KMEMLEAK` is not set |
| `dmesg` | Needs root; use `su -` |
| Peer machine | Another machine on the same LAN over a gigabit link, running `iperf3 -s` and `netserver` for the benchmarks; ICMP is blocked on this network, so `ping` shows nothing |

The running kernel already contains the network-quota hooks, so the baseline and all later measurements are on the same kernel, which keeps comparisons fair. The hooks are not expected to affect this work.

Measured facts (chip RTL8168h/8111h, link speed, static coalescing support, `DIMLIB=y` with `r8169` a module, `MODULE_SIG_FORCE=y`) are recorded in `docs/results/phase_0_environment_and_baseline.md`.

What the baseline showed (details and tables in the Phase 0 results file): the Phase 1 module with adaptive off matches the stock module; bulk TCP at 941 Mbit/s takes only about 2 interrupts per second, so there is almost nothing to moderate; request-response takes 2 interrupts per transaction and any static timer only adds latency (+42 microseconds for 50, +187 for 200); UDP shows fewer NET_RX softirqs with a timer and no loss either way. The all-CPU busy figure was too noisy to use, so later runs use per-CPU columns. A small or negative gain is therefore a likely outcome and is acceptable.

Conventions carried over from the other kernel projects:

- **Branches:** `Dhruv_Patel/<feature or fix name>`; keep merged branches.
- **Authorship:** commits and patches have Dhruv Rakeshbhai Patel as author and `Co-authored-by: Claude <noreply@anthropic.com>` as a trailer, never Claude as author.
- **SPDX headers:** every new source file starts with `// SPDX-License-Identifier: GPL-2.0-only` (new `.c` and `.h` files), or `# SPDX-License-Identifier: GPL-2.0-only` as the first line after the shebang for Python and shell scripts. This applies to new files only; the existing driver file keeps its header.
- **Results and handoff:** each phase's results go in `docs/results/phase_<number>_<title>.md`; this file is only for context transfer between chats.
- **Delivery:** kernel changes are exchanged as `git format-patch` files; the kernel tree on the PC is not a git repository, so they are applied there with `patch -p1` (dry run first). Patches that only update the project repository (docs, scripts, results) are throwaway: plain files, no separate folder, applied with `git am` from the repository root with explicit file names, then deleted. They are not part of the `patches/` series.

## 6. How to build, sign, load and test (proven in Phase 1)

On the PC, as root, at the console. The recipe with the exact outputs is in `docs/results/phase_1_plumbing.md`.

```bash
cd /usr/src/linux-7.2.15
patch -p1 --dry-run < <patch>      # then without --dry-run
make M=drivers/net/ethernet/realtek modules W=1 2>&1 | tee ~/r8169-build.log
modinfo -F vermagic drivers/net/ethernet/realtek/r8169.ko     # must match `uname -r`
cp drivers/net/ethernet/realtek/r8169.ko /root/r8169-new-signed.ko
scripts/sign-file sha512 certs/signing_key.pem certs/signing_key.x509 /root/r8169-new-signed.ko
rmmod r8169 && insmod /root/r8169-new-signed.ko
```

The way back to the stock module is `rmmod r8169; modprobe r8169`. The benchmarks are described in the Phase 0 results (`scripts/rx_bench.sh`, `scripts/summarize_results.py`, `scripts/read_intrmit.sh`). Phase 2 adds `scripts/build_sign_load.sh` and `scripts/sample_level.sh`.

## 7. Open items and next steps

1. Phase 2 (`docs/plans/plan-2-adaptive-core.md`): the `static-0us` check is done (no difference, see the Phase 2 results); apply patches 0003 and 0004 on a branch `Dhruv_Patel/<name>` and run the tests.
2. Phase 3, 4 and 5 follow their plans. Rerun `stock` in Phase 4 with the updated benchmark script so every label has the per-CPU columns.
3. Not known yet: the course deadline and the required format of the report and demo (Phase 5), and the peer machine's kernel and NIC, which the meta files do not record.

## 8. Decisions and why

- The professor first asked for changes to existing drivers, then recommended a driver from scratch. After the owner sent him two options, he chose the `i2c-i801` statistics project, and when the owner proposed this idea as something new he said it looks good. The `i2c-i801` work has its own repository, `https://github.com/Dhruv0306/i2c-i801-adaptive-trace`, and stays available as a fallback.
- Use the existing DIM library, not a hand-written algorithm: it is the kernel's established mechanism, other drivers (for example `virtio_net`) show the pattern, and it keeps the change small.
- RX only: it keeps the first version small, and the receive fields of `IntrMitigate` can be changed without touching the TX fields.
- The work function writes only `IntrMitigate`, so it does not become another writer of `CPlusCmd` next to the ethtool and reset paths. For the same reason the `INTT` bits are chosen on the ethtool path only and kept across a link-speed change (the steps get coarser or finer until adaptive mode is turned off and on again).
- Timer-only levels: the hardware needs a timer whenever a frame limit is set, and the stock timer-only path runs with `PktCntrDisable` set (confirmed on the hardware). A frame limit is added only if measurements show a need.
- Own five-level table: the library's default values assume much larger counts than this hardware's 4-bit fields can hold.
- Events are poll calls and DIM is called on every poll, not only at completion, so it still runs at line rate.
- A mutex and the lock order RTNL, PHY lock, `rx_dim_lock`, so the work can be cancelled under RTNL without a deadlock (same pattern as `virtio_net`).
- Idle decay is needed because DIM is driven only by polls: after a burst the level would stay high and delay the first packets of sparse traffic.
- Phase 2 is split into two patches (counters and a logging work function first, hardware writes second) so DIM's behaviour is visible before any register is touched.
- Report any result, including a small or negative gain. The baseline shows NAPI already keeps interrupts very low under bulk load, so a large gain is not expected.

## 9. Known limitations

- The hardware timer is only 4 bits wide and its unit is shared by RX and TX, so the five levels are a rough fit.
- RTL8125 (2.5G) chips are not supported by the driver's coalescing code and are out of scope.
- Results depend on the chip variant of this machine, one peer and one link speed, and are not generalized.
- The hardware start path clears `IntrMitigate`, so after a reset or resume the level must be written again by the new code.

## 10. Gotchas

- The NIC is the machine's only network connection. Do not run tests over a network session into the same machine, and keep a console or phone tether ready. Always keep a copy of the stock `r8169` module.
- `ethtool -C` merges the new setting with the current ones, so values from an earlier command carry over (a leftover `rx-frames 8` keeps a frame limit). It treats `rx-frames 1` as "no frame limit"; the stock driver uses this convention when reading values back.
- The module will not load if the kernel tree is not the one that built the running kernel.
- The running kernel enforces module signatures (`CONFIG_MODULE_SIG_FORCE=y`): a rebuilt `r8169.ko` must be signed with the key in `/usr/src/linux-7.2.15/certs/` before `insmod`. Never copy `certs/signing_key.pem` out of the tree.
- Moving files between Windows and Linux can turn line endings into CRLF, which breaks `patch`. Use `git clone` or `git pull` on the Linux machine. The `.gitattributes` file (renamed from a misspelt name) enforces LF for sources, scripts and patches.
- `dmesg` is restricted for a normal user on this machine; use `su -`. `sudo` needs the password. In a root shell `~` is `/root`, so use the full path `/home/aoscsg623/Downloads/r8169-adaptive-rx-dim`.
- `ping` gets no replies on this network while TCP works, so latency probes must use TCP or UDP.
- The NIC's interrupt is 135 (MSI-X, row `enp3s0` in `/proc/interrupts`). `/sys/class/net/enp3s0/device/irq` says 18, which is wrong for counting NIC interrupts; `scripts/rx_bench.sh` finds the right row by device name.
- `scripts/rx_bench.sh` runs as root from the repository root, one label per configuration, and refuses to append to a CSV written with an older column layout (the baseline files use the older layout). `scripts/summarize_results.py` reads both layouts.
- In PowerShell, `git am` does not expand `*`; give the patch file names explicitly.
