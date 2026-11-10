#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Show the r8169 interrupt moderation state as the hardware holds it:
# CPlusCmd (offset 0xe0) and IntrMitigate (offset 0xe2), read from the
# register dump. Needs root for "ethtool -d".
#
# usage: read_intrmit.sh DEV
#        read_intrmit.sh -f regdump.bin     (decode a saved raw dump)
#
# Save a dump with:  ethtool -d DEV raw on > regdump.bin

set -eu

usage() {
	echo "usage: $0 DEV | $0 -f regdump.bin" >&2
	exit 2
}

file=""
while getopts "f:" opt; do
	case $opt in
	f) file=$OPTARG ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))

if [ -n "$file" ]; then
	bytes=$(od -An -tu1 -j224 -N4 "$file")
else
	[ $# -eq 1 ] || usage
	bytes=$(ethtool -d "$1" raw on | od -An -tu1 -j224 -N4)
fi

# shellcheck disable=SC2086
set -- $bytes
if [ $# -ne 4 ]; then
	echo "could not read the registers" >&2
	exit 1
fi

cplus=$(($1 | ($2 << 8)))
intr=$(($3 | ($4 << 8)))

printf 'CPlusCmd     0x%04x  INTT=%d  PktCntrDisable=%d\n' \
	"$cplus" $((cplus & 3)) $(((cplus >> 7) & 1))
printf 'IntrMitigate 0x%04x  rx_timer=%d  rx_frames=%d (field %d)  tx_timer=%d  tx_frames=%d (field %d)\n' \
	"$intr" $(((intr >> 4) & 15)) $(((intr & 15) * 4)) $((intr & 15)) \
	$(((intr >> 12) & 15)) $((((intr >> 8) & 15) * 4)) $(((intr >> 8) & 15))
