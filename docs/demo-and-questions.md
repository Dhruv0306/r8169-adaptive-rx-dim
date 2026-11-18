# Running the demo, and the questions to expect

How to run the live demo, what to say, and the questions a professor is likely to ask, with answers grounded in the project. Companion documents: the run sheet [`demo.md`](demo.md) (setup table, stage-by-stage notes and failure handling), [setup and testing](setup-and-testing.md), [project explained](project-explained.md), [results explained](results-explained.md) and the [diagrams](diagrams/README.md). Keep [diagram 0](diagrams/00-overview.md) open on screen or printed; it answers most "how does it work" questions.

## 1. What the demo shows, in one sentence

On the real machine, the card's receive timer rises to 400 microseconds when a burst of small packets arrives, falls back to 0 when it stops, and stays at 0 for request-response traffic, where a fixed 400 microsecond timer would cost 87% of the transactions per second.

## 2. Before the demo

| When | Do |
|---|---|
| The day before | Rehearse twice with the real script. Charge the phone for tethering. Check `git status` is clean on the branch you will show, and that the module loads |
| 15 minutes before | Peer: `pkill iperf3; iperf3 -s &` and `netserver` running. PC at the console, logged in as root, in the repository root. `cat /sys/module/r8169/srcversion` prints `04E8D19E5DCBE28E8305847` (the frozen build); if it does not, run `bash scripts/build_sign_load.sh /usr/src/linux-7.2.15`. Wait 40 s after any link-up or module swap |
| Open on screen | The terminal, [diagram 0](diagrams/img/00-overview.png), and `docs/figures/stepped_adaptive-600M.png` as a backup |
| Backup ready | The recorded session: `scriptreplay -T results/phase5/fallback/demo-timing.txt -s results/phase5/fallback/demo-session.txt -d 2` (needs no network) |

## 3. Running it

```bash
export PEER=<peer address>
bash scripts/demo.sh -p $PEER              # about 3 minutes with pauses, press Enter after each stage
bash scripts/demo.sh -p $PEER -t long      # about 10 minutes (longer idle periods, a 15 s burst)
bash scripts/demo.sh -p $PEER -y -o results/phase5/rehearsal-N   # rehearsal: no pauses, log kept
```

The script puts the device back (adaptive off, `rx-usecs` 0) when it ends or is interrupted with Ctrl-C. The short version prints about 20 lines in stage 4; the long version prints about 40 and scrolls the burst off the screen, so use the short version live and the long one for recordings.

## 4. The script: what to say at each stage

| Stage | On screen | Say |
|---|---|---|
| 1. Module and flag | `Adaptive RX: off`, `rx-usecs: 0`, the kernel and srcversion | "This is the modified `r8169` driver. With the flag off it behaves exactly like the stock driver; the stock module prints `Adaptive RX: n/a` and refuses the flag." |
| 2. Adaptive on, idle | `Adaptive RX: on`, level 0, almost no interrupts | "I switch the mode on with ethtool. Without traffic there is no delay: the level is 0." |
| 3. Burst | The peer sends 100 byte UDP packets. `rx-usecs` goes to about 400, interrupts per second fall to about 3,300 | "DIM sees more packets per millisecond and steps the level up. The card now holds the interrupt back up to 400 microseconds, so one interrupt covers about 40 packets. With the mode off this load takes about 17,000 interrupts a second." Point at the first row (the ramp) and at a dip to 200 if it appears: "DIM tries one level down and goes back up." |
| 4. Burst ends | The level falls to 0 within the first rows | "When the packets stop, a 200 millisecond watch drops the level to 0, so the next packet is not delayed. Measured: 0.4 seconds." |
| 5. Request-response | About 13,000 transactions per second at level 0; then about 1,600 with a fixed 400 us timer | "One packet at a time: the adaptive mode stays at 0 and costs nothing. A fixed 400 microsecond timer would cost 87% of the transactions per second, which is why it must be adaptive." |
| 6. Cleanup | Back to adaptive off | "The script restores the device." |

Numbers on the day differ a little from the tables; say so. The reference values are in [results explained, 5.3 and 5.5](results-explained.md).

## 5. What to state about the limits

One chip variant (RTL8168h), one peer, one link speed (1 Gbit/s). The gain is in softirq work and CPU time under small-packet load; bulk TCP has nothing to win and is unchanged. At 900 Mbit/s of large datagrams the level climbs unreliably.

## 6. Questions to expect, with answers

Answers are short and refer to where the evidence is. Where the honest answer is "not tested" or "not known", it says so; say the same.

### 6.1 The idea

**What problem does this solve?**
A card can delay its receive interrupt so that one interrupt covers many packets. A fixed delay saves CPU work under heavy load and slows every reply under light load. The driver could only use a fixed value set by hand. This makes the delay follow the traffic. ([Project explained, section 1](project-explained.md))

**What is interrupt moderation, and why not just use NAPI?**
NAPI already polls and keeps the interrupt masked while packets keep coming, so at line rate with big packets moderation has nothing to add: bulk TCP takes about 2 interrupts a second even without it. Moderation helps in the middle range, with many small packets, where the poll finishes between packets and each one causes an interrupt. ([Results 4, 5.6](results-explained.md))

**Why not choose one good fixed value?**
There is none. 80 microseconds costs 42% of the request-response transactions per second, 400 microseconds costs 87%, and 0 gives up the saving under heavy load. ([Results 5.5](results-explained.md))

**What is DIM and who else uses it?**
The kernel's dynamic interrupt moderation library (`lib/dim`). Other drivers use it, `virtio_net` among them, and it was the model here. `r8169` did not use it before. ([Diagram 2](diagrams/02-dim-decision.md))

**What is the register you write?**
`IntrMitigate`, 16 bits: RX frame count, RX timer, TX frame count, TX timer, 4 bits each. The timer unit depends on the link speed and the `INTT` bits of `CPlusCmd`. I write only the RX timer field. ([Project explained, 2.2](project-explained.md))

### 6.2 Design

**Why five levels and why 0, 40, 80, 200, 400?**
DIM has five levels. The library's default tables assume counts a 4 bit field cannot hold. At 1 Gbit/s with `INTT` 1 the unit is 40 microseconds, so 40 to 400 microseconds are fields 1 to 10, below the limit of 15. The 200 microsecond point was measured in Phase 0. The table passed the plan's tuning rule on the first try, so it was not changed. ([Project explained, 12](project-explained.md))

**Why timer-only, no frame counts?**
The hardware needs a timer whenever a frame count is set, and the stock timer-only path runs with `PktCntrDisable` set (confirmed on this chip). A frame limit would add a rule the hardware must obey and was not needed.

**Why receive only?**
To keep the first version small. The RX and TX fields of the register are separate, so RX can change without touching TX. A non-zero TX frame limit is refused while adaptive mode is on.

**Why do you call DIM on every poll and not at poll completion?**
At line rate the poll may never complete, so DIM would not be sampled. An event is one poll that received packets. ([Diagram 1](diagrams/01-poll-and-sampling.md))

**What is the single-packet guard? Is it a hack?**
At level 0 a poll with one packet is not shown to DIM. Without it DIM left level 0 on statistics noise and request-response lost 5.8% (test T5). It is a heuristic on top of the stock algorithm, and I say so. Above level 0 every poll counts, so DIM can step back down. A smaller first step would have given up much of the UDP gain, and accepting the loss was against the plan's own criterion.

**Why an idle decay?**
DIM runs only when polls happen. After a burst there are no more samples, so the level would stay at 400 microseconds and delay the first packets of the next sparse traffic. I saw exactly that in test T7 before adding the decay. A 200 ms delayed work drops the level to 0 when no poll happened in a whole period. ([Diagram 5](diagrams/05-lifecycle.md))

**Why is the `INTT` unit chosen once, on the ethtool path?**
So that the work function never writes `CPlusCmd`. Otherwise it would be a third writer next to the ethtool path and the hardware start. The unit is chosen for the longest level.

**What does `ethtool -c` show while adaptive is on?**
The live register, so the current level. A request that echoes `rx-usecs` back is ignored for the same reason, and the user's static settings are saved when the mode is turned on and restored when it is turned off. ([Diagram 4](diagrams/04-ethtool-control.md))

### 6.3 Code and correctness

**Which files did you change?**
Two kernel files: `drivers/net/ethernet/realtek/r8169_main.c` and its `Kconfig` (one line, `select DIMLIB`). 374 lines added and 31 removed in six patches. ([Kernel changes](kernel-changes.md))

**How do you avoid races between the poll, ethtool and the work items?**
One mutex, `rx_dim_lock`, protects the flag, the saved settings and the register writes of the adaptive path. The poll never takes it: the counters are written and read only in NAPI context, and the flag is written with `WRITE_ONCE()` and read with `READ_ONCE()`. The work items take only that mutex. ([Diagram 6](diagrams/06-locking.md))

**Why can the work be cancelled under RTNL without a deadlock?**
Because the work items never take RTNL or the PHY lock. If one did, `cancel_work_sync()` under RTNL could wait for something that waits for RTNL. Same pattern as `virtio_net`.

**What happens when the NIC is reset?**
The chip start writes `IntrMitigate = 0`. `rtl_rx_dim_restore()` writes the level DIM holds again at the end of `rtl_hw_start()`, before the interrupts are enabled. I tested it with a debugfs hook that forces a reset: the log showed level 4 and `IntrMitigate 0x00a0` right after. ([Diagram 5](diagrams/05-lifecycle.md))

**What happens when the link speed changes?**
The timer unit changes (20.48 microseconds at 100 Mbit/s), so a work item writes the level again with the new unit. I measured level 2 as field 4 at 100 Mbit/s. The PHY handler holds the PHY lock, so it only queues that work.

**What happens on unload, suspend and resume?**
`rtl8169_down()` cancels the work items after NAPI is stopped and resets DIM; after resume the level starts at 0. Tested: five unload rounds under load, suspend with `rtcwake`, and a 36 minute stress run with 19 link bounces and 20 module reloads, with lockdep on and no report.

**How do you know it is safe?**
Lockdep was enabled in the kernel for all tests; `W=1` compiles with no warning; checkpatch reports only expected items. What I did not do: run `sparse`, test other chips, or get a maintainer review. ([Results 5.2, 5.8](results-explained.md))

**Does adaptive off really equal the stock driver?**
In the final matrix `stock` against `off` is noise in every cell, and `rtl_write_coalesce()` with `adaptive` false is the old code moved unchanged.

### 6.4 Measurement

**How did you measure, and why these workloads?**
Two machines on a gigabit LAN. `iperf3` for bulk TCP and UDP, `netperf` TCP_RR for request-response. Request-response is where latency matters, bulk TCP is the case where nothing should change, and small-packet UDP is where moderation should help. Five configurations in interleaved rounds with alternating order, 12 runs per cell in the final matrix, `stock` at both ends. ([Diagram 7](diagrams/07-measurement-setup.md))

**Why do you measure CPU from cpuidle residency?**
The PC's kernel samples `/proc/stat` only at the scheduler tick; with paced traffic the same load read 0% in one run and 86% in the next. The share of time the interrupt CPU is not in a cpuidle state does not depend on the tick. ([Results 3.3](results-explained.md))

**Why the 100 microsecond pacing timer for the small-packet workload?**
iperf3's default 1 ms pacing sends bursts, so the NIC takes about 2,000 interrupts per second at every rate and the interrupt rate says nothing about moderation. With a 100 microsecond timer the rate follows the load (about 17,000 to 20,000 per second with the mode off).

**What are the headline numbers?**
Small-packet UDP at 50 and 100 Mbit/s: NET_RX -82% and -77%, interrupts per second from about 19,900 and 16,900 to about 3,100 and 3,300, interrupt CPU -15% and -31%, no loss. Request-response unchanged (about 13,000 transactions per second, 77 us). Bulk TCP unchanged at 941 Mbit/s. ([Results 2](results-explained.md))

**Are the differences significant?**
A difference smaller than the larger standard deviation is called noise. The headline differences are many standard deviations (for example NET_RX 39,885 +/- 283 against 7,176 +/- 1,820). Effects below about 1.5% cannot be resolved with 12 runs.

**Was there a cost?**
Packet delay: jitter at 50 Mbit/s rose from 0.007 to 0.017 ms. A fixed 400 microsecond timer gives 0.021 ms. Possibly a very small cost for bulk TCP in the tick-sampled counters, which the cpuidle measure cannot resolve.

**Why does it only reach about 3,300 interrupts per second and not 2,500 (one per 400 microseconds)?**
I did not analyse the card's timer behaviour in that detail. What was measured is that the interrupt rate falls to about 3,300 per second with the timer at 400 microseconds, about one interrupt per 300 microseconds on average.

**Why does the level dip to 200 now and then?**
DIM tries one level down to see whether the traffic does as well, and goes back up. It happens in a few samples out of 30 and never goes lower during the burst.

**What about 900 Mbit/s?**
The result is partial: NET_RX -20% and CPU -18% on average, but the level traces are bimodal (one run in ten reached the top level, three stayed at 0). DIM judges packets, bytes and polls per millisecond, and those barely change between levels there. A fixed 400 microsecond timer cuts NET_RX by 36% but not the interrupt rate, which supports that explanation. I did not test it further or change the algorithm. ([Results 5.7](results-explained.md))

### 6.5 Process and honesty

**What went wrong during the project?**
Request-response lost 5.8% with the first core (fixed by patch 0005); the level stayed high after a burst (fixed by the idle decay); the interrupt counter first read the wrong IRQ; one visit in the final matrix was disturbed by a transmit timeout and was removed from one configuration with the raw logs kept; my first Phase 5 check used the wrong pacing and was redone. ([Results 5.9](results-explained.md))

**Anything unexplained?**
Two things outside the driver: this network forwards nothing for about 35 seconds after every link-up, and a forced reset under heavy load leaves RX dead for 20 s or more with the mode on or off. Both are recorded, neither is caused by the patches, and the second may be the same switch effect (not proven). About 200 ms latency outliers appear in a few request-response runs with every configuration including stock; the cause was not investigated.

**Why is Claude listed as co-author?**
Commits carry a `Co-authored-by: Claude` trailer because an AI assistant helped draft the code and the documents. Say what is true for your own work: what you decided and reviewed, and that you ran every measurement on your own hardware. Do not claim more or less than that.

**What would you do next?**
Test other chips of the family (RTL8125 needs a different coalescing path), transmit moderation, a second source of load information so DIM can ramp up at 900 Mbit/s (for example the poll rate alone), more than one queue, and a submission to the netdev list, which needs `Signed-off-by`, a review of the guard heuristic and the table, and tests on more hardware.

**Could this go upstream?**
Not as it is. It needs a maintainer's review, more chips and link speeds, `sparse` and a justification of the single-packet guard.

**Which part is your own contribution and which is the library's?**
The library decides the level. The project supplies the sampling (counters, events, the guard), the table, the register write, the ethtool semantics, the restart, link and idle handling, the locking, and the measurements.

## 7. Questions you may not expect, and a safe way to answer them

| Question | Safe answer |
|---|---|
| "Run it with the stock driver." | `rmmod r8169; modprobe r8169`, wait 40 s, `ethtool -c enp3s0` prints `Adaptive RX: n/a` and `adaptive-rx on` is refused. Then reload the patched module with `build_sign_load.sh`. Do this only if there is time |
| "Show the registers." | `bash scripts/read_intrmit.sh enp3s0` decodes `CPlusCmd` and `IntrMitigate`; with the mode on and a burst running, run it twice and the RX timer field changes (5 and 10 under load) |
| "What if I unplug the cable now?" | The link work and the idle decay handle it; this was tested with 19 link bounces. On this network traffic takes about 35 s to come back after the link returns |
| "Does this work on my laptop's card?" | Only on the RTL8111/8168 family with static coalescing support. RTL8125 chips return `EOPNOTSUPP` and are out of scope. Not tested on other chips |
| "Show me the code." | `git diff v7.2.15..HEAD` on the patched kernel tree, or open `patches/0004-*.patch` and `patches/0006-*.patch`; the functions are listed in [kernel changes](kernel-changes.md) |
| "What if DIM chose a wrong level?" | The worst case is a delay of up to 400 microseconds on packets, or the saving not realised; nothing is lost. The measurements show no loss and no throughput change |
