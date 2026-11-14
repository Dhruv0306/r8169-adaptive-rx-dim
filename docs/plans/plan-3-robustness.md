# Plan for Phase 3: Robustness and locking

Status: not started. Depends on Phase 2. High-level summary: [`../phases.md`](../phases.md), Phase 3. Results go in `docs/results/phase_3_robustness.md`, and the locking analysis in `docs/locking.md`.

Machine tags: **[Claude]** work in the chat, **[PC]** machine under test (root, at the console), **[PEER]** second machine, **[repo]** project repository. Set `PEER=<peer address>` first.

## 1. Goal and scope

Make adaptive mode correct in every situation the hardware and the stack put it in: hardware restarts, link speed changes, interface down and up, suspend and resume, module unload, idle after load, and concurrent ethtool changes. Write the locking rules down and check them with lockdep.

Patch series: 0006 (re-apply, link change, idle decay, teardown, locking). The locking analysis is a document, not code.

Not in scope: new levels or tuning (Phase 4), TX moderation, RTL8125.

## 2. Facts this phase builds on (v7.2.15 source, checked while planning)

- `rtl_hw_start()` writes `CPlusCmd = tp->cp_cmd`, runs `rtl_hw_start_8168()` (which writes `IntrMitigate = 0`) and ends with `rtl_set_rx_mode()` and `rtl_irq_enable()`. So after any hardware start the `INTT` unit and `PktCntrDisable` survive (they live in `tp->cp_cmd`) and only `IntrMitigate` is lost. Confirmed by the register check in Phase 0.
- `rtl_hw_start()` is reached through `rtl_reset_work()`, from two callers: `rtl8169_up()` (open and resume, RTNL held) and `rtl_task()` (a workqueue, no RTNL), which handles the transmit timeout and PCI error resets. `rtl_task()` takes no lock, which is why the work function must not depend on RTNL.
- `rtl8169_down()` serves both close and suspend: `disable_work_sync()` on the reset work, `phy_stop()`, `rtl8169_cleanup()` (which runs `napi_disable()` and masks interrupts), then power-down. Close, system suspend and runtime suspend all call it with RTNL held.
- `rtl_remove_one()` calls `unregister_netdev()`, which closes the device through the same path.
- Link changes arrive in `r8169_phylink_handler()` (called from the PHY state machine with the PHY lock held). The timer unit for a given `INTT` depends on link speed (at 100 Mbit/s the units are 2.56, 20.48, 40.96, 81.92 microseconds; at 10 Mbit/s 40.96 up to about 1.3 ms).
- DIM is driven only from the poll function, so with no packets the level never changes (Phase 2, test T7).

## 3. Design decisions

| # | Decision | Reason and alternatives |
|---|---|---|
| D1 | Re-apply at the end of `rtl_hw_start()`, just before `rtl_irq_enable()`: under `rx_dim_lock`, if adaptive is on, reset the DIM measurement state (`DIM_START_MEASURE`) and write the current level | One place covers open, resume and both reset causes. Writing before interrupts are enabled avoids a window with no moderation |
| D2 | Level kept across a hardware reset (transmit timeout, PCI error); reset to 0 in `rtl8169_down()` | A reset is invisible to the user, so the load is probably the same. A real stop (close, suspend) restarts the measurement from level 0 |
| D3 | Link change: `r8169_phylink_handler()` queues a separate small work item. It recomputes the timer units for the new speed with `INTT` unchanged and writes `IntrMitigate`. At 10 Mbit/s a level that rounds to 0 units means no moderation | A separate work item keeps the PHY lock away from `rx_dim_lock` and does not disturb DIM's own state machine. `INTT` stays unchanged so that no new writer of `CPlusCmd` exists. Known limit: after a speed change the steps are coarser or finer than ideal until adaptive mode is turned off and on again |
| D4 | Idle decay: a delayed work that runs every 200 ms while the level is above 0. If the poll event counter has not moved since the last tick, set the level to 0, reset the DIM state and write the register | DIM never runs without packets, so a high level would delay the first packets after a quiet period. For sparse traffic DIM would need 64 events to react. Measured need: Phase 2, test T7 |
| D5 | Teardown order in `rtl8169_down()`: after `rtl8169_cleanup()` (poll can no longer schedule work), `net_dim_work_cancel()`, `cancel_work_sync()` on the link work, `cancel_delayed_work_sync()` on the decay work. Never while holding `rx_dim_lock` | The cancel calls wait for a running work, and that work takes `rx_dim_lock` |
| D6 | Lock order: RTNL, then PHY lock, then `rx_dim_lock`. Nothing takes RTNL or the PHY lock while holding `rx_dim_lock`. The work items take only `rx_dim_lock`. `rx_dim_enabled` is written with `WRITE_ONCE()` under `rx_dim_lock` and read in the poll with `READ_ONCE()` | The only writers of `CPlusCmd` stay the ethtool path and `rtl_hw_start()`; the DIM-related code writes only `IntrMitigate` |
| D7 | A test-only hook (not in the series) forces the reset path: a debugfs write that calls `rtl_schedule_task(tp, RTL_FLAG_TASK_RESET_PENDING)`. Kept as `scripts/test-hooks/force_reset.patch` | A transmit timeout cannot be triggered on demand, and F4 and F6 do not exercise the `rtl_task()` caller of `rtl_hw_start()` |

## 4. Work steps

1. **[Claude] Read the code paths again against Phase 2's final code** and write `docs/locking.md` first: every function that touches `IntrMitigate`, `cp_cmd`, `rx_dim_enabled` or the DIM state, which context it runs in (hard IRQ, softirq, workqueue, RTNL, PHY lock), and the lock order of D6.
2. **[Claude] Write patch 0006** (D1 to D5) and the test hook patch (D7). Deliver as patch files, tested with `patch -p1` on the series so far.
3. **[PC] Apply, build, sign, load** with `scripts/build_sign_load.sh` (Phase 2).
4. **[PC] Run the tests of section 5 in order**, reading `dmesg` after each. Keep the console open; a stuck state can take the only network link down.
5. **[PC] Run the stress test** of F7 for at least 30 minutes.
6. **[Claude] Write `docs/results/phase_3_robustness.md`**, finish `docs/locking.md` with what the tests showed, and update the tracker and handoff.

## 5. Tests

Start each test with `ethtool -C enp3s0 adaptive-rx on`, and use `bash scripts/read_intrmit.sh enp3s0` for the registers and `scripts/sample_level.sh` for the level.

| # | Test | Commands and procedure | Expected |
|---|---|---|---|
| F4 | Down and up under adaptive mode | `for i in $(seq 1 10); do ip link set enp3s0 down; sleep 1; ip link set enp3s0 up; sleep 5; bash scripts/read_intrmit.sh enp3s0; done` (console or tether) | After each up the registers show the adaptive state (`INTT` 1, `PktCntrDisable` 1, `IntrMitigate 0x0000` at idle) and the first traffic moves the level. No warning in `dmesg` |
| F4b | Reset path (needs the test hook) | Load the traffic: `iperf3 -c $PEER -R -u -b 600M -t 40 &`; when the level is above 0, trigger the forced reset; read the registers | The level is written again immediately after the reset, `IntrMitigate` is not left at 0 while the level is above 0 |
| F5 | Link speed change | On the PC: `ethtool -s enp3s0 advertise 0x008` (100 Mbit/s full), wait for the link, run `ethtool -c` and the registers, then restore with `ethtool -s enp3s0 advertise 0x02f` (the link drops for a few seconds, so use the console) | `INTT` unchanged; timer in microseconds roughly equal to the table at the new speed (rounded to the 20.48 microsecond unit); back at 1000 Mbit/s the original values return |
| F6 | Suspend and resume | If supported: `echo freeze > /sys/power/state` at the console, wake with a key; or `rtcwake -m freeze -s 20` | Adaptive mode still reported `on`, registers show the adaptive state, traffic moves the level, no warning |
| F7 | Stress | Traffic running from the peer (`iperf3 -c $PEER -R -u -b 300M -t 1800` and a TCP_RR loop). A script toggles `adaptive-rx on/off` every 100 ms, `ip link set down/up` every 10 s, and the 20 module reloads (`rmmod r8169; insmod /root/r8169-new-signed.ko`) once the toggling has run for 10 minutes | No oops, no `WARN`, no lockdep report, no stuck `rmmod`; the registers are consistent with the flag after every step |
| F9 | Idle decay | Run T4 of Phase 2 (UDP at 600 Mbit/s), stop it, sample the level for 5 seconds | The level is back at 0 within about 400 ms after the traffic ends |
| F10 | Sparse traffic after a burst | Bulk UDP for 10 seconds, stop, wait 2 seconds, then `netperf -H $PEER -t TCP_RR -l 5 -P 0 -- -r 64,64` | Transactions per second and latency close to the no-moderation figures from the first second |
| F11 | Concurrent ethtool | Two terminals alternate `ethtool -C enp3s0 adaptive-rx on/off` and `ethtool -C enp3s0 tx-usecs 20 / tx-usecs 0` while the load runs | No warning; TX settings keep their value; the RX bits follow the flag |
| F8 | Build quality | `make W=1`; `sparse` (`make C=1 M=drivers/net/ethernet/realtek`) if installed; `checkpatch --strict --no-tree` | No new warning in `r8169_main.c` |

`dmesg` after each test: `dmesg | grep -iE 'lockdep|WARNING|BUG|Oops|possible circular|r8169'` as root.

## 6. Acceptance criteria

- F4 to F7 and F9 to F11 pass with no lockdep report, oops or `WARN`, and the level is right after every hardware restart.
- `docs/locking.md` exists, states the lock order and which context runs each function, and was checked against the final patch.
- Patch 0006 builds with no warning from `r8169_main.c` and applies on the series with `patch -p1`.
- The test hook is not part of the series.

## 7. Risks and fallbacks

| Risk | Fallback |
|---|---|
| A deadlock between the ethtool path, the PHY handler and the work items | Lockdep is on; fix the order, or drop the separate link work and handle the speed change inside the DIM work |
| The idle decay adds noticeable overhead or fights DIM | Longer period (500 ms), or decay only the top levels; compare `irq_cpu_busy_pct` with and without |
| Suspend and resume are not supported on the machine | Record F6 as not run and cover the same code with F4 (the resume path is `rtl8169_up()`) |
| The PHY handler path cannot take the work item safely | Move the recompute into `rtl_hw_start()` and `rtl_set_coalesce()` only, and document that a pure speed change keeps the old units until the next restart |
| A test leaves the NIC unusable | `rmmod r8169; modprobe r8169` loads the stock module; keep the phone tether ready |

## 8. Results file outline (`docs/results/phase_3_robustness.md`)

Status and date; patch 0006 and what it changes; decisions D1 to D7 with changes from this plan; each test F4 to F11 with the commands run and the outcome; lockdep and `dmesg` findings; bugs found and fixed during the phase; known limits (for example the `INTT` after a speed change); carried-forward items for Phase 4.
