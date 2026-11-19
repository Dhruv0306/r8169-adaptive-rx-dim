#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Draw the Phase 4 figures from rx_bench.sh and stepped_load.sh results.

usage: plot_results.py [-d RESULTS_DIR] [-o FIGDIR] [--stepped DIR ...] [LABEL ...]

  -d DIR        directory with one sub-directory of summary.csv per label
                (default results/baseline)
  -o FIGDIR     where the PNG files go (default docs/figures)
  --stepped DIR a stepped_load.sh run directory (levels.csv and markers.csv);
                may be repeated; one figure per directory
  LABEL         labels to draw, in order (default: all, in the natural order)

Figures (each only when the data exists):
  udp_netrx_softirq.png, udps_netrx_softirq.png
        NET_RX per second and softirq share of the interrupt CPU against the
        offered rate, one line per label, error bars are one standard deviation
  request_response.png
        transactions per second and mean latency for rr and rrp
  tcp_bulk.png
        throughput and softirq share of the interrupt CPU
  stepped_<label>.png
        rx-usecs against time with the bursts shaded, and the interrupt rate
"""

import argparse
import csv
import os
import statistics as st
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from summarize_results import label_key, load_label, rate_of  # noqa: E402


def mean_sd(values):
    if not values:
        return None, None
    return st.mean(values), (st.stdev(values) if len(values) > 1 else 0.0)


def colours(labels):
    cmap = plt.get_cmap("tab10")
    return {label: cmap(i % 10) for i, label in enumerate(labels)}


def cell_values(rows, workload, param, key):
    return [r[key] for r in rows
            if r["workload"] == workload and r["param"] == param and key in r]


def rate_figure(data, labels, col, workload, outdir):
    params = sorted({r["param"] for rows in data.values() for r in rows
                     if r["workload"] == workload}, key=lambda p: (rate_of(p), p))
    if not params:
        return None
    fig, axes = plt.subplots(1, 2, figsize=(11, 4))
    for ax, key, title in ((axes[0], "net_rx_softirq_per_s", "NET_RX softirq runs per second"),
                           (axes[1], "irq_cpu_softirq_pct", "softirq share of the interrupt CPU (%)")):
        for label in labels:
            xs, ys, es = [], [], []
            for i, p in enumerate(params):
                m, sd = mean_sd(cell_values(data[label], workload, p, key))
                if m is not None:
                    xs.append(i)
                    ys.append(m)
                    es.append(sd)
            if xs:
                ax.errorbar(xs, ys, yerr=es, marker="o", capsize=3, label=label, color=col[label])
        ax.set_xticks(range(len(params)))
        ax.set_xticklabels(params, rotation=20)
        ax.set_xlabel("offered rate (%s)" % workload)
        ax.set_title(title)
        ax.grid(alpha=0.3)
    axes[0].legend()
    fig.tight_layout()
    path = os.path.join(outdir, "%s_netrx_softirq.png" % workload)
    fig.savefig(path, dpi=130)
    plt.close(fig)
    return path


def rr_figure(data, labels, col, outdir):
    cells = [(w, p) for w in ("rr", "rrp")
             for p in sorted({r["param"] for rows in data.values() for r in rows if r["workload"] == w})]
    if not cells:
        return None
    fig, axes = plt.subplots(1, 2, figsize=(11, 4))
    width = 0.8 / max(len(labels), 1)
    for ax, key, title in ((axes[0], "tps", "transactions per second"),
                           (axes[1], "mean_lat_us", "mean latency (us)")):
        for j, label in enumerate(labels):
            xs, ys, es = [], [], []
            for i, (w, p) in enumerate(cells):
                m, sd = mean_sd(cell_values(data[label], w, p, key))
                if m is not None:
                    xs.append(i + j * width)
                    ys.append(m)
                    es.append(sd)
            ax.bar(xs, ys, width=width, yerr=es, capsize=3, label=label, color=col[label])
        ax.set_xticks([i + 0.4 - width / 2 for i in range(len(cells))])
        ax.set_xticklabels(["%s %s" % c for c in cells])
        ax.set_title(title)
        ax.grid(alpha=0.3, axis="y")
    axes[0].legend()
    fig.tight_layout()
    path = os.path.join(outdir, "request_response.png")
    fig.savefig(path, dpi=130)
    plt.close(fig)
    return path


def tcp_figure(data, labels, col, outdir):
    if not any(r["workload"] == "tcp" for rows in data.values() for r in rows):
        return None
    fig, axes = plt.subplots(1, 2, figsize=(9, 4))
    for ax, key, title in ((axes[0], "mbit", "throughput (Mbit/s)"),
                           (axes[1], "irq_cpu_softirq_pct", "softirq share of the interrupt CPU (%)")):
        xs, ys, es, cs = [], [], [], []
        for i, label in enumerate(labels):
            m, sd = mean_sd(cell_values(data[label], "tcp", "bulk", key))
            if m is not None:
                xs.append(i)
                ys.append(m)
                es.append(sd)
                cs.append(col[label])
        ax.bar(xs, ys, yerr=es, capsize=3, color=cs)
        ax.set_xticks(range(len(labels)))
        ax.set_xticklabels(labels, rotation=25)
        ax.set_title(title)
        ax.grid(alpha=0.3, axis="y")
    fig.tight_layout()
    path = os.path.join(outdir, "tcp_bulk.png")
    fig.savefig(path, dpi=130)
    plt.close(fig)
    return path


def stepped_figure(directory, outdir):
    try:
        levels = list(csv.DictReader(open(os.path.join(directory, "levels.csv"))))
        markers = list(csv.DictReader(open(os.path.join(directory, "markers.csv"))))
    except OSError as e:
        print("skipping %s: %s" % (directory, e))
        return None
    t = [float(r["time_s"]) for r in levels]
    us = [int(r["rx_usecs"]) for r in levels]
    irq = [int(r["irq_count"]) for r in levels]
    rate = [0.0] + [(b - a) / (tb - ta) if tb > ta else 0.0
                    for a, b, ta, tb in zip(irq, irq[1:], t, t[1:])]
    fig, axes = plt.subplots(2, 1, figsize=(10, 5.5), sharex=True)
    axes[0].step(t, us, where="post", color="tab:blue")
    axes[0].set_ylabel("rx-usecs (level)")
    axes[1].plot(t, rate, color="tab:red", linewidth=0.8)
    axes[1].set_ylabel("NIC interrupts per second")
    axes[1].set_xlabel("time (s)")
    starts = {m["event"][:-6]: float(m["time_s"]) for m in markers if m["event"].endswith("_start")}
    for m in markers:
        if m["event"].endswith("_end") and m["event"][:-4] in starts:
            for ax in axes:
                ax.axvspan(starts[m["event"][:-4]], float(m["time_s"]), color="grey", alpha=0.2)
    for ax in axes:
        ax.grid(alpha=0.3)
    axes[0].set_title("%s (shaded: load from the peer)" % os.path.basename(os.path.normpath(directory)))
    fig.tight_layout()
    path = os.path.join(outdir, "stepped_%s.png" % os.path.basename(os.path.normpath(directory)))
    fig.savefig(path, dpi=130)
    plt.close(fig)
    return path


def main():
    ap = argparse.ArgumentParser(description="Draw the Phase 4 figures")
    ap.add_argument("-d", "--dir", default="results/baseline")
    ap.add_argument("-o", "--out", default="docs/figures")
    ap.add_argument("--stepped", action="append", default=[])
    ap.add_argument("labels", nargs="*")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    made = []
    if os.path.isdir(args.dir):
        labels = args.labels or sorted(
            (d for d in os.listdir(args.dir)
             if os.path.isfile(os.path.join(args.dir, d, "summary.csv"))), key=label_key)
        data = {label: load_label(args.dir, label) for label in labels}
        col = colours(labels)
        if labels:
            for w in ("udp", "udps"):
                made.append(rate_figure(data, labels, col, w, args.out))
            made.append(rr_figure(data, labels, col, args.out))
            made.append(tcp_figure(data, labels, col, args.out))
    for d in args.stepped:
        made.append(stepped_figure(d, args.out))
    made = [m for m in made if m]
    for m in made:
        print("wrote", m)
    if not made:
        print("nothing to draw", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
