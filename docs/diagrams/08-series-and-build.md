# Diagram 8: Patch series, build and load

How the six patches build on each other, and how they become the module that runs on the PC.

```mermaid
flowchart TD
  subgraph SER["Patch series in patches/, applied in order on v7.2.15"]
    P1["0001 Kconfig and state<br/>select DIMLIB, new fields"] --> P2["0002 ethtool flag<br/>adaptive-rx, no hardware effect"]
    P2 --> P3["0003 sampling<br/>counters, DIM called, work logs the level"]
    P3 --> P4["0004 apply the level<br/>level table, register write, ethtool semantics"]
    P4 --> P5["0005 single-packet guard<br/>request-response stays at level 0"]
    P5 --> P6["0006 robustness<br/>restart, link change, idle decay, teardown"]
  end
  subgraph BLD["Build and load on the PC, as root"]
    B1["Kernel tree /usr/src/linux-7.2.15"] --> B2["patch -p1 --dry-run, then patch -p1"]
    B2 --> B3["make M=drivers/net/ethernet/realtek<br/>modules W=1"]
    B3 --> B4{"vermagic equals uname -r?"}
    B4 -- "no" --> BX["stop"]
    B4 -- "yes" --> B5["sign-file sha512 with the tree's key<br/>on a copy of r8169.ko"]
    B5 --> B6["rmmod r8169, insmod the signed copy"]
    B6 --> B7["srcversion of the loaded module<br/>equals that of the build"]
  end
  P6 --> B2
  B7 --> RUN["Running module: adaptive-rx available"]
  RUN -. "way back: rmmod r8169, modprobe r8169" .-> STOCK["Stock module"]
  subgraph CHK["Clean-tree check, scripts/check_series.sh"]
    C1["git tree at v7.2.15"] --> C2["take the two files"] --> C3["apply the six patches in order"] --> C4["checkpatch --strict per patch"]
  end
  P6 -.-> C3
```

Exported image: [`img/08-series-and-build.svg`](img/08-series-and-build.svg) ([PNG](img/08-series-and-build.png)).

## The two kernel files

| File | Changed by |
|---|---|
| `drivers/net/ethernet/realtek/Kconfig` | 0001 |
| `drivers/net/ethernet/realtek/r8169_main.c` | 0001 to 0006 |

The complete list of changes, function by function, is in [kernel changes](../kernel-changes.md).

## Why it is built this way

- The kernel on the PC enforces module signatures (`CONFIG_MODULE_SIG_FORCE=y`), so a rebuilt module has to be signed with the key of the tree it was built from before `insmod`. The unsigned build output is left unchanged and the key never leaves the tree.
- `scripts/build_sign_load.sh` does the build, the vermagic check, the signing and the swap in one command.
- The series is split so that behaviour can be observed before any register is touched: 0003 only logs the level DIM chooses, and 0004 starts writing the register.
- The stock module stays installed, so `rmmod r8169; modprobe r8169` is always the way back. The card is the PC's only connection, so this is done at the console.

## Related

[Overview](00-overview.md), [07 measurement setup](07-measurement-setup.md), [setup and testing](../setup-and-testing.md), [kernel changes](../kernel-changes.md).
