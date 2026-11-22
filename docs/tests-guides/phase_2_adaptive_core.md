# Phase 2 test guide: adaptive core

Tests of the module with patches 0001 to 0005. The level follows the load and request-response traffic is not harmed. Results: [`../results/phase_2_adaptive_core.md`](../results/phase_2_adaptive_core.md). General setup: [`../setup-and-testing.md`](../setup-and-testing.md), Phase 2.

## Conditions

- Patches 0003 (counters, `net_dim()` call, logging work function), 0004 (level table `{0, 40, 80, 200, 400}` us, register writes, ethtool semantics) and 0005 (single-packet polls not shown to DIM at level 0). Final `srcversion` `2711688295ECDA0D2245862`. Lockdep enabled.
- Test machine RTL8168h on `enp3s0`, 1 Gbit/s, peer `10.8.1.53` (variable `$PEER`). Governor `powersave`.
- Level sampler in a second terminal: `bash scripts/sample_level.sh enp3s0 > /tmp/level.csv &` (0.2 s interval). Timer field 0, 1, 2, 5, 10 means 0, 40, 80, 200, 400 us.
- `chk` means the log check as root: `dmesg | grep -iE 'lockdep|WARNING|BUG|Oops|possible circular'`, boot banners excluded. It must print nothing new.

## Tests

| ID | Test | Commands | Expected | Result |
|---|---|---|---|---|
| T1 | Flag round trip | `ethtool -C enp3s0 adaptive-rx on`; `ethtool -c enp3s0 \| grep Adaptive`; `bash scripts/read_intrmit.sh enp3s0`; `adaptive-rx off` | `Adaptive RX: on`; `CPlusCmd 0x20e1` (`INTT` 1, `PktCntrDisable` 1); `IntrMitigate 0x0000`; off gives `0x20e0`, `0x0000` | Pass |
| T2 | Static settings are saved | `ethtool -C enp3s0 rx-usecs 50`; `adaptive-rx on`; some load; `adaptive-rx off`; `ethtool -c enp3s0` | `rx-usecs` is 50 again, registers `0x20e0` / `0x00a0` | Pass |
| T3 | Refused combination | `ethtool -C enp3s0 adaptive-rx on tx-frames 8` | `Invalid argument`, message "TX frame limit is not supported with adaptive-rx", state unchanged | Pass |
| T4 | Heavy UDP | `iperf3 -c $PEER -R -u -b 600M -t 30` with the sampler | Timer field rises to 5 and 10 within seconds; NET_RX/s well below adaptive off; no loss | Pass (NET_RX/s 20872 to 3792); see loss note |
| T5 | Request-response | `netperf -H $PEER -t TCP_RR -l 30 -P 0 -- -r 64,64` with the sampler | Level at or near 0; trans/s within 5% of adaptive off | **Fail with 0003 and 0004** (-5.8%), **pass with 0005** (+1.8%) |
| T6 | Bulk TCP | `iperf3 -c $PEER -R -t 30` | 941 Mbit/s unchanged | Pass (941.2 against 941.3, 0 retransmits) |
| T7 | Idle observation | After T4 stop traffic, sample for 30 s | With 0003 to 0005 the level stays high (the gap patch 0006 closes) | Observed as expected (field 10, about 4 irq/s) |
| T8 | No regression with adaptive off | `bash scripts/rx_bench.sh -l patched-off-2 -p $PEER -w "rr tcp"`; `python3 scripts/summarize_results.py patched-off patched-off-2` | Within noise of the earlier `patched-off` | Pass (9340 against 9330 trans/s, 107.0 against 107.1 us) |
| T9 | Build quality | `make M=drivers/net/ethernet/realtek modules W=1`; checkpatch `--strict --no-tree` per patch | No compiler warning; only the expected checkpatch items | Pass |
| T10 | Unload safety | Five times, adaptive on and traffic running: `ip link set enp3s0 down`, `rmmod r8169`, `insmod /root/r8169-new-signed.ko` | No oops, `WARN` or lockdep report | Pass (end state `0x2061` / `0x0000`) |
| T11 | Fall after load | 600M UDP for 20 s, then TCP_RR, sampler running | Level 10 until the load ends, 0 at the next sample and after | Pass with 0005 (level 10 until 19.93 s, 0 at 20.17 s and for the next 12 s) |

## Extra checks

### `static-0us` (Phase 0 carry-forward, 2026-11-13)

Question: does level 0 through the ethtool path (`PktCntrDisable` set) behave like a freshly loaded module (bit clear)? Module: installed stock module.

```bash
bash scripts/read_intrmit.sh                       # start state
ethtool -C enp3s0 rx-usecs 50;  bash scripts/read_intrmit.sh
ethtool -C enp3s0 rx-usecs 0 rx-frames 1; bash scripts/read_intrmit.sh
bash scripts/rx_bench.sh -l static-0us -p $PEER -w "rr tcp"     # 5 runs
```

| Configuration | RR trans/s | RR latency us | RR irq/s | TCP Mbit/s |
|---|---|---|---|---|
| `stock` (Phase 0 session) | 9213 +/- 93 | 108.4 +/- 1.1 | 18384 +/- 179 | 941.2 |
| `stock-again` (same session, bit clear) | 9519 +/- 147 | 105.0 +/- 1.6 | 19001 +/- 289 | 941.2 |
| `static-0us` (bit set) | 9563 +/- 133 | 104.5 +/- 1.5 | 19087 +/- 266 | 941.3 |

Pass: `static-0us` against `stock-again` differs by 0.5% (trans/s, latency and irq/s), inside the spread. Level 0 may use the ethtool path with `PktCntrDisable` set. The first attempt tested nothing (see pitfalls) and was kept as `stock-again`.

### Same-session comparison, adaptive off against on

```bash
bash scripts/rx_bench.sh -l patched-off-2 -p $PEER
ethtool -C enp3s0 adaptive-rx on
bash scripts/rx_bench.sh -l adaptive-on -p $PEER
python3 scripts/summarize_results.py -r patched-off-2
```

| Workload | Metric | off | on (0003, 0004) | on (with 0005) |
|---|---|---|---|---|
| RR 64 B | trans/s | 9340 +/- 115 | 8794 +/- 113 | 9508 +/- 192 |
| RR 64 B | latency us | 107.0 +/- 1.3 | 113.6 +/- 1.5 | 104.9 +/- 2.0 |
| TCP bulk | Mbit/s, NET_RX/s | 941.3, 32504 | 941.2, 33439 | 941.3, 32480 |
| UDP 600M | NET_RX/s, loss % | 20872, 0 | 3792, 0 | 3954 +/- 293, 0 |
| UDP 900M | NET_RX/s | 36801 +/- 358 | 21510 +/- 2707 | 25853 +/- 7451 |
| UDP 900M | loss % (5 runs) | 0.0007 | 0.0000 | 0.0018 (two runs of 0.0045) |

### Level traces (0.2 s sampling), samples per timer field 0 / 1 / 2 / 5 / 10

| Run | 0 | 1 | 2 | 5 | 10 |
|---|---|---|---|---|---|
| T4 (30 s UDP, then 30 s idle) | 58 | 8 | 1 | 108 | 208 |
| T5 (TCP_RR, without 0005) | 74 | 38 | 2 | 0 | 3 |
| T6 (bulk TCP) | 46 | 16 | 47 | 3 | 10 |

`dmesg` showed 523 `rx dim:` lines in the T4 run, about 17 level changes per second.

### Loss at 600M UDP

The T4 run lost 59 of 1553877 datagrams (0.0038%) at seconds 7 to 9 with the sampler running. Two further 30 s runs lost 0 and 10. In the run that lost 10, `UdpRcvbufErrors` and `UdpInErrors` both rose by 10 and the interface `missed` counter stayed at 110, so the datagrams were dropped by the receive socket buffer of the test machine, not by the NIC. One of ten adaptive-off runs also lost datagrams. Not attributed to the driver; repeat with `iperf3 -w` if it matters.

### 900 Mbit/s UDP dwell at low levels (carried to Phase 4)

Six 15 s runs with the sampler and adaptive on with 0005:

| Run | NET_RX/s | Samples at field 0 / 1 / 2 / 5 / 10 | Loss % |
|---|---|---|---|
| 1 | 23239 | 3 / 1 / 4 / 10 / 38 | 0.011 |
| 2 | 21227 | 0 / 0 / 0 / 10 / 45 | 0 |
| 3 | 20270 | 0 / 0 / 0 / 10 / 45 | 0.012 |
| 4 | 21455 | 0 / 0 / 0 / 9 / 46 | 0.0095 |
| 5 | 31036 | 17 / 6 / 12 / 9 / 12 | 0 |
| 6 | 22720 | 0 / 0 / 3 / 14 / 38 | 0.0021 |

Over all guarded runs, three of eleven dwelled low at 900M; without 0005 one of five was intermediate. Too little data to say whether 0005 changes this; Phase 4 repeated it.

## Why T5 failed and what fixed it

DIM works in windows of 64 events. At level 0 it leaves for level 1 whenever bytes, packets or events per millisecond change by more than 10% between two windows, which request-response does all the time (a window is about 7 ms at 9,000 trans/s). Each excursion costs the replies in that window the full 40 us, which fits the measured +6.6 us. Patch 0005 (decision D10) hides single-packet polls from DIM at level 0, so request-response never leaves level 0 while bulk traffic (about 2.5 packets per poll at level 0) still climbs. Above level 0 every poll is shown to DIM so the level can step back down.

## Pitfalls

- A test that fails is a finding. T5 failed with 0003 and 0004 and led to patch 0005; keep the failing numbers.
- `ethtool -C ... rx-usecs 0 rx-frames 1` is a no-op when those values are already in force; change a value first to force a driver call.
- Compare only configurations measured in the same session (`stock` against `stock-again` differ by 3.3%, more than the 1.6% inside one session).
- `INTT` survives a module reload (probe reads `CPlusCmd & CPCMD_MASK`); `PktCntrDisable` does not. A reboot clears both.
- The sampler runs `ethtool` every 0.2 s and may add load; loss seen while it runs is not by itself a driver effect.
