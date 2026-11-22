# Setup and testing guide

How to set up the project from nothing, and how to test every phase in detail, with the commands that were used and what to expect. The commands are the ones run on the author's machines; paths and the peer address are the author's and are marked where you must change them. Background: [project explained](project-explained.md). What the numbers mean: [results explained](results-explained.md). Pictures of the setup: [diagram 7](diagrams/07-measurement-setup.md) and [diagram 8](diagrams/08-series-and-build.md).

**Safety first.** On the test machine the network card is the only network connection, and many tests take the link down on purpose. Work at the console (keyboard and screen) or over a phone tether, never through an SSH session into the same machine. Always keep a copy of the stock `r8169` module.

## 1. What you need

The exact hardware the project was made and tested for, and which other chips the change reaches, is in [hardware](hardware.md). To take the project off the machine again, see [uninstall](uninstall.md).

| Item | Requirement | The author's setup |
|---|---|---|
| Machine under test | Linux PC with a Realtek RTL8111/8168 family card (not RTL8125, which the coalescing code does not support), root access, console access | Lenovo desktop, Intel Alder Lake-S, RTL8168h (XID 541, PCI revision 15, firmware rtl8168h-2_0.0.2), interface `enp3s0`, PCI `03:00.0` |
| Kernel | Source of the running kernel, `r8169` built as a module, `CONFIG_DIMLIB` available | Linux 7.2.15, tarball in `/usr/src/linux-7.2.15` (not a git tree), `CONFIG_R8169=m`, `CONFIG_DIMLIB=y`, `CONFIG_LOCKDEP=y`, `CONFIG_DEBUG_FS=y`, `CONFIG_MODULE_SIG_FORCE=y`, running as `7.2.15-netquota` (includes the author's network-quota patches) |
| Peer machine | A second machine on the same gigabit LAN with `iperf3` and `netperf` | Ubuntu 24.04, kernel 7.0.0-42-generic, RTL8168h (rev 15), iperf3 3.16, netperf 2.7.0 |
| Tools on the PC | `ethtool`, `iperf3`, `netperf`, `python3`, `awk`, `gcc`/`make` and the kernel build prerequisites, `git` | |
| For the clean-tree checks | A git clone of the kernel at `v7.2.15` (any machine), `perl` | `git clone --depth 1 --branch v7.2.15 https://github.com/gregkh/linux.git ~/linux-r8169-clean` |

Check the card and the kernel first:

```bash
lspci -nn | grep -i ethernet                  # note the PCI address
ethtool -i enp3s0                             # driver: r8169
uname -r
zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(R8169|DIMLIB|MODULE_SIG_FORCE|LOCKDEP)=' || grep -E 'CONFIG_(R8169|DIMLIB|MODULE_SIG_FORCE|LOCKDEP)=' /boot/config-$(uname -r)
```

`CONFIG_R8169` must be `m` (a module you can swap) and `CONFIG_DIMLIB` `y` or `m`. If `CONFIG_DIMLIB` is off in the running kernel, the new module cannot load until the library is built too.

## 2. Get the code

On the machine under test, as a normal user (not root):

```bash
cd ~/Downloads
git clone <repository URL> r8169-adaptive-rx-dim
cd r8169-adaptive-rx-dim
git tag | tail -3                      # v1.0 is the final state
ls patches/                            # 0001 to 0006
```

The repository holds all phases and carries the tag `v1.0`. On the author's machine the remote `origin` is this repository and `private` is the private working copy used for Phases 4 and 5; a fresh clone of `origin` is enough. Check that `docs/results/phase_5_report_and_demo.md` exists.

Put the kernel source of the running kernel in `/usr/src/linux-7.2.15` (or another path, passed to `build_sign_load.sh`). It needs a `.config` identical to the running kernel's, and the tree must have been built before (`make modules_prepare` is enough for module builds).

## 3. Set up the peer

On the peer:

```bash
iperf3 -s &              # port 5201
netserver                # netperf server, port 12865
```

Note the peer's details for the record: `uname -r; lspci | grep -i ethernet; ethtool -i <peer dev>; iperf3 --version; netperf -V`. On the PC, check the connection and set the variable that every script uses:

```bash
export PEER=<peer address>            # the IP address of the peer on the LAN
ping -c 3 $PEER
iperf3 -c $PEER -t 3 && netperf -H $PEER -l 3
```

After every link-up, module swap or resume, wait about 40 seconds before traffic flows on the author's network (a switch port effect, see [results explained, 5.8](results-explained.md)); the scripts poll the peer for up to 120 s.

## 4. Back up the stock module and build the patched one

As root, at the console:

```bash
mkdir -p ~/r8169-stock-src
cp /usr/src/linux-7.2.15/drivers/net/ethernet/realtek/{Kconfig,r8169_main.c} ~/r8169-stock-src/
cp /usr/src/linux-7.2.15/drivers/net/ethernet/realtek/r8169.ko ~/r8169-stock-src/ 2>/dev/null || true
modinfo -F filename r8169             # the installed stock module; it is what "modprobe r8169" loads
```

Apply the patches in order, with a dry run first (the kernel tree is a tarball, so `patch -p1` and not `git am`):

```bash
cd /usr/src/linux-7.2.15
for p in ~/Downloads/r8169-adaptive-rx-dim/patches/000[1-6]-*.patch; do
    patch -p1 --dry-run < $p && patch -p1 < $p || break
done
```

Build, sign and load in one step:

```bash
cd ~/Downloads/r8169-adaptive-rx-dim
bash scripts/build_sign_load.sh /usr/src/linux-7.2.15
```

The script builds with `W=1`, refuses to load when the module's vermagic differs from `uname -r`, signs a copy (`/root/r8169-new-signed.ko`) with `certs/signing_key.pem` and `certs/signing_key.x509` of the tree, runs `rmmod r8169` and `insmod`, and prints the `srcversion`. If your kernel does not enforce signatures, the signing step is harmless. The key never leaves the tree.

The way back to the stock module, at any time:

```bash
rmmod r8169; modprobe r8169
```

Check that the new module is the one running:

```bash
cat /sys/module/r8169/srcversion
modinfo -F srcversion /root/r8169-new-signed.ko          # must match
ethtool -c enp3s0 | head -3                              # "Adaptive RX: off" (stock prints n/a)
bash scripts/read_intrmit.sh enp3s0                      # decodes CPlusCmd and IntrMitigate
```

## 5. Check the series without touching the PC

On any machine with a kernel git clone (no hardware needed):

```bash
bash scripts/check_series.sh -t ~/linux-r8169-clean -c
```

It applies the six patches in order on pristine `v7.2.15` files and runs `checkpatch.pl --strict` on each. Expected: all six apply; checkpatch shows only the `Co-authored-by` warning, the missing `Signed-off-by`, and three CamelCase checks in 0004. For a warning-free compile on a clean tree with lockdep:

```bash
cd ~/linux-r8169-clean && git config user.name "Your Name" && git config user.email you@example.com && git switch -c series && git am ~/Downloads/r8169-adaptive-rx-dim/patches/000[1-6]-*.patch
make defconfig && scripts/config -e MODULES -m R8169 -e PROVE_LOCKING -e DEBUG_FS && make olddefconfig
make -j4 modules_prepare && make M=drivers/net/ethernet/realtek modules W=1     # compile has 0 warnings; the final link needs a full build
make M=drivers/net/ethernet/realtek C=2 CF="-D__CHECK_ENDIAN__" r8169_main.o     # sparse, if a recent sparse is installed
```

## 6. Testing each phase

All commands as root at the console from the repository root, with `PEER` exported and the peer servers running. `enp3s0` is the author's interface name. Test numbers (F1, T5, ...) are the ones used in the phase results files. The complete list of tests per phase, with conditions, observed results and pitfalls, is in [`tests-guides/`](tests-guides/), one file per phase.

The phases and what each one answers are drawn in [diagram 9](diagrams/09-phases.md).

### Phase 0: environment and baseline

Purpose: know the hardware and the stock driver's behaviour. Done with the **stock** module loaded (`modprobe r8169`).

```bash
bash scripts/read_intrmit.sh enp3s0            # registers of the stock module: CPlusCmd 0x2060, IntrMitigate 0x0000
ethtool -c enp3s0                              # stock prints "Adaptive RX: n/a"
bash scripts/rx_bench.sh -l stock -p $PEER                 # default: idle rr tcp udp, 5 runs of 20 s
ethtool -C enp3s0 rx-usecs 50  && bash scripts/rx_bench.sh -l static-50us  -p $PEER
ethtool -C enp3s0 rx-usecs 200 && bash scripts/rx_bench.sh -l static-200us -p $PEER
python3 scripts/summarize_results.py -d results/baseline -r stock
```

Expected (5 runs per cell): bulk TCP 941 Mbit/s with about 2 interrupts per second; request-response takes 2 interrupts per transaction and gets slower with a static timer (about +42 us for 50, +187 us for 200); UDP shows fewer NET_RX with a timer and no loss. Check the interrupt counter against a known load first: during a download, `rx_bench.sh -w idle` style readings must show interrupts (the script finds the NIC row in `/proc/interrupts` by device name). Details: [phase 0 results](results/phase_0_environment_and_baseline.md).

### Phase 1: plumbing (patches 0001 and 0002)

Purpose: the flag exists and nothing else changes. Load a module built from 0001 and 0002 only (apply just those two patches, `build_sign_load.sh`).

| Test | Commands | Expected |
|---|---|---|
| F1 | `ethtool -c enp3s0 \| grep Adaptive`; `ethtool -C enp3s0 adaptive-rx on`; `ethtool -c enp3s0 \| grep Adaptive`; `ethtool -C enp3s0 adaptive-rx off` | `off`, then `on`, then `off` (stock: `n/a`) |
| F3 | Compare `ethtool -c` with adaptive off against the stock output; `ethtool -C enp3s0 rx-usecs 50`, read back, then `rx-usecs 0` | Same values (`rx-usecs 0`, `rx-frames 1`); 50 reads back as 50; registers equal to stock |
| F8 | `make M=drivers/net/ethernet/realtek modules W=1`; checkpatch on the two patches | No warning from `r8169_main.c`; checkpatch only the `Signed-off-by` and `Co-authored-by` items |

Details: [phase 1 results](results/phase_1_plumbing.md).

### Phase 2: adaptive core (patches 0003 to 0005)

Purpose: the level follows the load, request-response is not harmed. Apply 0003 to 0005 and load. For levels over time, start the sampler in a second terminal: `bash scripts/sample_level.sh enp3s0 > /tmp/level.csv &`.

| # | Test | Commands | Expected |
|---|---|---|---|
| T1 | Flag round trip | `ethtool -C enp3s0 adaptive-rx on`; `ethtool -c enp3s0 \| grep Adaptive`; `bash scripts/read_intrmit.sh enp3s0`; then `adaptive-rx off` | `Adaptive RX: on`; `CPlusCmd 0x20e1` (`INTT` 1, `PktCntrDisable` 1); `IntrMitigate 0x0000` |
| T2 | Static settings are saved | `ethtool -C enp3s0 rx-usecs 50`; `adaptive-rx on`; some load; `adaptive-rx off`; `ethtool -c enp3s0` | `rx-usecs` is 50 again |
| T3 | Refused combination | `ethtool -C enp3s0 adaptive-rx on tx-frames 8` | `Invalid argument` with the message "TX frame limit is not supported with adaptive-rx"; state unchanged |
| T4 | Heavy UDP | `iperf3 -c $PEER -R -u -b 600M -t 30` with the sampler running | Timer field rises to 5 and 10 (200 and 400 us) within seconds; NET_RX per second well below adaptive off; no loss |
| T5 | Request-response | `netperf -H $PEER -t TCP_RR -l 30 -P 0 -- -r 64,64` with the sampler running | Level stays at or near 0; transactions per second within 5% of adaptive off |
| T6 | Bulk TCP | `iperf3 -c $PEER -R -t 30` | 941 Mbit/s unchanged |
| T7 | Idle observation | After T4, stop traffic and sample for 30 s | With patches 0003 to 0005 the level stays high (the problem patch 0006 fixes) |
| T8 | No regression with adaptive off | `bash scripts/rx_bench.sh -l patched-off-2 -p $PEER -w "rr tcp"`; `python3 scripts/summarize_results.py patched-off patched-off-2` | Within noise of the earlier `patched-off` |
| T9 | Build quality | `make M=drivers/net/ethernet/realtek modules W=1`; `perl scripts/checkpatch.pl --strict --no-tree <patch>` in the kernel tree | No compiler warning; only the expected checkpatch items |
| T10 | Unload safety | Five times, with adaptive on and traffic running: `ip link set enp3s0 down`, `rmmod r8169`, `insmod /root/r8169-new-signed.ko` | No oops, `WARN` or lockdep report in `dmesg` |
| T11 | Fall after load | 600M UDP for 20 s, then TCP_RR, sampler running | Level 10 until the load ends, 0 at the next sample and for the following seconds |

Same-session comparison of adaptive off against on: `bash scripts/rx_bench.sh -l patched-off-2 -p $PEER` and again with `ethtool -C enp3s0 adaptive-rx on` and `-l adaptive-on`; `python3 scripts/summarize_results.py -r patched-off-2`. A test that **fails** here is a finding: T5 failed with 0003 and 0004 and led to patch 0005. Details: [phase 2 results](results/phase_2_adaptive_core.md).

### Phase 3: robustness (patch 0006)

Purpose: correct after restarts, link changes, suspend, stress. Load the full series with lockdep enabled in the kernel. After every test check the log as root: `dmesg | grep -iE 'lockdep|WARNING|BUG|Oops|possible circular|r8169'` (must print nothing new).

```bash
ethtool -C enp3s0 adaptive-rx on
bash scripts/phase3_tests.sh enp3s0 f4        # F4: 10 rounds of down, up, read the registers
bash scripts/phase3_tests.sh enp3s0 f5        # F5: link speed to 100 Mbit/s and back under load
bash scripts/phase3_tests.sh enp3s0 f9        # F9: idle decay time
bash scripts/phase3_tests.sh enp3s0 f10       # F10: request-response right after a burst
bash scripts/phase3_tests.sh enp3s0 f11 60    # F11: 60 s of concurrent ethtool changes
rtcwake -m mem -s 30                          # F6: suspend and resume (console), then read the registers
bash scripts/stress_f7.sh enp3s0 15 20        # F7: about 36 minutes, 19 link bounces and 20 module reloads; keep a tether
bash scripts/decay_timing.sh enp3s0           # exact decay time, resolution 0.1 s
```

| Test | Expected |
|---|---|
| F4 | After every `up`: `CPlusCmd 0x20e1`, `IntrMitigate 0x0000` at idle |
| F5 | `INTT` unchanged; at 100 Mbit/s the level converts with the 20.48 us unit (level 2 is field 4, `IntrMitigate 0x0040`); back at 1000 Mbit/s the original values return |
| F6 | `Adaptive RX: on` after resume; level rises under load |
| F7 | No oops, `WARN`, lockdep report or stuck `rmmod`; registers consistent with the flag |
| F9 | Level back at 0 about 0.4 s after the last packet |
| F10 | Transactions per second and latency close to the no-moderation figures from the first second |
| F11 | No hang; TX settings keep their value (`tx-usecs 20` reads back as 40 at 1 Gbit/s) |

F4b (reset path) needs the test hook, which is not part of the series and must be removed before any measurement:

```bash
cd /usr/src/linux-7.2.15 && patch -p1 < ~/Downloads/r8169-adaptive-rx-dim/scripts/test-hooks/force_reset.patch
cd ~/Downloads/r8169-adaptive-rx-dim && bash scripts/build_sign_load.sh
bash scripts/phase3_tests.sh enp3s0 f4b                       # writes 1 to /sys/kernel/debug/r8169_force_reset under load
dmesg | grep 'TEST restore'                                   # expect: level 4, IntrMitigate 0x00a0
cd /usr/src/linux-7.2.15 && patch -R -p1 < ~/Downloads/r8169-adaptive-rx-dim/scripts/test-hooks/force_reset.patch
cd ~/Downloads/r8169-adaptive-rx-dim && bash scripts/build_sign_load.sh
```

Known behaviour that is not a failure: after a forced reset under heavy load RX stays dead for 20 s or more with adaptive on **or** off, and any link-up on the author's network takes about 35 s before traffic flows. Details: [phase 3 results](results/phase_3_robustness.md), [locking notes](locking.md).

### Phase 4: measurement and tuning

Purpose: measure all configurations on all workloads with enough runs. No driver change. Prepare the session: governor `performance` (the matrix script sets and restores it with `-g`), NIC interrupt pinned to one CPU and `irqbalance` stopped (the author's session), the frozen module loaded.

| Step | Command | Result |
|---|---|---|
| Peer notes | On the peer: `uname -r; lspci \| grep -i ethernet; ethtool -i <dev>; iperf3 --version; netperf -V` | Save as `results/phase4/peer.txt` |
| Calibrate the small-packet load | `ethtool -C enp3s0 adaptive-rx off rx-usecs 0`; `bash scripts/rx_bench.sh -l calib -p $PEER -o results/phase4/calibration -w udps -r "20M 50M 100M 200M 300M" -n 3 -t 15`; then again with `-m 100` | With the default pacing the interrupt rate stays about 2,000 per second at every rate; with `-m 100` it follows the load |
| Plan only | `bash scripts/run_matrix.sh -p $PEER -o results/phase4/exploratory-1 -n` | Configurations, cells, runs, time estimate; nothing is run |
| Exploratory matrix | `bash scripts/run_matrix.sh -p $PEER -o results/phase4/exploratory-1 -R 2 -V 3 -c "off static-L2 static-L4 adaptive" -r "50M 100M 200M" -m 100 -g performance` | About 6 runs per cell |
| Stock at both ends | `rmmod r8169; modprobe r8169`, wait 40 s, `bash scripts/rx_bench.sh -l stock -p $PEER -o results/phase4/exploratory-1 -n 5 -w "rr rrp tcp udp udps" -u "300M 600M 900M" -r "50M 100M 200M" -m 100`; reload the patched module | `stock` label in the same directory |
| Summary | `python3 scripts/summarize_results.py -d results/phase4/exploratory-1 -r off` | Tables and a noise-aware comparison against `off` |
| Level traces | `bash scripts/dwell_check.sh -p $PEER -n 10 -r 900M -a on` (and `-a off` as control) | `results/phase4/dwell/<label>/`: one trace per run |
| CPU check | `run_matrix.sh` into `results/phase4/cpucheck` | The cpuidle-based CPU figure |
| Final matrix | As the exploratory one with `-R 4 -V 3` (12 runs per cell) on the frozen build, `stock` at both ends | `results/phase4/final/` with `matrix.log` and `warnings.txt` |
| Stepped load | `bash scripts/stepped_load.sh -p $PEER -a on`, and `-a off` as control | `results/phase4/stepped/<label>/` |
| Figures | `python3 scripts/plot_results.py -d results/phase4/final -o docs/figures --stepped results/phase4/stepped/adaptive-600M` | PNG files in `docs/figures/` |

Run the matrix as root, then `chown -R <user>:<user> results` before committing. Compare labels only within one session and one directory. Read `warnings.txt` after a run: a visit with a transmit timeout or a changed configuration is listed there and must be handled before the numbers are used. The tuning rule: request-response within 5% of `off`, no throughput or loss regression, lower NET_RX and CPU for the UDP cells; if it fails, change the level table, rebuild, and run `run_matrix.sh -c "off adaptive" -T "<new table>"` into a new directory. Details: [phase 4 results](results/phase_4_measurement_and_tuning.md).

### Phase 5: report, demo and final checks

```bash
bash scripts/check_series.sh -t ~/linux-r8169-clean -c                    # clean-tree check (section 5)
cat /sys/module/r8169/srcversion                                           # the frozen build
bash scripts/run_matrix.sh -p $PEER -o results/phase5/final-check -c "off adaptive" -w "rr udps" -r "50M 100M" -m 100 -R 1 -V 3 -g performance
python3 scripts/summarize_results.py -d results/phase5/final-check -r off
bash scripts/demo.sh -p $PEER -y -o results/phase5/rehearsal-1             # a rehearsal, no pauses
```

Expected: the matched run agrees with the Phase 4 final matrix inside the spread of three runs (`rr` unchanged; `udps` 50M NET_RX about -82%, 100M about -77%; interrupts about 3,100 to 3,300 per second against about 19,900 and 16,900). Running the demo is explained in [demo and questions](demo-and-questions.md). Details: [phase 5 results](results/phase_5_report_and_demo.md).

## 7. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `insmod: Key was rejected by service` or `Required key not available` | The kernel enforces signatures: use `build_sign_load.sh` (it signs with the tree's key) |
| `vermagic does not match` | The source tree is not the one that built the running kernel; use the same version and `.config` |
| `Unknown symbol` for DIM functions when loading | `CONFIG_DIMLIB` is not built in the running kernel |
| `ethtool -C ... adaptive-rx on` says operation not supported | The stock module is loaded, or the chip is an RTL8125 |
| Scripts report no peer | `PEER` unset or the peer servers are not running (`pkill iperf3; iperf3 -s`); wait 40 s after a link-up |
| NIC dead after a test | At the console: `ip link set enp3s0 up`, or `rmmod r8169; modprobe r8169` (stock module), or use the phone tether |
| Interrupt counts read 0 during traffic | The script read the wrong IRQ: the sysfs `device/irq` file shows the legacy IRQ, the MSI-X interrupt in `/proc/interrupts` differs; the scripts match by device name |
| `git am` fails on the patches in `patches/` | They are kernel patches, not repository patches: apply them in the kernel tree with `patch -p1` |
| Patch fails with CRLF errors | Files copied from Windows have CRLF line endings; clone or pull on the Linux machine |
| `results/` owned by root, `git add` fails | `chown -R <user>:<user> results` |
