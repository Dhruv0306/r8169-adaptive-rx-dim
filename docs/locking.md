# Locking notes for adaptive RX moderation

Written for Phase 3 against the code of patches 0001 to 0006 on `v7.2.15`. It must be checked again against the final patch series before Phase 5, and the test results that bear on it are in `docs/results/phase_3_robustness.md`.

## 1. Locks and their order

| Lock | Kind | Held by |
|---|---|---|
| RTNL | mutex | the networking core around `ndo_open`, `ndo_stop`, ethtool calls and `unregister_netdev()`; the driver itself in `rtl8169_suspend()` and `rtl8169_runtime_suspend()`. The resume functions do not take it |
| PHY lock (`phydev->lock`) | mutex | the PHY state machine around `r8169_phylink_handler()` |
| `rx_dim_lock` | mutex | `rtl_set_coalesce()`, the DIM work, the decay work, the link work, `rtl_rx_dim_restore()` |

**Order: RTNL, then PHY lock, then `rx_dim_lock`.** Nothing takes RTNL or the PHY lock while holding `rx_dim_lock`, and the three work items and `rtl_rx_dim_restore()` take `rx_dim_lock` and nothing else. That is what allows `net_dim_work_cancel()`, `cancel_delayed_work_sync()` and `cancel_work_sync()` to be called under RTNL: the work they wait for never needs RTNL.

`rx_dim_lock` is a mutex, so it is taken only in process context. The poll function (softirq) never takes it.

## 2. Who touches what

| Function | Context | Locks held on entry | Touches |
|---|---|---|---|
| `rtl_set_coalesce()` | process, ethtool | RTNL | takes `rx_dim_lock`; writes `IntrMitigate` and `CPlusCmd` (`cp_cmd`); writes `rx_dim_enabled` (`WRITE_ONCE`); resets DIM when turning on; after dropping the lock, `synchronize_net()`, `net_dim_work_cancel()`, `cancel_delayed_work_sync()`, `cancel_work_sync()` when turning off |
| `rtl_get_coalesce()` | process, ethtool | RTNL | reads `IntrMitigate`, `cp_cmd`, `rx_dim_enabled` (`READ_ONCE`); no lock |
| `rtl_hw_start()` | process | RTNL from `rtl8169_up()` when it comes from open; none when it comes from resume, runtime resume or `rtl_task()` | writes `CPlusCmd` from `cp_cmd`, `IntrMitigate = 0` (chip start); at its end `rtl_rx_dim_restore()` |
| `rtl_rx_dim_restore()` | process, inside `rtl_hw_start()` | none of its own | takes `rx_dim_lock`; writes `IntrMitigate` (RX bits); sets DIM state; arms the decay work |
| `rtl8169_poll()` and `rtl_rx_dim_update()` | softirq (NAPI) | none | reads `rx_dim_enabled`, `profile_ix`; writes the packet, byte and event counters and, through `net_dim()`, the DIM state and `profile_ix`; queues the DIM work. Never takes `rx_dim_lock` |
| `rtl_rx_dim_work()` | workqueue | none | takes `rx_dim_lock`; writes `IntrMitigate` (RX bits); arms the decay work; sets DIM state |
| `rtl_rx_dim_decay_work()` | workqueue | none | takes `rx_dim_lock`; may reset DIM and write `IntrMitigate` (RX bits); re-arms itself |
| `rtl_rx_dim_link_work()` | workqueue | none | takes `rx_dim_lock`; writes `IntrMitigate` (RX bits) |
| `r8169_phylink_handler()` | PHY state machine | PHY lock | reads `rx_dim_enabled`; `schedule_work()` for the link work; takes no other lock |
| `rtl8169_down()` | process, close, suspend or runtime suspend | RTNL | after `rtl8169_cleanup()` (NAPI disabled): `net_dim_work_cancel()`, `cancel_delayed_work_sync()`, `cancel_work_sync()`, DIM reset; holds no `rx_dim_lock` |
| `rtl_task()` | workqueue | none | `rtl_reset_work()`, which runs `rtl_hw_start()` |

Writers of `CPlusCmd` are `rtl_set_coalesce()` (through `rtl_write_coalesce()`), `rtl_hw_start()` and the existing offload code (`rtl_set_rx_config_features()` path); none of the DIM work items writes it. Writers of `IntrMitigate` are the same two plus the three work items and `rtl_rx_dim_restore()`, and every one of the last four does a read-modify-write of the RX bits under `rx_dim_lock`.

## 3. Rules the code follows

1. `rx_dim_enabled` is written with `WRITE_ONCE()` under `rx_dim_lock` and read with `READ_ONCE()` in the poll function and the PHY handler. The work items and the ethtool path read it under the lock.
2. The packet, byte and event counters are written only in NAPI context (one queue, one NAPI instance, so no lock). The decay work reads the event counter with `READ_ONCE()`; a torn read is not possible for a `u16`.
3. The work items check `rx_dim_enabled` after taking the lock, so a work item that ran after adaptive mode was turned off does nothing.
4. Cancel calls are made with no lock of the driver held: in `rtl_set_coalesce()` after `mutex_unlock()`, in `rtl8169_down()` where nothing holds `rx_dim_lock`.
5. Teardown order in `rtl8169_down()`: `rtl8169_cleanup()` first (so no poll can queue the DIM work), then `net_dim_work_cancel()`, then the decay work (it can be re-armed by the DIM work, so the DIM work goes first), then the link work.
6. `rtl_hw_start()` takes `rx_dim_lock` only at its end, with no other driver lock held, so it is safe with or without RTNL, from every caller of `rtl_reset_work()` (open, resume, runtime resume and `rtl_task()`).

## 4. Known races and why they are harmless

| Race | What can happen | Why it is acceptable |
|---|---|---|
| The decay work sets `profile_ix` to 0 and resets DIM state while `net_dim()` runs in NAPI | DIM may use a mix of old and new state for one decision, or write `profile_ix` after the work did | Needs a poll to arrive in the same moment that a whole 200 ms period had none. Whatever `net_dim()` decides it queues the DIM work, which writes the level `profile_ix` holds when it runs, so register and DIM agree again afterwards. No memory is shared in a way that can be corrupted |
| `rtl_hw_start()` in `rtl_task()` runs with NAPI already enabled | The restore sets DIM state while a poll could run | The interrupts stay masked until the end of `rtl_hw_start()` and the RX path is off, so no poll is expected; the DIM work does the same write from the workqueue in normal operation |
| The link work runs after a speed change while the DIM work applies a new level | Two writers of `IntrMitigate` | Both hold `rx_dim_lock` and read-modify-write the RX bits, so the last writer wins and both write the same level |
| `INTT` was chosen at one speed and the link changes | The unit changes; the level is rounded to the new unit | By design (D3 of the plan). A level shorter than half a unit gives 0 (no moderation). Turning adaptive mode off and on again chooses `INTT` for the new speed |

## 5. What the tests must show (Phase 3)

- No lockdep report in any test, in particular F4, F4b, F7 and F11, which run the three paths (ethtool, workqueue, RTNL) against each other.
- After every hardware restart the registers agree with the DIM level (F4, F4b).
- `rmmod` never hangs (F7).

Results and the conclusions drawn from them go in the Phase 3 results file.
