#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Phase 3 stress test F7 for adaptive RX moderation: traffic runs while
# adaptive mode is toggled every 100 ms and the link is taken down and up
# every 10 s, then the module is reloaded several times. Run as root at the
# console, from the repository root. The NIC is the only network connection
# and goes down on purpose, so keep a phone tether ready.
#
# usage: stress_f7.sh DEV MINUTES [RELOADS [MODULE.ko]]
#
#   MINUTES   how long the toggling runs (the plan asks for at least 30)
#   RELOADS   module reloads after the toggling (default 20, 0 to skip)
#   MODULE.ko signed module to load (default /root/r8169-new-signed.ko)
#
# Needs PEER=<address of the machine running iperf3 -s and netserver>.
# The script ends with the registers and the kernel messages that appeared
# while it ran; look for lockdep, WARNING, BUG and Oops.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
dev=${1:-}
minutes=${2:-}
reloads=${3:-20}
ko=${4:-/root/r8169-new-signed.ko}

[ -n "$dev" ] && [ -n "$minutes" ] ||
	{ sed -n '/^# usage:/,/^# while it ran/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ -n "${PEER:-}" ] || { echo "export PEER=<peer address> first" >&2; exit 2; }

log=/root/stress_f7.log
m=$(dmesg | wc -l)
pids=""

cleanup() {
	# shellcheck disable=SC2086
	[ -z "$pids" ] || kill $pids 2>/dev/null || true
	pkill -x iperf3 2>/dev/null || true
	pkill -x netperf 2>/dev/null || true
}
trap cleanup EXIT

# A state check: with adaptive mode on, PktCntrDisable must be set and the
# RX frame limit must be 0. Prints INCONSISTENT otherwise.
check_state() {
	local out flag

	out=$(bash "$here/read_intrmit.sh" "$dev")
	flag=$(ethtool -c "$dev" | sed -n 's/^Adaptive RX: *\([a-z]*\).*/\1/p')
	if [ "$flag" = on ]; then
		echo "$out" | grep -q 'PktCntrDisable=1' &&
			echo "$out" | grep -q 'rx_frames=0 ' ||
			{ echo "INCONSISTENT with adaptive on:"; echo "$out"; }
	fi
	echo "$(date +%T) adaptive=$flag $(echo "$out" | tr '\n' ' ')" >>"$log"
}

: >"$log"
ethtool -C "$dev" adaptive-rx on

# Loads that restart themselves when a link bounce kills them
(while :; do iperf3 -c "$PEER" -R -u -b 300M -t 30 >/dev/null 2>&1 || sleep 1; done) &
pids="$pids $!"
(while :; do netperf -H "$PEER" -t TCP_RR -l 30 -P 0 -- -r 64,64 >/dev/null 2>&1 || sleep 1; done) &
pids="$pids $!"

# Toggle adaptive mode every 100 ms
(while :; do
	ethtool -C "$dev" adaptive-rx off >/dev/null 2>&1 || true
	sleep 0.1
	ethtool -C "$dev" adaptive-rx on >/dev/null 2>&1 || true
	sleep 0.1
done) &
toggler=$!
pids="$pids $toggler"

end=$(($(date +%s) + minutes * 60))
round=0
while [ "$(date +%s)" -lt "$end" ]; do
	sleep 10
	round=$((round + 1))
	ip link set "$dev" down
	sleep 1
	ip link set "$dev" up
	echo "round $round: link bounced at $(date +%T)"
done

kill "$toggler" 2>/dev/null || true
wait "$toggler" 2>/dev/null || true
sleep 1
ethtool -C "$dev" adaptive-rx on
sleep 5
echo "== state after the toggling"
check_state
bash "$here/read_intrmit.sh" "$dev"

i=0
while [ "$i" -lt "$reloads" ]; do
	i=$((i + 1))
	rmmod r8169
	insmod "$ko"
	ip link set "$dev" up 2>/dev/null || true
	sleep 8
	ethtool -C "$dev" adaptive-rx on
	echo "reload $i: srcversion $(cat /sys/module/r8169/srcversion)"
	check_state
done

cleanup
pids=""
ethtool -C "$dev" adaptive-rx off || true
echo "== state log in $log, last lines:"
tail -n 3 "$log"
echo "--- dmesg since the start (r8169, lockdep, WARNING, BUG, Oops) ---"
found=$(dmesg | tail -n +"$((m + 1))" |
	grep -iE 'lockdep|WARNING:|BUG:|Oops|possible circular|possible recursive|r8169' || true)
[ -n "$found" ] && echo "$found" || echo "(nothing)"
