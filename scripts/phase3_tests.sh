#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Phase 3 checks for adaptive RX moderation (plan: docs/plans/plan-3-robustness.md).
# Run as root at the console, from the repository root, with the patched
# module loaded. The NIC is the only network connection and goes down for
# some tests, so do not run this over a network session into the machine.
#
# usage: phase3_tests.sh DEV TEST [ARG]
#
#   f4 [N]      N times (default 10): interface down, up, read the registers
#   f4b         run the reset task under load (needs the force_reset test hook);
#               samples the level and the packet counter for 5 s afterwards
#   f5          link speed change to 100 Mbit/s and back, under load
#               (F5_RATE, default 95M, and F5_LEN, default 64 byte payloads:
#               at 100 Mbit/s large packets are too few per second for DIM
#               to leave level 0, small ones are not)
#   f9          idle decay: time from the end of a UDP load to level 0
#   f10         sparse request-response traffic right after a burst
#   f11 [SECS]  concurrent ethtool changes while the load runs (default 60)
#
# Load tests need PEER=<address of the machine running iperf3 -s and
# netserver>. Every test prints the registers (scripts/read_intrmit.sh) and
# the kernel messages that appeared while it ran; look for lockdep, WARNING,
# BUG and Oops.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
dev=${1:-}
test_name=${2:-}
arg=${3:-}
f5_rate=${F5_RATE:-95M}
f5_len=${F5_LEN:-64}

usage() {
	sed -n '/^# usage:/,/^# BUG and Oops/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

[ -n "$dev" ] && [ -n "$test_name" ] || usage

regs() {
	bash "$here/read_intrmit.sh" "$dev"
}

timer_field() {
	regs | sed -n 's/.*rx_timer=\([0-9]*\).*/\1/p'
}

need_peer() {
	[ -n "${PEER:-}" ] || { echo "export PEER=<peer address> first" >&2; exit 2; }
}

# After a link change or a module reload the address and the neighbour entry
# need a few seconds to come back, and iperf3 then fails with "No route to
# host" and the test runs without traffic. Wait until the peer answers.
wait_peer() {
	local i

	for i in $(seq 1 30); do
		if iperf3 -c "$PEER" -t 1 >/dev/null 2>&1; then
			sleep 1
			return 0
		fi
		sleep 1
	done
	echo "FAIL: iperf3 cannot reach $PEER after 30 s (is iperf3 -s running, has the link an address?)" >&2
	return 1
}

# Start a reverse UDP load from the peer in the background; sets load_pid.
start_load() {
	need_peer
	wait_peer || exit 1
	iperf3 -c "$PEER" -R -u -b "$1" -t "$2" ${3:+-l "$3"} >/tmp/p3_load.log 2>&1 &
	load_pid=$!
}

# Wait for the load to end; say so if iperf3 failed (for example when the
# server on the peer is busy), because then nothing was tested.
end_load() {
	if ! wait "$load_pid"; then
		echo "WARNING: the load failed, this test did not run under traffic:" >&2
		tail -n 3 /tmp/p3_load.log >&2
	fi
}

# Wait until the RX timer field is above 0, at most $1 seconds.
wait_level_up() {
	local i=0 limit=$(($1 * 4))

	while [ "$i" -lt "$limit" ]; do
		[ "$(timer_field)" -gt 0 ] && return 0
		sleep 0.25
		i=$((i + 1))
	done
	return 1
}

# The start time, as seconds since the epoch. The kernel log is read by time
# and not by line count, because a full ring buffer makes line counts useless.
mark() {
	date +%s
}

# Print what the kernel logged since mark() returned $1: link messages are
# summarised, anything about lockdep, WARNING, BUG or Oops is shown.
report() {
	local log found links

	log=$(journalctl -k --since "@$1" --no-pager 2>/dev/null || dmesg)
	links=$(echo "$log" | grep -ciE 'link is (up|down)' || true)
	found=$(echo "$log" |
		grep -iE 'lockdep|WARNING:|BUG:|Oops|possible circular|possible recursive' || true)
	echo "--- kernel log since the start of the test: $links link up/down lines ---"
	if [ -n "$found" ]; then
		echo "$found"
	else
		echo "(no lockdep, WARNING, BUG or Oops)"
	fi
}

# Turn adaptive mode on, or stop with the likely cause: the stock r8169 has no
# adaptive-rx flag, which is what is loaded after a reboot.
adaptive_on() {
	local err

	if ! err=$(ethtool -C "$dev" adaptive-rx on 2>&1); then
		echo "FAIL: ethtool refused adaptive-rx on: $(echo "$err" | tr '\n' ' ')" >&2
		echo "The patched module is probably not loaded. Check" >&2
		echo "  cat /sys/module/r8169/srcversion" >&2
		echo "and run: bash scripts/build_sign_load.sh" >&2
		exit 1
	fi
}

case $test_name in
f4)
	n=${arg:-10}
	m=$(mark)
	adaptive_on
	for i in $(seq 1 "$n"); do
		ip link set "$dev" down
		sleep 1
		ip link set "$dev" up
		sleep 5
		echo "== round $i: $(ethtool -c "$dev" | grep 'Adaptive RX')"
		regs
	done
	report "$m"
	;;
f4b)
	[ -e /sys/kernel/debug/r8169_force_reset ] ||
		{ echo "no /sys/kernel/debug/r8169_force_reset: build with scripts/test-hooks/force_reset.patch" >&2; exit 1; }
	m=$(mark)
	echo 'module r8169 +p' >/sys/kernel/debug/dynamic_debug/control
	adaptive_on
	start_load 600M 30
	if wait_level_up 15; then
		echo "== before the reset (level above 0)"
		regs
		csv=/tmp/f4b_samples.csv
		echo "t_after_reset,rx_packets,rx_timer" >"$csv"
		t0=$(date +%s.%N)
		echo 1 >/sys/kernel/debug/r8169_force_reset
		end=$(($(date +%s) + 5))
		while [ "$(date +%s)" -lt "$end" ]; do
			now=$(date +%s.%N)
			printf '%.2f,%s,%s\n' "$(echo "$now - $t0" | bc)" \
				"$(cat "/sys/class/net/$dev/statistics/rx_packets")" "$(timer_field)" >>"$csv"
		done
		echo "== after the reset: time, rx_packets, RX timer field (every 0.1 s, in $csv)"
		cat "$csv"
	else
		echo "FAIL: the level never rose above 0, no reset done" >&2
	fi
	end_load
	echo "== kernel messages about the restore and the DIM levels (first 40)"
	journalctl -k --since "@$m" --no-pager | grep -E 'TEST restore|rx dim' | head -n 40 || true
	echo "== load report (per second, look at the second of the reset)"
	grep -E '^\[ +5\] +[0-9]' /tmp/p3_load.log | head -n 12
	report "$m"
	;;
f5)
	need_peer
	m=$(mark)
	adaptive_on
	echo "== at the start"
	ethtool "$dev" | grep -E 'Speed|Duplex'
	regs
	ethtool -s "$dev" advertise 0x008
	for i in $(seq 1 40); do
		ethtool "$dev" | grep -q 'Speed: 100Mb/s' && break
		sleep 0.5
	done
	sleep 3
	echo "== link at 100 Mbit/s, no load"
	ethtool "$dev" | grep -E 'Speed|Duplex'
	ethtool -c "$dev" | grep -E 'Adaptive RX|rx-usecs'
	regs
	start_load "$f5_rate" 10 "$f5_len"
	sleep 6
	echo "== 100 Mbit/s, $f5_rate UDP load with $f5_len byte payloads, level"
	ethtool -c "$dev" | grep -E 'rx-usecs'
	regs
	[ "$(timer_field)" -gt 0 ] ||
		echo "NOTE: the level stayed at 0 under this load, so the unit conversion was not exercised; try a higher rate"
	end_load
	ethtool -s "$dev" advertise 0x02f
	for i in $(seq 1 40); do
		ethtool "$dev" | grep -q 'Speed: 1000Mb/s' && break
		sleep 0.5
	done
	sleep 3
	echo "== back at 1000 Mbit/s"
	ethtool "$dev" | grep -E 'Speed|Duplex'
	ethtool -c "$dev" | grep -E 'Adaptive RX|rx-usecs'
	regs
	report "$m"
	;;
f9)
	m=$(mark)
	adaptive_on
	start_load 600M 15
	if ! wait_level_up 10; then
		echo "FAIL: the level never rose above 0, the decay was not tested" >&2
		end_load
		report "$m"
		exit 1
	fi
	echo "== under load"
	regs
	end_load
	t0=$(date +%s.%N)
	while [ "$(timer_field)" -gt 0 ]; do
		now=$(date +%s.%N)
		if [ "$(echo "$now - $t0 > 5" | bc)" -eq 1 ]; then
			echo "FAIL: level still above 0 five seconds after the load ended"
			regs
			report "$m"
			exit 1
		fi
		sleep 0.05
	done
	now=$(date +%s.%N)
	printf 'level 0 after %.2f s (expected within about 0.4 s plus one register read)\n' \
		"$(echo "$now - $t0" | bc)"
	regs
	report "$m"
	;;
f10)
	need_peer
	m=$(mark)
	adaptive_on
	start_load 600M 10
	end_load
	sleep 2
	echo "== level before the sparse traffic"
	regs
	netperf -H "$PEER" -t TCP_RR -l 5 -P 0 -- -r 64,64
	echo "(compare with the adaptive-guard TCP_RR figures: about 9500 transactions per second)"
	report "$m"
	;;
f11)
	secs=${arg:-60}
	m=$(mark)
	adaptive_on
	start_load 300M $((secs + 5))
	(
		end=$(($(date +%s) + secs))
		while [ "$(date +%s)" -lt "$end" ]; do
			ethtool -C "$dev" adaptive-rx on || true
			ethtool -C "$dev" adaptive-rx off || true
		done
	) &
	a=$!
	(
		end=$(($(date +%s) + secs))
		while [ "$(date +%s)" -lt "$end" ]; do
			ethtool -C "$dev" tx-usecs 20 || true
			ethtool -C "$dev" tx-usecs 0 || true
		done
	) &
	b=$!
	wait "$a" "$b" || true
	end_load
	echo "== after the toggling"
	ethtool -c "$dev" | grep -E 'Adaptive RX|tx-usecs|rx-usecs'
	regs
	ethtool -C "$dev" adaptive-rx on tx-usecs 20
	echo "== adaptive on, tx-usecs 20 (the TX timer reads 40: 20 us rounds up to one 40 us unit; PktCntrDisable must be 1)"
	ethtool -c "$dev" | grep -E 'Adaptive RX|tx-usecs'
	regs
	ethtool -C "$dev" adaptive-rx off tx-usecs 0
	report "$m"
	;;
*)
	usage
	;;
esac
