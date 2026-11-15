#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Does the network come back after one link bounce under load, and when? One
# steady UDP load from the peer, then ip link set down, one second, ip link
# set up. Every second afterwards the script tries a TCP connection to the
# peer (bash /dev/tcp, port 5201), reads the rx_packets counter and the
# neighbour (ARP) entry of the peer, until both the TCP connection and the UDP
# stream work again or WAIT seconds (default 90) have passed. Run it on the stock
# module and on the patched one (adaptive on and off) to see whether a stall
# belongs to the driver or to the patches. Run as root at the console, from
# the repository root. The NIC is the only connection: NetworkManager is told
# to leave the device alone for the run (the icon disappears, no internet)
# and gets it back at the end.
#
# usage: [WAIT=90] bounce_rx_check.sh DEV [on|off|none]
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

echo "t_after_bounce,rx_packets,tcp_to_peer,neighbour_state" >"$csv"
echo "== after the bounce (a line every 5 s and whenever something changes)"
wait_s=${WAIT:-90}
tcp_ok=""
udp_ok=""
t0=$(date +%s.%N)
ip link set "$dev" down
sleep 1
ip link set "$dev" up
ip addr replace "$addr" dev "$dev"
prev=$(rx)
last_tcp=no
last_nb=""
n=0
end=$(($(date +%s) + wait_s))
while [ "$(date +%s)" -lt "$end" ]; do
	sleep 1
	n=$((n + 1))
	cur=$(rx)
	now=$(date +%s.%N)
	t=$(echo "$now - $t0" | bc)
	tcp=no
	if timeout 1 bash -c "exec 3<>/dev/tcp/$PEER/5201" 2>/dev/null; then
		tcp=yes
	fi
	nb=$(ip neigh show "$PEER" 2>/dev/null | awk '{print $NF}' | head -n 1)
	echo "$t,$cur,$tcp,$nb" >>"$csv"
	if [ "$tcp" = yes ] && [ -z "$tcp_ok" ]; then
		tcp_ok=$t
	fi
	if [ -z "$udp_ok" ] && [ $((cur - prev)) -gt 10000 ]; then
		udp_ok=$t
	fi
	if [ "$tcp" != "$last_tcp" ] || [ "$nb" != "$last_nb" ] || [ $((n % 5)) = 0 ]; then
		printf '%5.1f s  rx_packets +%-7s TCP to the peer: %-3s  neighbour entry: %s\n' \
			"$t" "$((cur - prev))" "$tcp" "${nb:-none}"
	fi
	last_tcp=$tcp
	last_nb=$nb
	prev=$cur
	if [ -n "$tcp_ok" ] && [ -n "$udp_ok" ]; then
		break
	fi
done
echo "== summary"
if [ -n "$tcp_ok" ]; then
	printf 'TCP to the peer works again %.1f s after the link went down\n' "$tcp_ok"
else
	echo "TCP to the peer did NOT work again within $wait_s s"
fi
if [ -n "$udp_ok" ]; then
	printf 'The UDP stream is back (more than 10000 packets per second) %.1f s after the link went down\n' "$udp_ok"
else
	echo "The UDP stream did not come back within $wait_s s (the peer may have ended the test)"
fi
echo "== interface counters (RX: bytes packets errors dropped missed mcast)"
ip -s link show "$dev" | sed -n '/RX:/{n;p}'
echo "== kernel log (r8169, lockdep, WARNING, BUG, Oops) since 3 minutes ago"
journalctl -k --since "-180s" --no-pager 2>/dev/null | grep -iE 'lockdep|WARNING:|BUG:|Oops|r8169' | tail -n 12 || true
