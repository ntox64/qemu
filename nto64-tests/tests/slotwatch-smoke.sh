#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause

set -eu

QEMU=${QEMU:-../build/qemu-system-x86_64}
PLUGIN=${PLUGIN:-plugins/slotwatch.so}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/slotwatch-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

run()
{
    name=$1
    args=$2
    out="$WORK/$name.log"
    timeout --preserve-status -s INT 2 \
        "$QEMU" -machine none -accel tcg -display none -nodefaults \
        -plugin "file=$PLUGIN,$args" >"$out" 2>&1 || true
}

expect()
{
    name=$1
    text=$2
    grep -F "$text" "$WORK/$name.log" >/dev/null || {
        echo "FAIL: $name: missing '$text'" >&2
        sed 's/^/  /' "$WORK/$name.log" >&2
        exit 1
    }
}

run valid 'slot=0x1000,code=0x1000:0x1010,physlo=0x2000,physhi=0x2100'
expect valid 'SLOTWATCH-ARM'
expect valid 'armed=yes'
expect valid 'stores_observed=no'
expect valid 'target_hits=0'
expect valid 'measured=NO-MEASUREMENT'

run zero 'slot=0'
expect zero 'SLOTWATCH-ERROR slot=VA is required'

run physlo-only 'slot=0x1000,physlo=0x2000'
expect physlo-only 'physlo= and physhi= must be given together'

run reversed 'slot=0x1000,physlo=0x2000,physhi=0x2000'
expect reversed 'empty physical range'

run frameoff-only 'slot=0x1000,frameoff=0x20'
expect frameoff-only 'requires frame'

run frameany-only 'slot=0x1000,frameany=1'
expect frameany-only 'requires frame'

echo "PASS: slotwatch option validation and truthful summary"
