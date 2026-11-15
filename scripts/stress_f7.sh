#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Phase 3 stress test F7 for adaptive RX moderation: traffic runs while
# adaptive mode is toggled every 100 ms and the link is taken down and up,
# then the module is reloaded several times. Run as root at the console, from
# the repository root. The NIC is the only network connection and goes down
# on purpose, so keep a phone tether ready.
#
# usage: stress_f7.sh DEV MINUTES [RELOADS [MODULE.ko]]
#
#   MINUTES   how long the bounce phase runs; one bounce cycle takes about a
#             minute, see below
#   RELOADS   module reloads after the bounce phase (default 20, 0 to skip);
#             a reload takes about a minute too
#   MODULE.ko signed module to load (default /root/r8169-new-signed.ko)
#
# Needs PEER=<address of the machine running iperf3 -s and netserver>. The
# environment variable F7_DWELL (default 12) is the number of seconds of
# traffic before every bounce or reload.
#
# Why a bounce cycle takes about a minute: on this network the switch port
# forwards nothing for about 30 s after every link-up (bounce_rx_check.sh
# measured 35 s from the bounce to a working TCP connection, the same on
# every run), so no traffic can flow between bounces 10 s apart and no bounce
# would find the RX level above 0. The script leaves NetworkManager in
# charge, waits after every bounce and every reload until the peer answers
# again, lets the traffic run for the dwell time and only then bounces again.
# The plan's "every 10 s" is therefore replaced by "after every recovery".
#
# Every second bounce stops the 100 ms toggling for a moment first, so that
# DIM can climb to a level: with the mode flipping that often it never does,
# and the bounce would not find the decay work armed. The bounces in between
# happen while the toggling runs, to race the ethtool path against the
# teardown. The PC has no network for about 35 s after every bounce and
# reload, which is expected.
#
# The script ends with the traffic that ran, how many bounces and reloads
# found the RX level above 0, how long the network took to come back, the
# registers and the kernel messages that appeared while it ran; look for
# lockdep, WARNING, BUG and Oops.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
dev=${1:-}
minutes=${2:-}
reloads=${3:-20}
ko=${4:-/root/r8169-new-signed.ko}
dwell=${F7_DWELL:-12}

[ -n "$dev" ] && [ -n "$minutes" ] ||
	{ sed -n '/^# usage:/,/^# lockdep, WARNING/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ -n "${PEER:-}" ] || { echo "export PEER=<peer address> first" >&2; exit 2; }

log=/root/stress_f7.log
m=$(date +%s)
pids=""

cleanup() {
	# shellcheck disable=SC2086
	[ -z "$pids" ] || kill $pids 2>/dev/null || true
	pkill -x iperf3 2>/dev/null || true
	pkill -x netperf 2>/dev/null || true
	# An interrupted run can stop between a link down and the next up, or
	# between rmmod and insmod: leave a module loaded and the link up.
	[ -d /sys/module/r8169 ] || insmod "$ko" 2>/dev/null || true
	ip link set "$dev" up 2>/dev/null || true
	rm -f /tmp/f7_pause
}
trap cleanup EXIT

# The RX timer field now; above 0 means DIM has a level and the decay work is armed.
level_now() {
	bash "$here/read_intrmit.sh" "$dev" 2>/dev/null | sed -n 's/.*rx_timer=\([0-9]*\).*/\1/p'
}

# Wait up to $1 seconds for the RX level to rise above 0, which needs traffic.
# After a bounce the peer's iperf3 server can stay busy with the cut test for
# a while, so the loads sometimes start again late. Returns 1 if it never rose.
wait_level_up() {
	local i=0 limit=$(($1 * 2)) l

	while [ "$i" -lt "$limit" ]; do
		l=$(level_now || true)
		[ "${l:-0}" -gt 0 ] && return 0
		sleep 0.5
		i=$((i + 1))
	done
	return 1
}

# A TCP connection to the iperf3 port of the peer works.
peer_up() {
	timeout 2 bash -c "exec 3<>/dev/tcp/$PEER/5201" 2>/dev/null
}

# Wait until the peer answers, at most $1 seconds. Sets peer_wait to the
# seconds it took; returns 1 when it never answered.
peer_wait=0
wait_peer() {
	local t0 now

	t0=$(date +%s)
	while :; do
		if peer_up; then
			peer_wait=$(($(date +%s) - t0))
			return 0
		fi
		now=$(date +%s)
		if [ $((now - t0)) -ge "$1" ]; then
			peer_wait=$((now - t0))
			return 1
		fi
		sleep 1
	done
}

bounces=0
bounces_up=0
quiet_bounces=0
quiet_up=0
reload_up=0
back_n=0
back_sum=0
back_min=99999
back_max=0
not_back=0

# Remember how long the network took to come back.
record_back() {
	back_n=$((back_n + 1))
	back_sum=$((back_sum + peer_wait))
	[ "$peer_wait" -lt "$back_min" ] && back_min=$peer_wait
	[ "$peer_wait" -gt "$back_max" ] && back_max=$peer_wait
	return 0
}

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
if ! err=$(iperf3 -c "$PEER" -t 1 2>&1); then
	echo "FAIL: iperf3 cannot use $PEER, the error was:" >&2
	echo "  $(echo "$err" | tail -n 1)" >&2
	echo "On the peer: pkill iperf3; iperf3 -s   (a server still busy with an abandoned test refuses every client)" >&2
	exit 1
fi

# Loads that restart themselves. The rounds are 2 s and are killed after 8 s,
# so that a round stuck in the outage after a bounce does not hold the load
# back; every round is counted, because a stress test with no traffic proves
# nothing.
: >/tmp/f7_udp.log
: >/tmp/f7_rr.log
(while :; do
	if timeout 8 iperf3 -c "$PEER" -R -u -b 300M -t 2 >/dev/null 2>&1; then
		echo ok >>/tmp/f7_udp.log
	else
		echo fail >>/tmp/f7_udp.log
		sleep 1
	fi
done) &
pids="$pids $!"
(while :; do
	if out=$(timeout 8 netperf -H "$PEER" -t TCP_RR -l 2 -P 0 -- -r 64,64 2>/dev/null); then
		echo "ok $(echo "$out" | head -n 1 | awk '{print $NF}')" >>/tmp/f7_rr.log
	else
		echo fail >>/tmp/f7_rr.log
		sleep 1
	fi
done) &
pids="$pids $!"

# Toggle adaptive mode every 100 ms (see the header for the pause file).
rm -f /tmp/f7_pause
(while :; do
	if [ -e /tmp/f7_pause ]; then
		sleep 0.1
		continue
	fi
	ethtool -C "$dev" adaptive-rx off >/dev/null 2>&1 || true
	sleep 0.1
	ethtool -C "$dev" adaptive-rx on >/dev/null 2>&1 || true
	sleep 0.1
done) &
toggler=$!
pids="$pids $toggler"

echo "bounce phase: $minutes min, then $reloads reloads; one cycle takes about a minute"
end=$(($(date +%s) + minutes * 60))
round=0
while [ "$(date +%s)" -lt "$end" ]; do
	sleep "$dwell"
	round=$((round + 1))
	quiet=0
	if [ $((round % 2)) = 0 ]; then
		quiet=1
		touch /tmp/f7_pause
		sleep 0.3
		ethtool -C "$dev" adaptive-rx on >/dev/null 2>&1 || true
		sleep 1.5
		wait_level_up 20 || true
	fi
	lvl=$(level_now || true)
	if [ "$quiet" = 1 ]; then
		quiet_bounces=$((quiet_bounces + 1))
		[ "${lvl:-0}" -gt 0 ] && quiet_up=$((quiet_up + 1))
	else
		bounces=$((bounces + 1))
		[ "${lvl:-0}" -gt 0 ] && bounces_up=$((bounces_up + 1))
	fi
	ip link set "$dev" down
	sleep 1
	ip link set "$dev" up
	rm -f /tmp/f7_pause
	if wait_peer 150; then
		record_back
		echo "round $round: bounced at $(date +%T) (level $lvl, toggling paused: $quiet), network back after $peer_wait s"
	else
		not_back=$((not_back + 1))
		echo "round $round: bounced at $(date +%T), network NOT back after $peer_wait s"
	fi
done

kill "$toggler" 2>/dev/null || true
wait "$toggler" 2>/dev/null || true
sleep 1
ethtool -C "$dev" adaptive-rx on
sleep "$dwell"
echo "== state after the bounce phase"
check_state
bash "$here/read_intrmit.sh" "$dev"

i=0
while [ "$i" -lt "$reloads" ]; do
	i=$((i + 1))
	wait_level_up 30 || true
	lvl=$(level_now || true)
	if [ "${lvl:-0}" -gt 0 ]; then
		reload_up=$((reload_up + 1))
	fi
	rmmod r8169
	insmod "$ko"
	sleep 2
	ethtool -C "$dev" adaptive-rx on || true
	if wait_peer 150; then
		record_back
	else
		not_back=$((not_back + 1))
		echo "reload $i: network NOT back after $peer_wait s"
	fi
	sleep "$dwell"
	echo "reload $i: srcversion $(cat /sys/module/r8169/srcversion), level before the reload $lvl, network back after $peer_wait s"
	check_state
done

cleanup
pids=""
echo "== traffic that ran during the test"
echo "UDP rounds (2 s each; rounds during the outage after a bounce count as failed): ok $(grep -c '^ok' /tmp/f7_udp.log || true), failed $(grep -c '^fail' /tmp/f7_udp.log || true)"
echo "TCP_RR rounds: ok $(grep -c '^ok' /tmp/f7_rr.log || true), failed $(grep -c '^fail' /tmp/f7_rr.log || true), last transaction rate: $(grep '^ok' /tmp/f7_rr.log | tail -n 1 | cut -d' ' -f2)"
echo "== teardown with DIM active"
echo "link bounces with the toggling paused and the RX level above 0 (teardown with the decay work armed): $quiet_up of $quiet_bounces"
echo "link bounces during the toggling with the RX level above 0: $bounces_up of $bounces"
echo "module reloads with the RX level above 0: $reload_up of $i"
if [ "$back_n" -gt 0 ]; then
	echo "network back after a bounce or reload: $back_n times, min $back_min s, average $((back_sum / back_n)) s, max $back_max s; never back within 150 s: $not_back times"
else
	echo "the network never came back within 150 s ($not_back times)"
fi
ethtool -C "$dev" adaptive-rx off || true
echo "== state log in $log, last lines:"
tail -n 3 "$log"
log_k=$(journalctl -k --since "@$m" --no-pager 2>/dev/null || dmesg)
echo "--- kernel log since the start: $(echo "$log_k" | grep -ciE 'link is (up|down)' || true) link up/down lines ---"
found=$(echo "$log_k" |
	grep -iE 'lockdep|WARNING:|BUG:|Oops|possible circular|possible recursive' || true)
[ -n "$found" ] && echo "$found" || echo "(no lockdep, WARNING, BUG or Oops)"
