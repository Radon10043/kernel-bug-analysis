#!/bin/bash

# Boot a FreeBSD VM image with QEMU for single-shot bug reproduction.
# Modeled after omnislash/scripts/freebsd/qemu.sh and scripts/linux/qemu.sh.
#
# usage:
#   scripts/freebsd/qemu.sh [-i /path/to/freebsd.qcow2]
#
# commands for save/load/delete/check snapshots in qemu monitor:
#   nc 127.0.0.1 $MONITOR_PORT
#   (qemu monitor) savevm clean
#   (qemu monitor) loadvm clean
#   (qemu monitor) delvm clean
#   (qemu monitor) info snapshots

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

IMAGE="${FREEBSD_IMAGE:-$WORKSPACE/image/freebsd/freebsd.qcow2}"
SSH_PORT="${SSH_PORT:-37331}"
QMP_PORT="${QMP_PORT:-37332}"
MONITOR_PORT="${MONITOR_PORT:-37333}"
MEM="${MEM:-2048}"
SMP="${SMP:-2}"
LOG="${LOG:-$WORKSPACE/repro/kernel.log}"
SNAPSHOT=true

print_help() {
    echo "usage: $0 [ARGS]"
    echo "  args (optional):"
    echo "    -i, --image           <IMAGE>         path to the freebsd qcow2 image (default: $IMAGE)"
    echo "    -s, --ssh-port        <SSH_PORT>      port for ssh/scp etc.           (default: $SSH_PORT)"
    echo "    -q, --qmp-port        <QMP_PORT>      port for qmp                    (default: $QMP_PORT)"
    echo "    -m, --monitor-port    <MONITOR_PORT>  port for qemu monitor           (default: $MONITOR_PORT)"
    echo "        --mem             <MEM_MB>        VM memory in MB                 (default: $MEM)"
    echo "        --smp             <CPUS>          number of vCPUs                 (default: $SMP)"
    echo "    -l, --log             <LOGFILE>       serial console log file         (default: $LOG)"
    echo "        --no-snapshot                     disable -snapshot (persist disk writes)"
    echo "    -h, --help                            print help message"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -i | --image)
            IMAGE="$2"
            shift 2
            ;;
        -s | --ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        -q | --qmp-port)
            QMP_PORT="$2"
            shift 2
            ;;
        -m | --monitor-port)
            MONITOR_PORT="$2"
            shift 2
            ;;
        --mem)
            MEM="$2"
            shift 2
            ;;
        --smp)
            SMP="$2"
            shift 2
            ;;
        -l | --log)
            LOG="$2"
            shift 2
            ;;
        --no-snapshot)
            SNAPSHOT=false
            shift
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

if [[ ! -f "$IMAGE" ]]; then
    echo "error: '$IMAGE' does not exist." >&2
    exit 1
fi

IMAGE=$(realpath "$IMAGE")
mkdir -p "$(dirname "$LOG")"

SNAPSHOT_ARGS=()
if [[ "$SNAPSHOT" == true ]]; then
    SNAPSHOT_ARGS+=(-snapshot)
fi

qemu-system-x86_64 \
    -m "$MEM" \
    -smp "$SMP" \
    -chardev "socket,id=QMP,server=on,wait=off,host=127.0.0.1,port=${QMP_PORT}" \
    -mon chardev=QMP,mode=control \
    -chardev "socket,id=HMP,server=on,wait=off,host=127.0.0.1,port=${MONITOR_PORT}" \
    -mon chardev=HMP,mode=readline \
    -display none \
    -serial stdio \
    -no-reboot \
    -device virtio-rng-pci \
    -enable-kvm \
    -cpu host,migratable=off \
    -device e1000,netdev=net0 \
    -netdev "user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -hda "$IMAGE" \
    "${SNAPSHOT_ARGS[@]}" 2>&1 | tee "$LOG"
