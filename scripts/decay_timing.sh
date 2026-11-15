#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Time from the last received packet to the RX timer field returning to 0
# (idle decay of adaptive RX moderation). The register is sampled together
# with the interface's rx_packets counter, so a stray packet that restarts
# the idle window shows up as a later "last packet" instead of as a slow
# decay. Run as root from the repository root with the patched module loaded.
#
# usage: decay_timing.sh DEV
#
# Needs PEER=<address of the machine running iperf3 -s>. Writes the samples
# to /tmp/decay_timing.csv (time, rx_packets, rx_timer field). One register
# read takes about 0.1 s, which is the resolution of the result.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
dev=${1:-}
sys_net=${SYS_NET:-/sys/class/net}
csv=/tmp/decay_timing.csv

[ -n "$dev" ] || { sed -n '/^# usage:/,/^# read takes/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ -n "${PEER:-}" ] || { echo "export PEER=<peer address> first" >&2; exit 2; }

sample() {
	local t pk f

	t=$(date +%s.%N)
	pk=$(cat "$sys_net/$dev/statistics/rx_packets")
	f=$(bash "$here/read_intrmit.sh" "$dev" | sed -n 's/.*rx_timer=\([0-9]*\).*/\1/p')
	echo "$t,$pk,$f" >>"$csv"
}

if ! err=$(ethtool -C "$dev" adaptive-rx on 2>&1); then
	echo "FAIL: ethtool refused adaptive-rx on: $err" >&2
	exit 1
fi
iperf3 -c "$PEER" -t 1 >/dev/null 2>&1 || sleep 3

echo "t,rx_packets,rx_timer" >"$csv"
iperf3 -c "$PEER" -R -u -b 600M -t 10 >/tmp/decay_load.log 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
	sample
done
wait "$pid" || { echo "WARNING: the load failed:" >&2; tail -n 3 /tmp/decay_load.log >&2; }
end=$(($(date +%s) + 4))
while [ "$(date +%s)" -lt "$end" ]; do
	sample
done

awk -F, '
NR == 1 { next }
{
	if (seen && $2 != prev)
		last = $1
	if ($3 > 0) {
		up = 1
		zero = 0
	} else if (!zero) {
		zero = $1
	}
	prev = $2
	seen = 1
}
END {
	if (!up) {
		print "FAIL: the level never rose above 0"
		exit 1
	}
	if (!zero) {
		print "FAIL: the level was still above 0 at the end of the samples"
		exit 1
	}
	printf "last packet to level 0: %.2f s (expected about 0.4 s or less, resolution about 0.1 s)\n", zero - last
}' "$csv"
