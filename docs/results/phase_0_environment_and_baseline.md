# Phase 0: Environment and baseline

Status: done (2026-11-11). Started 2026-11-10. Every machine fact is recorded, the source question is settled and confirmed on the hardware, the benchmark script is validated, and the baseline runs for four configurations are in `results/baseline/`.

Plan: [`../phases.md`](../phases.md), Phase 0.

## Task status

| # | Task | State |
|---|---|---|
| 1 | Identify the chip and link | Done |
| 2 | Check that static coalescing works on this chip | Done |
| 3 | Check the kernel configuration | Done |
| 4 | Back up the stock module | Done |
| 5 | Check the build path | Done with the Phase 1 patched tree; an unmodified-tree build was not run separately |
| 6 | Arrange the second machine | Done: a machine on the same LAN over a gigabit link, running `iperf3` 3.16 and `netperf` 2.7.0 |
| 7 | Create the repository | Done: https://github.com/Dhruv0306/r8169-adaptive-rx-dim |
| 8 | Baseline for the stock driver | Done 2026-11-11: four labelled runs (below) |
| 9 | Read `rtl_set_coalesce()` for the `PktCntrDisable` question | Done: source reading and register check (below) |

## Facts recorded

| Item | Value |
|---|---|
| Chip | RTL8168h/8111h, XID 541, PCI revision 15 (`10ec:8168`), at `03:00.0` |
| Firmware | `rtl8168h-2_0.0.2 02/26/15` |
| Interface | `enp3s0`, link 1000 Mbit/s full duplex |
| NIC interrupt | 135, MSI-X (`IR-PCI-MSIX-0000:03:00.0 0-edge enp3s0`), all counts on CPU 7. `/sys/class/net/enp3s0/device/irq` says 18 and is not the NIC's vector |
| Driver | `r8169`, version string `7.2.15-netquota` |
| Kernel | `7.2.15-netquota`, tree `/usr/src/linux-7.2.15`, 20 CPUs, governor `powersave` |
| `CONFIG_R8169` | `m` |
| `CONFIG_DIMLIB` | `y` (built in, so no kernel rebuild is needed) |
| `CONFIG_MODULE_SIG_FORCE` | `y`, hash `sha512`, key `certs/signing_key.pem` |
| `CONFIG_LOCKDEP` | `y` |
| Stock module | Uncompressed, `/lib/modules/7.2.15-netquota/kernel/drivers/net/ethernet/realtek/r8169.ko`, srcversion `A8C76016444D067D3998384` |
| Phase 1 module | Signed copy `/root/r8169-new-signed.ko`, srcversion `9BF0EA4C816C5F152E47686` |
| Backups | Stock `r8169.ko`, `Kconfig` and `r8169_main.c` in root's `~/r8169-stock-src/` |
| State after a fresh module load | `CPlusCmd` `0x2060` (`PktCntrDisable` 0, `INTT` 0), `IntrMitigate` `0x0000` |
| Static coalescing | Accepted. `ethtool -C enp3s0 rx-usecs 50` reads back as `rx-usecs 50` with `rx-frames 0`. `rx-usecs 0` restores `rx-usecs 0` and `rx-frames 1` (the "1 means no frame limit" convention). TX stayed at `tx-usecs 0`, `tx-frames 1` |


## Benchmark scripts and their validation

- `scripts/read_intrmit.sh` prints the live moderation state from the registers. Reused later for the stepped-load demo.
- `scripts/rx_bench.sh` is the receive-side benchmark. The peer sends to this machine (`iperf3 -R`, `netperf TCP_RR`), so no ICMP is used. Per run it records the NIC interrupt rate, the NET_RX softirq rate and the CPU busy percentage in `results/baseline/<label>/summary.csv`, with the raw tool output and a `meta_*.txt` setup snapshot next to it.
- `scripts/summarize_results.py` turns the CSV files into the Markdown tables below.

Validation on 2026-11-10 found and fixed a wrong interrupt number:

- A no-peer idle test printed `irq_per_s` 0, and a test with a working download (about 26 Mbit/s, NET_RX rose from about 61 to 719 per second) still printed 0.0. The script had taken the interrupt number from `/sys/class/net/enp3s0/device/irq`, which prints 18 (the legacy line), while `ls /sys/class/net/enp3s0/device/msi_irqs` lists 135, the vector that `/proc/interrupts` shows for `enp3s0`.
- The script now finds the row by device name in the last column of `/proc/interrupts`, falls back to `msi_irqs` and then to sysfs, stops if the row is missing, and warns if the row is not named after the device.
- With the fix, a download of about 51 Mbit/s gave 65.8 interrupts per second (NET_RX 2157 per second). The earlier idle rows with 0 interrupts are discarded.
- The rates are printed with one decimal, because rates below 0.5 per second showed as 0.

Changes made after the baseline was run, from reading its results:

- The UDP parser did not record loss and jitter, because iperf3 3.16 also reports `sum_received` for UDP and the script tested that first. It now tests for `lost_percent` first. The baseline CSV files lack the figures, so `summarize_results.py` reads them from the raw JSON.
- New columns `irq_cpu`, `irq_cpu_busy_pct` and `irq_cpu_softirq_pct`: the busy and softirq share of the one CPU that took the NIC interrupts. The all-CPU figure is divided by 20 CPUs and turned out unusable (see limitations). The script refuses to append to a CSV with the older layout, so a rerun needs a new label or directory. The baseline files keep the older layout and `summarize_results.py` reads both.
- A 2 second pause between runs, so the servers on the peer can settle.

## Baseline measurements (run 2026-11-11)

### Setup

The peer is on the same LAN and sends to this machine over a 1000 Mbit/s link. Command per label, from the repository root as root: `bash scripts/rx_bench.sh -l <label> -p <peer>` with the defaults of 5 runs of 20 seconds per cell. Workloads:

- `idle`: no traffic, only interrupt counts.
- `rr`: `netperf` TCP_RR with 64 byte requests and responses.
- `tcp`: `iperf3 -R` bulk TCP.
- `udp`: `iperf3 -u -R` at 100, 300, 600 and 900 Mbit/s offered (1448 byte datagrams).

| Label | Module and setting | Registers read back |
|---|---|---|
| `stock` | Installed module, `Adaptive RX: n/a`, `rx-usecs 0`, `rx-frames 1` | `CPlusCmd` `0x2060`, `IntrMitigate` `0x0000` |
| `patched-off` | Phase 1 module, `Adaptive RX: off`, no static timer | `0x2060`, `0x0000` |
| `static-50us` | Phase 1 module, `ethtool -C enp3s0 rx-usecs 50` | `0x20e0` (`PktCntrDisable` 1, `INTT` 0), `0x00a0` (RX timer 10) |
| `static-200us` | Phase 1 module, `ethtool -C enp3s0 rx-usecs 200` | `0x20e1` (`INTT` 1, 40 microsecond unit), `0x0050` (RX timer 5) |

The runs happened in that order, from about 16:34 to 17:36 (+05:30). `patched-off` has two meta files (16:48 and 16:52); the first start left no rows in `summary.csv`, so it was presumably aborted and restarted, and the 35 rows in the file are one complete run. This was not investigated.

### Results

Mean +/- standard deviation over 5 runs, produced with `python3 scripts/summarize_results.py` from the repository root. All 140 runs have status `ok`. `CPU all %` is the busy share of all 20 CPUs together.

#### idle

| Configuration | Runs | irq/s | NET_RX/s | CPU all % |
|---|---|---|---|---|
| patched-off | 5 | 2.5 +/- 0.8 | 5 +/- 2 | 0.10 +/- 0.00 |
| static-200us | 5 | 2.4 +/- 0.7 | 5 +/- 1 | 0.10 +/- 0.00 |
| static-50us | 5 | 2.7 +/- 1.7 | 5 +/- 3 | 0.10 +/- 0.00 |
| stock | 5 | 2.2 +/- 0.7 | 4 +/- 1 | 0.36 +/- 0.36 |

#### rr 64B

| Configuration | Runs | trans/s | mean latency us | irq/s | irq per trans | NET_RX/s | CPU all % |
|---|---|---|---|---|---|---|---|
| patched-off | 5 | 9330 +/- 140 | 107.1 +/- 1.6 | 18626.7 +/- 278.1 | 2.00 +/- 0.00 | 28056 +/- 412 | 1.68 +/- 0.24 |
| static-200us | 5 | 3390 +/- 157 | 295.3 +/- 13.7 | 6774.0 +/- 313.0 | 2.00 +/- 0.00 | 10191 +/- 472 | 1.10 +/- 0.07 |
| static-50us | 5 | 6632 +/- 13 | 150.6 +/- 0.2 | 13253.7 +/- 26.0 | 2.00 +/- 0.00 | 19945 +/- 41 | 1.68 +/- 0.08 |
| stock | 5 | 9213 +/- 93 | 108.4 +/- 1.1 | 18384.2 +/- 178.9 | 2.00 +/- 0.00 | 27701 +/- 274 | 2.08 +/- 0.39 |

#### tcp bulk

| Configuration | Runs | Mbit/s | irq/s | NET_RX/s | CPU all % |
|---|---|---|---|---|---|
| patched-off | 5 | 941.3 +/- 0.0 | 1.5 +/- 0.0 | 32561 +/- 124 | 2.22 +/- 0.04 |
| static-200us | 5 | 941.3 +/- 0.1 | 1.6 +/- 0.2 | 32626 +/- 168 | 2.24 +/- 0.05 |
| static-50us | 5 | 941.3 +/- 0.1 | 1.3 +/- 0.1 | 32483 +/- 141 | 2.22 +/- 0.04 |
| stock | 5 | 941.2 +/- 0.1 | 1.8 +/- 0.4 | 32783 +/- 314 | 2.32 +/- 0.16 |

#### udp 100M

| Configuration | Runs | Mbit/s | loss % | jitter ms | irq/s | NET_RX/s | CPU all % |
|---|---|---|---|---|---|---|---|
| patched-off | 5 | 100.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.023 +/- 0.004 | 2001.6 +/- 1.0 | 5011 +/- 15 | 3.00 +/- 3.00 |
| static-200us | 5 | 100.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.013 +/- 0.000 | 1002.8 +/- 1.4 | 2005 +/- 2 | 0.10 +/- 0.00 |
| static-50us | 5 | 100.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.020 +/- 0.005 | 2001.5 +/- 0.8 | 4003 +/- 2 | 0.10 +/- 0.00 |
| stock | 5 | 100.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.023 +/- 0.002 | 2001.6 +/- 1.0 | 5003 +/- 10 | 3.00 +/- 2.47 |

#### udp 300M

| Configuration | Runs | Mbit/s | loss % | jitter ms | irq/s | NET_RX/s | CPU all % |
|---|---|---|---|---|---|---|---|
| patched-off | 5 | 300.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.020 +/- 0.004 | 2000.5 +/- 0.5 | 8241 +/- 583 | 5.78 +/- 3.96 |
| static-200us | 5 | 300.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.016 +/- 0.006 | 2001.2 +/- 0.8 | 3068 +/- 51 | 2.44 +/- 2.17 |
| static-50us | 5 | 300.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.020 +/- 0.004 | 2000.6 +/- 0.5 | 6959 +/- 420 | 3.28 +/- 3.27 |
| stock | 5 | 300.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.020 +/- 0.005 | 2000.8 +/- 0.7 | 8179 +/- 355 | 4.48 +/- 4.13 |

#### udp 600M

| Configuration | Runs | Mbit/s | loss % | jitter ms | irq/s | NET_RX/s | CPU all % |
|---|---|---|---|---|---|---|---|
| patched-off | 5 | 600.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.020 +/- 0.008 | 2000.1 +/- 0.7 | 20340 +/- 1819 | 3.32 +/- 3.02 |
| static-200us | 5 | 600.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.013 +/- 0.004 | 2000.1 +/- 0.7 | 12038 +/- 2298 | 1.86 +/- 2.91 |
| static-50us | 5 | 600.0 +/- 0.0 | 0.0005 +/- 0.0012 | 0.025 +/- 0.012 | 2000.1 +/- 0.3 | 16792 +/- 668 | 4.24 +/- 2.39 |
| stock | 5 | 600.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.023 +/- 0.006 | 1999.4 +/- 0.7 | 20315 +/- 2054 | 2.92 +/- 2.55 |

#### udp 900M

| Configuration | Runs | Mbit/s | loss % | jitter ms | irq/s | NET_RX/s | CPU all % |
|---|---|---|---|---|---|---|---|
| patched-off | 5 | 900.0 +/- 0.0 | 0.0017 +/- 0.0038 | 0.020 +/- 0.008 | 1960.0 +/- 10.1 | 36577 +/- 189 | 2.76 +/- 0.97 |
| static-200us | 5 | 900.0 +/- 0.1 | 0.0042 +/- 0.0093 | 0.022 +/- 0.016 | 1499.0 +/- 383.4 | 30704 +/- 752 | 2.46 +/- 1.33 |
| static-50us | 5 | 900.0 +/- 0.0 | 0.0000 +/- 0.0000 | 0.022 +/- 0.007 | 1663.0 +/- 407.6 | 34515 +/- 479 | 3.14 +/- 0.82 |
| stock | 5 | 899.9 +/- 0.2 | 0.0086 +/- 0.0157 | 0.021 +/- 0.008 | 1862.3 +/- 160.9 | 36666 +/- 295 | 3.02 +/- 0.93 |

### Findings

Measured:

1. **The Phase 1 module with adaptive off behaves like the stock module.** No throughput, latency, interrupt or NET_RX figure differs by more than about 1.3% between `stock` and `patched-off`, apart from the 900 Mbit/s UDP interrupt rate (5%, inside the spread of the stock runs, which have a standard deviation of 161) and the CPU figures, which are too noisy to compare (finding 6). For example request-response gives 9213 +/- 93 against 9330 +/- 140 transactions per second, 108.4 against 107.1 microseconds, and 18384 against 18627 interrupts per second. The registers read back the same (`0x2060`, `0x0000`). This closes test F3 from Phase 1. With 5 runs only large differences could show up.
2. **Bulk TCP leaves nothing for moderation to remove.** All four configurations reach 941.2 to 941.3 Mbit/s with 1.3 to 1.8 interrupts per second, while NET_RX runs at about 32,500 per second. At line rate the receive path is already in NAPI polling, so the stock driver takes almost no interrupts.
3. **A static timer adds latency and saves no interrupts per transaction in request-response.** Interrupts per transaction stay at 2.00 in all four configurations. A 50 microsecond timer raises the mean latency from 108.4 to 150.6 microseconds (+42) and a 200 microsecond timer to 295.3 (+187), and transactions per second fall by 28% and 63%. The interrupt rate falls by the same percentages only because the transactions slow down.
4. **For UDP the interrupt rate is flat and moderation shows up in NET_RX and at low load.** Stock takes about 2000 interrupts per second at 100, 300 and 600 Mbit/s, so the rate does not follow the load. This is probably the sender's 1 millisecond pacing bursts in iperf3, which was not confirmed. A 200 microsecond timer halves the interrupts at 100 Mbit/s (2001.6 to 1002.8). NET_RX per second falls with the timer at every rate: at 600 Mbit/s from 20,315 to 16,792 (-17%) with 50 microseconds and to 12,038 (-41%) with 200; at 900 Mbit/s by 6% and 16%, where the interrupt figures are noisy (standard deviation about 400). Throughput equals the offered rate and loss stays at or below 0.04% in every run, so there is no loss to reduce.
5. **Idle** takes 2.2 to 2.7 interrupts per second in all configurations.

Not measured well:

6. **The all-CPU busy figure cannot separate the configurations.** It is a tick-based share of 20 CPUs, so 1% is 0.2 of a CPU, and the values are noisy: stock UDP at 100 Mbit/s reads 3.0 +/- 2.5 against 0.10 in both static runs, and idle reads exactly 0.10 in most runs. Nothing about CPU cost can be concluded from this baseline. The per-CPU columns added to the script address this.

### What this means for the project

- Under request-response load the adaptive mode has to stay at level 0, because any timer costs about its own length in latency with no saving per transaction.
- On this 1 Gbit/s link with 1448 byte datagrams and one flow, the stock driver is already at a low interrupt rate, so a large gain from adaptive moderation is not expected. The project plan already says to report a small or negative gain, and this baseline makes that outcome likely.
- The success criterion "lower interrupt rate and CPU use under bulk load" cannot be demonstrated with the current workloads. Phase 4 needs workloads that load the receive path harder (small-packet UDP at a high packet rate, several parallel TCP_RR streams) and the per-CPU measure.

### Limitations

- Five runs of 20 seconds per cell, and the labels were run one after another over about an hour, so configuration and time are mixed. The peer shared a LAN with other devices.
- `stock` and `patched-off` run with `PktCntrDisable` 0, the static runs with 1. This was not separated from the timer: the effect of the bit alone is unknown (see below).
- CPU governor `powersave` on all runs. Peer details (kernel, NIC) were not recorded in the meta files.
- UDP loss and jitter come from the raw iperf3 JSON, not from the CSV.


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

## Observations

- **ICMP does not work on this network.** `ping` to the gateway and to `8.8.8.8` got no replies, while the gateway answered ARP and `curl` returned HTTP 200. Latency probes therefore use TCP or UDP (`netperf` TCP_RR here).
- **Receive drops.** `ip -s link` showed `RX dropped 12` out of 922 packets, with no errors and no missed packets, before any measurement. Not compared with the stock driver.
- **Taint line.** `dmesg` reports `loading out-of-tree module taints kernel` when the rebuilt module loads. This is expected and does not disable lockdep.

## Carried forward

1. **Level 0 with `PktCntrDisable` set.** The adaptive design will run its "no moderation" level through the ethtool path, which sets `PktCntrDisable`, while a freshly loaded module has it clear. Check that the two behave the same: run `ethtool -C enp3s0 rx-usecs 0 rx-frames 1`, confirm `0x20e0` and `0x0000` with `scripts/read_intrmit.sh enp3s0`, then `bash scripts/rx_bench.sh -l static-0us -p <peer> -w "rr tcp"` and compare with `stock`. Do this at the start of Phase 2.
2. **Phase 4 workloads and measure.** Add small-packet high-rate UDP and parallel TCP_RR, use the per-CPU columns, and rerun `stock` with the updated script so every label has the same columns. Record the peer's kernel and NIC.
3. **Optional:** confirm the cause of the flat 2000 interrupts per second in UDP (for example with a different `iperf3` pacing setting), and look at the `RX dropped` counter before and after a run.
