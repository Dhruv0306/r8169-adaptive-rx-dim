#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Live demo of adaptive RX interrupt moderation on the r8169 (Phase 5).
# Run as root at the console of the machine under test, from the repository
# root, with the patched module loaded. The peer runs
#     iperf3 -s
#     netserver
# The run sheet, with what to say at each stage, is docs/demo.md.
#
# usage: demo.sh -p PEER [options]
#   -p PEER     address of the peer
#   -d DEV      network interface                          (default enp3s0)
#   -t LENGTH   short (about 3 minutes) or long (about 10) (default short)
#   -y          do not wait for Enter between stages (rehearsal and recording)
#   -o OUTDIR   keep a copy of the screen output in OUTDIR/demo.log
#
# The stages: (1) the module and the flag, adaptive off; (2) adaptive on and
# idle; (3) a small-packet UDP burst from the peer, with the level and the
# interrupt rate shown twice a second; (4) idle again, the level falls;
# (5) request-response with adaptive on, then with a static 400 us timer,
# for comparison; (6) back to the starting state. The traffic is the
# "udps" workload of Phase 4: 100 byte datagrams, 100 us pacing timer.

set -u

DEV=enp3s0
PEER=""
LENGTH=short
WAIT=1
OUTDIR=""
# the burst: 100 byte datagrams at 100 Mbit/s, iperf3 pacing timer 100 us
BURST_ARGS="-u -l 100 -b 100M --pacing-timer 100"

usage() {
	sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "p:d:t:yo:h" opt; do
	case $opt in
	p) PEER=$OPTARG ;;
	d) DEV=$OPTARG ;;
	t) LENGTH=$OPTARG ;;
	y) WAIT=0 ;;
	o) OUTDIR=$OPTARG ;;
	*) usage ;;
	esac
done

[ -n "$PEER" ] || usage
case $LENGTH in
short) IDLE=4 BURST=8 RR=5 ;;
long) IDLE=8 BURST=15 RR=10 ;;
*) usage ;;
esac

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for tool in ethtool iperf3 netperf awk; do
	command -v "$tool" > /dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -d "/sys/class/net/$DEV" ] || { echo "no interface $DEV" >&2; exit 1; }
[ -r /sys/module/r8169/srcversion ] || { echo "r8169 is not loaded" >&2; exit 1; }

if [ -n "$OUTDIR" ]; then
	mkdir -p "$OUTDIR"
	exec > >(tee "$OUTDIR/demo.log") 2>&1
fi

nic_irqs() {
	awk -v d="$DEV" '$0 ~ d {n=0; for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) n+=$i; print n; exit}' /proc/interrupts
}

rx_usecs() {
	ethtool -c "$DEV" | awk '/^rx-usecs:/ {print $2}'
}

adaptive_line() {
	ethtool -c "$DEV" | awk '/^Adaptive RX:/ {print}'
}

pause() {
	[ "$WAIT" -eq 1 ] || return 0
	printf '\n[Enter to continue] '
	read -r _
}

stage() {
	printf '\n==== %s ====\n' "$1"
}

# Print "time level interrupts/s bar" twice a second for SECS seconds.
watch_level() {
	local secs=$1 n us prev now rate bar t0
	t0=$(date +%s.%N)
	prev=$(nic_irqs)
	n=$((secs * 2))
	printf '%6s  %8s  %8s\n' "time" "rx-usecs" "irq/s"
	while [ "$n" -gt 0 ]; do
		n=$((n - 1))
		sleep 0.5
		us=$(rx_usecs)
		now=$(nic_irqs)
		rate=$(((now - prev) * 2))
		prev=$now
		bar=$(printf '%*s' $((${us:-0} / 20)) '' | tr ' ' '#')
		printf '%5.1fs  %6s us  %8d  %s\n' "$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN {print a - b}')" "${us:-0}" "$rate" "$bar"
	done
}

run_burst() {
	iperf3 -c "$PEER" -R $BURST_ARGS -t "$BURST" > /dev/null 2>&1 &
	BURST_PID=$!
}

run_rr() {
	netperf -H "$PEER" -t TCP_RR -l "$RR" -P 0 -- -r 64,64 -o THROUGHPUT,MEAN_LATENCY 2> /dev/null |
		tail -n 1 | awk -F, '{printf "  %.0f transactions/s, mean latency %.1f us\n", $1, $2}'
}

cleanup() {
	[ -n "${BURST_PID:-}" ] && kill "$BURST_PID" 2> /dev/null
	ethtool -C "$DEV" adaptive-rx off > /dev/null 2>&1
	ethtool -C "$DEV" rx-usecs 0 > /dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM

timeout 120 bash -c "until timeout 2 bash -c 'exec 3<>/dev/tcp/$PEER/5201' 2> /dev/null; do sleep 1; done" ||
	{ echo "peer $PEER does not answer on 5201 (iperf3 -s running?)" >&2; exit 1; }

# a known starting state
ethtool -C "$DEV" adaptive-rx off 2> /dev/null
ethtool -C "$DEV" rx-usecs 0 2> /dev/null

stage "1. The module and the flag (adaptive off)"
echo "kernel $(uname -r), r8169 srcversion $(cat /sys/module/r8169/srcversion)"
ethtool -i "$DEV" | sed -n '1,2p'
ethtool -c "$DEV" | sed -n '/^Adaptive/p;/^rx-usecs/p;/^rx-frames:/p'
echo "The stock driver prints 'Adaptive RX: n/a' here and refuses the flag."
pause

stage "2. Adaptive mode on, no traffic"
ethtool -C "$DEV" adaptive-rx on || { echo "adaptive-rx refused: is the patched module loaded?" >&2; exit 1; }
adaptive_line
watch_level "$IDLE"
pause

stage "3. A burst of small UDP packets from the peer"
echo "Watch rx-usecs rise and irq/s fall."
run_burst
watch_level "$BURST"
wait "$BURST_PID" 2> /dev/null
BURST_PID=""
pause

stage "4. The burst has ended"
echo "The level falls back to 0 when the packets stop (about 0.4 s)."
watch_level "$IDLE"
pause

stage "5. Request-response (one packet at a time)"
echo "adaptive on, level stays at 0:"
run_rr
echo "level now: $(rx_usecs) us"
echo "for comparison, a fixed 400 us timer (adaptive off):"
ethtool -C "$DEV" adaptive-rx off
ethtool -C "$DEV" rx-usecs 400
run_rr
pause

stage "6. Back to the starting state"
cleanup
ethtool -c "$DEV" | sed -n '/^Adaptive/p;/^rx-usecs/p'
echo "Done."
