#!/bin/bash

# Convert a FreeBSD syzkaller program (.syz) to C source on a Linux host.
#
# syz-prog2c spoils target.CPP to "cant-build-freebsd-on-linux" when running on
# Linux (sys/targets/targets.go), even though csource only invokes CPP with
# "-nostdinc -undef -fdirectives-only -dDI -E -P -CC -" for pure macro
# expansion. This wrapper temporarily shims that name to GNU cpp on PATH.

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

PROG2C="$WORKSPACE/syzkaller/bin/syz-prog2c"
PROG="$WORKSPACE/repro/repro.syz"
OUT="$WORKSPACE/repro/repro.c"
ARCH="${ARCH:-amd64}"
CPP_BIN="${CPP_BIN:-}"
EXTRA_ARGS=()

print_help() {
    echo "usage: $0 [ARGS] [--] [SYZ_PROG2C_FLAGS...]"
    echo "  args (optional):"
    echo "    -f, --file    <FILE>   input .syz program (default: $PROG)"
    echo "    -o, --output  <FILE>   output .c file, or '-' for stdout (default: $OUT)"
    echo "    -a, --arch    <ARCH>   target FreeBSD arch (default: $ARCH)"
    echo "        --cpp     <PATH>   GNU cpp/g++ binary for preprocessing (default: auto-detect)"
    echo "    -h, --help             print help message"
    echo ""
    echo "  any additional flags (e.g. -threaded -repeat=0 -procs=6 -sandbox=none -tmpdir -segv)"
    echo "  are forwarded directly to syz-prog2c. Do not pass -build on Linux."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -f | --file | -prog)
            PROG="$2"
            shift 2
            ;;
        -prog=*)
            PROG="${1#-prog=}"
            shift
            ;;
        -o | --output)
            OUT="$2"
            shift 2
            ;;
        -a | --arch | -arch)
            ARCH="$2"
            shift 2
            ;;
        -arch=*)
            ARCH="${1#-arch=}"
            shift
            ;;
        --cpp)
            CPP_BIN="$2"
            shift 2
            ;;
        -build | -build=true | --build | --build=true)
            echo "error: -build is not supported on Linux; compile the generated .c inside the FreeBSD VM (e.g. scripts/freebsd/exec-c.sh)." >&2
            exit 1
            ;;
        -h | --help)
            print_help
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS+=("$@")
            break
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

for arg in "${EXTRA_ARGS[@]}"; do
    case "$arg" in
        -build | -build=true | --build | --build=true)
            echo "error: -build is not supported on Linux; compile the generated .c inside the FreeBSD VM (e.g. scripts/freebsd/exec-c.sh)." >&2
            exit 1
            ;;
    esac
done

if [[ ! -x "$PROG2C" ]]; then
    echo "error: '$PROG2C' not found or not executable." >&2
    echo "hint: build it with 'make -C syzkaller prog2c'." >&2
    exit 1
fi

if [[ ! -f "$PROG" ]]; then
    echo "error: input program '$PROG' does not exist." >&2
    exit 1
fi

if [[ -z "$CPP_BIN" ]]; then
    if command -v cpp >/dev/null 2>&1; then
        CPP_BIN=$(command -v cpp)
    elif command -v g++ >/dev/null 2>&1; then
        CPP_BIN=$(command -v g++)
    else
        echo "error: neither GNU 'cpp' nor 'g++' found in PATH." >&2
        exit 1
    fi
elif [[ ! -x "$CPP_BIN" ]]; then
    echo "error: preprocessor '$CPP_BIN' is not executable." >&2
    exit 1
fi

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ln -s "$CPP_BIN" "$TMPDIR_WORK/cant-build-freebsd-on-${HOST_OS}"

TMP_OUT="$TMPDIR_WORK/repro.c"
PATH="$TMPDIR_WORK:$PATH" "$PROG2C" \
    -os=freebsd \
    -arch="$ARCH" \
    -prog="$PROG" \
    "${EXTRA_ARGS[@]}" \
    > "$TMP_OUT"

if [[ "$OUT" == "-" ]]; then
    cat "$TMP_OUT"
else
    mkdir -p "$(dirname "$OUT")"
    cp "$TMP_OUT" "$OUT"
    echo "generated: $OUT" >&2
fi
