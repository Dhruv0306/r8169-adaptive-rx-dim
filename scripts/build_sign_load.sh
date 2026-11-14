#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the r8169 module in the kernel tree, sign a copy with the tree's
# key and swap it in. Run as root at the console: the NIC is the only
# network connection and goes down for a moment.
#
# usage: build_sign_load.sh [KERNEL_TREE]    (default /usr/src/linux-7.2.15)
#
# Way back to the stock module:  rmmod r8169; modprobe r8169

set -eu

tree=${1:-/usr/src/linux-7.2.15}
ko=drivers/net/ethernet/realtek/r8169.ko
out=/root/r8169-new-signed.ko

cd "$tree"
make M=drivers/net/ethernet/realtek modules W=1 2>&1 | tee /root/r8169-build.log
if [ "$(modinfo -F vermagic "$ko" | cut -d' ' -f1)" != "$(uname -r)" ]; then
	echo "vermagic does not match $(uname -r), not loading" >&2
	exit 1
fi
cp "$ko" "$out"
scripts/sign-file sha512 certs/signing_key.pem certs/signing_key.x509 "$out"
rmmod r8169
insmod "$out"
echo "loaded $out, srcversion $(cat /sys/module/r8169/srcversion)"
