#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Check the patch series in patches/ against a pristine v7.2.15 (Phase 5).
# It takes the two files the series changes from a kernel git tree, applies
# every patch in order with "patch -p1" (a dry run first, as the plan says),
# and optionally runs checkpatch.pl --strict on each patch. Nothing in the
# kernel tree is changed. Run from the repository root, as a normal user.
#
# usage: check_series.sh -t KERNEL_GIT_TREE [options]
#   -t TREE   a kernel git tree that has the tag (for example the clean clone
#             ~/linux-r8169-clean); only "git show" is run in it
#   -b TAG    base tag                     (default v7.2.15)
#   -c        also run TREE/scripts/checkpatch.pl --strict --no-tree per patch
#   -p DIR    directory with the patches   (default patches)
#
# Expected result: every patch applies, and checkpatch reports only the
# "Non-standard signature: Co-authored-by" warning, the missing
# Signed-off-by (the patches in patches/ are not signed) and the CamelCase
# checks on register names the driver already uses.

set -eu

TREE=""
TAG=v7.2.15
CHECKPATCH=0
PDIR=patches
FILES="drivers/net/ethernet/realtek/r8169_main.c drivers/net/ethernet/realtek/Kconfig"

usage() {
	sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "t:b:cp:h" opt; do
	case $opt in
	t) TREE=$OPTARG ;;
	b) TAG=$OPTARG ;;
	c) CHECKPATCH=1 ;;
	p) PDIR=$OPTARG ;;
	*) usage ;;
	esac
done

[ -n "$TREE" ] || usage
git -C "$TREE" rev-parse -q --verify "$TAG^{commit}" > /dev/null ||
	{ echo "tag $TAG not found in $TREE" >&2; exit 1; }
ls "$PDIR"/0*.patch > /dev/null 2>&1 || { echo "no patches in $PDIR" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for f in $FILES; do
	mkdir -p "$work/$(dirname "$f")"
	git -C "$TREE" show "$TAG:$f" > "$work/$f"
done

pdir=$(cd "$PDIR" && pwd)
count=0
cd "$work"
for p in "$pdir"/0*.patch; do
	name=$(basename "$p")
	if ! patch -p1 --dry-run < "$p" > /dev/null; then
		echo "FAIL (dry run): $name" >&2
		exit 1
	fi
	patch -p1 -s < "$p"
	count=$((count + 1))
	echo "applies: $name"
done
echo "all $count patches apply in order on $TAG"

if [ "$CHECKPATCH" -eq 1 ]; then
	cp="$TREE/scripts/checkpatch.pl"
	[ -f "$cp" ] || { echo "no checkpatch.pl in $TREE/scripts" >&2; exit 1; }
	for p in "$pdir"/0*.patch; do
		echo "== $(basename "$p")"
		perl "$cp" --strict --no-tree "$p" 2>&1 | grep -E '^(WARNING|ERROR|CHECK)|^total' || true
	done
fi
