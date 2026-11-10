# Handoff: r8169 adaptive receive interrupt moderation

The state of the project as of 2026-11-10. It tells a newcomer (a new chat, or a new reader) what the project is, how the work is meant to be done, and where things stand. It is only for moving context between chats and is not a results log: what each phase did and found is in `docs/results/phase_<number>_<title>.md`, and the phase plan is in `docs/phases.md`. The design is in `plan.md`.

## 1. What this is

A course project for Advanced Operating Systems (CS G623): change an existing Linux device driver for real hardware. The driver is `r8169`, for the Realtek RTL8111/8168 Gigabit Ethernet controller in the project owner's PC (PCI `03:00.0`).

The change adds an adaptive receive interrupt moderation mode, built on the kernel's DIM library, switched with `ethtool -C <dev> adaptive-rx on|off`. At present the driver can only be given fixed coalescing values by hand, and it starts with coalescing off.

## 2. State at a glance

| Item | State |
|---|---|
| Professor's decision | He reviewed the idea and replied that it looks good |
| Design | Written, in `plan.md` |
| Source checked | Yes, against the `v7.2.15` tag (section 4) |
| Code written | Phase 1 patches 0001 and 0002 |
| Built | Phase 1 module, loaded on the test machine |
| Tested or measured | Phase 1 functional checks only; nothing measured |
| Repository | https://github.com/Dhruv0306/r8169-adaptive-rx-dim |
| Phase results | `docs/results/phase_0_environment_and_baseline.md` (in progress), `docs/results/phase_1_plumbing.md` (done) |

## 3. Intended behaviour

Short version; the full design is in `plan.md` section 4.

- `select DIMLIB` is added to the `R8169` Kconfig entry. `struct rtl8169_private` gets a `struct dim`, an adaptive flag and driver-owned RX packet and byte counters.
- `rtl8169_poll()` builds a sample after `rtl_rx()` and calls `net_dim()` when adaptive mode is on. DIM chooses one of five levels. The driver's work function turns the level into a timer value and writes it to `IntrMitigate`.
- The first version uses timer-only levels (frame limit 0), with a driver-supplied five-level table because the library's default values do not fit this hardware.
- The work function writes only `IntrMitigate`. The timer unit is chosen on the ethtool path and again on a link change. The current level is written again after every hardware start, because the start path zeroes the register.
- `ethtool -c` reads the register back, so it shows the live level while DIM runs.

## 4. What was checked in the 7.2.15 source

All of this was read from the `v7.2.15` tag of the stable tree, not from the machine.

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

## 5. The machine and the workflow

Known from the earlier part of the course project and from the logs the owner supplied:

| Item | Value |
|---|---|
| Machine | A Lenovo desktop, Intel Alder Lake-S, user `aoscsg623` |
| NIC | Realtek RTL8111/8168/8211/8411, PCI revision 15, driver `r8169`, `03:00.0` |
| Running kernel | Custom `7.2.15-netquota`, built from `/usr/src/linux-7.2.15` (a tarball, not a git repository, `.config` present, identical to `/boot/config`). It includes the owner's network-quota system call patches |
| Kernel options seen | `CONFIG_DEBUG_FS=y`, `CONFIG_LOCKDEP=y`; `KMEMLEAK` is not set |
| `dmesg` | Needs root; use `su -` |

The running kernel already contains the network-quota hooks, so the baseline and all later measurements are on the same kernel, which keeps comparisons fair. The hooks are not expected to affect this work.

Measured facts (chip RTL8168h/8111h, link speed, static coalescing support, `DIMLIB=y` with `r8169` a module, `MODULE_SIG_FORCE=y`) are recorded in `docs/results/phase_0_environment_and_baseline.md`.

Still open: no second machine for `iperf3` and `netperf` is available yet (as of 2026-11-10), so the stock-driver baseline is blocked.

Conventions carried over from the other kernel projects:

- **Branches:** `Dhruv_Patel/<feature or fix name>`; keep merged branches.
- **Authorship:** commits and patches have Dhruv Rakeshbhai Patel as author and `Co-authored-by: Claude <noreply@anthropic.com>` as a trailer, never Claude as author.
- **SPDX headers:** every new source file starts with `// SPDX-License-Identifier: GPL-2.0-only` (new `.c` and `.h` files), or `# SPDX-License-Identifier: GPL-2.0-only` as the first line after the shebang for Python and shell scripts. This applies to new files only; the existing driver file keeps its header.
- **Results and handoff:** each phase's results go in `docs/results/phase_<number>_<title>.md`; this file is only for context transfer between chats.
- **Delivery:** changes are exchanged as `git format-patch` files and applied with `git am`. The kernel tree is not a git repository, so patches are applied there with `patch -p1`.

## 6. How to build and test (proposed, not yet run)

These commands are a proposal. None of them has been run for this project, and the paths are assumptions.

```bash
cd /usr/src/linux-7.2.15
grep -E 'CONFIG_DIMLIB|CONFIG_R8169' .config
make modules_prepare
make M=drivers/net/ethernet/realtek modules      # builds r8169 and its neighbours
modinfo -F vermagic drivers/net/ethernet/realtek/r8169.ko   # must match `uname -r`
```

Before the first load, copy the installed stock module somewhere safe, for example from `/lib/modules/$(uname -r)/kernel/drivers/net/ethernet/realtek/` (the file may be compressed). To test:

```bash
sudo rmmod r8169 && sudo insmod drivers/net/ethernet/realtek/r8169.ko
ethtool -c <dev>
sudo ethtool -C <dev> adaptive-rx on
```

If `CONFIG_DIMLIB` is off in the running kernel, the new module cannot be loaded until the library is built too. If it is a module (`dimlib.ko`) it has to be built and loaded first; if it is not enabled at all, the kernel configuration has to change and the kernel rebuilt.

## 7. Open items and next steps

1. Finish Phase 0 (see its results file): second machine, stock baseline, the `PktCntrDisable` reading.
2. Arrange the second machine and the measurement tools.
3. Take the baseline for the stock driver (the measurement matrix in `plan.md` section 5).
4. The repository exists; create the first working branch when Phase 2 starts.
5. Decide the open design choices: the five-level table and timer unit, whether a frame limit is needed, whether timer-only operation needs `PktCntrDisable` set, and the locking between the DIM work, the ethtool path and the reset task.
6. Implement in the phase order of `plan.md` section 8.

## 8. Decisions and why

- The professor first asked for changes to existing drivers, then recommended a driver from scratch. After the owner sent him two options, he chose the `i2c-i801` statistics project, and when the owner proposed this idea as something new he said it looks good. The `i2c-i801` work has its own repository, `https://github.com/Dhruv0306/i2c-i801-adaptive-trace`, and stays available as a fallback.
- Use the existing DIM library, not a hand-written algorithm: it is the kernel's established mechanism, other drivers (for example `virtio_net`) show the pattern, and it keeps the change small.
- RX only: it keeps the first version small, and the receive fields of `IntrMitigate` can be changed without touching the TX fields.
- The work function writes only `IntrMitigate`, so it does not become a third writer of `CPlusCmd` next to the ethtool and reset paths.
- Timer-only levels first: the hardware needs a timer whenever a frame limit is set, and frame limits bring in the `PktCntrDisable` handling. A frame limit is added only if measurements show a need.
- Own five-level table: the library's default values assume much larger counts than this hardware's 4-bit fields can hold.
- Report any result, including a small or negative gain. NAPI already reduces interrupts under load, so the benefit on a fast CPU may be modest, and the project is about measuring it properly.

## 9. Known limitations

- The hardware timer is only 4 bits wide and its unit is shared by RX and TX, so the five levels are a rough fit.
- RTL8125 (2.5G) chips are not supported by the driver's coalescing code and are out of scope.
- Results depend on the chip variant of this machine and are not generalized to others.
- The hardware start path clears coalescing, so after a reset or resume the level must be written again by the new code.

## 10. Gotchas

- The NIC is the machine's only network connection. Do not run tests over a network session into the same machine, and keep a console or phone tether ready. Always keep a copy of the stock `r8169` module.
- `ethtool -C` treats `rx-frames 1` as "no frame limit"; the stock driver uses this convention when reading values back.
- The module will not load if the kernel tree is not the one that built the running kernel (section 6).
- Moving files between Windows and Linux can turn line endings into CRLF, which breaks `patch`. Use `git clone` or `git pull` on the Linux machine.
- `dmesg` is restricted for a normal user on this machine; use `su -`. `sudo` needs the password.
- The running kernel enforces module signatures (`CONFIG_MODULE_SIG_FORCE=y`): a rebuilt `r8169.ko` must be signed with the key in `/usr/src/linux-7.2.15/certs/` before `insmod`. The recipe is in `docs/results/phase_1_plumbing.md`.
- `ping` gets no replies on this network while TCP works, so latency probes must use TCP or UDP.
- The NIC's interrupt is 135 (MSI-X, row `enp3s0` in `/proc/interrupts`). `/sys/class/net/enp3s0/device/irq` says 18, which is wrong for counting NIC interrupts; `scripts/rx_bench.sh` finds the right row by device name.