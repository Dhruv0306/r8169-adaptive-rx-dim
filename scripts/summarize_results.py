#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Summarise rx_bench.sh results as Markdown tables.

For every workload cell (idle, rr, rrp, tcp, and each udp and udps rate)
one table is printed with one row per configuration label: mean +/-
standard deviation over the runs. Runs written by older versions of
rx_bench.sh are handled too: when a UDP row has no loss figure, it is read
from the raw iperf3 JSON next to the CSV file.

With -r REF, a second table per cell compares every other label with the
reference label. A difference counts as better or worse only when it is
larger than the larger of the two standard deviations; otherwise it is
reported as "noise" (the tuning rule of plan-4: a difference below one
standard deviation is not a gain).

usage: summarize_results.py [-d RESULTS_DIR] [-r REF_LABEL] [LABEL ...]
       (default directory results/baseline, default labels: all found)
"""

import argparse
import csv
import json
import os
import re
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
            if r["workload"] in ("rr", "rrp") and r.get("tps"):
                r["irq_per_txn"] = r["irq_per_s"] / r["tps"]
            rows.append(r)
    return rows


# column title, key, number format, which workloads show it
ALL = ("idle", "rr", "rrp", "tcp", "udp", "udps")
COLUMNS = [
    ("Mbit/s", "mbit", "%.1f", ("tcp", "udp", "udps")),
    ("pkt/s", "pps", "%.0f", ("udp", "udps")),
    ("loss %", "loss_pct", "%.4f", ("udp", "udps")),
    ("jitter ms", "jitter_ms", "%.3f", ("udp", "udps")),
    ("trans/s", "tps", "%.0f", ("rr", "rrp")),
    ("mean latency us", "mean_lat_us", "%.1f", ("rr", "rrp")),
    ("irq/s", "irq_per_s", "%.1f", ALL),
    ("irq per trans", "irq_per_txn", "%.2f", ("rr", "rrp")),
    ("NET_RX/s", "net_rx_softirq_per_s", "%.0f", ALL),
    ("CPU all %", "cpu_busy_pct", "%.2f", ALL),
    ("IRQ CPU busy %", "irq_cpu_busy_pct", "%.1f", ALL),
    ("IRQ CPU softirq %", "irq_cpu_softirq_pct", "%.1f", ALL),
    ("IRQ CPU non-idle %", "cpu_nonidle_pct", "%.1f", ALL),
]

# With fewer runs than this, the standard deviation says nothing, so no
# verdict is given
MIN_RUNS = 3

# Key metrics for the comparison table: key, title, True when a higher
# value is better, workloads it applies to
COMPARE = [
    ("tps", "trans/s", True, ("rr", "rrp")),
    ("mean_lat_us", "latency", False, ("rr", "rrp")),
    ("mbit", "Mbit/s", True, ("tcp", "udp", "udps")),
    ("loss_pct", "loss", False, ("udp", "udps")),
    ("net_rx_softirq_per_s", "NET_RX/s", False, ALL),
    ("irq_cpu_softirq_pct", "IRQ CPU softirq", False, ALL),
    ("cpu_nonidle_pct", "IRQ CPU non-idle", False, ALL),
]


def cell(values, fmt):
    if not values:
        return "-"
    sd = st.stdev(values) if len(values) > 1 else 0.0
    return (fmt + " +/- " + fmt) % (st.mean(values), sd)


def label_key(label):
    """Natural order of the Phase 4 labels: stock, off, static-L<k>, adaptive, others."""
    m = re.match(r"static-L(\d+)$", label)
    if label == "stock":
        return (0, 0, label)
    if label == "off":
        return (1, 0, label)
    if m:
        return (2, int(m.group(1)), label)
    if label == "adaptive":
        return (3, 0, label)
    return (4, 0, label)


def rate_of(param):
    """Offered rate in Mbit/s from a parameter such as 600M or 100B-50M."""
    m = re.search(r"(\d+)M$", param)
    return float(m.group(1)) if m else 0.0


def verdict(ref, other, higher_better, force_abs=False):
    """(difference, absolute, verdict) of other against ref.

    The difference is a percentage of the reference mean, or the plain
    difference (absolute is True) when the reference mean is 0. The verdict
    is "better", "worse" or "noise", or a note when either side has fewer than
    MIN_RUNS runs.
    """
    if not ref or not other:
        return None
    mr, mo = st.mean(ref), st.mean(other)
    too_few = len(ref) < MIN_RUNS or len(other) < MIN_RUNS
    sr = st.stdev(ref) if len(ref) > 1 else 0.0
    so = st.stdev(other) if len(other) > 1 else 0.0
    diff = mo - mr
    absolute = force_abs or mr == 0
    value = diff if absolute else 100.0 * diff / mr
    if too_few:
        return value, absolute, "(fewer than %d runs)" % MIN_RUNS
    if abs(diff) <= max(sr, so):
        return value, absolute, "noise"
    return value, absolute, "better" if (diff > 0) == higher_better else "worse"


def compare_table(data, ref, workload, param):
    """Markdown table of every label against the reference label, or None."""
    sel = {label: [r for r in rows if r["workload"] == workload and r["param"] == param]
           for label, rows in data.items()}
    if not sel.get(ref):
        return None
    metrics = [m for m in COMPARE if workload in m[3]
               and any(m[0] in r for r in sel[ref])]
    out = ["| Configuration | " + " | ".join(m[1] for m in metrics) + " |",
           "|---|" + "---|" * len(metrics)]
    for label, rows in sel.items():
        if label == ref or not rows:
            continue
        cells = []
        for key, _, higher, _ in metrics:
            v = verdict([r[key] for r in sel[ref] if key in r],
                        [r[key] for r in rows if key in r], higher,
                        key == "loss_pct")
            if v is None:
                cells.append("-")
            elif v[1]:
                cells.append("%+.4f points %s" % (v[0], v[2]))
            else:
                cells.append("%+.1f%% %s" % (v[0], v[2]))
        out.append("| %s | %s |" % (label, " | ".join(cells)))
    return "\n".join(out) if len(out) > 2 else None


def main():
    ap = argparse.ArgumentParser(description="Summarise rx_bench.sh results")
    ap.add_argument("-d", "--dir", default="results/baseline")
    ap.add_argument("-r", "--ref", help="label to compare the others against")
    ap.add_argument("labels", nargs="*")
    args = ap.parse_args()

    labels = args.labels or sorted(
        (d for d in os.listdir(args.dir)
         if os.path.isfile(os.path.join(args.dir, d, "summary.csv"))),
        key=label_key)
    data = {label: load_label(args.dir, label) for label in labels}

    order = ["idle", "rr", "rrp", "tcp", "udp", "udps"]
    cells = []
    for rows in data.values():
        for r in rows:
            if (r["workload"], r["param"]) not in cells:
                cells.append((r["workload"], r["param"]))
    cells.sort(key=lambda c: (order.index(c[0]) if c[0] in order else 99,
                              rate_of(c[1]), c[1]))

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
        if args.ref:
            table = compare_table(data, args.ref, workload, param)
            if table:
                print("Against %s (a difference within the larger standard deviation is noise):\n" % args.ref)
                print(table)
                print()


if __name__ == "__main__":
    sys.exit(main())
