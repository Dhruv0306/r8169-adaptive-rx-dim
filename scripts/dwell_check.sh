#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Repeat one UDP run many times with the level sampler running, to see how
# often the level dwells low (the 900 Mbit/s question carried over from
# Phase 2; plan-4, section 3.5). Run as root at the console, from the
# repository root, with the patched module loaded; the peer runs iperf3 -s.
#
# usage: dwell_check.sh -p PEER [options]
#   -p PEER      address of the peer
#   -d DEV       network interface            (default enp3s0)
#   -o OUTDIR    output directory             (default results/phase4/dwell)
#   -l LABEL     name of this series, a sub-directory (default <mode>-<rate>)
#   -n RUNS      number of runs               (default 10)
#   -t SECS      seconds per run              (default 15)
#   -r RATE      UDP rate                     (default 900M)
#   -s BYTES     UDP datagram payload         (default: iperf3 default, 1448)
#   -a MODE      on (default) or off (control: adaptive off)
#   -v SECS      sampling interval            (default 0.2)
#
# Per run: run<N>.csv (level samples), run<N>.json (iperf3) and one line in
# OUTDIR/LABEL/summary.csv with the NET_RX rate, the mean timer, the share of
# samples below 200 us and the level changes per second.

set -u

DEV=enp3s0
PEER=""
OUTDIR=results/phase4/dwell
LABEL=""
RUNS=10
SECS=15
RATE=900M
LEN=""
MODE=on
INTERVAL=0.2

usage() {
	sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "p:d:o:l:n:t:r:s:a:v:h" opt; do
	case $opt in
	p) PEER=$OPTARG ;;
	d) DEV=$OPTARG ;;
	o) OUTDIR=$OPTARG ;;
	l) LABEL=$OPTARG ;;
	n) RUNS=$OPTARG ;;
	t) SECS=$OPTARG ;;
	r) RATE=$OPTARG ;;
	s) LEN=$OPTARG ;;
	a) MODE=$OPTARG ;;
	v) INTERVAL=$OPTARG ;;
	*) usage ;;
	esac
done

[ -n "$PEER" ] || usage
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
case $MODE in on | off) ;; *) usage ;; esac
for tool in ethtool iperf3 bc python3; do
	command -v "$tool" > /dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

here=$(dirname "$0")
[ -n "$LABEL" ] || LABEL="$MODE-$RATE"
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

ethtool -C "$DEV" adaptive-rx off || exit 1
ethtool -C "$DEV" rx-usecs 0 || exit 1
if [ "$MODE" = on ]; then
	ethtool -C "$DEV" adaptive-rx on || { echo "adaptive-rx is refused: is the patched module loaded?" >&2; exit 1; }
fi

SAMPLER=""
cleanup() {
	[ -n "$SAMPLER" ] && kill "$SAMPLER" 2> /dev/null
	ethtool -C "$DEV" adaptive-rx off > /dev/null 2>&1
	ethtool -C "$DEV" rx-usecs 0 > /dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM

net_rx() { awk '$1 == "NET_RX:" { s = 0; for (i = 2; i <= NF; i++) s += $i; print s }' /proc/softirqs; }

{
	echo "date: $(date -Is)"
	echo "command: $0 $*"
	echo "kernel: $(uname -r)  r8169 srcversion: $(cat /sys/module/r8169/srcversion 2> /dev/null)"
} > "$OUT/meta_$(date +%Y%m%d_%H%M%S).txt"

CSV="$OUT/summary.csv"
[ -s "$CSV" ] || echo "label,run,secs,net_rx_per_s,mbit,loss_pct,mean_usecs,low_pct,changes_per_s" > "$CSV"
first=$(($(grep -c ',' "$CSV") ))   # lines already there, header included

for i in $(seq 1 "$RUNS"); do
	run=$((first + i - 1))
	export T0
	T0=$(date +%s.%N)
	bash "$here/sample_level.sh" "$DEV" "$INTERVAL" > "$OUT/run$run.csv" 2> /dev/null &
	SAMPLER=$!
	s0=$(net_rx)
	ts0=$(date +%s.%N)
	if [ -n "$LEN" ]; then
		iperf3 -c "$PEER" -R -u -b "$RATE" -l "$LEN" -t "$SECS" -J > "$OUT/run$run.json" 2>&1
	else
		iperf3 -c "$PEER" -R -u -b "$RATE" -t "$SECS" -J > "$OUT/run$run.json" 2>&1
	fi
	rc=$?
	ts1=$(date +%s.%N)
	s1=$(net_rx)
	kill "$SAMPLER" 2> /dev/null
	wait "$SAMPLER" 2> /dev/null
	SAMPLER=""

	rate=$(awk -v a="$s0" -v b="$s1" -v t0="$ts0" -v t1="$ts1" 'BEGIN { printf "%.0f", (b - a) / (t1 - t0) }')
	res=$(python3 - "$OUT/run$run.json" << 'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))["end"]["sum"]
    print("%.1f,%.4f" % (s["bits_per_second"] / 1e6, s.get("lost_percent", 0)))
except Exception:
    print("-,-")
PY
)
	dw=$(python3 "$here/level_dwell.py" --csv "$OUT/run$run.csv" 2> /dev/null || echo "-,-,-")
	[ "$rc" -eq 0 ] || res="fail($rc),-"
	echo "$LABEL,$run,$SECS,$rate,$res,$dw" | tee -a "$CSV"
	sleep 2
done
