#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Does RX come back after one link bounce under load? One steady UDP load
# from the peer, then ip link set down, one second, ip link set up, and the
# rx_packets counter is watched until it moves again. Run it on the stock
# module and on the patched one (adaptive on and off) to see whether a stall
# belongs to the driver or to the patches. Run as root at the console, from
# the repository root. The NIC is the only connection: NetworkManager is told
# to leave the device alone for the run (the icon disappears, no internet)
# and gets it back at the end.
#
# usage: bounce_rx_check.sh DEV [on|off|none]
#
#   on, off   set adaptive mode first (patched module only)
#   none      leave the adaptive mode alone (default, and the stock module)
#
# Needs PEER=<address of the machine running iperf3 -s>.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
dev=${1:-}
mode=${2:-none}
sys_net=${SYS_NET:-/sys/class/net}
csv=/tmp/bounce_rx.csv

[ -n "$dev" ] || { sed -n '/^# usage:/,/^# Needs PEER/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ -n "${PEER:-}" ] || { echo "export PEER=<peer address> first" >&2; exit 2; }

nm_off=0
cleanup() {
	pkill -x iperf3 2>/dev/null || true
	ip link set "$dev" up 2>/dev/null || true
	if [ "$nm_off" = 1 ]; then
		nmcli dev set "$dev" managed yes || true
		nm_off=0
	fi
}
trap cleanup EXIT

rx() {
	cat "$sys_net/$dev/statistics/rx_packets"
}

addr=$(ip -4 -o addr show dev "$dev" | awk '{print $4; exit}')
[ -n "$addr" ] || { echo "FAIL: $dev has no IPv4 address" >&2; exit 1; }

case $mode in
on | off)
	ethtool -C "$dev" adaptive-rx "$mode" || { echo "FAIL: adaptive-rx $mode refused (stock module? use none)" >&2; exit 1; }
	;;
none) ;;
*) echo "mode must be on, off or none" >&2; exit 2 ;;
esac
echo "module srcversion $(cat /sys/module/r8169/srcversion 2>/dev/null || echo unknown), adaptive mode: $mode"

if command -v nmcli >/dev/null 2>&1; then
	nmcli dev set "$dev" managed no || true
	nm_off=1
fi
ip link set "$dev" up || true
ip addr replace "$addr" dev "$dev" || true
for _ in $(seq 1 30); do
	iperf3 -c "$PEER" -t 1 >/dev/null 2>&1 && break
	sleep 1
done
iperf3 -c "$PEER" -t 1 >/dev/null 2>&1 || { echo "FAIL: iperf3 cannot reach $PEER" >&2; exit 1; }
sleep 2

iperf3 -c "$PEER" -R -u -b 300M -t 45 >/tmp/bounce_load.log 2>&1 &
sleep 5
p0=$(rx)
sleep 1
p1=$(rx)
echo "packets per second before the bounce: $((p1 - p0))"
if [ "$mode" != none ]; then
	bash "$here/read_intrmit.sh" "$dev" | sed -n 2p
fi
if [ $((p1 - p0)) -lt 5000 ]; then
	echo "FAIL: no load is arriving before the bounce, nothing was tested" >&2
	exit 1
fi

echo "t_after_bounce,rx_packets" >"$csv"
t0=$(date +%s.%N)
ip link set "$dev" down
sleep 1
ip link set "$dev" up
ip addr replace "$addr" dev "$dev"
recovered=""
prev=$(rx)
end=$(($(date +%s) + 30))
while [ "$(date +%s)" -lt "$end" ]; do
	sleep 0.5
	cur=$(rx)
	now=$(date +%s.%N)
	t=$(echo "$now - $t0" | bc)
	echo "$t,$cur" >>"$csv"
	if [ -z "$recovered" ] && [ $((cur - prev)) -gt 5000 ]; then
		recovered=$t
		printf 'RX is back %.1f s after the link went down (more than 10000 packets per second again)\n' "$t"
		break
	fi
	prev=$cur
done
[ -n "$recovered" ] || echo "RX did NOT come back within 30 s after the bounce"

echo "== TCP to the peer after the bounce:"
if timeout 10 iperf3 -c "$PEER" -t 1 >/dev/null 2>&1; then
	echo "works"
else
	echo "does not work (yet)"
fi
echo "== load report (tail)"
grep -E '^\[ +5\] +[0-9]' /tmp/bounce_load.log | tail -n 12
echo "== kernel log (r8169, lockdep, WARNING, BUG, Oops) since 60 s ago"
journalctl -k --since "-60s" --no-pager 2>/dev/null | grep -iE 'lockdep|WARNING:|BUG:|Oops|r8169' | tail -n 12 || true
