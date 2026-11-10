# Phase 0: Environment and baseline

Status: in progress (started 2026-11-10). The machine checks, the source reading and the register check are done. The stock-driver baseline is blocked: no second machine is available yet.

Plan: [`../phases.md`](../phases.md), Phase 0.

## Task status

| # | Task | State |
|---|---|---|
| 1 | Identify the chip and link | Done |
| 2 | Check that static coalescing works on this chip | Done |
| 3 | Check the kernel configuration | Done |
| 4 | Back up the stock module | Done |
| 5 | Check the build path | Done with the Phase 1 patched tree; an unmodified-tree build was not run separately |
| 6 | Arrange the second machine | Open: none available on 2026-11-10 |
| 7 | Create the repository | Done: https://github.com/Dhruv0306/r8169-adaptive-rx-dim |
| 8 | Baseline for the stock driver | Blocked on task 6; the benchmark script is written and its no-peer test has run (below) |
| 9 | Read `rtl_set_coalesce()` for the `PktCntrDisable` question | Done: source reading and register check (below) |

## Facts recorded

| Item | Value |
|---|---|
| Chip | RTL8168h/8111h, XID 541, PCI revision 15 (`10ec:8168`), at `03:00.0` |
| Firmware | `rtl8168h-2_0.0.2 02/26/15` |
| Interface | `enp3s0`, link 1000 Mbit/s full duplex |
| Driver | `r8169`, version string `7.2.15-netquota` |
| Kernel | `7.2.15-netquota`, tree `/usr/src/linux-7.2.15` |
| `CONFIG_R8169` | `m` |
| `CONFIG_DIMLIB` | `y` (built in, so no kernel rebuild is needed) |
| `CONFIG_MODULE_SIG_FORCE` | `y`, hash `sha512`, key `certs/signing_key.pem` |
| `CONFIG_LOCKDEP` | `y` |
| Stock module | Uncompressed, `/lib/modules/7.2.15-netquota/kernel/drivers/net/ethernet/realtek/r8169.ko` |
| Backups | Stock `r8169.ko`, `Kconfig` and `r8169_main.c` in root's `~/r8169-stock-src/` |
| Static coalescing | Accepted. `ethtool -C enp3s0 rx-usecs 50` reads back as `rx-usecs 50` with `rx-frames 0`. `rx-usecs 0` restores `rx-usecs 0` and `rx-frames 1` (the "1 means no frame limit" convention). TX stayed at `tx-usecs 0`, `tx-frames 1` |

## What the v7.2.15 source says about timer-only operation

Read from the unpatched `r8169_main.c` of `v7.2.15` (line numbers refer to that file).

- **This chip takes the `PktCntrDisable` branch.** XID 541 maps to `RTL_GIGA_MAC_VER_46` (line 140), and `rtl_is_8168evl_up()` (line 871) is true for versions 34 to 52 except 39.
- **Static path.** `rtl_set_coalesce()` (lines 2202 to 2212) sets `PktCntrDisable` in `tp->cp_cmd` when both frame limits are zero, and clears it when either is set. Timer-only is exactly the "both zero" case, so the stock driver's own timer-only configuration runs with `PktCntrDisable` set. The code does not say what the hardware would do with timer-only and the bit clear, so the adaptive mode should copy the stock configuration and keep the bit set.
- **Where the bit lives.** At probe, `tp->cp_cmd = RTL_R16(CPlusCmd) & CPCMD_MASK` (line 5698). The mask does not include `PktCntrDisable`, so the bit starts cleared. `rtl_hw_start()` writes `CPlusCmd = tp->cp_cmd` before `rtl_hw_start_8168()` zeroes `IntrMitigate` (lines 4083 and 4109). After a first `ethtool -C` that leaves no frame limit (which includes every `rx-usecs 0` test run so far), the bit and the `INTT` unit bits stay in `tp->cp_cmd` and are written back on every hardware start.
- **Consequence for Phase 2 and 3.** After a hardware start only `IntrMitigate` is lost, so the re-apply step only has to write that register, which matches the rule that the work function never writes `CPlusCmd`. The `INTT` unit depends on link speed, so it must be chosen again on a speed change.
- **Timer unit on this chip.** `rtl_coalesce_info_8168_8136` at 1000 Mbit/s gives 5, 40, 80 or 160 microseconds (`INTT` 0 to 3). `rtl_coalesce_choose_scale()` picks the smallest unit whose largest timer (15 units) covers the request. The timer field is therefore at most 75, 600, 1200 or 2400 microseconds. This matches the earlier readback: `rx-usecs 50` fits the 5 microsecond unit and reads back as 50.
- **Side effect on the running machine.** Because of the `PktCntrDisable` rule above, the machine is no longer in its freshly booted state (bit clear) once any `ethtool -C` has been run. A reboot or `rmmod` and `modprobe` returns it to that state.

### Register check (run 2026-11-10)

`scripts/read_intrmit.sh` decodes `CPlusCmd` (0xe0) and `IntrMitigate` (0xe2) from `ethtool -d`. The four settings were applied in this order, each read back from the hardware:

| Setting applied | `CPlusCmd` | `PktCntrDisable` | `INTT` | `IntrMitigate` | Matches the source |
|---|---|---|---|---|---|
| `rx-usecs 0 rx-frames 1` | `0x20e0` | 1 | 0 | `0x0000` | Yes |
| `rx-usecs 50` | `0x20e0` | 1 | 0 | `0x00a0` (RX timer 10) | Yes |
| `rx-usecs 50 rx-frames 8` | `0x2060` | 0 | 0 | `0x00a2` (RX timer 10, frames field 2) | Yes |
| `rx-usecs 100` | `0x2061` | 0 | 1 (40 microseconds) | `0x0032` (RX timer 3, frames field 2) | Yes, see below |

The fourth row differs from the value first predicted (`PktCntrDisable` 1, `IntrMitigate` `0x0030`), and the prediction was wrong, not the driver: `ethtool -C` merges the new setting with the current ones, so `rx-frames 8` from the previous step was still in force. A frame limit set means `PktCntrDisable` is cleared and the frames field stays 2, which is what the registers show. The timer part is as predicted: 100 microseconds does not fit the 5 microsecond unit (75 microseconds at most), so the 40 microsecond unit (`INTT` 1) is chosen and the timer is 3. The settings were put back with `rx-usecs 0 rx-frames 1` afterwards.

This confirms on the real hardware that a timer-only setting runs with `PktCntrDisable` set, that a frame limit clears it, that the timer unit follows the requested time, and that `read_intrmit.sh` decodes the registers correctly. The Phase 2 and 3 design can rely on all four.

## Scripts added

- `scripts/read_intrmit.sh`: prints the live moderation state from the registers. Reused later for the stepped-load demo.
- `scripts/rx_bench.sh`: receive-side benchmark for the baseline and later runs. Peer sends to this machine (`iperf3 -R`, `netperf TCP_RR`); records NIC interrupts per second, NET_RX softirqs per second and CPU busy percentage per run, plus the workload result, in `results/baseline/<label>/summary.csv`. TCP and UDP latency probes avoid ICMP. Tested here only for the idle workload, the register decoding and the result parsers; the `iperf3` and `netperf` runs and their selectors still have to be confirmed on the first real run, which needs the peer.

### No-peer test of `rx_bench.sh` (run 2026-11-10)

Command: `bash scripts/rx_bench.sh -l idle-test -w idle -n 2 -t 10 -o /tmp/rxtest`, as root on the machine under test.

| Run | Seconds | `irq_per_s` | `net_rx_softirq_per_s` | `cpu_busy_pct` | Status |
|---|---|---|---|---|---|
| 1 | 10.01 | 0 | 70 | 3.2 | ok |
| 2 | 10.01 | 0 | 71 | 1.5 | ok |

The script runs end to end and writes `summary.csv` and the meta file. The numbers are **not yet trustworthy as an interrupt measurement**, for two reasons found while reading them:

- The interrupt rate was printed with no decimals, so any rate below 0.5 per second shows as 0. On an idle network with about one packet per second that is a plausible result and also hides the real value.
- The script took the interrupt number from sysfs and, if that number had matched no row of `/proc/interrupts`, it would silently report 0.

Both were fixed afterwards: the two rates now print with one decimal, and the script stops with an error if the interrupt number is not in `/proc/interrupts`. The meta file now also records the matching `/proc/interrupts` row. The idle test has to be repeated with the fixed script. The 70 NET_RX softirqs per second at idle are not from the NIC alone, since local traffic and other sources also raise that softirq.

## Observations

- **ICMP does not work on this network.** `ping` to the gateway and to `8.8.8.8` got no replies, while the gateway answered ARP (`REACHABLE`) and `curl https://example.com` returned HTTP 200. The idle-latency workload in `plan.md` section 5.3 must therefore use a TCP or UDP probe (for example `netperf` TCP_RR or `sockperf`).
- **Receive drops.** `ip -s link` showed `RX dropped 12` out of 922 packets, with no errors and no missed packets. Not yet compared with the stock driver; check it during the baseline.
- **Taint line.** `dmesg` reports `loading out-of-tree module taints kernel` when the rebuilt module loads. This is expected and does not disable lockdep.
- **Stock `ethtool -c` was not captured** before the module swap, so there is no stock output to diff against yet. It can be captured with `rmmod r8169; modprobe r8169` at the start of the baseline.

## Open items

1. Second machine: none is available yet (2026-11-10). It needs to run `iperf3 -s` and `netserver`, on a direct cable or the same network. Options and their limits are to be settled before the baseline.
2. Baseline for the stock driver: the "Stock" row of the measurement matrix (`plan.md` section 5), raw logs in `results/baseline/`. Blocked on item 1.
3. Repeat the idle test with the fixed `rx_bench.sh` and confirm the interrupt count reads the NIC (the rate must rise when something is downloaded during the run).
