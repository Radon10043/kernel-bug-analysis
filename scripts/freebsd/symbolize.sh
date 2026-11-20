#!/bin/bash

# Parse and symbolize a FreeBSD kernel console log using syz-symbolize.

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

KERNEL_SRC="${FREEBSD_SRC:-$WORKSPACE/kernel/freebsd}"
KERNEL_OBJ="${FREEBSD_OBJ:-}"
LOG="$WORKSPACE/repro/kernel.log"
OUTDIR="$WORKSPACE/repro/symbolize"
OUTLOG="$WORKSPACE/repro/symbolize.log"

print_help() {
    echo "usage: $0 [ARGS]"
    echo "  args (optional):"
    echo "    -l, --log        <LOGFILE>   input kernel log       (default: $LOG)"
    echo "    -o, --outdir     <OUTDIR>    symbolize output dir   (default: $OUTDIR)"
    echo "        --outlog     <OUTLOG>    stdout redirect file   (default: $OUTLOG)"
    echo "    -s, --sourcedir  <SRC>       FreeBSD kernel source  (default: $KERNEL_SRC)"
    echo "        --objdir     <OBJ>       dir containing kernel.full (default: auto-detect under SRC/build)"
    echo "    -h, --help                   print help message"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -l | --log)
            LOG="$2"
            shift 2
            ;;
        -o | --outdir)
            OUTDIR="$2"
            shift 2
            ;;
        --outlog)
            OUTLOG="$2"
            shift 2
            ;;
        -s | --sourcedir)
            KERNEL_SRC="$2"
            shift 2
            ;;
        --objdir)
            KERNEL_OBJ="$2"
            shift 2
            ;;
        -h | --help)
            print_help
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            print_help >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$LOG" ]]; then
    echo "error: kernel log '$LOG' does not exist." >&2
    exit 1
fi

if [[ -z "$KERNEL_OBJ" && -d "$KERNEL_SRC/build" ]]; then
    KERNEL_FULL=$(find "$KERNEL_SRC/build" -name 'kernel.full' -print -quit 2>/dev/null || true)
    if [[ -n "$KERNEL_FULL" ]]; then
        KERNEL_OBJ=$(dirname "$KERNEL_FULL")
    fi
fi

mkdir -p "$OUTDIR" "$(dirname "$OUTLOG")"
SYMB_ARGS=(
    -os=freebsd
    -arch=amd64
    -kernel_src="$KERNEL_SRC"
    -outdir="$OUTDIR"
)
if [[ -n "$KERNEL_OBJ" ]]; then
    SYMB_ARGS+=(-kernel_obj="$KERNEL_OBJ")
fi
"$WORKSPACE/syzkaller/bin/syz-symbolize" "${SYMB_ARGS[@]}" "$LOG" > "$OUTLOG"
