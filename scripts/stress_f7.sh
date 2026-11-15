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
#
# NetworkManager takes the address away on every "ip link set down" and needs
# longer than the time between two bounces to give it back, so with it in
# charge no traffic runs at all. The script therefore tells NetworkManager to
# leave the device alone (nmcli dev set DEV managed no) and puts the address
# back itself after every bounce and every reload. The PC has no other
# connection during the run and no internet, which is expected; the script
# gives the device back to NetworkManager at the end.
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
m=$(date +%s)
pids=""
nm_off=0

cleanup() {
	# shellcheck disable=SC2086
	[ -z "$pids" ] || kill $pids 2>/dev/null || true
	pkill -x iperf3 2>/dev/null || true
	pkill -x netperf 2>/dev/null || true
	if [ "$nm_off" = 1 ]; then
		nmcli dev set "$dev" managed yes || true
		nm_off=0
	fi
}
trap cleanup EXIT

# Take the device away from NetworkManager and put its address back, as it was
# before the test, so that a bounce does not lose it.
own_address() {
	if command -v nmcli >/dev/null 2>&1; then
		nmcli dev set "$dev" managed no || true
		nm_off=1
	fi
	ip link set "$dev" up || true
	ip addr replace "$addr" dev "$dev" || true
}

addr=$(ip -4 -o addr show dev "$dev" | awk '{print $4; exit}')
[ -n "$addr" ] || { echo "FAIL: $dev has no IPv4 address, bring the network up first" >&2; exit 1; }
echo "keeping $addr on $dev across the bounces"

# The RX timer field now; above 0 means DIM has a level and the decay work is armed.
level_now() {
	bash "$here/read_intrmit.sh" "$dev" 2>/dev/null | sed -n 's/.*rx_timer=\([0-9]*\).*/\1/p'
}

bounces=0
bounces_up=0
reload_up=0

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
ethtool -C "$dev" adaptive-rx on || {
	echo "FAIL: adaptive-rx is refused, the patched module is probably not loaded." >&2
	echo "Check cat /sys/module/r8169/srcversion and run scripts/build_sign_load.sh" >&2
	exit 1
}
own_address
for i in $(seq 1 30); do
	iperf3 -c "$PEER" -t 1 >/dev/null 2>&1 && break
	sleep 1
done
iperf3 -c "$PEER" -t 1 >/dev/null 2>&1 || { echo "FAIL: iperf3 cannot reach $PEER with the address kept" >&2; exit 1; }

# Loads that restart themselves when a link bounce kills them. A bounce takes
# the address away for a few seconds, so a round that lasts 30 s never ends:
# the rounds are 2 s, and every round is counted, so that the end of the run
# shows how much traffic really ran. A stress test with no traffic proves
# nothing.
: >/tmp/f7_udp.log
: >/tmp/f7_rr.log
(while :; do
	if iperf3 -c "$PEER" -R -u -b 300M -t 2 >/dev/null 2>&1; then
		echo ok >>/tmp/f7_udp.log
	else
		echo fail >>/tmp/f7_udp.log
		sleep 1
	fi
done) &
pids="$pids $!"
(while :; do
	if out=$(netperf -H "$PEER" -t TCP_RR -l 2 -P 0 -- -r 64,64 2>/dev/null); then
		echo "ok $(echo "$out" | head -n 1 | awk '{print $NF}')" >>/tmp/f7_rr.log
	else
		echo fail >>/tmp/f7_rr.log
		sleep 1
	fi
done) &
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
	lvl=$(level_now || true)
	bounces=$((bounces + 1))
	if [ "${lvl:-0}" -gt 0 ]; then
		bounces_up=$((bounces_up + 1))
	fi
	ip link set "$dev" down
	sleep 1
	ip link set "$dev" up
	ip addr replace "$addr" dev "$dev"
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
	lvl=$(level_now || true)
	if [ "${lvl:-0}" -gt 0 ]; then
		reload_up=$((reload_up + 1))
	fi
	rmmod r8169
	insmod "$ko"
	sleep 2
	own_address
	sleep 8
	ethtool -C "$dev" adaptive-rx on
	echo "reload $i: srcversion $(cat /sys/module/r8169/srcversion)"
	check_state
done

cleanup
pids=""
echo "== traffic that ran during the test"
echo "UDP rounds (2 s each; a round cut by a link bounce or started while the address is missing counts as failed): ok $(grep -c '^ok' /tmp/f7_udp.log || true), failed $(grep -c '^fail' /tmp/f7_udp.log || true)"
echo "link bounces with the RX level above 0 (the teardown ran with the decay work armed): $bounces_up of $bounces"
echo "module reloads with the RX level above 0: $reload_up of $i"
echo "TCP_RR rounds: ok $(grep -c '^ok' /tmp/f7_rr.log || true), failed $(grep -c '^fail' /tmp/f7_rr.log || true), last transaction rate: $(grep '^ok' /tmp/f7_rr.log | tail -n 1 | cut -d' ' -f2)"
ethtool -C "$dev" adaptive-rx off || true
echo "== state log in $log, last lines:"
tail -n 3 "$log"
log_k=$(journalctl -k --since "@$m" --no-pager 2>/dev/null || dmesg)
echo "--- kernel log since the start: $(echo "$log_k" | grep -ciE 'link is (up|down)' || true) link up/down lines ---"
found=$(echo "$log_k" |
	grep -iE 'lockdep|WARNING:|BUG:|Oops|possible circular|possible recursive' || true)
[ -n "$found" ] && echo "$found" || echo "(no lockdep, WARNING, BUG or Oops)"
