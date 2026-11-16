#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Stepped load for the demo and the level-versus-time figure (Phase 4):
# idle, a UDP burst from the peer, idle, repeated, while the RX timer is
# sampled a few times a second. Run as root at the console, from the
# repository root, with the patched module loaded; the peer runs iperf3 -s.
#
# usage: stepped_load.sh -p PEER [options]
#   -p PEER      address of the peer
#   -d DEV       network interface                 (default enp3s0)
#   -o OUTDIR    output directory                  (default results/phase4/stepped)
#   -l LABEL     name of this run, a sub-directory (default adaptive-<rate>)
#   -c CYCLES    number of idle+burst cycles       (default 3)
#   -i SECS      idle time before each burst and after the last one (default 10)
#   -b SECS      burst length                      (default 10)
#   -r RATE      UDP rate of the burst             (default 600M)
#   -s BYTES     UDP datagram payload              (default 1448, the iperf3 default)
#   -a MODE      on (default): adaptive mode on, level 0 at the start;
#                off: adaptive off, rx-usecs 0 (a flat control trace);
#                keep: leave the device as it is
#   -v SECS      sampling interval                 (default 0.2)
#
# Writes OUTDIR/LABEL/levels.csv (time_s, rx_timer_field, rx_usecs, irq_count,
# from sample_level.sh), markers.csv (time_s on the same clock, event),
# burst<N>.json (iperf3 output) and meta.txt. The burst markers are taken just
# before iperf3 starts and just after it returns, so they are a few hundred
# milliseconds wider than the traffic itself. plot_results.py --stepped
# draws the figure.

set -u

DEV=enp3s0
PEER=""
OUTDIR=results/phase4/stepped
LABEL=""
CYCLES=3
IDLE=10
BURST=10
RATE=600M
LEN=""
MODE=on
INTERVAL=0.2

usage() {
	sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "p:d:o:l:c:i:b:r:s:a:v:h" opt; do
	case $opt in
	p) PEER=$OPTARG ;;
	d) DEV=$OPTARG ;;
	o) OUTDIR=$OPTARG ;;
	l) LABEL=$OPTARG ;;
	c) CYCLES=$OPTARG ;;
	i) IDLE=$OPTARG ;;
	b) BURST=$OPTARG ;;
	r) RATE=$OPTARG ;;
	s) LEN=$OPTARG ;;
	a) MODE=$OPTARG ;;
	v) INTERVAL=$OPTARG ;;
	*) usage ;;
	esac
done

[ -n "$PEER" ] || usage
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for tool in ethtool iperf3 bc; do
	command -v "$tool" > /dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
case $MODE in on | off | keep) ;; *) usage ;; esac

here=$(dirname "$0")
[ -n "$LABEL" ] || LABEL="adaptive-$RATE"
[ "$MODE" = off ] && [ "$LABEL" = "adaptive-$RATE" ] && LABEL="off-$RATE"
OUT="$OUTDIR/$LABEL"
mkdir -p "$OUT"

wait_peer() {
	local i
	for i in $(seq 1 120); do
		timeout 2 bash -c "exec 3<>/dev/tcp/$PEER/5201" 2> /dev/null && return 0
		sleep 1
	done
	return 1
}
wait_peer || { echo "peer $PEER does not answer on 5201" >&2; exit 1; }

case $MODE in
on)
	ethtool -C "$DEV" adaptive-rx off || exit 1
	ethtool -C "$DEV" rx-usecs 0 || exit 1
	ethtool -C "$DEV" adaptive-rx on || { echo "adaptive-rx is refused: is the patched module loaded?" >&2; exit 1; }
	;;
off)
	ethtool -C "$DEV" adaptive-rx off || exit 1
	ethtool -C "$DEV" rx-usecs 0 || exit 1
	;;
esac

SAMPLER=""
cleanup() {
	[ -n "$SAMPLER" ] && kill "$SAMPLER" 2> /dev/null
	[ "$MODE" = keep ] || { ethtool -C "$DEV" adaptive-rx off > /dev/null 2>&1; ethtool -C "$DEV" rx-usecs 0 > /dev/null 2>&1; }
}
trap cleanup EXIT
trap 'exit 130' INT TERM

{
	echo "date: $(date -Is)"
	echo "command: $0 $*"
	echo "kernel: $(uname -r)  r8169 srcversion: $(cat /sys/module/r8169/srcversion 2> /dev/null)"
	echo "mode: $MODE  cycles: $CYCLES  idle: $IDLE s  burst: $BURST s  rate: $RATE  len: ${LEN:-default}"
	ethtool -c "$DEV" 2>&1 | head -n 8
} > "$OUT/meta.txt"

export T0
T0=$(date +%s.%N)
bash "$here/sample_level.sh" "$DEV" "$INTERVAL" > "$OUT/levels.csv" 2> "$OUT/sampler.err" &
SAMPLER=$!

echo "time_s,event" > "$OUT/markers.csv"
mark() { printf '%.2f,%s\n' "$(echo "$(date +%s.%N) - $T0" | bc)" "$1" >> "$OUT/markers.csv"; }

mark start
for n in $(seq 1 "$CYCLES"); do
	echo "cycle $n of $CYCLES: idle $IDLE s"
	sleep "$IDLE"
	echo "cycle $n of $CYCLES: $RATE UDP for $BURST s"
	mark "burst${n}_start"
	if [ -n "$LEN" ]; then
		iperf3 -c "$PEER" -R -u -b "$RATE" -l "$LEN" -t "$BURST" -J > "$OUT/burst$n.json" 2>&1
	else
		iperf3 -c "$PEER" -R -u -b "$RATE" -t "$BURST" -J > "$OUT/burst$n.json" 2>&1
	fi
	rc=$?
	mark "burst${n}_end"
	[ "$rc" -eq 0 ] || echo "warning: iperf3 failed in burst $n (exit $rc), see $OUT/burst$n.json" >&2
done
echo "final idle $IDLE s"
sleep "$IDLE"
mark end

kill "$SAMPLER" 2> /dev/null
wait "$SAMPLER" 2> /dev/null
SAMPLER=""
echo "wrote $OUT/levels.csv ($(($(wc -l < "$OUT/levels.csv") - 1)) samples) and $OUT/markers.csv"
python3 "$here/level_dwell.py" "$OUT/levels.csv" 2> /dev/null || true
