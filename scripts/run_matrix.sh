#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Interleaved measurement matrix for Phase 4 (plan: docs/plans/plan-4-measurement-and-tuning.md,
# section 3.4). Runs on the machine under test, as root, from the repository
# root, with the patched module loaded and the peer running
#     iperf3 -s
#     netserver
#
# The configurations are switched with ethtool, not by swapping modules, so
# they can be interleaved: each round visits every configuration once and runs
# every workload a few times, and the order is reversed on every second round
# so that drift in time (peer state, temperature, the other users of the
# network) does not line up with one configuration. All runs of one label
# end up in OUTDIR/LABEL/summary.csv with continuing run numbers.
#
# The stock module is not a configuration here (it needs a module swap): run
# it by hand with rx_bench.sh at the start and the end of the session, using
# the same OUTDIR, workloads and options. See the runbook in plan-4, section 9.
#
# usage: run_matrix.sh -p PEER -o OUTDIR [options]
#   -p PEER      address of the peer (iperf3 -s and netserver running)
#   -o OUTDIR    output directory, for example results/phase4/exploratory-1
#   -d DEV       network interface                    (default enp3s0)
#   -c CONFIGS   configurations to visit, in order    (default "off static-L2 adaptive")
#                  off          adaptive off, no static timer
#                  static-L<k>  adaptive off, rx-usecs = k-th value of -T
#                  adaptive     adaptive on, starting from level 0
#   -T TABLE     the non-zero levels of the module's table, in microseconds
#                (default "40 80 200 400"); must match the build under test
#   -w LIST      workloads for rx_bench.sh            (default "rr rrp tcp udp udps")
#   -u RATES     udp rates                            (default "300M 600M 900M")
#   -r RATES     udps rates                           (default "50M 100M 200M")
#   -s BYTES     udps datagram payload                (default 100)
#   -m USECS     udps iperf3 pacing timer             (default: iperf3's own)
#   -P N         rrp instances                        (default 8)
#   -t SECS      seconds per run                      (default 20)
#   -R ROUNDS    rounds                               (default 4)
#   -V RUNS      runs per cell and visit              (default 3)
#   -g GOV       set this CPU governor for the session and restore it at the end
#   -n           print the plan and the time estimate, run nothing
#
# Runs per cell and label = ROUNDS * RUNS (default 12). Examples:
#   exploratory (about 5 runs): -R 2 -V 3 -c "off static-L2 static-L4 adaptive"
#   final (10 or more runs):    -R 4 -V 3 -c "off static-L2 static-L4 adaptive"
#   one tuning round:           -R 2 -V 3 -c "off adaptive" -w "rrp udp udps"

set -u

DEV=enp3s0
PEER=""
OUTDIR=""
CONFIGS="off static-L2 adaptive"
TABLE="40 80 200 400"
WORKLOADS="rr rrp tcp udp udps"
UDP_RATES="300M 600M 900M"
UDPS_RATES="50M 100M 200M"
UDPS_LEN=100
UDPS_PACING=""
PARALLEL=8
SECS=20
ROUNDS=4
VISIT_RUNS=3
GOVERNOR=""
DRY=0

usage() {
	sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "p:o:d:c:T:w:u:r:s:m:P:t:R:V:g:nh" opt; do
	case $opt in
	p) PEER=$OPTARG ;;
	o) OUTDIR=$OPTARG ;;
	d) DEV=$OPTARG ;;
	c) CONFIGS=$OPTARG ;;
	T) TABLE=$OPTARG ;;
	w) WORKLOADS=$OPTARG ;;
	u) UDP_RATES=$OPTARG ;;
	r) UDPS_RATES=$OPTARG ;;
	s) UDPS_LEN=$OPTARG ;;
	m) UDPS_PACING=$OPTARG ;;
	P) PARALLEL=$OPTARG ;;
	t) SECS=$OPTARG ;;
	R) ROUNDS=$OPTARG ;;
	V) VISIT_RUNS=$OPTARG ;;
	g) GOVERNOR=$OPTARG ;;
	n) DRY=1 ;;
	*) usage ;;
	esac
done

[ -n "$PEER" ] && [ -n "$OUTDIR" ] || usage

here=$(dirname "$0")
read -ra TAB <<< "$TABLE"
read -ra CFG <<< "$CONFIGS"

# ---- configurations -------------------------------------------------

# static_us NAME: rx-usecs of a static-L<k> configuration, or fail
static_us() {
	local k=${1#static-L}
	[[ $k =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "${#TAB[@]}" ] || return 1
	echo "${TAB[k - 1]}"
}

for c in "${CFG[@]}"; do
	case $c in
	off | adaptive) ;;
	static-L*) static_us "$c" > /dev/null || { echo "$c: no such level in -T \"$TABLE\"" >&2; exit 2; } ;;
	*) echo "unknown configuration: $c" >&2; exit 2 ;;
	esac
done

# apply_config NAME: leave the device in the named configuration. The order
# matters: turning adaptive mode off restores the static settings saved when
# it was turned on, and ethtool -C merges with the current settings.
apply_config() {
	local us
	ethtool -C "$DEV" adaptive-rx off || return 1
	case $1 in
	off) ethtool -C "$DEV" rx-usecs 0 || return 1 ;;
	static-L*)
		us=$(static_us "$1") || return 1
		ethtool -C "$DEV" rx-usecs 0 || return 1
		ethtool -C "$DEV" rx-usecs "$us" || return 1
		;;
	adaptive)
		ethtool -C "$DEV" rx-usecs 0 || return 1
		ethtool -C "$DEV" adaptive-rx on || return 1
		;;
	esac
}

# verify_config NAME: read the configuration back; prints what was read
verify_config() {
	local out ad us fr want
	out=$(ethtool -c "$DEV") || return 1
	ad=$(awk '/^Adaptive RX:/ { print $3 }' <<< "$out")
	us=$(awk '/^rx-usecs:/ { print $2 }' <<< "$out")
	fr=$(awk '/^rx-frames:/ { print $2 }' <<< "$out")
	echo "adaptive=$ad rx-usecs=$us rx-frames=$fr"
	case $1 in
	off) [ "$ad" = off ] && [ "$us" = 0 ] ;;
	adaptive) [ "$ad" = on ] ;;
	static-L*)
		want=$(static_us "$1")
		# the hardware unit rounds the value; accept 25% or 5 us
		[ "$ad" = off ] && awk -v u="$us" -v w="$want" \
			'BEGIN { d = u - w; if (d < 0) d = -d; t = w * 0.25; if (t < 5) t = 5; exit !(d <= t) }'
		;;
	esac
}

# ---- plan and time estimate -----------------------------------------

count_words() { set -- $1; echo $#; }

cells=0
for w in $WORKLOADS; do
	case $w in
	udp) cells=$((cells + $(count_words "$UDP_RATES"))) ;;
	udps) cells=$((cells + $(count_words "$UDPS_RATES"))) ;;
	idle | rr | rrp | tcp) cells=$((cells + 1)) ;;
	*) echo "unknown workload: $w" >&2; exit 2 ;;
	esac
done
runs_per_cell=$((ROUNDS * VISIT_RUNS))
# every run takes SECS plus the 2 s settle time of rx_bench.sh
est=$(awk -v r="$ROUNDS" -v c="${#CFG[@]}" -v n="$cells" -v v="$VISIT_RUNS" -v s="$SECS" \
	'BEGIN { printf "%.0f", r * c * n * v * (s + 2.2) / 60 }')

cat << EOF
configurations: ${CFG[*]}  (table: $TABLE)
workloads: $WORKLOADS  ($cells cells)
rounds: $ROUNDS  runs per cell and visit: $VISIT_RUNS  runs per cell and label: $runs_per_cell
seconds per run: $SECS
estimated time: about $est minutes
EOF
[ "$DRY" = 1 ] && exit 0

# ---- preconditions --------------------------------------------------

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for tool in ethtool iperf3 netperf python3; do
	command -v "$tool" > /dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -x "$here/rx_bench.sh" ] || { echo "$here/rx_bench.sh not found" >&2; exit 1; }

wait_peer() {
	local i
	for i in $(seq 1 "${1:-120}"); do
		if timeout 2 bash -c "exec 3<>/dev/tcp/$PEER/5201" 2> /dev/null; then
			return 0
		fi
		sleep 1
	done
	return 1
}

mkdir -p "$OUTDIR"
LOG="$OUTDIR/matrix.log"
WARN="$OUTDIR/warnings.txt"

log() { echo "$(date -Is) $*" | tee -a "$LOG"; }

wait_peer 120 || { echo "peer $PEER does not answer on 5201 (iperf3 -s running? link up for 40 s?)" >&2; exit 1; }

# the adaptive configuration must be accepted, which the stock module does not do
for c in "${CFG[@]}"; do
	if [ "$c" = adaptive ] && ! apply_config adaptive; then
		echo "adaptive-rx is refused: is the patched module loaded? srcversion $(cat /sys/module/r8169/srcversion 2> /dev/null)" >&2
		ethtool -C "$DEV" adaptive-rx off 2> /dev/null
		exit 1
	fi
done

# ---- governor and cleanup -------------------------------------------

GOV_SAVE="$OUTDIR/governor.saved"
: > "$GOV_SAVE"
if [ -n "$GOVERNOR" ]; then
	for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
		[ -w "$f" ] || continue
		echo "$f $(cat "$f")" >> "$GOV_SAVE"
		echo "$GOVERNOR" > "$f"
	done
	log "governor set to $GOVERNOR on $(wc -l < "$GOV_SAVE") CPUs"
fi

cleanup() {
	local f g
	ethtool -C "$DEV" adaptive-rx off > /dev/null 2>&1
	ethtool -C "$DEV" rx-usecs 0 > /dev/null 2>&1
	while read -r f g; do
		[ -n "$f" ] && echo "$g" > "$f"
	done < "$GOV_SAVE"
	log "stopped; the device is back to adaptive off, rx-usecs 0"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

{
	echo "date: $(date -Is)"
	echo "command: $0 $*"
	echo "kernel: $(uname -r)"
	echo "r8169 srcversion: $(cat /sys/module/r8169/srcversion 2> /dev/null || echo unknown)"
	echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2> /dev/null || echo unknown)"
	echo "configurations: ${CFG[*]}  table: $TABLE"
	echo "workloads: $WORKLOADS  udp: $UDP_RATES  udps: ${UDPS_LEN}B at $UDPS_RATES, pacing ${UDPS_PACING:-default}  rrp: $PARALLEL"
	echo "rounds: $ROUNDS  runs per visit: $VISIT_RUNS  secs: $SECS"
} > "$OUTDIR/session_$(date +%Y%m%d_%H%M%S).txt"

# ---- the matrix -----------------------------------------------------

for round in $(seq 1 "$ROUNDS"); do
	order=("${CFG[@]}")
	if [ $((round % 2)) -eq 0 ]; then
		order=()
		for ((i = ${#CFG[@]} - 1; i >= 0; i--)); do order+=("${CFG[i]}"); done
	fi
	offset=$(((round - 1) * VISIT_RUNS))

	for c in "${order[@]}"; do
		log "round $round/$ROUNDS: configuration $c (runs $((offset + 1)) to $((offset + VISIT_RUNS)))"
		if ! apply_config "$c"; then
			log "cannot apply $c, skipping this visit"
			echo "round $round $c: not applied" >> "$WARN"
			continue
		fi
		if ! got=$(verify_config "$c"); then
			log "after applying $c the device reads: $got; skipping this visit"
			echo "round $round $c: reads $got" >> "$WARN"
			continue
		fi
		log "$c applied: $got"
		wait_peer 120 || { log "peer lost before $c"; echo "round $round $c: peer lost" >> "$WARN"; continue; }
		sleep 2

		"$here/rx_bench.sh" -l "$c" -p "$PEER" -d "$DEV" -o "$OUTDIR" -n "$VISIT_RUNS" -O "$offset" \
			-t "$SECS" -w "$WORKLOADS" -u "$UDP_RATES" -r "$UDPS_RATES" -s "$UDPS_LEN" -m "$UDPS_PACING" -P "$PARALLEL" \
			2>&1 | tee -a "$LOG"

		# the device must still be in the configuration after the visit
		if ! got=$(verify_config "$c"); then
			log "WARNING: after the visit $c reads: $got (reset or link change during the runs?)"
			echo "round $round $c: changed during the visit, reads $got" >> "$WARN"
		fi
	done
done

log "matrix finished"
if [ -s "$WARN" ]; then
	echo "warnings (visits that may be invalid) in $WARN:" >&2
	cat "$WARN" >&2
fi
