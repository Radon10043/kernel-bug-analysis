#!/bin/bash

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$WORKSPACE/repro/symbolize"
"$WORKSPACE/syzkaller/bin/syz-symbolize" \
    -kernel_obj="$WORKSPACE/kernel/linux" \
    -outdir="$WORKSPACE/repro/symbolize" \
    "$WORKSPACE/repro/kernel.log" > "$WORKSPACE/repro/symbolize.log"
