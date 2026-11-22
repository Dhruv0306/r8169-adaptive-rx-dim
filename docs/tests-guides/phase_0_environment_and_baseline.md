# Phase 0 test guide: environment and baseline

All checks and measurements of Phase 0, in the order they were run, with the commands, the expected outcome and what was observed. Results and discussion: [`../results/phase_0_environment_and_baseline.md`](../results/phase_0_environment_and_baseline.md). Plan: [`../phases.md`](../phases.md), Phase 0. General setup: [`../setup-and-testing.md`](../setup-and-testing.md).

Phase 0 has no numbered tests. The checks below use the labels P0-A to P0-J so later documents can refer to them.

## Conditions

- Machine under test: RTL8168h/8111h (XID 541, `10ec:8168`), interface `enp3s0`, kernel `7.2.15-netquota`, 20 CPUs, governor `powersave`, `irqbalance` running (NIC interrupt on CPU 7).
- Peer: a second machine on the same gigabit LAN, `iperf3` 3.16 and `netperf` 2.7.0 servers running (`iperf3 -s`, `netserver`).
- Run as root at the console. The NIC is the only connection, so do not take the link down while another session depends on it.
- ICMP does not work on this network. Never use `ping` as a test; use TCP or UDP.

## Tests and checks

| ID | Check | Command or action | Expected | Observed | Status |
|---|---|---|---|---|---|
| P0-A | Chip and link | `lspci -nn`, `ethtool -i enp3s0`, `ethtool enp3s0` | `r8169`, 1000 Mbit/s full duplex | RTL8168h XID 541, link 1000 full | Pass |
| P0-B | Static coalescing works | `ethtool -C enp3s0 rx-usecs 50`, `ethtool -c`, then `rx-usecs 0` | `rx-usecs 50`, `rx-frames 0`; after `rx-usecs 0` back to `rx-usecs 0`, `rx-frames 1`; TX unchanged | As expected | Pass |
| P0-C | Kernel configuration | `zcat /proc/config.gz \| grep -E 'CONFIG_(R8169\|DIMLIB\|MODULE_SIG_FORCE\|LOCKDEP)='` | `R8169=m`, `DIMLIB` y or m, signatures enforced | `R8169=m`, `DIMLIB=y`, `MODULE_SIG_FORCE=y`, `LOCKDEP=y` | Pass |
| P0-D | Backup of the stock module and sources | Copy `r8169.ko`, `Kconfig`, `r8169_main.c` to `~/r8169-stock-src/` | Files present | Done | Pass |
| P0-E | Build path | `make modules_prepare`, `make M=drivers/net/ethernet/realtek modules W=1` | Module builds, `vermagic` equals `uname -r` | Done on the Phase 1 patched tree; an unmodified-tree build was not run on its own | Pass (partly) |
| P0-F | Peer arranged, tools present | On the peer start `iperf3 -s` and `netserver`; check versions | Both servers answer the benchmark | Same LAN, gigabit link, iperf3 3.16, netperf 2.7.0 | Pass |
| P0-G | Interrupt-number fix in `rx_bench.sh` | Idle run with no peer, then a download of about 50 Mbit/s | Idle near 2 to 3 irq/s; the download shows tens of irq/s | Before the fix `irq_per_s` was 0 in both (script used `device/irq` = 18); after: 65.8 irq/s at 51 Mbit/s | Fixed, then pass |
| P0-H | Baseline benchmark, four configurations | See "Baseline runs" | Stock and patched-off agree | See below | Pass |
| P0-I | Source reading of `PktCntrDisable` | Read `rtl_set_coalesce()` and `rtl_hw_start()` in v7.2.15 | Timer-only sets the bit; a frame limit clears it | As described in the results file | Done |
| P0-J | Register check of that reading | `bash scripts/read_intrmit.sh` after each setting below | Matches the source | All four rows match | Pass |

## P0-G: validating the benchmark script

```bash
ls /sys/class/net/enp3s0/device/msi_irqs        # lists 135, the real vector
grep enp3s0 /proc/interrupts                     # the row the script must use
bash scripts/rx_bench.sh -l idle-test -p PEER    # then check summary.csv
```

The wrong number came from `/sys/class/net/enp3s0/device/irq` (18, the legacy line). The script now finds the row by device name in the last column of `/proc/interrupts`, falls back to `msi_irqs`, and stops if no row is found. Rates are printed with one decimal and there is a 2 second pause between runs. Rows from before the fix were discarded.

## P0-H: baseline runs

Run from the repository root, as root, once per label, with the module and setting in the table. Defaults: 5 runs of 20 seconds per cell.

```bash
bash scripts/rx_bench.sh -l <label> -p <peer>
python3 scripts/summarize_results.py          # tables from results/baseline/*/summary.csv
```

| Label | Module and setting | Registers read back |
|---|---|---|
| `stock` | Installed module, `Adaptive RX: n/a`, `rx-usecs 0`, `rx-frames 1` | `CPlusCmd 0x2060`, `IntrMitigate 0x0000` |
| `patched-off` | Phase 1 module, `Adaptive RX: off` | `0x2060`, `0x0000` |
| `static-50us` | Phase 1 module, `ethtool -C enp3s0 rx-usecs 50` | `0x20e0`, `0x00a0` |
| `static-200us` | Phase 1 module, `ethtool -C enp3s0 rx-usecs 200` | `0x20e1`, `0x0050` |

Workloads per label: `idle` (no traffic, interrupt counts only), `rr` (`netperf` TCP_RR, 64 byte request and response), `tcp` (`iperf3 -R`), `udp` (`iperf3 -u -R` at 100, 300, 600 and 900 Mbit/s offered, 1448 byte datagrams). 140 runs, all status `ok`. The labels ran in the order stock, patched-off, static-50us, static-200us between 16:34 and 17:36 (+05:30) on 2026-11-11.

Key observed values (mean of 5 runs):

| Workload | stock | patched-off | static-50us | static-200us |
|---|---|---|---|---|
| `rr` trans/s | 9213 | 9330 | 6632 | 3390 |
| `rr` mean latency (us) | 108.4 | 107.1 | 150.6 | 295.3 |
| `rr` irq per transaction | 2.00 | 2.00 | 2.00 | 2.00 |
| `tcp` Mbit/s | 941.2 | 941.3 | 941.3 | 941.3 |
| `udp` 600M NET_RX/s | 20315 | 20340 | 16792 | 12038 |
| `udp` 100M irq/s | 2001.6 | 2001.6 | 2001.5 | 1002.8 |

Pass criteria and conclusions:

- `stock` against `patched-off`: no throughput, latency, interrupt or NET_RX figure differs by more than about 1.3% (this closes Phase 1 test F3). The 5% difference in 900M UDP interrupts is inside the spread of the stock runs.
- Bulk TCP leaves nothing to moderate (1.3 to 1.8 irq/s, NET_RX about 32,500/s).
- A static timer costs latency in request-response and saves no interrupts per transaction.
- The all-CPU busy figure (share of 20 CPUs) cannot separate the configurations; the per-CPU columns `irq_cpu`, `irq_cpu_busy_pct` and `irq_cpu_softirq_pct` were added for later phases.

## P0-J: register check (2026-11-10)

Apply the settings in this order, one after another, and read the registers after each:

```bash
ethtool -C enp3s0 rx-usecs 0 rx-frames 1;  bash scripts/read_intrmit.sh
ethtool -C enp3s0 rx-usecs 50;             bash scripts/read_intrmit.sh
ethtool -C enp3s0 rx-usecs 50 rx-frames 8; bash scripts/read_intrmit.sh
ethtool -C enp3s0 rx-usecs 100;            bash scripts/read_intrmit.sh
ethtool -C enp3s0 rx-usecs 0 rx-frames 1                      # put back
```

| Setting applied | `CPlusCmd` | `PktCntrDisable` | `INTT` | `IntrMitigate` |
|---|---|---|---|---|
| `rx-usecs 0 rx-frames 1` | `0x20e0` | 1 | 0 | `0x0000` |
| `rx-usecs 50` | `0x20e0` | 1 | 0 | `0x00a0` (RX timer 10) |
| `rx-usecs 50 rx-frames 8` | `0x2060` | 0 | 0 | `0x00a2` (timer 10, frames field 2) |
| `rx-usecs 100` | `0x2061` | 0 | 1 (40 us unit) | `0x0032` (timer 3, frames field 2) |

The fourth row differs from the first prediction because `ethtool -C` merges the new request with the current settings, so `rx-frames 8` was still in force. The timer unit follows the requested time: 100 us does not fit the 5 us unit (75 us at most), so the 40 us unit is chosen.

## Pitfalls

- `ethtool -C` with the values already in force is a no-op and never reaches the driver. To force a driver call, change a value first.
- After any `ethtool -C`, the machine is no longer in its freshly booted register state (`PktCntrDisable` set). A reboot or `rmmod` and `modprobe` clears the bit; `INTT` survives a module reload and is cleared only by a reboot.
- Compare configurations measured in the same session; the baseline mixes configuration and time because the labels ran one after another over about an hour.
- Governor `powersave` on all Phase 0 runs; peer kernel and NIC were not recorded in the meta files.
- UDP loss and jitter are read from the raw iperf3 JSON, not from the CSV, for the baseline files.
- The first `patched-off` start (16:48) left no rows in `summary.csv` and was presumably aborted; the 35 rows of the 16:52 run are one complete run.
