#!/usr/bin/env bash

# Compile a C reproducer statically on the Linux host, upload it over SSH, and
# execute it inside the running Asterinas VM.

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

SSH_PORT="${SSH_PORT:-${PORT:-10022}}"
HOST="${HOST:-127.0.0.1}"
SSH_KEY="${ASTERINAS_SSHKEY:-${SSHKEY:-$WORKSPACE/image/asterinas/asterinas.id_rsa}}"
REPRO="${REPRO:-$WORKSPACE/repro/repro.c}"
HOST_CC="${HOST_CC:-gcc}"

print_help() {
    echo "usage: $0 [ARGS]"
    echo "  args (optional):"
    echo "    -f, --file      <FILE>      path to C reproducer (default: $REPRO)"
    echo "    -s, -p, --ssh-port, --port  forwarded SSH port   (default: $SSH_PORT)"
    echo "    -k, --key       <SSH_KEY>   SSH private key      (default: $SSH_KEY)"
    echo "        --host      <HOST>      SSH target host      (default: $HOST)"
    echo "    -h, --help                  print help message"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -f | --file)
            REPRO="$2"
            shift 2
            ;;
        -s | -p | --ssh-port | --port)
            SSH_PORT="$2"
            shift 2
            ;;
        -k | --key)
            SSH_KEY="$2"
            shift 2
            ;;
        --host)
            HOST="$2"
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
if ! command -v "$HOST_CC" >/dev/null 2>&1; then
    echo "error: host C compiler '$HOST_CC' not found." >&2
    exit 1
fi

TMP_BIN=$(mktemp /tmp/asterinas-repro-bin.XXXXXX)
trap 'rm -f "$TMP_BIN"' EXIT

"$HOST_CC" -static -pthread -O2 "$REPRO" -o "$TMP_BIN"

SSH_OPTS=(
    -F /dev/null
    -o UserKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o ConnectTimeout=10
    -i "$SSH_KEY"
)

scp -O -P "$SSH_PORT" "${SSH_OPTS[@]}" "$TMP_BIN" "root@${HOST}:/tmp/repro.out"
ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" "root@${HOST}" "chmod +x /tmp/repro.out && /tmp/repro.out"
