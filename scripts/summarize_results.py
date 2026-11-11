#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Summarise rx_bench.sh results as Markdown tables.

For every workload cell (idle, rr, tcp, and each udp rate) one table is
printed with one row per configuration label: mean +/- standard deviation
over the runs. Runs written by older versions of rx_bench.sh are handled
too: when a UDP row has no loss figure, it is read from the raw iperf3
JSON next to the CSV file.

usage: summarize_results.py [-d RESULTS_DIR] [LABEL ...]
       (default directory results/baseline, default labels: all found)
"""

import argparse
import csv
import json
import os
import statistics as st
import sys


def parse_result(text):
    out = {}
    for item in text.split(";"):
        if "=" in item:
            key, val = item.split("=", 1)
            try:
                out[key] = float(val)
            except ValueError:
                pass
    return out


def load_label(base, label):
    rows = []
    with open(os.path.join(base, label, "summary.csv")) as f:
        for r in csv.DictReader(f):
            if r["status"] != "ok":
                continue
            r.update(parse_result(r["result"]))
            for key in ("irq_per_s", "net_rx_softirq_per_s", "cpu_busy_pct",
                        "irq_cpu_busy_pct", "irq_cpu_softirq_pct"):
                if r.get(key) not in (None, "", "-"):
                    r[key] = float(r[key])
                else:
                    r.pop(key, None)
            if r["workload"] == "udp" and "loss_pct" not in r:
                raw = os.path.join(base, label,
                                   "udp_%s_run%s.txt" % (r["param"], r["run"]))
                try:
                    s = json.load(open(raw))["end"]["sum"]
                    r["loss_pct"] = float(s.get("lost_percent", 0))
                    r["jitter_ms"] = float(s.get("jitter_ms", 0))
                except (OSError, KeyError, ValueError):
                    pass
            if r["workload"] == "rr" and r.get("tps"):
                r["irq_per_txn"] = r["irq_per_s"] / r["tps"]
            rows.append(r)
    return rows


# column title, key, number format, which workloads show it
COLUMNS = [
    ("Mbit/s", "mbit", "%.1f", ("tcp", "udp")),
    ("loss %", "loss_pct", "%.4f", ("udp",)),
    ("jitter ms", "jitter_ms", "%.3f", ("udp",)),
    ("trans/s", "tps", "%.0f", ("rr",)),
    ("mean latency us", "mean_lat_us", "%.1f", ("rr",)),
    ("irq/s", "irq_per_s", "%.1f", ("idle", "rr", "tcp", "udp")),
    ("irq per trans", "irq_per_txn", "%.2f", ("rr",)),
    ("NET_RX/s", "net_rx_softirq_per_s", "%.0f", ("idle", "rr", "tcp", "udp")),
    ("CPU all %", "cpu_busy_pct", "%.2f", ("idle", "rr", "tcp", "udp")),
    ("IRQ CPU busy %", "irq_cpu_busy_pct", "%.1f", ("idle", "rr", "tcp", "udp")),
    ("IRQ CPU softirq %", "irq_cpu_softirq_pct", "%.1f", ("idle", "rr", "tcp", "udp")),
]


def cell(values, fmt):
    if not values:
        return "-"
    sd = st.stdev(values) if len(values) > 1 else 0.0
    return (fmt + " +/- " + fmt) % (st.mean(values), sd)


def main():
    ap = argparse.ArgumentParser(description="Summarise rx_bench.sh results")
    ap.add_argument("-d", "--dir", default="results/baseline")
    ap.add_argument("labels", nargs="*")
    args = ap.parse_args()

    labels = args.labels or sorted(
        d for d in os.listdir(args.dir)
        if os.path.isfile(os.path.join(args.dir, d, "summary.csv")))
    data = {label: load_label(args.dir, label) for label in labels}

    order = ["idle", "rr", "tcp", "udp"]
    cells = []
    for rows in data.values():
        for r in rows:
            if (r["workload"], r["param"]) not in cells:
                cells.append((r["workload"], r["param"]))
    cells.sort(key=lambda c: (order.index(c[0]) if c[0] in order else 99,
                              float(c[1].rstrip("M")) if c[1].rstrip("M").isdigit() else 0))

    for workload, param in cells:
        title = workload if param == "-" else "%s %s" % (workload, param)
        shown = [c for c in COLUMNS if workload in c[3]
                 and any(c[1] in r for rows in data.values() for r in rows)]
        print("### %s\n" % title)
        print("| Configuration | Runs | " + " | ".join(c[0] for c in shown) + " |")
        print("|---|---|" + "---|" * len(shown))
        for label, rows in data.items():
            sel = [r for r in rows if r["workload"] == workload and r["param"] == param]
            if not sel:
                continue
            vals = [cell([r[c[1]] for r in sel if c[1] in r], c[2]) for c in shown]
            print("| %s | %d | %s |" % (label, len(sel), " | ".join(vals)))
        print()


if __name__ == "__main__":
    sys.exit(main())
