# Demo run sheet

The demo shows the adaptive mode following a load on the real machine: the receive timer rises when a burst of small packets arrives, falls when it stops, and stays at zero for request-response traffic. It is run by `scripts/demo.sh`. The script stops after each stage (press Enter), so the speaker sets the pace.

## 1. Setup before the demo

Do this once, at least ten minutes before, because a link-up needs about 35 s before traffic flows on this network (see `docs/handoff.md`, section 5).

| Where | What |
|---|---|
| PC | Console, logged in as root. `cd /home/aoscsg623/Downloads/r8169-adaptive-rx-dim` (the clone, on `main`). Phone tether ready: the NIC is the only connection |
| PC | The patched module is loaded and signed: `cat /sys/module/r8169/srcversion` prints `04E8D19E5DCBE28E8305847` (the frozen build). If not, `bash scripts/build_sign_load.sh /usr/src/linux-7.2.15` |
| PC | A copy of the stock module is at `~/r8169-stock-src/` (the way back is `rmmod r8169; modprobe r8169`) |
| PC | `irqbalance` stopped and the CPU governor as in Phase 4 only if the numbers matter; for the demo the defaults are fine |
| Peer | `iperf3 -s` and `netserver` running (`pkill iperf3; iperf3 -s` clears a busy server) |
| Both | Same LAN, gigabit cable. `ping PEER` answers |

Rehearse twice, as it will be shown (plan-5, step 5). Keep the stock module and the tether at hand.

## 2. Commands

Three minute version, with a pause after each stage:

```bash
bash scripts/demo.sh -p PEER
```

Ten minute version (longer idle periods, a 15 s burst, 10 s request-response runs):

```bash
bash scripts/demo.sh -p PEER -t long
```

Rehearsal or fallback recording, no pauses, with a copy of the screen in a file:

```bash
bash scripts/demo.sh -p PEER -y -o results/phase5/rehearsal-1
```

Fallback recording of the whole terminal session (run before the script, stop with `exit`):

```bash
script -t 2> /root/demo-timing.txt /root/demo-session.txt
```

`scripts/stepped_load.sh -p PEER` gives the same idea as a figure (level against time over three bursts, `docs/figures/stepped_adaptive-600M.png`); keep the figure open as a second fallback.

## 3. What each stage shows and what to say

| Stage | On screen | Say |
|---|---|---|
| 1. Module and flag | `Adaptive RX: off`, `rx-usecs: 0`, kernel and srcversion | The driver is the modified `r8169`. With the flag off it behaves like the stock driver. The stock module prints `Adaptive RX: n/a` and refuses the flag |
| 2. Adaptive on, idle | `Adaptive RX: on`, the level line at 0 us | The mode is a switch in ethtool, `adaptive-rx on`. With no traffic there is no delay |
| 3. Burst | Peer sends 100 byte UDP packets. `rx-usecs` climbs to about 400 (usually within a second; in Phase 4 one run of ten ramped late) and the interrupt rate drops to about 3,300 per second. The level dips to 200 us now and then (up to about a third of the samples in the rehearsals): DIM tries one level down and goes back up. Never below 200 while the burst lasts | DIM sees more packets per millisecond and steps the level up. The hardware now holds interrupts back for up to 400 microseconds and one interrupt serves many packets. In Phase 4 the interrupt rate at this load fell from about 16,900 to 3,300 per second at 100 Mbit/s, and the receive softirq rate fell by 77 to 82% |
| 4. Burst ends (starts at once, no pause after stage 3, sampled every 0.2 s) | `rx-usecs` falls to 0 about 0.4 s after the last packet (Phase 3 and 4: 0.4 to 1.3 s with the measurement slack) | The idle timer (a 200 ms tick) sets the level to 0, so the next sparse packet is not delayed |
| 5. Request-response | With adaptive on: about 13,000 transactions per second, level 0. With a fixed 400 us timer: about 1,650 | Light traffic must not be delayed. A fixed timer costs 87% of the transactions per second here. The adaptive mode costs nothing measurable (Phase 4, `rr` and `rrp`) |
| 6. Cleanup | `Adaptive RX: off`, `rx-usecs: 0` | The script puts the device back, also when stopped with Ctrl-C |

The numbers quoted are from `docs/results/phase_4_measurement_and_tuning.md`, section 4.4 (12 runs per cell). Live numbers on the day will differ a little; say so.

## 4. If something goes wrong

| Problem | Do |
|---|---|
| `adaptive-rx` is refused | The stock module is loaded. Check `cat /sys/module/r8169/srcversion`, then `bash scripts/build_sign_load.sh` and wait 40 s |
| `peer ... does not answer on 5201` | On the peer: `pkill iperf3; iperf3 -s` and check `netserver` is running. After a link-up wait about 40 s |
| The level does not rise in stage 3 | The burst never started (peer busy). Check the peer, run the stage again; or show the figure `docs/figures/stepped_adaptive-600M.png` |
| The network is gone after the demo | `ethtool -C enp3s0 adaptive-rx off; ip link set enp3s0 up`; if needed `rmmod r8169; modprobe r8169` (stock module), then phone tether |
| Time is short | Run the stage 3 and stage 5 only, from the figures and the Phase 4 tables for the rest |

## 5. Limits to state during the demo

One chip variant (RTL8168h), one peer, one link speed (1 Gbit/s). The benefit is in softirq work and CPU time under small-packet load, not in bulk TCP, which already takes about 2 interrupts per second at line rate. At 900 Mbit/s UDP the level rises late in some runs (reported in Phase 4).
