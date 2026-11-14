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
#   f4b         run the reset task under load (needs the force_reset test hook)
#   f5          link speed change to 100 Mbit/s and back, under load
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

# Start a reverse UDP load from the peer in the background; sets load_pid.
start_load() {
	need_peer
	iperf3 -c "$PEER" -R -u -b "$1" -t "$2" >/dev/null 2>&1 &
	load_pid=$!
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

mark() {
	dmesg | wc -l
}

# Print what the kernel logged since mark() returned $1.
report() {
	local found

	found=$(dmesg | tail -n +"$(($1 + 1))" |
		grep -iE 'lockdep|WARNING:|BUG:|Oops|possible circular|possible recursive|r8169' || true)
	echo "--- dmesg since the start of the test (r8169, lockdep, WARNING, BUG, Oops) ---"
	if [ -n "$found" ]; then
		echo "$found"
	else
		echo "(nothing)"
	fi
}

adaptive_on() {
	ethtool -C "$dev" adaptive-rx on
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
	adaptive_on
	start_load 600M 40
	if wait_level_up 15; then
		echo "== before the reset (level above 0)"
		regs
		echo 1 >/sys/kernel/debug/r8169_force_reset
		for d in 0.05 0.3 1.0; do
			sleep "$d"
			echo "== ${d}s after the reset"
			regs
		done
	else
		echo "the level never rose above 0, no reset done" >&2
	fi
	wait "$load_pid" || true
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
	start_load 80M 10
	sleep 6
	echo "== 100 Mbit/s, 80M UDP load, level"
	ethtool -c "$dev" | grep -E 'rx-usecs'
	regs
	wait "$load_pid" || true
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
	wait_level_up 10 || echo "the level never rose above 0" >&2
	echo "== under load"
	regs
	wait "$load_pid" || true
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
	wait "$load_pid" || true
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
	wait "$load_pid" || true
	echo "== after the toggling"
	ethtool -c "$dev" | grep -E 'Adaptive RX|tx-usecs|rx-usecs'
	regs
	ethtool -C "$dev" adaptive-rx on tx-usecs 20
	echo "== adaptive on, tx-usecs 20 (the TX timer must read 20, PktCntrDisable must be 1)"
	ethtool -c "$dev" | grep -E 'Adaptive RX|tx-usecs'
	regs
	ethtool -C "$dev" adaptive-rx off tx-usecs 0
	report "$m"
	;;
*)
	usage
	;;
esac
