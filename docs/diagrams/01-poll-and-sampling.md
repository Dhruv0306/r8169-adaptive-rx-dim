# Diagram 1: Receive poll and sampling (box B)

What happens from an interrupt to a sample for DIM. The new code is the shaded steps; the rest is the stock driver.

```mermaid
flowchart TD
  IRQ["Card raises the interrupt<br/>rtl8169_interrupt"] --> MASK["Mask the card's interrupts<br/>and schedule NAPI"]
  MASK --> POLL["rtl8169_poll runs in softirq"]
  POLL --> TX["rtl_tx: free sent packets"]
  TX --> RX["rtl_rx: take up to budget packets<br/>from the ring"]
  RX --> CNT["NEW: add the packets and bytes<br/>to rx_dim_packets and rx_dim_bytes"]
  CNT --> Q1{"work_done above 0 and<br/>rx_dim_enabled set?"}
  Q1 -- "no" --> DONE
  Q1 -- "yes" --> UPD["NEW: rtl_rx_dim_update"]
  UPD --> Q2{"fewer than 2 packets and<br/>level is 0?"}
  Q2 -- "yes: request-response guard" --> DONE
  Q2 -- "no" --> SAMPLE["dim_update_sample with<br/>events plus 1, packets, bytes"]
  SAMPLE --> NETDIM["net_dim<br/>see diagram 2"]
  NETDIM --> Q3{"level changed?"}
  Q3 -- "yes" --> WORK["queue rtl_rx_dim_work<br/>see diagram 3"]
  Q3 -- "no" --> DONE
  WORK --> DONE["poll finishes"]
  DONE --> NC{"work_done below budget and<br/>napi_complete_done true?"}
  NC -- "yes" --> EN["rtl_irq_enable:<br/>card may interrupt again<br/>after its timer"]
  NC -- "no" --> POLL
  classDef new fill:#dff0d8,stroke:#3c763d,color:#000
  class CNT,UPD,Q2,SAMPLE,NETDIM,WORK new
```

Exported image: [`img/01-poll-and-sampling.svg`](img/01-poll-and-sampling.svg) ([PNG](img/01-poll-and-sampling.png)).

## Steps

| Step | Function | Notes |
|---|---|---|
| Counters | `rtl_rx()` | The kernel's own receive statistics are per CPU and cannot be read as one number, so the driver keeps `rx_dim_packets` and `rx_dim_bytes`. They are written only here and read only in `rtl8169_poll()`, the same NAPI context, so no lock is needed |
| Condition | `rtl8169_poll()` | `work_done` is the number of packets taken in this poll. A poll with no packet is not an event |
| Event | `rtl_rx_dim_update()` | One event is one poll that received packets. DIM is called in every such poll, not only when the poll completes, because at line rate a poll may never complete |
| Guard | `rtl_rx_dim_update()` | At level 0 a poll with a single packet is dropped. It means the CPU kept up with the card, a longer timer would only add latency, and request-response traffic looks exactly like that. Above level 0 every poll counts, so DIM can always step back down |
| Sample | `dim_update_sample()` | Builds a `struct dim_sample` with the event count, packets and bytes and a time stamp |
| Decision | `net_dim()` | Library code, see [diagram 2](02-dim-decision.md) |

## Why the guard exists

The first version had no guard. A single request-response stream lost 5.8% of its transactions per second, because DIM kept leaving level 0 on statistics noise and every visit to level 1 delays each reply by the full 40 microsecond timer. The guard (patch 0005) removed the loss: 9,508 against 9,340 transactions per second in the same session.

## Related

[Overview](00-overview.md), [02 DIM decision](02-dim-decision.md), [06 locking](06-locking.md). Prose: [project explained, section 5](../project-explained.md). Results that depend on it: [results explained, request-response](../results-explained.md).
