# Kernel code changes: files created or changed

Everything the project changed in the kernel's source tree, with the purpose of each change. The base is Linux `v7.2.15`. The series changes two files; the numbers are from `git diff --stat v7.2.15..HEAD` on a clean tree with the six patches applied: 374 lines added and 31 removed. Nothing is created in the kernel tree by the series: no new `.c` or `.h` file, and no change to any other kernel file. Where the code sits in the system: [diagram 0](diagrams/00-overview.md); how the patches build up: [diagram 8](diagrams/08-series-and-build.md). The design behind each item is in [project explained](project-explained.md).

## 1. Summary table

| File | Kind | Patches | Purpose |
|---|---|---|---|
| `drivers/net/ethernet/realtek/Kconfig` | Changed | 0001 | Make the `R8169` driver select the DIM library |
| `drivers/net/ethernet/realtek/r8169_main.c` | Changed | 0001 to 0006 | All of the adaptive moderation: state, sampling, level table, register write, ethtool flag, lifecycle handling |
| `scripts/test-hooks/force_reset.patch` (in the project repository, applies to `r8169_main.c`) | Test aid, not part of the series | none | A debugfs hook that triggers the driver's reset task on demand, to test that the level is written again after a reset. Never applied for measurements |

No other file of the kernel source is touched. The driver is built as a module (`r8169.ko`), so a rebuild of the whole kernel is not needed.

## 2. `drivers/net/ethernet/realtek/Kconfig`

| Change | Patch | Purpose |
|---|---|---|
| `select DIMLIB` added to `config R8169` | 0001 | The driver now calls the DIM library (`net_dim()` and friends), so the library must be built whenever `r8169` is. Without it the module fails to load with unknown symbols |

## 3. `drivers/net/ethernet/realtek/r8169_main.c`

### 3.1 Per patch

| Patch | Title | What it changes | Purpose |
|---|---|---|---|
| 0001 | select DIMLIB and add adaptive RX moderation state | Includes `<linux/dim.h>`; adds fields to `struct rtl8169_private` (`rx_dim`, `rx_dim_enabled`, packet and byte counters, `rx_dim_lock` and others added by later patches) | State for the feature. No behaviour change |
| 0002 | add ethtool adaptive-rx coalescing flag | Adds `ETHTOOL_COALESCE_USE_ADAPTIVE_RX` to `supported_coalesce_params`; `rtl_get_coalesce()` reports the flag, `rtl_set_coalesce()` stores it | The user can switch the mode with `ethtool -C adaptive-rx on\|off` and read it. No hardware effect yet |
| 0003 | sample RX traffic for DIM and log the chosen level | `rtl_rx()` counts packets and bytes; `rtl8169_poll()` calls the new `rtl_rx_dim_update()`, which builds a sample and calls `net_dim()`; new `rx_dim_lock`, `rtl_rx_dim_reset()` and a work function `rtl_rx_dim_work()` that only logs the level; turning the flag off waits with `synchronize_net()` and cancels the DIM work; `rtl8169_down()` cancels the DIM work; `rtl_init_one()` initialises the lock and the work | DIM sees the traffic and its decisions can be observed in the kernel log before any register is written |
| 0004 | apply the DIM level to the RX interrupt timer | New level table `rtl_rx_dim_usecs`, `rtl_rx_dim_units()`, `rtl_rx_dim_apply()`, the saved static RX settings (`rx_static_usecs`, `rx_static_frames`); `rtl_set_coalesce()` is split into itself and `rtl_write_coalesce()`, with the off-to-on, on-to-on and on-to-off rules; the work function now writes the register | The level reaches the card. ethtool semantics: the live level is visible, the static RX settings are saved and restored |
| 0005 | keep single-packet traffic at DIM level 0 | `rtl_rx_dim_update()` gets the packet count of the poll as an argument and returns early when it is fewer than two and the level is 0 | Request-response traffic stays at level 0 (it lost 5.8% without this) |
| 0006 | re-apply DIM level on restart, link change and idle | New `rtl_rx_dim_restore()` called from `rtl_hw_start()`; `rtl_rx_dim_link_work()` scheduled from `r8169_phylink_handler()`; `rtl_rx_dim_arm_decay()` and `rtl_rx_dim_decay_work()` (200 ms); ordered cancels in `rtl8169_down()` and in the on-to-off path | The level survives a restart, follows a link-speed change and falls to 0 when traffic stops |

### 3.2 Per function and structure

| Item | New or changed | Purpose |
|---|---|---|
| `#include <linux/dim.h>` | New | DIM types and functions |
| `struct rtl8169_private`: `rx_dim`, `rx_dim_enabled`, `rx_dim_events`, `rx_dim_packets`, `rx_dim_bytes`, `rx_dim_lock`, `rx_static_usecs`, `rx_static_frames`, `rx_dim_decay`, `rx_dim_link_work`, `rx_dim_decay_events` | New fields | The DIM state, the user's flag, the counters DIM is fed from, the lock, the saved static RX settings, and the two extra work items with the poll count at the last decay tick |
| `rtl_rx_dim_usecs[]` | New table | Levels 0, 40, 80, 200, 400 microseconds |
| `rtl_rx_dim_units()` | New | Converts a level to a timer field value for the current unit, rounds to the closest unit, at most 15; a level shorter than half a unit gives 0 |
| `rtl_rx_dim_reset()` | New | Puts DIM back at level 0 (state, profile index, steps, previous statistics) |
| `rtl_rx_dim_apply()` | New | Read-modify-write of the RX fields of `IntrMitigate` for a level; never writes `CPlusCmd` |
| `rtl_rx_dim_work()` | New | DIM's work item: takes `rx_dim_lock`, applies the level, arms the idle watch |
| `rtl_rx_dim_arm_decay()`, `rtl_rx_dim_decay_work()` | New | The 200 ms idle watch: drops the level to 0 when no poll happened in a whole period |
| `rtl_rx_dim_link_work()` | New | Writes the level again with the timer unit of the new link speed |
| `rtl_rx_dim_restore()` | New | Writes the level again at the end of `rtl_hw_start()`, before the interrupts are enabled |
| `rtl_rx_dim_update()` | New | Builds the sample and calls `net_dim()`; holds the single-packet guard |
| `rtl_write_coalesce()` | New (the old body of `rtl_set_coalesce()` moved here) | Writes `IntrMitigate` and the `INTT` and `PktCntrDisable` bits of `CPlusCmd`; with `adaptive` true the RX frame limit is 0, the RX timer is the current level and the unit fits the longest level |
| `rtl_set_coalesce()` | Changed | Takes `rx_dim_lock`; the flag transitions; refuses a TX frame limit with adaptive on; on to off cancels the work after `synchronize_net()` |
| `rtl_get_coalesce()` | Changed | Reports `use_adaptive_rx_coalesce` |
| `rtl8169_ethtool_ops` | Changed | `supported_coalesce_params` includes `ETHTOOL_COALESCE_USE_ADAPTIVE_RX` |
| `rtl_rx()` | Changed | Counts packets and bytes into `rx_dim_packets` and `rx_dim_bytes` |
| `rtl8169_poll()` | Changed | Calls `rtl_rx_dim_update()` right after `rtl_rx()` when packets were received and the flag is set |
| `rtl_hw_start()` | Changed | Calls `rtl_rx_dim_restore()` before `rtl_irq_enable()` |
| `r8169_phylink_handler()` | Changed | Schedules `rx_dim_link_work` when the link is up and the mode is on |
| `rtl8169_down()` | Changed | After `rtl8169_cleanup()`, cancels the DIM, decay and link work and resets DIM |
| `rtl_init_one()` | Changed | Initialises `rx_dim_lock` and the three work items and sets the DIM mode |

### 3.3 What is deliberately not changed

| Not changed | Why |
|---|---|
| Transmit moderation, the TX fields of `IntrMitigate` | The project is RX only |
| `CPlusCmd` writes outside the ethtool path and `rtl_hw_start()` | Keeps the work functions from becoming extra writers |
| RTL8125 handling | The coalescing functions return `-EOPNOTSUPP` for those chips, as before |
| The driver's behaviour with `adaptive-rx off` | It is the stock behaviour (`rtl_write_coalesce()` with `adaptive` false) |
| Any other kernel file | The feature lives in the driver and uses the existing library |

## 4. The test hook (not part of the series)

`scripts/test-hooks/force_reset.patch` adds 24 lines to `r8169_main.c` (a `<linux/debugfs.h>` include and a debugfs file). Writing `1` to `/sys/kernel/debug/r8169_force_reset` schedules the same reset task as a transmit timeout or a PCI error, and the restore step logs the level and the `IntrMitigate` value it wrote. It exists so that test F4b can check that the level is written again after a reset, which cannot be triggered on demand otherwise. It applies on top of patches 0001 to 0006 and must not be applied for any measurement; the way to apply and remove it is in [setup and testing, Phase 3](setup-and-testing.md).

## 5. How to list the changes yourself

On a kernel git tree with the series applied (see [setup and testing, section 5](setup-and-testing.md)):

```bash
git diff --stat v7.2.15..HEAD                   # two files, 374 insertions, 31 deletions
git diff v7.2.15..HEAD -- drivers/net/ethernet/realtek/Kconfig
git diff v7.2.15..HEAD -- drivers/net/ethernet/realtek/r8169_main.c
```

Or read the patches in `patches/`: each starts with a commit message that explains its purpose.
