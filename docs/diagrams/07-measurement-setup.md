# Diagram 7: Measurement setup and data flow

Two machines, a set of scripts, and what the scripts read and write. This is how every number in the [results](../results-explained.md) was produced.

```mermaid
flowchart LR
  subgraph PEER["Peer machine, Ubuntu 24.04, gigabit LAN"]
    IP["iperf3 -s<br/>bulk TCP and paced UDP"]
    NP["netserver<br/>request-response"]
  end
  subgraph PC["Machine under test: PC with the RTL8168h, kernel 7.2.15-netquota"]
    MOD["Patched r8169 module<br/>or the stock module"]
    subgraph SCR["Scripts in scripts/"]
      RB["rx_bench.sh<br/>one configuration, all workloads"]
      RM["run_matrix.sh<br/>interleaved configurations<br/>off, static, adaptive"]
      SL["sample_level.sh<br/>level as CSV, 5 per second"]
      ST["stepped_load.sh<br/>idle, burst, idle cycles"]
      PT["phase3_tests.sh, stress_f7.sh,<br/>decay_timing.sh, bounce_rx_check.sh"]
      DM["demo.sh"]
    end
    subgraph SRC["What the scripts read"]
      PI["/proc/interrupts<br/>NIC interrupts per second"]
      PS["/proc/softirqs<br/>NET_RX per second"]
      CI["cpuidle residency<br/>of the interrupt CPU"]
      ET["ethtool -c and the registers<br/>the live level"]
    end
  end
  subgraph OUT["Repository"]
    RAW["results/ raw CSV and JSON"]
    SUM["summarize_results.py<br/>tables, comparison, noise rule"]
    PLT["plot_results.py<br/>figures"]
    DOC["docs/results and docs/figures"]
  end
  IP <-->|"traffic"| MOD
  NP <-->|"traffic"| MOD
  RM --> RB
  RB --> MOD
  SL --> ET
  ST --> SL
  RB --> PI
  RB --> PS
  RB --> CI
  RB --> RAW
  SL --> RAW
  PT --> RAW
  RAW --> SUM --> DOC
  RAW --> PLT --> DOC
  DM --> MOD
```

Exported image: [`img/07-measurement-setup.svg`](img/07-measurement-setup.svg) ([PNG](img/07-measurement-setup.png)).

## Workloads and what each one tests

| Workload (`rx_bench.sh -w`) | Traffic | What it shows |
|---|---|---|
| `idle` | none | Background interrupts |
| `rr` | one `netperf` TCP_RR stream, 64 byte messages | Latency traffic: must not get slower |
| `rrp` | eight parallel TCP_RR streams | The same with more load |
| `tcp` | `iperf3 -R` bulk TCP | Throughput traffic at line rate: nothing to win, must not lose |
| `udp` | `iperf3 -u -R`, 1448 byte datagrams, 100 to 900 Mbit/s | Heavy load with large packets |
| `udps` | `iperf3 -u -R`, 100 byte datagrams, 100 microsecond pacing timer, 50 to 200 Mbit/s | Heavy load with small packets: the case moderation is for |

## Configurations compared

`stock` (the unmodified module), `off` (the patched module, adaptive off), `static-L2` (a fixed 80 us timer), `static-L4` (a fixed 400 us timer) and `adaptive`. `run_matrix.sh` switches between the last four with `ethtool` only, in interleaved rounds with the order reversed on every second round, so drift in time does not line up with one configuration.

## Measures

NIC interrupts per second, NET_RX softirq runs per second, throughput, latency and transactions per second, loss and jitter, and the share of the wall time that the interrupt CPU was not in a cpuidle state. The cpuidle measure is used because the kernel on the PC samples `/proc/stat` only at the scheduler tick, which makes its busy and softirq percentages unreliable for paced traffic.

## Related

[Overview](00-overview.md), [08 patch series and build](08-series-and-build.md), [setup and testing](../setup-and-testing.md), [results explained, section 3](../results-explained.md).
