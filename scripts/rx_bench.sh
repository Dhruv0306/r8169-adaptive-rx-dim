#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Receive-side benchmark for the r8169 interrupt moderation project.
#
# Runs on the machine under test. The peer machine must run:
#     iperf3 -s
#     netserver
# Every workload makes the peer send to this machine, so the numbers
# describe the receive path. The script does not change the coalescing
# settings: set them (or load the stock or modified module) first, and
# pass a label that names that configuration.
#
# Per run it records the NIC interrupt rate, the NET_RX softirq rate and
# the CPU busy percentage over the run, plus the workload result. Raw
# tool output is kept next to a summary.csv.
#
# usage: rx_bench.sh -l LABEL -p PEER [options]
#   -l LABEL     configuration name, for example stock or static-low
#   -p PEER      address of the peer machine (not needed for -w idle)
#   -d DEV       network interface            (default enp3s0)
#   -i IRQ       NIC interrupt number         (default: found in /proc/interrupts by device name)
#   -o OUTDIR    output directory             (default results/baseline)
#   -n RUNS      repetitions per cell         (default 5)
#   -t SECS      seconds per run              (default 20)
#   -w LIST      workloads: idle rr tcp udp   (default "idle rr tcp udp")
#   -u RATES     UDP offered rates            (default "100M 300M 600M 900M")

set -u

DEV=enp3s0
IRQ=""
OUTDIR=results/baseline
RUNS=5
SECS=20
WORKLOADS="idle rr tcp udp"
UDP_RATES="100M 300M 600M 900M"
LABEL=""
PEER=""

usage() {
	sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "l:p:d:i:o:n:t:w:u:h" opt; do
	case $opt in
	l) LABEL=$OPTARG ;;
	p) PEER=$OPTARG ;;
	d) DEV=$OPTARG ;;
	i) IRQ=$OPTARG ;;
	o) OUTDIR=$OPTARG ;;
	n) RUNS=$OPTARG ;;
	t) SECS=$OPTARG ;;
	w) WORKLOADS=$OPTARG ;;
	u) UDP_RATES=$OPTARG ;;
	*) usage ;;
	esac
done

[ -n "$LABEL" ] || usage
need_peer=0
for w in $WORKLOADS; do
	[ "$w" = idle ] || need_peer=1
done
if [ "$need_peer" = 1 ] && [ -z "$PEER" ]; then
	echo "a peer (-p) is needed for these workloads" >&2
	exit 2
fi

INTERRUPTS_FILE=${INTERRUPTS_FILE:-/proc/interrupts}

# The row of /proc/interrupts named after the device is the reliable
# source. "device/irq" in sysfs is the legacy line for MSI-X devices
# such as this NIC and points at an unrelated interrupt.
if [ -z "$IRQ" ]; then
	IRQ=$(awk -v d="$DEV" '$NF == d { sub(":", "", $1); print $1; exit }' "$INTERRUPTS_FILE")
fi
if [ -z "$IRQ" ]; then
	IRQ=$(ls "/sys/class/net/$DEV/device/msi_irqs" 2>/dev/null | head -n 1)
fi
if [ -z "$IRQ" ]; then
	IRQ=$(cat "/sys/class/net/$DEV/device/irq" 2>/dev/null || true)
fi
if [ -z "$IRQ" ]; then
	echo "cannot find the interrupt of $DEV; pass it with -i" >&2
	exit 1
fi

for tool in awk python3; do
	command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
for w in $WORKLOADS; do
	case $w in
	rr) command -v netperf >/dev/null || { echo "missing tool: netperf" >&2; exit 1; } ;;
	tcp | udp) command -v iperf3 >/dev/null || { echo "missing tool: iperf3" >&2; exit 1; } ;;
	idle) ;;
	*) echo "unknown workload: $w" >&2; exit 2 ;;
	esac
done

OUT="$OUTDIR/$LABEL"
mkdir -p "$OUT"
CSV="$OUT/summary.csv"
if [ ! -s "$CSV" ]; then
	echo "label,workload,param,run,secs,irq_per_s,net_rx_softirq_per_s,cpu_busy_pct,status,result" > "$CSV"
fi

# ---- counters -------------------------------------------------------

irq_total() {
	awk -v irq="$IRQ:" '$1 == irq { s = 0; for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i; print s }' "$INTERRUPTS_FILE"
}

softirq_net_rx() {
	awk '$1 == "NET_RX:" { s = 0; for (i = 2; i <= NF; i++) s += $i; print s }' /proc/softirqs
}

# prints "busy_jiffies total_jiffies" for all CPUs together
cpu_times() {
	awk '$1 == "cpu" { idle = $5 + $6; t = 0; for (i = 2; i <= 9; i++) t += $i; print t - idle, t }' /proc/stat
}

# ---- result parsers -------------------------------------------------

parse_iperf() {
	python3 - "$1" <<'PY'
import json, sys
try:
    e = json.load(open(sys.argv[1]))["end"]
    if "sum_received" in e:
        print("mbit=%.1f" % (e["sum_received"]["bits_per_second"] / 1e6))
    else:
        s = e["sum"]
        print("mbit=%.1f;loss_pct=%.3f;jitter_ms=%.3f" % (
            s["bits_per_second"] / 1e6, s.get("lost_percent", 0), s.get("jitter_ms", 0)))
except Exception:
    print("parse_error")
PY
}

parse_netperf() {
	tail -n 1 "$1" | awk -F, '{ printf "tps=%s;mean_lat_us=%s;min_lat_us=%s;max_lat_us=%s;stddev_us=%s\n", $1, $2, $3, $4, $5 }'
}

parse_none() {
	echo "-"
}

# ---- one measured run -----------------------------------------------

# measure WORKLOAD PARAM RUN PARSER COMMAND...
measure() {
	local workload=$1 param=$2 run=$3 parser=$4
	shift 4
	local raw="$OUT/${workload}_${param}_run${run}.txt"
	local b0 t0 b1 t1 i0 i1 s0 s1 ts0 ts1 rc rates result status

	read -r b0 t0 < <(cpu_times)
	i0=$(irq_total)
	s0=$(softirq_net_rx)
	ts0=$(date +%s.%N)

	"$@" > "$raw" 2>&1
	rc=$?

	ts1=$(date +%s.%N)
	read -r b1 t1 < <(cpu_times)
	i1=$(irq_total)
	s1=$(softirq_net_rx)

	rates=$(awk -v ts0="$ts0" -v ts1="$ts1" -v i0="$i0" -v i1="$i1" \
		-v s0="$s0" -v s1="$s1" -v b0="$b0" -v b1="$b1" -v t0="$t0" -v t1="$t1" \
		'BEGIN { dt = ts1 - ts0; dtt = t1 - t0;
			printf "%.2f,%.1f,%.1f,%.1f", dt, (i1 - i0) / dt, (s1 - s0) / dt, (dtt > 0 ? 100 * (b1 - b0) / dtt : 0) }')

	if [ "$rc" -eq 0 ]; then
		status=ok
		result=$("$parser" "$raw")
	else
		status="fail($rc)"
		result="-"
	fi
	echo "$LABEL,$workload,$param,$run,$rates,$status,$result" | tee -a "$CSV"

	# let the servers on the peer and the NIC settle before the next run
	sleep 2
}

# ---- setup snapshot -------------------------------------------------

# A wrong interrupt number would give a silent 0, so fail early instead.
if [ -z "$(irq_total)" ]; then
	echo "interrupt $IRQ not found in $INTERRUPTS_FILE; find it with: grep $DEV /proc/interrupts" >&2
	exit 1
fi
if ! grep -E "^ *$IRQ:" "$INTERRUPTS_FILE" | grep -qw "$DEV"; then
	echo "warning: interrupt $IRQ is not named $DEV in $INTERRUPTS_FILE; check the row below" >&2
	grep -E "^ *$IRQ:" "$INTERRUPTS_FILE" >&2
fi

{
	echo "date: $(date -Is)"
	echo "label: $LABEL"
	echo "peer: ${PEER:-none}"
	echo "dev: $DEV  irq: $IRQ  secs: $SECS  runs: $RUNS"
	echo "kernel: $(uname -r)"
	echo "r8169 srcversion: $(cat /sys/module/r8169/srcversion 2>/dev/null || echo unknown)"
	echo "cpus: $(nproc)"
	echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
	echo "iperf3: $(iperf3 --version 2>/dev/null | head -n 1)"
	echo "netperf: $(netperf -V 2>/dev/null | head -n 1)"
	echo
	echo "--- ethtool -i"
	ethtool -i "$DEV" 2>&1
	echo "--- link"
	ethtool "$DEV" 2>&1 | grep -E 'Speed|Duplex|Link detected'
	echo "--- ethtool -c"
	ethtool -c "$DEV" 2>&1
	echo "--- /proc/interrupts row"
	grep -E "^ *$IRQ:" "$INTERRUPTS_FILE"
	echo "--- registers"
	"$(dirname "$0")/read_intrmit.sh" "$DEV" 2>&1 || true
} > "$OUT/meta_$(date +%Y%m%d_%H%M%S).txt"

if [ "$need_peer" = 1 ]; then
	if ! iperf3 -c "$PEER" -t 1 -R > /dev/null 2>&1; then
		echo "cannot reach iperf3 on $PEER (is 'iperf3 -s' running there?)" >&2
		exit 1
	fi
fi

# ---- workloads ------------------------------------------------------

for w in $WORKLOADS; do
	for run in $(seq 1 "$RUNS"); do
		case $w in
		idle)
			measure idle - "$run" parse_none sleep "$SECS"
			;;
		rr)
			measure rr 64B "$run" parse_netperf \
				netperf -H "$PEER" -t TCP_RR -l "$SECS" -P 0 -- -r 64,64 \
				-o THROUGHPUT,MEAN_LATENCY,MIN_LATENCY,MAX_LATENCY,STDDEV_LATENCY
			;;
		tcp)
			measure tcp bulk "$run" parse_iperf iperf3 -c "$PEER" -R -t "$SECS" -J
			;;
		udp)
			for rate in $UDP_RATES; do
				measure udp "$rate" "$run" parse_iperf iperf3 -c "$PEER" -R -u -b "$rate" -t "$SECS" -J
			done
			;;
		esac
	done
done
