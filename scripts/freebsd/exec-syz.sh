#!/bin/bash

# Copy syz-execprog/syz-executor and a syz program into the running FreeBSD VM and execute it.

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

SSH_PORT="${SSH_PORT:-37331}"
SSH_KEY="${FREEBSD_SSHKEY:-$WORKSPACE/image/freebsd/freebsd.id_rsa}"
REPRO="$WORKSPACE/repro/repro.syz"
PROCS="${PROCS:-8}"
REPEAT="${REPEAT:-0}"

print_help() {
    echo "usage: $0 [ARGS]"
    echo "  args (optional):"
    echo "    -f, --file      <FILE>      path to syz reproducer (default: $REPRO)"
    echo "    -s, --ssh-port  <SSH_PORT>  forwarded SSH port     (default: $SSH_PORT)"
    echo "    -k, --key       <SSH_KEY>   SSH private key        (default: $SSH_KEY)"
    echo "    -p, --procs     <PROCS>     parallel processes     (default: $PROCS)"
    echo "    -r, --repeat    <REPEAT>    repeat count (0=inf)   (default: $REPEAT)"
    echo "    -h, --help                  print help message"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -f | --file)
            REPRO="$2"
            shift 2
            ;;
        -s | --ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        -k | --key)
            SSH_KEY="$2"
            shift 2
            ;;
        -p | --procs)
            PROCS="$2"
            shift 2
            ;;
        -r | --repeat)
            REPEAT="$2"
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

BIN_DIR="$WORKSPACE/syzkaller/bin/freebsd_amd64"
if [[ ! -f "$BIN_DIR/syz-execprog" || ! -f "$BIN_DIR/syz-executor" ]]; then
    echo "error: FreeBSD syzkaller target binaries not found in '$BIN_DIR'." >&2
    echo "hint: build them with 'make syzutils-freebsd' or 'scripts/freebsd/build-binary.py'." >&2
    exit 1
fi
if [[ ! -f "$REPRO" ]]; then
    echo "error: reproducer '$REPRO' does not exist." >&2
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    echo "error: SSH key '$SSH_KEY' does not exist." >&2
    exit 1
fi

SSH_OPTS=(
    -F /dev/null
    -o UserKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o ConnectTimeout=10
    -i "$SSH_KEY"
)

scp -P "$SSH_PORT" "${SSH_OPTS[@]}" -v \
    "$BIN_DIR"/* root@localhost:/tmp/

scp -P "$SSH_PORT" "${SSH_OPTS[@]}" -v \
    "$REPRO" root@localhost:/tmp/repro.syz

ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" \
    root@localhost "cd /tmp && ./syz-execprog -os=freebsd -arch=amd64 -sandbox=none -enable=all -repeat=${REPEAT} -procs=${PROCS} ./repro.syz"
