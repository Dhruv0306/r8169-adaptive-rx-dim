# Phase 3 test guide: robustness and locking

Tests of the full series 0001 to 0006: restarts, link changes, suspend, module reloads, concurrent configuration and idle decay. Results: [`../results/phase_3_robustness.md`](../results/phase_3_robustness.md). Plan: [`../plans/plan-3-robustness.md`](../plans/plan-3-robustness.md). Locking notes: [`../locking.md`](../locking.md).

## Conditions

- Full series 0001 to 0006 loaded as a signed module, kernel with lockdep (`PROVE_LOCKING`). Test machine `enp3s0`, 1 Gbit/s, peer in `$PEER`, governor `powersave`.
- Run as root at the console. The NIC is the only connection and goes down in several tests. Keep a phone tether for F7.
- `PEER=<address>` must be exported for the load tests; the peer runs `iperf3 -s` and `netserver`.
- **Log check after every test.** Use the kernel journal, not a `dmesg` line count (the first script versions counted lines, which did not work): `journalctl -k -b | grep -iE 'lockdep|WARNING:|BUG:|Oops|possible circular'` must print nothing new. Only this check counts for F4 to F11.
- The test hook `scripts/test-hooks/force_reset.patch` is used for F4b only. It is not part of the series and must never be present during a measurement.

## Commands

```bash
ethtool -C enp3s0 adaptive-rx on
bash scripts/phase3_tests.sh enp3s0 f4        # F4: 10 rounds of down, up, read the registers
bash scripts/phase3_tests.sh enp3s0 f5        # F5: link speed to 100 Mbit/s and back under load
bash scripts/phase3_tests.sh enp3s0 f9        # F9: idle decay time
bash scripts/phase3_tests.sh enp3s0 f10       # F10: request-response right after a burst
bash scripts/phase3_tests.sh enp3s0 f11 60    # F11: 60 s of concurrent ethtool changes
rtcwake -m mem -s 30                          # F6: suspend and resume (console), then read the registers
bash scripts/stress_f7.sh enp3s0 15 20        # F7: about 36 minutes; keep a tether
bash scripts/decay_timing.sh enp3s0           # exact decay time, resolution 0.1 s
```

Every `phase3_tests.sh` test prints the registers (`scripts/read_intrmit.sh`) and the kernel messages that appeared while it ran.

## Tests

| ID | Test | What it does | Expected | Result |
|---|---|---|---|---|
| F4 | Down and up | 10 rounds of `ip link set down` and `up` with adaptive on | After every `up`: `CPlusCmd 0x20e1`, `IntrMitigate 0x0000` at idle | Pass |
| F4b | Reset path under load | With the hook, 600M UDP load at level 4, write `1` to `/sys/kernel/debug/r8169_force_reset` (same path as a transmit timeout or PCI error); sample `rx_packets` and the timer field every 0.1 s for 5 s. `F4B_ADAPTIVE=off` repeats it with adaptive off | Log line `TEST restore: level 4, IntrMitigate 0x00a0` right after the reset | Pass at the register level. RX stall found, not caused by 0006 (see findings) |
| F5 | Link speed change | 1000, 100, 1000 Mbit/s under a 90M to 95M load of 64 byte payloads (`F5_RATE`, `F5_LEN`) | `INTT` unchanged; at 100 Mbit/s the level converts with the 20.48 us unit (level 2 is field 4, `IntrMitigate 0x0040`); back at 1000 Mbit/s the original values return | Pass for the unit (`rx-usecs: 82`, `0x0040`, `rx_timer=4`); the link work itself is not separately visible |
| F6 | Suspend and resume | `rtcwake -m mem -s 30` at the console, then read the registers and run UDP | `Adaptive RX: on` after resume, `IntrMitigate 0x0000` right after resume, level rises under load | Pass (timer fields 5 and 10 appeared: 3 and 20 samples at 0.5 s) |
| F7 | Stress | `bash scripts/stress_f7.sh enp3s0 15 20`: link bounces and module reloads under 300M UDP and TCP_RR with `adaptive-rx` toggled every 100 ms | No oops, `WARN`, lockdep report or stuck `rmmod`; registers consistent with the flag | Pass, with the bounce interval changed |
| F8 | Build quality | `W=1` build; `checkpatch --strict --no-tree`; `sparse` | No warning; only the `Signed-off-by` and `Co-authored-by` items | Pass; `sparse` not run (not installed) |
| F9 | Idle decay | `f9` and `bash scripts/decay_timing.sh enp3s0` on the saved CSV | Level 0 about 0.4 s or less (+/- 0.1 s) after the last packet | Pass: 0.39 s |
| F10 | Request-response after a burst | Sparse TCP_RR right after a UDP burst, adaptive on against off in the same session | Trans/s and latency close to the no-moderation figures from the first second | Pass, no regression |
| F11 | Concurrent configuration | 60 s of concurrent `adaptive-rx` and `tx-usecs` changes under load | No hang; TX settings keep their value | Pass: no hang, final `PktCntrDisable=1`; `tx-usecs 20` reads back as 40 (one timer unit is 40 us at 1 Gbit/s, stock rounding) |

## Observed details

- **F4b register level:** the restore wrote level 4 (`IntrMitigate 0x00a0`) so the register was not left at 0. No lockdep, `WARNING`, `BUG` or `Oops` in either the adaptive-on or the adaptive-off run.
- **F7 (2026-11-15):** 19 link bounces and 20 module reloads. The 9 bounces with toggling paused found the RX level above 0 (levels 10, 2, 10, 10, 10, 10, 10, 10, 10), so teardown ran with the decay work armed. The 10 bounces during toggling read level 0, as expected with the mode flipping every 100 ms. 19 of the 20 reloads found the level above 0 (10 or 5). The network came back after 32 to 35 s each of the 39 times. 211 UDP and 222 TCP_RR rounds finished (failed rounds are the outages). Registers matched the flag after the bounce phase and after every reload, `rmmod` never hung, and 117 link up/down lines in the kernel log had no lockdep, `WARNING`, `BUG` or `Oops`.
- **F7 deviation:** "bounce every 10 s" became "bounce after every recovery" (about one per minute) because the switch port forwards nothing for about 30 s after each link-up. Five earlier runs (three of 30 minutes with 161 bounces, one of 3 minutes with the old design, one short run of the new design) had no or too little traffic at the bounces and are not counted; they ended with no hang, consistent registers and a clean log.
- **F9:** 0.39 s from the last packet seen at a level above 0 to level 0; 15 samples saw background packets after level 0 and do not take part in the decay.
- **F10:** adaptive on 9646, 9435, 9297 trans/s; adaptive off, same session, 9599 and 9100 (the first off run failed to connect to netserver). The sets overlap; run-to-run spread is about 5%.
- **Whole-boot journal check:** `journalctl -k -b` (603 link up/down lines, so the log was complete) had no lockdep report, `WARNING:`, `BUG:` or `Oops` after all tests.

## F4b step by step (test hook)

```bash
cd /usr/src/linux-7.2.15 && patch -p1 < ~/Downloads/r8169-adaptive-rx-dim/scripts/test-hooks/force_reset.patch
cd ~/Downloads/r8169-adaptive-rx-dim && bash scripts/build_sign_load.sh
bash scripts/phase3_tests.sh enp3s0 f4b                  # writes 1 to /sys/kernel/debug/r8169_force_reset under load
dmesg | grep 'TEST restore'                              # expect: level 4, IntrMitigate 0x00a0
cd /usr/src/linux-7.2.15 && patch -R -p1 < ~/Downloads/r8169-adaptive-rx-dim/scripts/test-hooks/force_reset.patch
cd ~/Downloads/r8169-adaptive-rx-dim && bash scripts/build_sign_load.sh
```

## Build and style checks (2026-11-14, clean `v7.2.15` clone)

- Patches 0001 to 0006 and the hook apply in order with `patch -p1`, each after `--dry-run`.
- `r8169_main.c` compiles with no warning at `W=1` (defconfig plus `PROVE_LOCKING`, `DEBUG_ATOMIC_SLEEP`, `DEBUG_MUTEXES`, `DYNAMIC_DEBUG`, `DEBUG_FS`, `R8169=m`), with and without the hook. The link step could not be checked there; the PC build is the real one.
- `checkpatch.pl --strict --no-tree` on 0006 and on the hook reports only the missing `Signed-off-by` and the `Co-authored-by` signature.
- `phase3_tests.sh` and `stress_f7.sh` pass `bash -n` and `shellcheck -S warning`; the `f4` and `f9` logic was run once against mocked `ethtool`, `ip` and `iperf3` (not a hardware test).

## Findings (outside patch 0006)

### RX stops after a forced reset

Two F4b runs with 600M UDP load, `rx_packets` and the timer field sampled every 0.1 s:

| Run | What happened |
|---|---|
| Adaptive on, level 4 | `TEST restore: level 4, IntrMitigate 0x00a0`, then `rx_packets` flat from 0.02 s after the reset. The iperf3 receiver got 0 bytes until about 20 s later, when data came back by itself. Turning adaptive off 6 s after the reset did not bring RX back |
| Adaptive off | `rx_packets` flat from 0.02 s after the reset; 600 Mbit/s for 4 s, then 461 packets, then nothing for the remaining 25 s |

The stall does not depend on adaptive mode, on the restore or on a nonzero RX timer. It is very probably the behaviour of the unmodified reset path on this NIC under heavy receive load; not proven because it was not run on an unpatched driver. Not investigated: whether the chip stops receiving or NAPI stops polling (`ip -s link` `rx_missed_errors` and `rx_fifo_errors`, and `/proc/interrupts`, would tell). A forced reset under load therefore cannot show the level climbing again afterwards.

### Network delay after a link-up

`bounce_rx_check.sh` takes the link down for 1 s under a steady 300M UDP load, with NetworkManager in charge, patched module with adaptive on and (first run) adaptive off.

| Observation | Both runs |
|---|---|
| Carrier back after `ip link set up` | about 4.5 s (autonegotiation) |
| Traffic until 31 s later | none; 3 to 4 ARP requests per second went out and nothing came back, the neighbour entry went `INCOMPLETE`, `FAILED`, `INCOMPLETE` |
| TCP and UDP back | both at 35.4 s in the same sample, at full rate (27000 packets per second) |
| Counters at the end | no RX errors, no missed packets (one run 21 missed in the 8 s before) |

The identical 35.4 s and the full-rate resume point at the switch port holding traffic for about 30 s after link-up, not at the NIC. Earlier runs with the stock module (`srcversion A8C76016444D067D3998384`) and NetworkManager off showed no traffic for 90 s with both modules alike. The first run was meant to use the stock module but the patched one was still loaded.

## Pitfalls

- Never apply `force_reset.patch` for a measurement; remove it and rebuild after F4b.
- A link bounce under load costs about 35 s of silence on this network, so any test needs a 30 s allowance after link-up and cannot bounce every 10 s with traffic.
- A static address with NetworkManager off never recovered within 90 s; `stress_f7.sh` no longer uses it.
- A speed change always drops the link for a second or more, so the decay has already set the level to 0 when the link returns; the link work is a safety net for shorter flaps and cannot be observed on hardware by changing the speed. `INTT` stays as chosen, so the steps are coarser or finer than ideal until adaptive mode is turned off and on again.
- A 100 ms toggling of `adaptive-rx` keeps the level at 0; F7 pauses it before every second bounce so teardown sees a level above 0.
- Script bugs fixed during the phase: the line-count `dmesg` check, hidden load failures, a decay timing that took the last packet of any kind, F5 and F10 loads that could not raise the level, and F7 runs with no traffic at the bounces.
- A reset or resume still clears the TX fields of `IntrMitigate` (stock behaviour); only the RX timer is written again.
