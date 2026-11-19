#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""How fast the RX timer level follows a stepped load (stepped_load.sh output).

For every burst: the time from the start of the burst until the level first
rises above 0, until it first reaches the top level, and the time from the
end of the burst until it is back at 0. The burst markers are taken just
before iperf3 starts and just after it returns, so the rise times include
the iperf3 start-up (a few hundred milliseconds) and the decay time starts
at a marker that is slightly later than the last packet. The resolution is
the sampling interval.

usage: level_response.py RUN_DIR      (a directory with levels.csv and markers.csv)
"""

import csv
import os
import sys


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    d = sys.argv[1]
    try:
        levels = [(float(r["time_s"]), int(r["rx_usecs"]))
                  for r in csv.DictReader(open(os.path.join(d, "levels.csv")))]
        markers = {r["event"]: float(r["time_s"])
                   for r in csv.DictReader(open(os.path.join(d, "markers.csv")))}
    except (OSError, KeyError, ValueError) as e:
        print("cannot read %s: %s" % (d, e), file=sys.stderr)
        return 1
    if not levels:
        print("no samples", file=sys.stderr)
        return 1
    top = max(v for _, v in levels)
    print("%s: %d samples, top level %d us" % (d, len(levels), top))
    n = 1
    while "burst%d_start" % n in markers:
        t0 = markers["burst%d_start" % n]
        t1 = markers.get("burst%d_end" % n)
        nxt = markers.get("burst%d_start" % (n + 1), markers.get("end"))
        rise = next((t - t0 for t, v in levels if t >= t0 and v > 0), None)
        at_top = next((t - t0 for t, v in levels if t >= t0 and v >= top), None)
        decay = None
        if t1 is not None:
            decay = next((t - t1 for t, v in levels
                          if t >= t1 and v == 0 and (nxt is None or t <= nxt)), None)
        fmt = lambda x: "none" if x is None else "%.2f s" % x
        print("burst %d: first above 0 after %s, top level after %s, back at 0 %s after the end"
              % (n, fmt(rise), fmt(at_top), fmt(decay)))
        n += 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
