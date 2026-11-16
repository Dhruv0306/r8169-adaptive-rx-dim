#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Summarise how long the RX timer level sat where, from sample_level.sh CSV files.

For every file: the number of samples, the mean rx-usecs, the share of samples
at each value, the share below a threshold ("low dwell") and the number of
changes of rx-usecs per second between consecutive samples (a lower bound,
since changes between two samples are not seen).

usage: level_dwell.py [--low USECS] [--csv] FILE.csv [FILE.csv ...]
  --low USECS  rx-usecs below this count as low dwell (default 200, the
               third level of the table 0, 40, 80, 200, 400)
  --csv        print "mean_usecs,low_pct,changes_per_s" for the first file only
"""

import argparse
import csv
import sys


def load(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            try:
                rows.append((float(r["time_s"]), int(r["rx_usecs"])))
            except (KeyError, ValueError, TypeError):
                continue
    return rows


def stats(rows, low):
    n = len(rows)
    if n < 2:
        return None
    values = [v for _, v in rows]
    span = rows[-1][0] - rows[0][0]
    changes = sum(1 for a, b in zip(values, values[1:]) if a != b)
    shares = {}
    for v in values:
        shares[v] = shares.get(v, 0) + 1
    return {
        "samples": n,
        "mean": sum(values) / n,
        "low_pct": 100.0 * sum(1 for v in values if v < low) / n,
        "changes_per_s": changes / span if span > 0 else 0.0,
        "shares": {v: 100.0 * c / n for v, c in sorted(shares.items())},
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--low", type=int, default=200)
    ap.add_argument("--csv", action="store_true")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()

    if args.csv:
        s = stats(load(args.files[0]), args.low)
        print("-,-,-" if s is None else
              "%.1f,%.1f,%.2f" % (s["mean"], s["low_pct"], s["changes_per_s"]))
        return 0

    for path in args.files:
        s = stats(load(path), args.low)
        if s is None:
            print("%s: too few samples" % path)
            continue
        shares = " ".join("%d us %.0f%%" % (v, p) for v, p in s["shares"].items())
        print("%s: %d samples, mean %.0f us, below %d us %.0f%%, %.1f changes/s; %s" % (
            path, s["samples"], s["mean"], args.low, s["low_pct"],
            s["changes_per_s"], shares))
    return 0


if __name__ == "__main__":
    sys.exit(main())
