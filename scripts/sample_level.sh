#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Print the r8169 RX interrupt timer a few times a second as CSV, so the
# DIM level can be plotted against time. Run as root. Stop with Ctrl-C.
#
# usage: sample_level.sh DEV [INTERVAL_SECONDS]   (default 0.2)
#
# Columns: time_s, rx_timer_field, rx_usecs (ethtool -c), irq_count.
# The level is read from the live register through "ethtool -c", so it
# works with or without dynamic debug.

set -eu

[ $# -ge 1 ] || { echo "usage: $0 DEV [INTERVAL]" >&2; exit 2; }
dev=$1
iv=${2:-0.2}
t0=$(date +%s.%N)

echo "time_s,rx_timer_field,rx_usecs,irq_count"
while true; do
	now=$(date +%s.%N)
	us=$(ethtool -c "$dev" | awk '/^rx-usecs:/ {print $2}')
	field=$(bash "$(dirname "$0")/read_intrmit.sh" "$dev" |
		sed -n 's/.*rx_timer=\([0-9]*\).*/\1/p')
	irq=$(awk -v d="$dev" '$0 ~ d {n=0; for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) n+=$i; print n; exit}' /proc/interrupts)
	printf '%.2f,%s,%s,%s\n' "$(echo "$now - $t0" | bc)" "$field" "$us" "${irq:-0}"
	sleep "$iv"
done
