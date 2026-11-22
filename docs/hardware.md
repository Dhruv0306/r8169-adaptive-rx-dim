# The hardware this work is for

The exact hardware the modified `r8169` driver was developed and tested on, which other chips the change reaches in the code and what happens there, and how to read the identity of your own hardware. Related documents: [kernel changes](kernel-changes.md) (what was changed in the driver), [project explained](project-explained.md) (the register and the timer units), [setup and testing](setup-and-testing.md) (what a reproduction needs), [uninstall](uninstall.md).

## 1. In short

The project changes the Linux `r8169` driver for Realtek Ethernet controllers. It was developed and measured on **one chip**: an **RTL8168h/8111h** (PCI `10ec:8168`, revision 15, XID 541) in a PC, at 1 Gbit/s. The code change reaches every chip the driver already treats as coalescing-capable, which is most of the Realtek family except the 2.5 Gbit/s and faster chips. Results are valid for the tested chip; for any other chip the code is expected to work but was not run.

## 2. The tested hardware

Taken from the Phase 0 results ([`results/phase_0_environment_and_baseline.md`](results/phase_0_environment_and_baseline.md)) and the peer notes (`results/phase4/peer.txt`).

### 2.1 The network card of the machine under test

| Item | Value |
|---|---|
| Controller | Realtek RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet Controller, chip **RTL8168h/8111h** |
| Chip identification in the driver | XID 541, `mac_version` `RTL_GIGA_MAC_VER_46` (the driver's table entry `0x541` is named "RTL8168h/8111h"; the entry `0x6c0` "RTL8168M" maps to the same version) |
| PCI identification | vendor:device `10ec:8168`, revision 15, subsystem `17aa:32e6` (Lenovo), at `03:00.0` |
| Firmware file | `rtl8168h-2_0.0.2 02/26/15` (`FIRMWARE_8168H_2`) |
| Interface name | `enp3s0` |
| Link | 1000 Mbit/s full duplex, gigabit switch network |
| Interrupt | MSI-X, vector 135 (`IR-PCI-MSIX-0000:03:00.0 0-edge enp3s0` in `/proc/interrupts`). `/sys/class/net/enp3s0/device/irq` says 18 and is not the NIC's vector |
| Coalescing | Static coalescing supported by the stock driver; `PktCntrDisable` branch taken (`rtl_is_8168evl_up()` is true for versions 34 to 52 except 39); timer unit table `rtl_coalesce_info_8168_8136`, which at 1 Gbit/s gives 5, 40, 80 or 160 microseconds depending on the two `INTT` bits |

### 2.2 The machine

| Item | Value |
|---|---|
| Computer | Lenovo desktop, Intel Alder Lake-S, 20 CPUs |
| Kernel | `7.2.15-netquota`: Linux 7.2.15 built from `/usr/src/linux-7.2.15` (a tarball) with the owner's network-quota patches; `CONFIG_R8169=m`, `CONFIG_DIMLIB=y`, `CONFIG_LOCKDEP=y`, `CONFIG_DEBUG_FS=y`, `CONFIG_MODULE_SIG=y` (`CONFIG_MODULE_SIG_FORCE` is not set: signatures are not enforced; Secure Boot is disabled and the lockdown mode is `none`) |
| CPU governor | `powersave` in Phases 0 to 3, `performance` in Phases 4 and 5 |
| NIC interrupt | Pinned to one CPU (CPU 3) with `irqbalance` stopped during Phases 4 and 5; before that the interrupt landed on CPU 7 |
| Other recorded facts | `dmesg` is restricted for a normal user; `sudo` needs a password, so root work is done in a `su -` shell |

### 2.3 The peer

| Item | Value |
|---|---|
| System | Ubuntu 24.04, kernel `7.0.0-42-generic` |
| Network card | RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet Controller, revision 15, at `01:00.0`, firmware `rtl8168h-2_0.0.2 02/26/15` (the same chip as the machine under test) |
| Software | iperf3 3.16, netperf 2.7.0 (`netserver`) |
| Link | The same LAN over a gigabit link |

### 2.4 The network

A gigabit switch network. Two properties matter for the measurements: ICMP to the gateway and to `8.8.8.8` gets no reply (ARP and TCP work, so latency is measured with TCP and UDP tools), and traffic is forwarded only about 35 seconds after every link-up (see [results explained, 5.8](results-explained.md)).

### 2.5 What the repository does not record

The exact Lenovo model, the CPU model name, the amount of memory, the motherboard and the switch model are not recorded. To add them, run on the machine under test, as root:

```bash
cat /sys/class/dmi/id/product_name /sys/class/dmi/id/product_version 2>/dev/null
cat /sys/class/dmi/id/board_name 2>/dev/null
lscpu | grep -E 'Model name|^CPU\(s\)'
free -h | head -2
lspci -nnk -s 03:00.0
dmesg | grep -iE 'r8169|XID' | head
ethtool -i enp3s0
cat /sys/class/net/enp3s0/speed
```

## 3. Which chips the change reaches

The driver identifies a chip by its XID bits and gives it a `mac_version`. The change in `r8169_main.c` depends on the version in two places: the table of timer units (`rtl_coalesce_info()`) and the check for the 2.5 Gbit/s family (`rtl_is_8125()`, true from `RTL_GIGA_MAC_VER_61`). The chip names below are the ones in the driver's table.

| `mac_version` | Chips | What the change does | Tested |
|---|---|---|---|
| 02 to 06 | RTL8169s, RTL8110s, RTL8169sb/8110sb, RTL8169sc/8110sc (the old PCI Gigabit family) | The code is active, with its own unit table (0.32, 2.56, 5.12 or 10.24 microseconds at 1 Gbit/s). The longest unit gives at most 153.6 microseconds, so the 400 microsecond top level cannot be expressed at 1 Gbit/s and, from the code, `adaptive-rx on` is refused with `ERANGE` at that speed. At 100 Mbit/s it fits | No |
| 07 to 52 | RTL8102e/8103e/8101e/8100e/8105e/8106e, RTL8401/8402 (Fast Ethernet, 10 and 100 Mbit/s) and RTL8168b to RTL8168h, RTL8168M, RTL8411/8411b, RTL8168ep/8111ep, RTL8168fp/RTL8117 (Gigabit, PCI Express) | The code is active and uses the "8168/8136" unit table. For the Gigabit chips this is the situation of the tested chip. Version 46 (RTL8168h/8111h and RTL8168M) is the one that was run; the others are expected to work, not verified | Version 46 only (RTL8168h/8111h) |
| 61 and above | RTL8125A/B/D/K/BP/CP, RTL9151A, RTL8126A, RTL8127A (2.5 Gbit/s and faster) | Unchanged. The coalescing functions return `-EOPNOTSUPP` for these chips, as in the stock driver, so `adaptive-rx` cannot be turned on | Not applicable |

The chips of versions 7 to 52 that are Fast Ethernet only (the 8100/8101/8102/8103/8105/8106/8401/8402 family) never link at 1 Gbit/s, so the unit table of the second row applies at 100 and 10 Mbit/s only.

## 4. The timer limit that fixes the levels

The receive timer field is 4 bits wide, so it holds 0 to 15 units, and the length of a unit depends on the link speed and the `INTT` bits (the two bits of `CPlusCmd` that select one of four unit lengths). The driver's own comment gives the units; the last column is the largest timer the field can hold (15 units).

| Family (code table) | Speed | Unit for `INTT` 0, 1, 2, 3 | Largest timer for `INTT` 0, 1, 2, 3 |
|---|---|---|---|
| 8168/8136 (`mac_version` above 6) | 1000 Mbit/s | 5, 40, 80, 160 us | 75, 600, 1,200, 2,400 us |
| | 100 Mbit/s | 2.56, 20.48, 40.96, 81.92 us | 38, 307, 614, 1,229 us |
| | 10 Mbit/s | 40.96, 327.7, 655.4, 1,310 us | 614, 4,916, 9,831, 19,650 us |
| 8169 (`mac_version` 2 to 6) | 1000 Mbit/s | 0.32, 2.56, 5.12, 10.24 us | 4.8, 38, 77, 154 us |
| | 100 Mbit/s | 2.56, 20.48, 40.96, 81.92 us | 38, 307, 614, 1,229 us |
| | 10 Mbit/s | 40.96, 327.7, 655.4, 1,310 us | 614, 4,916, 9,831, 19,650 us |

What follows for the levels 0, 40, 80, 200 and 400 microseconds:

- **At 1 Gbit/s on the tested chip family:** `INTT` 1 (a 40 microsecond unit) is the smallest unit whose largest timer (600 us) covers the 400 us top level, so it is chosen, and the levels become the fields 0, 1, 2, 5 and 10. This was measured (`IntrMitigate` values `0x0010`, `0x0020`, `0x0050`, `0x00a0`).
- **After a speed drop from 1 Gbit/s to 100 Mbit/s with the mode on:** `INTT` stays at 1, so the unit becomes 20.48 us. Level 2 (80 us) is field 4 (82 us), measured in test F5. Level 4 (400 us) would need 20 units, which is more than 15, so it is capped at 15 units, about 307 us. This follows from the code; it was not measured.
- **Turning the mode on while the link is at 100 or 10 Mbit/s:** the smallest unit that covers 400 us is chosen (`INTT` 2 at 100 Mbit/s, `INTT` 0 at 10 Mbit/s), so all levels fit.
- **Old 8169 chips at 1 Gbit/s:** no unit covers 400 us (the largest timer is 154 us), so the request is refused as described in section 3.

## 5. What a reproduction needs

| Need | Minimum | Notes |
|---|---|---|
| Network card | A Realtek RTL8111/8168/8211/8411 PCI Express controller in `mac_version` 07 to 52 | The tested chip is RTL8168h/8111h (version 46). Other versions of the same family should behave alike, but results are not transferable |
| Not usable | RTL8125 and newer (2.5 Gbit/s and above) | `-EOPNOTSUPP` |
| Link | 1 Gbit/s to a peer, same LAN | The numbers in this project are at 1 Gbit/s |
| Peer | Any Linux machine with `iperf3` and `netperf` | The tested peer has the same chip, which is not required |
| Host | A Linux kernel with the `r8169` driver as a module and `CONFIG_DIMLIB` | Tested on Linux 7.2.15; the patches are against `v7.2.15` |
| Console access | Keyboard and screen, or a second network path | The card is the only connection of the tested machine, and many tests take the link down |

To check whether your own card is in scope:

```bash
lspci -nn | grep -i ethernet                      # look for 10ec:8168 (or 10ec:8136, 10ec:8169 and so on)
dmesg | grep -i r8169                             # "XID xxx" line gives the chip; compare with the table in section 3
ethtool -i <interface>                            # driver: r8169
ethtool -c <interface>                            # with the stock driver: "Adaptive RX: n/a" and static settings
```

If the first command shows `10ec:8125`, `10ec:8126` or `10ec:8127`, the change does nothing for that card.
