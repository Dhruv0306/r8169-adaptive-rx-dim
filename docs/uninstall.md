# Removing the modified driver after the demo

How to take the project off the machine under test completely and return it to the stock driver and the original settings. Read the next section first: the aim is to remove the **modification**, not the `r8169` driver itself, because the network card needs the driver. Related documents: [setup and testing](setup-and-testing.md) (how it was put there), [hardware](hardware.md), [kernel changes](kernel-changes.md), [demo and questions](demo-and-questions.md).

Do this only **after the demo and after the grade is final**, and keep the repository (it holds the work). If you are not sure, do step 1 only: it returns the machine to the stock driver and leaves everything else to be removed later.

## What "remove" means here

- The patched module was never installed into the system. `build_sign_load.sh` builds `r8169.ko` in the kernel tree, signs a **copy** (`/root/r8169-new-signed.ko`) and loads it with `rmmod` and `insmod`. The stock module under `/lib/modules/<kernel>/` was never touched. So the patched driver exists only in memory until the next reboot, in the signed copy, and in the edited kernel source.
- Never remove `r8169` without loading it again: the card is the PC's only connection. The way back is always `rmmod r8169; modprobe r8169`.
- Removing the project fully therefore means: load the stock module, delete the signed copy and the build leftovers, put the two edited kernel source files back, undo the tuning of the machine, and check.

## What the project left on the machine

| Item | Where | What to do |
|---|---|---|
| The running patched module | In memory (srcversion `04E8D19E5DCBE28E8305847`) | Step 1: load the stock module |
| Signed copy of the patched module | `/root/r8169-new-signed.ko` | Step 2: delete |
| Build log | `/root/r8169-build.log` | Step 2: delete |
| Edited kernel source | `/usr/src/linux-7.2.15/drivers/net/ethernet/realtek/r8169_main.c` and `Kconfig` | Step 3: restore |
| Build outputs in the kernel tree | `drivers/net/ethernet/realtek/*.o`, `r8169.ko`, `.*.cmd`, `Module.symvers`, `modules.order` | Step 3: rebuild the stock module or clean |
| Backup of the stock files | `/root/r8169-stock-src/` (`r8169.ko`, `Kconfig`, `r8169_main.c`) | Keep until step 3 is done and checked |
| The test hook, if it is still applied | Part of `r8169_main.c` (debugfs file `r8169_force_reset`) | Step 3: removed with the file restore |
| Tuning of the machine | `irqbalance` stopped, the NIC interrupt pinned to CPU 3, governor `performance`, adaptive flag and `rx-usecs` | Step 4: restore |
| The repository, results and documents | `/home/aoscsg623/Downloads/r8169-adaptive-rx-dim/` | Keep |
| Clean kernel clone used for checks | `/root/linux-r8169-clean` (a home of root) | Optional: delete, it is large |
| Backup bundle of the private repository | `/home/aoscsg623/r8169-private-backup-2026-11-19.bundle` | Keep a copy off the PC, then it may go |
| Tools installed for the tests | `iperf3`, `netperf`, `ethtool` (packages) | Optional: remove if nothing else uses them |

## Step 1: go back to the stock module (at the console, as root)

Use a console or the phone tether, not a network session: the link goes down for a moment.

```bash
su -                                       # a root shell; sudo needs a password on this machine
ethtool -C enp3s0 adaptive-rx off rx-usecs 0
rmmod r8169
modprobe r8169
sleep 5
cat /sys/module/r8169/srcversion           # the srcversion of the STOCK module
modinfo -F srcversion r8169                # the stock file in /lib/modules: must be the same value
modinfo -n r8169                           # path of the stock module file (it must be under /lib/modules, not /root)
ethtool -c enp3s0 | head -3                # must say "Adaptive RX: n/a"
ethtool -C enp3s0 adaptive-rx on           # must fail: "Operation not supported"
ip link show enp3s0 | head -1              # state UP
```

After a module swap, wait about 40 seconds before expecting traffic on this network. If the two srcversion values differ, the patched module is still loaded: run `lsmod | grep r8169`, then `rmmod r8169` and `modprobe r8169` again.

## Step 2: delete the signed copy and the build log

```bash
ls -l /root/r8169-new-signed.ko /root/r8169-build.log
rm -f /root/r8169-new-signed.ko /root/r8169-build.log
```

The signed copy is the only file that can load the patched driver on a machine that enforces module signatures, so after this the patched driver cannot be loaded again without a rebuild.

## Step 3: restore the kernel source tree

The tree is a tarball, not a git repository, so there are two ways. Use 3.1; 3.2 is the alternative when the backup is missing.

### 3.1 Restore from the backup of the stock files

```bash
cd /usr/src/linux-7.2.15/drivers/net/ethernet/realtek
cp /root/r8169-stock-src/Kconfig Kconfig
cp /root/r8169-stock-src/r8169_main.c r8169_main.c
cmp /root/r8169-stock-src/r8169_main.c r8169_main.c && cmp /root/r8169-stock-src/Kconfig Kconfig && echo "source files are the stock ones"
grep -c 'rx_dim' r8169_main.c               # must print 0
grep -c 'DIMLIB' Kconfig                    # must print 0
```

### 3.2 Reversing the patches (when the backup is missing)
Reverse the series in the opposite order, with a dry run first:

```bash
cd /usr/src/linux-7.2.15
for p in $(ls /home/aoscsg623/Downloads/r8169-adaptive-rx-dim/patches/000[1-6]-*.patch | sort -r); do
    patch -R -p1 --dry-run < $p && patch -R -p1 < $p || break
done
```

If the test hook (`scripts/test-hooks/force_reset.patch`) is still applied, reverse it first: `patch -R -p1 < /home/aoscsg623/Downloads/r8169-adaptive-rx-dim/scripts/test-hooks/force_reset.patch`.

### 3.3 Rebuild the stock module so the tree matches its sources

The build outputs in the tree still come from the patched source. Rebuild from the restored source (this does not load anything):

```bash
cd /usr/src/linux-7.2.15
make M=drivers/net/ethernet/realtek modules
modinfo -F srcversion drivers/net/ethernet/realtek/r8169.ko        # must equal the stock srcversion from step 1
```

Or only remove the outputs: `make M=drivers/net/ethernet/realtek clean`. The kernel configuration (`.config`) never changed: `CONFIG_DIMLIB=y` was already set in the running kernel, so nothing else needs to be restored.

## Step 4: undo the tuning of the machine

```bash
# 1. the NIC interrupt: let it float on all CPUs again, then restart irqbalance
IRQ=$(awk '/enp3s0/ {sub(":","",$1); print $1; exit}' /proc/interrupts)
cat /proc/irq/$IRQ/smp_affinity_list         # 3 while pinned
echo 0-19 > /proc/irq/$IRQ/smp_affinity_list
systemctl is-enabled irqbalance              # "enabled" is normal
systemctl start irqbalance
systemctl is-active irqbalance               # active
sleep 15; cat /proc/irq/$IRQ/smp_affinity_list

# 2. the CPU governor: the original was powersave (Phase 0)
cat /home/aoscsg623/Downloads/r8169-adaptive-rx-dim/results/phase5/final-check/governor.saved | sort | uniq -c   # what the last matrix saved
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave > $g; done
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# 3. the NIC settings are back to the defaults after step 1 of this document
ethtool -c enp3s0 | sed -n '1,4p'
```

If `echo ... > smp_affinity_list` fails with an input/output error, the vector is managed by the kernel and was not pinned by the project; skip it. If the system default governor on your machine is different, set that one. These settings are not persistent: a reboot returns the governor and interrupt affinity to the system defaults, and starts `irqbalance` if it is enabled at boot.

## Step 5: reboot test (recommended)

```bash
reboot
```

After the machine is up, as root:

```bash
lsmod | grep r8169                         # loaded
modinfo -n r8169                           # path under /lib/modules
cat /sys/module/r8169/srcversion; modinfo -F srcversion r8169      # equal
ethtool -c enp3s0 | head -3                # Adaptive RX: n/a
ls /root/r8169-new-signed.ko 2>&1          # No such file
dmesg | grep -iE 'r8169|XID' | head -5     # normal probe lines for the RTL8168h, no warnings
systemctl is-active irqbalance             # active
```

## Optional clean-up of what is left

| Item | Command | Note |
|---|---|---|
| Large clean kernel clone | `rm -rf /root/linux-r8169-clean` | Used only by `check_series.sh`; it can be cloned again |
| Test packages | `apt remove iperf3 netperf` | Only if nothing else needs them; keep `ethtool` |
| Stock backup | `rm -rf /root/r8169-stock-src` | Only after step 3 and the reboot test (step 5) passed; the stock module is in `/lib/modules` regardless |
| Repository on the PC | `rm -rf /home/aoscsg623/Downloads/r8169-adaptive-rx-dim` | Not recommended: all work is in the shared repository and a clone can be made again. Make sure everything is pushed first (`git status`, `git log origin/main..`) |
| Raw results | Part of the repository | Keep |

## Checklist

| Check | Expected |
|---|---|
| `cat /sys/module/r8169/srcversion` and `modinfo -F srcversion r8169` | Equal (the stock module is loaded) |
| `ethtool -c enp3s0` | `Adaptive RX: n/a` |
| `ethtool -C enp3s0 adaptive-rx on` | Refused |
| `/root/r8169-new-signed.ko` | Gone |
| `grep -c rx_dim` in the kernel tree's `r8169_main.c` | 0 |
| `cmp` of the two source files against `/root/r8169-stock-src/` | Identical |
| `systemctl is-active irqbalance` | `active` |
| `scaling_governor` | The system default (`powersave` on this machine) |
| `dmesg` since boot | No `r8169` warnings, no lockdep report |
| Link | 1000 Mbit/s full duplex, traffic after about 40 s |

## If something goes wrong

| Problem | What to do |
|---|---|
| No network after `rmmod` | At the console: `modprobe r8169`. If it fails, read `dmesg | tail -20` and `modinfo -n r8169`; a failed load usually means the module file or its signature is wrong, so reboot: the stock module in `/lib/modules` loads at boot. Use the phone tether meanwhile |
| `modprobe r8169` loads the patched module | Check `modinfo -n r8169`: if it points to `/root` or the kernel tree, the module path was changed. It should be under `/lib/modules/<kernel>/`. `depmod -a` rebuilds the index |
| `patch -R` fails | The tree is not in the state of the patched series (partly restored, or a different version). Use step 3.1 instead and compare with `cmp` |
| The stock backup is missing | Take the two files from a clean `v7.2.15` source: `git show v7.2.15:drivers/net/ethernet/realtek/r8169_main.c` in a kernel git tree, or from the original source tarball |
| You want the patched driver back | Follow [setup and testing](setup-and-testing.md), sections 4 and 5 and the phase you need in section 6, from a clone of the repository |
