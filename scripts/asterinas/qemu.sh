#!/usr/bin/env bash

# Boot an Asterinas NixOS VM image with QEMU for single-shot bug reproduction.
#
# usage:
#   scripts/asterinas/qemu.sh [-i repro/asterinas-test.img]
#
# commands for save/load/delete/check snapshots in qemu monitor:
#   nc 127.0.0.1 $MONITOR_PORT
#   (qemu monitor) savevm clean
#   (qemu monitor) loadvm clean

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

DEFAULT_IMAGE_DIR="$WORKSPACE/image/asterinas"
if [[ -n "${ASTERINAS_OVERLAY:-}" ]]; then
    IMAGE="$ASTERINAS_OVERLAY"
else
    IMAGE="${ASTERINAS_IMAGE:-$DEFAULT_IMAGE_DIR/asterinas.img}"
fi
OVMF="${OVMF:-/usr/share/qemu/OVMF.fd}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
SSH_PORT="${SSH_PORT:-10022}"
QMP_PORT="${QMP_PORT:-10023}"
MONITOR_PORT="${MONITOR_PORT:-10024}"
SMP="${SMP:-2}"
MEM="${MEM:-4096}"
LOG="${LOG:-$WORKSPACE/repro/kernel.log}"
ENABLE_KVM=1
SNAPSHOT=1
FULL_DEVICES=1
SCRATCH_EXT2=""
SCRATCH_EXFAT=""
VSOCK_CID=""
NO_VSOCK=0
VIRTIOFS_SOCK=""
VIRTIOFS_TAG="aster-virtiofs"

print_help() {
    cat <<EOF
usage: $0 [ARGS]
  args (optional):
    -i, --image <IMAGE>           path to asterinas.img (default: $IMAGE)
    -p, -s, --port, --ssh-port N  host port forwarded to guest SSH 22 (default: $SSH_PORT)
    -q, --qmp-port <PORT>         QMP control port, 0 to disable (default: $QMP_PORT)
    -m, --monitor-port <PORT>     QEMU HMP monitor port, 0 to disable (default: $MONITOR_PORT)
    -l, --log <LOGFILE>           serial console log file (default: $LOG)
        --ovmf <FILE>             OVMF firmware path (default: $OVMF)
        --qemu-bin <BIN>          QEMU binary (default: $QEMU_BIN)
        --cpu, --smp <N>          vCPU count (default: $SMP)
        --mem <MB>                VM memory in MB (default: $MEM)
        --full-devices            attach enlarged virtual device set (default)
        --minimal-devices         attach only boot disk + virtio-net
        --scratch-ext2 <IMG>      secondary raw virtio-blk disk (/dev/vdb)
        --scratch-exfat <IMG>     emulated NVMe raw disk (/dev/nvme0n1)
        --vsock-cid <CID>         attach vhost-vsock-pci with guest CID >= 3
        --no-vsock                skip vhost-vsock-pci
        --virtiofs-sock <SOCK>    attach vhost-user-fs-pci connected to virtiofsd socket
        --virtiofs-tag <TAG>      mount tag for vhost-user-fs-pci (default: $VIRTIOFS_TAG)
        --no-kvm                  use TCG instead of KVM
        --no-snapshot             write changes back to the disk image
    -h, --help                    print help message
EOF
}

need_arg() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "error: $1 requires an argument." >&2
        print_help >&2
        exit 1
    fi
}

probe_vsock_cid() {
    local requested_cid=${1:-}
    if [[ ! -e /dev/vhost-vsock ]]; then
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${requested_cid}" "${SSH_PORT}" <<'PY'
import errno
import fcntl
import os
import struct
import sys

VHOST_VSOCK_SET_GUEST_CID = 0x4008AF60
requested = sys.argv[1]
ssh_port = int(sys.argv[2]) if sys.argv[2].isdigit() else 10022

try:
    fd = os.open("/dev/vhost-vsock", os.O_RDWR)
except OSError:
    sys.exit(1)

try:
    if requested:
        candidates = [int(requested)]
    else:
        candidates = [3]
        if 3 <= ssh_port <= 65535 and ssh_port != 3:
            candidates.append(ssh_port)
        candidates.extend(range(10240, 10300))
    for cid in candidates:
        try:
            fcntl.ioctl(fd, VHOST_VSOCK_SET_GUEST_CID, struct.pack("=Q", cid))
            print(cid)
            sys.exit(0)
        except OSError as exc:
            if exc.errno == errno.EADDRINUSE and not requested:
                continue
            sys.exit(1)
    sys.exit(1)
finally:
    os.close(fd)
PY
        return $?
    fi
    if (exec 3<>/dev/vhost-vsock) 2>/dev/null; then
        echo "${requested_cid:-3}"
        return 0
    fi
    return 1
}

detect_disk_format() {
    local path=$1
    python3 - "$path" <<'PY'
import sys

with open(sys.argv[1], "rb") as f:
    magic = f.read(4)
print("qcow2" if magic == b"QFI\xfb" else "raw")
PY
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -i | --image)
            need_arg "$@"
            IMAGE="$2"
            shift 2
            ;;
        -p | -s | --port | --ssh-port)
            need_arg "$@"
            SSH_PORT="$2"
            shift 2
            ;;
        -q | --qmp-port)
            need_arg "$@"
            QMP_PORT="$2"
            shift 2
            ;;
        -m | --monitor-port)
            need_arg "$@"
            MONITOR_PORT="$2"
            shift 2
            ;;
        -l | --log)
            need_arg "$@"
            LOG="$2"
            shift 2
            ;;
        --ovmf)
            need_arg "$@"
            OVMF="$2"
            shift 2
            ;;
        --qemu-bin)
            need_arg "$@"
            QEMU_BIN="$2"
            shift 2
            ;;
        --cpu | --smp)
            need_arg "$@"
            SMP="$2"
            shift 2
            ;;
        --mem)
            need_arg "$@"
            MEM="$2"
            shift 2
            ;;
        --full-devices)
            FULL_DEVICES=1
            shift
            ;;
        --minimal-devices)
            FULL_DEVICES=0
            shift
            ;;
        --scratch-ext2)
            need_arg "$@"
            SCRATCH_EXT2=$(realpath -m "$2")
            shift 2
            ;;
        --scratch-exfat)
            need_arg "$@"
            SCRATCH_EXFAT=$(realpath -m "$2")
            shift 2
            ;;
        --vsock-cid)
            need_arg "$@"
            VSOCK_CID="$2"
            shift 2
            ;;
        --no-vsock)
            NO_VSOCK=1
            shift
            ;;
        --virtiofs-sock)
            need_arg "$@"
            VIRTIOFS_SOCK=$(realpath -m "$2")
            shift 2
            ;;
        --virtiofs-tag)
            need_arg "$@"
            VIRTIOFS_TAG="$2"
            shift 2
            ;;
        --no-kvm)
            ENABLE_KVM=0
            shift
            ;;
        --no-snapshot)
            SNAPSHOT=0
            shift
            ;;
        -h | --help)
            print_help
            exit 0
            ;;
        *)
            echo "error: unknown arg: $1" >&2
            print_help >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$IMAGE" ]]; then
    echo "error: '$IMAGE' does not exist." >&2
    exit 1
fi
if [[ ! -f "$OVMF" ]]; then
    echo "error: OVMF firmware '$OVMF' does not exist." >&2
    exit 1
fi

IMAGE=$(realpath "$IMAGE")
IMAGE_DIR=$(dirname "$IMAGE")
DISK_FORMAT=$(detect_disk_format "$IMAGE")
mkdir -p "$(dirname "$LOG")"

if [[ -n "$SCRATCH_EXT2" ]]; then
    if [[ ! -f "$SCRATCH_EXT2" ]]; then
        echo "error: scratch ext2 image '$SCRATCH_EXT2' does not exist." >&2
        exit 1
    fi
elif [[ "$FULL_DEVICES" -eq 1 ]]; then
    if [[ -f "${IMAGE_DIR}/scratch-ext2.img" ]]; then
        SCRATCH_EXT2="${IMAGE_DIR}/scratch-ext2.img"
    elif [[ -f "${DEFAULT_IMAGE_DIR}/scratch-ext2.img" ]]; then
        SCRATCH_EXT2="${DEFAULT_IMAGE_DIR}/scratch-ext2.img"
    fi
fi

if [[ -n "$SCRATCH_EXFAT" ]]; then
    if [[ ! -f "$SCRATCH_EXFAT" ]]; then
        echo "error: scratch exfat image '$SCRATCH_EXFAT' does not exist." >&2
        exit 1
    fi
elif [[ "$FULL_DEVICES" -eq 1 ]]; then
    if [[ -f "${IMAGE_DIR}/scratch-exfat.img" ]]; then
        SCRATCH_EXFAT="${IMAGE_DIR}/scratch-exfat.img"
    elif [[ -f "${DEFAULT_IMAGE_DIR}/scratch-exfat.img" ]]; then
        SCRATCH_EXFAT="${DEFAULT_IMAGE_DIR}/scratch-exfat.img"
    fi
fi

if [[ -n "$VSOCK_CID" ]]; then
    if [[ ! "$VSOCK_CID" =~ ^[0-9]+$ ]] || ((10#$VSOCK_CID < 3)); then
        echo "error: --vsock-cid must be an integer >= 3, got: '$VSOCK_CID'" >&2
        exit 1
    fi
fi

if [[ -n "$VIRTIOFS_SOCK" && ! -S "$VIRTIOFS_SOCK" && ! -e "$VIRTIOFS_SOCK" ]]; then
    echo "error: virtiofs socket '$VIRTIOFS_SOCK' does not exist." >&2
    exit 1
fi

QEMU_ARGS=(
    -m "$MEM"
    -smp "$SMP"
    -display none
    -serial stdio
    -no-reboot
    -machine "q35,kernel-irqchip=split"
    -bios "$OVMF"
    -device "virtio-blk-pci,drive=hd0,disable-legacy=on,disable-modern=off"
    -drive "if=none,format=${DISK_FORMAT},id=hd0,file=$IMAGE"
    -device "isa-debug-exit,iobase=0xf4,iosize=0x04"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
    -device "virtio-net-pci,netdev=net0,disable-legacy=on,disable-modern=off,csum=off,ctrl_guest_offloads=off,ctrl_mac_addr=off,ctrl_rx_extra=off,ctrl_rx=off,ctrl_vlan=off,ctrl_vq=off,event_idx=off,guest_announce=off,guest_csum=off,guest_ecn=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,host_ecn=off,host_tso4=off,host_tso6=off,host_ufo=off,host_uso=off,indirect_desc=off,mrg_rxbuf=off,queue_reset=off"
)

if [[ "$QMP_PORT" != "0" ]]; then
    QEMU_ARGS+=(
        -chardev "socket,id=QMP,server=on,wait=off,host=127.0.0.1,port=${QMP_PORT}"
        -mon "chardev=QMP,mode=control"
    )
fi

if [[ "$MONITOR_PORT" != "0" ]]; then
    QEMU_ARGS+=(
        -chardev "socket,id=HMP,server=on,wait=off,host=127.0.0.1,port=${MONITOR_PORT}"
        -mon "chardev=HMP,mode=readline"
    )
fi

if [[ -n "$SCRATCH_EXT2" ]]; then
    QEMU_ARGS+=(
        -drive "if=none,format=raw,id=hd1,file=$SCRATCH_EXT2"
        -device "virtio-blk-pci,drive=hd1,disable-legacy=on,disable-modern=off"
    )
fi

if [[ -n "$SCRATCH_EXFAT" ]]; then
    QEMU_ARGS+=(
        -drive "if=none,format=raw,id=nvme0,file=$SCRATCH_EXFAT"
        -device "nvme,serial=syz0,drive=nvme0"
    )
fi

if [[ "$FULL_DEVICES" -eq 1 ]]; then
    QEMU_ARGS+=(
        -vga none
        -device "bochs-display"
        -device "virtio-keyboard-pci,disable-legacy=on,disable-modern=off"
        -device "virtio-mouse-pci,disable-legacy=on,disable-modern=off"
        -device "virtio-serial-pci,disable-legacy=on,disable-modern=off"
        -chardev "null,id=hvc0"
        -device "virtconsole,chardev=hvc0"
        -object "rng-random,filename=/dev/urandom,id=rng0"
        -device "virtio-rng-pci,rng=rng0,disable-legacy=on,disable-modern=off"
    )
fi

if [[ "$NO_VSOCK" -eq 0 ]]; then
    if [[ -n "$VSOCK_CID" ]]; then
        if ! resolved_vsock_cid=$(probe_vsock_cid "$VSOCK_CID"); then
            echo "error: /dev/vhost-vsock is unavailable or guest CID '$VSOCK_CID' is busy." >&2
            exit 1
        fi
        QEMU_ARGS+=(
            -device "vhost-vsock-pci,guest-cid=${resolved_vsock_cid},disable-legacy=on,disable-modern=off"
        )
    elif [[ "$FULL_DEVICES" -eq 1 ]]; then
        if resolved_vsock_cid=$(probe_vsock_cid ""); then
            QEMU_ARGS+=(
                -device "vhost-vsock-pci,guest-cid=${resolved_vsock_cid},disable-legacy=on,disable-modern=off"
            )
        fi
    fi
fi

if [[ -n "$VIRTIOFS_SOCK" ]]; then
    if [[ "$MEM" =~ ^[0-9]+$ ]]; then
        MEM_SIZE="${MEM}M"
    else
        MEM_SIZE="$MEM"
    fi
    QEMU_ARGS+=(
        -object "memory-backend-memfd,id=mem0,size=${MEM_SIZE},share=on"
        -numa "node,memdev=mem0"
        -chardev "socket,id=char0,path=${VIRTIOFS_SOCK}"
        -device "vhost-user-fs-pci,chardev=char0,tag=${VIRTIOFS_TAG}"
    )
fi

if [[ "$ENABLE_KVM" -eq 1 ]]; then
    QEMU_ARGS+=(-enable-kvm -cpu host)
else
    QEMU_ARGS+=(-cpu qemu64)
fi

if [[ "$SNAPSHOT" -eq 1 ]]; then
    QEMU_ARGS+=(-snapshot)
fi

"$QEMU_BIN" "${QEMU_ARGS[@]}" 2>&1 | tee "$LOG"
