# Phase 0: Environment and baseline

Status: in progress (started 2026-11-10). The machine checks are done; the second machine, the stock-driver baseline and the `PktCntrDisable` reading are open.

Plan: [`../phases.md`](../phases.md), Phase 0.

## Task status

| # | Task | State |
|---|---|---|
| 1 | Identify the chip and link | Done |
| 2 | Check that static coalescing works on this chip | Done |
| 3 | Check the kernel configuration | Done |
| 4 | Back up the stock module | Done |
| 5 | Check the build path | Done with the Phase 1 patched tree; an unmodified-tree build was not run separately |
| 6 | Arrange the second machine | Open |
| 7 | Create the repository | Done: https://github.com/Dhruv0306/r8169-adaptive-rx-dim |
| 8 | Baseline for the stock driver | Open |
| 9 | Read `rtl_set_coalesce()` for the `PktCntrDisable` question | Open |

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

## Observations

- **ICMP does not work on this network.** `ping` to the gateway and to `8.8.8.8` got no replies, while the gateway answered ARP (`REACHABLE`) and `curl https://example.com` returned HTTP 200. The idle-latency workload in `plan.md` section 5.3 must therefore use a TCP or UDP probe (for example `netperf` TCP_RR or `sockperf`).
- **Receive drops.** `ip -s link` showed `RX dropped 12` out of 922 packets, with no errors and no missed packets. Not yet compared with the stock driver; check it during the baseline.
- **Taint line.** `dmesg` reports `loading out-of-tree module taints kernel` when the rebuilt module loads. This is expected and does not disable lockdep.
- **Stock `ethtool -c` was not captured** before the module swap, so there is no stock output to diff against yet. It can be captured with `rmmod r8169; modprobe r8169` at the start of the baseline.

## Open items

1. Second machine: is one available, and how does it connect (a direct cable or the same network)? Which of `iperf3`, `netperf` and `sockperf` are installed?
2. Baseline for the stock driver: the "Stock" row of the measurement matrix (`plan.md` section 5), raw logs in `results/baseline/`.
3. Read `rtl_set_coalesce()` and the hardware start code to settle whether timer-only operation needs `PktCntrDisable`. The chip is newer than 8168evl, so the `PktCntrDisable` branch probably applies; confirm with line numbers.
