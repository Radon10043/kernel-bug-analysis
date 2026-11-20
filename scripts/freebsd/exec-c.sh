#!/bin/bash

# Copy, compile, and run a C reproducer inside the running FreeBSD VM.

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

SSH_PORT="${SSH_PORT:-37331}"
SSH_KEY="${FREEBSD_SSHKEY:-$WORKSPACE/image/freebsd/freebsd.id_rsa}"
REPRO="$WORKSPACE/repro/repro.c"

print_help() {
    echo "usage: $0 [ARGS]"
    echo "  args (optional):"
    echo "    -f, --file      <FILE>      path to C reproducer (default: $REPRO)"
    echo "    -s, --ssh-port  <SSH_PORT>  forwarded SSH port   (default: $SSH_PORT)"
    echo "    -k, --key       <SSH_KEY>   SSH private key      (default: $SSH_KEY)"
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
    "$REPRO" root@localhost:/tmp/repro.c

ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" \
    root@localhost "cd /tmp && cc repro.c -pthread -o repro.out && chmod +x ./repro.out && ./repro.out"
