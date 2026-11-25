#!/usr/bin/env bash

# Build or update a bootable Asterinas NixOS disk image from a prebuilt kernel
# (produced by scripts/asterinas/build.sh), generate the SSH keypair, create
# companion ext2/exfat scratch disks, and record provenance metadata.
# Uses self-contained staging and loop-partition handling so unpatched upstream
# Asterinas trees work inside Docker without modifying the kernel git worktree.

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

KERNEL_PATH="${ASTERINAS_SRC:-$WORKSPACE/kernel/asterinas}"
SOURCE_DIR=""
OUT_DIR="${OUT_DIR:-$WORKSPACE/image/asterinas}"
DISK_SIZE_MB="${NIXOS_DISK_SIZE_IN_MB:-16384}"
FORCE=0

RELEASE_SUBSTITUTER="${RELEASE_SUBSTITUTER:-https://aster-nixos-release.cachix.org}"
RELEASE_TRUSTED_PUBLIC_KEY="${RELEASE_TRUSTED_PUBLIC_KEY:-aster-nixos-release.cachix.org-1:xB6U/f5ck5vGDJZ04kPp3zGpZ4Nro9X4+TSSMAETVFE=}"
DEV_SUBSTITUTER="${DEV_SUBSTITUTER:-https://aster-nixos-dev.cachix.org}"
DEV_TRUSTED_PUBLIC_KEY="${DEV_TRUSTED_PUBLIC_KEY:-aster-nixos-dev.cachix.org-1:xrCbE2flfliFTQCY/2HeJoT2tCO+5kMTZeLIUH9lnIA=}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -k, --kernel PATH         Built Asterinas kernel directory or bzImage file
                            (default: $KERNEL_PATH)
  -s, --source DIR          Asterinas source tree providing distro/ and flake.lock
                            (auto-detected when --kernel points to a source tree)
  -o, --out DIR             Output directory (default: $OUT_DIR)
      --disk-size-mb MB     Asterinas NixOS disk size in MB (default: $DISK_SIZE_MB)
      --force               Rebuild the full NixOS image instead of updating
                            an existing matching image in place
  -h, --help                Show this help

Outputs written to OUT:
  asterinas.img             Bootable NixOS raw image with the kernel installed
  asterinas.id_rsa          SSH private key (and .pub) matching the guest
  image-meta.txt            Image and kernel provenance metadata
  kernel.sha256             SHA-256 digest of the installed bzImage (and vmlinux)
  scratch-ext2.img          Companion 64 MiB ext2 scratch disk
  scratch-exfat.img         Companion 64 MiB exfat scratch disk
EOF
}

need_arg() {
    if [[ -z "${2:-}" || "${2}" == --* ]]; then
        echo "error: $1 requires an argument" >&2
        usage >&2
        exit 1
    fi
}

while (($#)); do
    case "$1" in
        -k | --kernel)
            need_arg "$1" "${2-}"
            KERNEL_PATH="$2"
            shift 2
            ;;
        -s | --source)
            need_arg "$1" "${2-}"
            SOURCE_DIR="$2"
            shift 2
            ;;
        -o | --out)
            need_arg "$1" "${2-}"
            OUT_DIR="$2"
            shift 2
            ;;
        --disk-size-mb)
            need_arg "$1" "${2-}"
            DISK_SIZE_MB="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: missing required command: $1" >&2
        exit 1
    fi
}

require_uint_range() {
    local name=$1
    local value=$2
    local min=$3
    local max=$4
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "error: ${name} must be an integer, got: ${value}" >&2
        exit 1
    fi
    local number=$((10#${value}))
    if ((number < min || number > max)); then
        echo "error: ${name} must be in [${min}, ${max}], got: ${value}" >&2
        exit 1
    fi
}

for cmd in cp python3 realpath sha256sum ssh-keygen stat; do
    require_cmd "${cmd}"
done
require_uint_range "--disk-size-mb" "${DISK_SIZE_MB}" 128 1048576

if [[ ! -e "${KERNEL_PATH}" ]]; then
    echo "error: Asterinas kernel path not found: ${KERNEL_PATH}" >&2
    exit 1
fi

kernel_abs=$(realpath "${KERNEL_PATH}")
bzimage_path=""
kernel_dir=""
vmlinux_path=""
manifest_path=""
build_record_path=""

if [[ -d "${kernel_abs}" ]]; then
    kernel_dir="${kernel_abs}"
    bzimage_path="${kernel_dir}/bzImage"
    if [[ ! -f "${bzimage_path}" ]]; then
        echo "error: missing ${bzimage_path}; build the kernel first with 'make asterinas'" >&2
        exit 1
    fi
else
    bzimage_path="${kernel_abs}"
    kernel_dir=$(dirname "${kernel_abs}")
fi

[[ -f "${kernel_dir}/vmlinux" ]] && vmlinux_path="${kernel_dir}/vmlinux"
[[ -f "${kernel_dir}/images.sha256" ]] && manifest_path="${kernel_dir}/images.sha256"
[[ -f "${kernel_dir}/build-record.txt" ]] && build_record_path="${kernel_dir}/build-record.txt"

python3 - "${bzimage_path}" <<'PY'
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    hdr = f.read(0x206)
if len(hdr) < 0x206 or hdr[0x1FE:0x200] != b"\x55\xaa" or hdr[0x202:0x206] != b"HdrS":
    print(f"error: not a valid Linux x86 bzImage (missing 0x55aa/HdrS header): {path}", file=sys.stderr)
    sys.exit(1)
PY

bzimage_sha256=$(sha256sum "${bzimage_path}" | awk '{print $1}')
vmlinux_sha256=""
if [[ -n "${vmlinux_path}" ]]; then
    vmlinux_sha256=$(sha256sum "${vmlinux_path}" | awk '{print $1}')
fi

if [[ -n "${manifest_path}" ]]; then
    python3 - "${manifest_path}" "${bzimage_path}" "${bzimage_sha256}" "${vmlinux_path}" "${vmlinux_sha256}" <<'PY'
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
bz_path = pathlib.Path(sys.argv[2])
bz_actual = sys.argv[3]
vm_path = pathlib.Path(sys.argv[4]) if sys.argv[4] else None
vm_actual = sys.argv[5]

entries: dict[str, str] = {}
for lineno, raw in enumerate(manifest_path.read_text(encoding="utf-8").splitlines(), 1):
    line = raw.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) != 2:
        print(f"error: malformed line {lineno} in {manifest_path}: {raw}", file=sys.stderr)
        sys.exit(1)
    digest, name = parts[0], parts[1].lstrip("*")
    entries[name] = digest

if bz_path.name in entries and entries[bz_path.name] != bz_actual:
    print(
        f"error: checksum mismatch for {bz_path}: manifest expects {entries[bz_path.name]}, got {bz_actual}",
        file=sys.stderr,
    )
    sys.exit(1)

if "vmlinux" in entries:
    if vm_path is None or not vm_path.is_file():
        print(
            f"error: manifest {manifest_path} records vmlinux, but matching vmlinux is missing",
            file=sys.stderr,
        )
        sys.exit(1)
    if entries["vmlinux"] != vm_actual:
        print(
            f"error: checksum mismatch for {vm_path}: manifest expects {entries['vmlinux']}, got {vm_actual}",
            file=sys.stderr,
        )
        sys.exit(1)
PY
fi

if [[ -z "${SOURCE_DIR}" ]] &&
    [[ -f "${kernel_dir}/VERSION" && -d "${kernel_dir}/distro/etc_nixos" ]]; then
    SOURCE_DIR="${kernel_dir}"
fi
if [[ -n "${SOURCE_DIR}" ]]; then
    SOURCE_DIR=$(realpath "${SOURCE_DIR}")
fi

OUT_DIR=$(realpath -m "${OUT_DIR}")
mkdir -p "${OUT_DIR}"
SSH_KEY="${OUT_DIR}/asterinas.id_rsa"
IMAGE="${OUT_DIR}/asterinas.img"
META_FILE="${OUT_DIR}/image-meta.txt"
SHA_FILE="${OUT_DIR}/kernel.sha256"
SCRATCH_EXT2="${OUT_DIR}/scratch-ext2.img"
SCRATCH_EXFAT="${OUT_DIR}/scratch-exfat.img"
SCRATCH_SIZE_BYTES=$((64 * 1024 * 1024))

if [[ ! -f "${SSH_KEY}" ]]; then
    ssh-keygen -f "${SSH_KEY}" -t rsa -b 2048 -N '' -C '' >/dev/null
fi
chmod 0600 "${SSH_KEY}"

if [[ ! -f "${SSH_KEY}.pub" ]]; then
    ssh-keygen -y -f "${SSH_KEY}" >"${SSH_KEY}.pub"
fi
PUBLIC_KEY=$(<"${SSH_KEY}.pub")
ssh_pubkey_sha256=$(printf '%s\n' "${PUBLIC_KEY}" | sha256sum | awk '{print $1}')

asterinas_version="unknown"
asterinas_commit="unknown"
kernel_kcov="unknown"
kernel_kasan="unknown"

if [[ -n "${build_record_path}" ]]; then
    rec_ver=$(sed -n 's/^Asterinas version: //p' "${build_record_path}" | head -n1 || true)
    rec_commit=$(sed -n 's/^Asterinas commit: //p' "${build_record_path}" | head -n1 || true)
    rec_instr=$(grep -m1 '^KCOV=' "${build_record_path}" || true)
    [[ -n "${rec_ver}" ]] && asterinas_version="${rec_ver}"
    [[ -n "${rec_commit}" ]] && asterinas_commit="${rec_commit}"
    if [[ "${rec_instr}" =~ KCOV=([01])[[:space:]]+KASAN=([01]) ]]; then
        kernel_kcov="${BASH_REMATCH[1]}"
        kernel_kasan="${BASH_REMATCH[2]}"
    fi
fi
if [[ "${asterinas_version}" == "unknown" && -n "${SOURCE_DIR}" && -f "${SOURCE_DIR}/VERSION" ]]; then
    asterinas_version=$(tr -d '[:space:]' <"${SOURCE_DIR}/VERSION")
fi
if [[ "${asterinas_commit}" == "unknown" && -n "${SOURCE_DIR}" ]] &&
    git -C "${SOURCE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    asterinas_commit=$(git -C "${SOURCE_DIR}" rev-parse --short=12 HEAD 2>/dev/null || echo "unknown")
fi

tmp_distro=""
img_tmp=""
loop_disk=""
tmp_mount_root=""
scratch_tmp=""
boot_mounted=0
root_mounted=0

cleanup() {
    if [[ "${boot_mounted}" -eq 1 && -n "${tmp_mount_root}" ]]; then
        umount -d "${tmp_mount_root}/boot" 2>/dev/null || true
    fi
    if [[ "${root_mounted}" -eq 1 && -n "${tmp_mount_root}" ]]; then
        umount -d "${tmp_mount_root}" 2>/dev/null || true
    fi
    if [[ -n "${loop_disk}" ]]; then
        local bdev="${loop_disk}p1"
        local rdev="${loop_disk}p2"
        losetup -d "${loop_disk}" 2>/dev/null || true
        [[ ! -e "/sys/class/block/${bdev#/dev/}" ]] && rm -f "${bdev}" 2>/dev/null || true
        [[ ! -e "/sys/class/block/${rdev#/dev/}" ]] && rm -f "${rdev}" 2>/dev/null || true
    fi
    if [[ -n "${tmp_mount_root}" && -d "${tmp_mount_root}" ]]; then
        rm -rf "${tmp_mount_root}"
    fi
    if [[ -n "${tmp_distro}" && -d "${tmp_distro}" ]]; then
        rm -rf "${tmp_distro}"
    fi
    if [[ -n "${img_tmp}" && -f "${img_tmp}" ]]; then
        rm -f "${img_tmp}"
    fi
    if [[ -n "${scratch_tmp}" && -f "${scratch_tmp}" ]]; then
        rm -f "${scratch_tmp}"
    fi
}
trap cleanup EXIT

sync_block_device_node() {
    local device_path=$1
    local device_name=${device_path#/dev/}
    local sysfs_dev="/sys/class/block/${device_name}/dev"
    if [[ ! -r "${sysfs_dev}" ]]; then
        if [[ -b "${device_path}" ]]; then
            rm -f "${device_path}"
        fi
        return 0
    fi
    local major minor
    IFS=: read -r major minor <"${sysfs_dev}"
    if [[ -b "${device_path}" ]]; then
        local cur_maj cur_min
        cur_maj=$((16#$(stat -c '%t' "${device_path}")))
        cur_min=$((16#$(stat -c '%T' "${device_path}")))
        if [[ "${cur_maj}" != "${major}" || "${cur_min}" != "${minor}" ]]; then
            rm -f "${device_path}"
        fi
    elif [[ -e "${device_path}" ]]; then
        rm -f "${device_path}"
    fi
    if [[ ! -b "${device_path}" ]]; then
        mknod "${device_path}" b "${major}" "${minor}"
    fi
}

create_sparse_image() {
    local path=$1
    local size_bytes=$2
    python3 - "${path}" "${size_bytes}" <<'PY'
import sys

with open(sys.argv[1], "wb") as f:
    f.truncate(int(sys.argv[2]))
PY
}

BOOT_LAYOUT_NAME="asterinas-nixos"
expected_bytes=$((DISK_SIZE_MB * 1024 * 1024))
can_update_in_place=0
boot_layout=""
if [[ "${FORCE}" -eq 0 && -f "${IMAGE}" && -f "${META_FILE}" ]]; then
    existing_bytes=$(stat -c '%s' "${IMAGE}" 2>/dev/null || echo "0")
    existing_key_sha=$(sed -n 's/^SSH_PUBKEY_SHA256=//p' "${META_FILE}" | head -n1 || true)
    existing_layout=$(sed -n 's/^BOOT_LAYOUT=//p' "${META_FILE}" | head -n1 || true)
    if [[ "${existing_bytes}" == "${expected_bytes}" && "${existing_key_sha}" == "${ssh_pubkey_sha256}" ]]; then
        can_update_in_place=1
        boot_layout="${existing_layout:-legacy}"
    fi
fi

build_mode=""
declare -a updated_slots=()

if [[ "${can_update_in_place}" -eq 1 ]]; then
    build_mode="in-place"
    bash "$WORKSPACE/scripts/asterinas/install-kernel.sh" \
        -i "${IMAGE}" \
        -k "${KERNEL_PATH}"
    rec_slots=$(sed -n 's/^KERNEL_SLOTS=//p' "${META_FILE}" | head -n1 || true)
    if [[ -n "${rec_slots}" ]]; then
        IFS=',' read -r -a updated_slots <<<"${rec_slots}"
    fi
else
    build_mode="full"
    boot_layout="${BOOT_LAYOUT_NAME}"
    if [[ -z "${SOURCE_DIR}" ]]; then
        echo "error: --source is required for full NixOS image creation when --kernel is not an Asterinas source tree" >&2
        exit 1
    fi
    if [[ ! -f "${SOURCE_DIR}/VERSION" || ! -f "${SOURCE_DIR}/flake.lock" || ! -d "${SOURCE_DIR}/distro/etc_nixos" || ! -d "${SOURCE_DIR}/distro/aster_nixos_installer" ]]; then
        echo "error: ${SOURCE_DIR} does not look like an Asterinas source tree" >&2
        exit 1
    fi

    actual_version=$(tr -d '[:space:]' <"${SOURCE_DIR}/VERSION")
    if [[ -z "${actual_version}" ]]; then
        echo "error: ${SOURCE_DIR}/VERSION is empty" >&2
        exit 1
    fi
    if [[ "${asterinas_version}" == "unknown" ]]; then
        asterinas_version="${actual_version}"
    fi

    if [[ -d "/root/.nix-profile/bin" && ":$PATH:" != *":/root/.nix-profile/bin:"* ]]; then
        export PATH="/root/.nix-profile/bin:$PATH"
    fi
    if [[ -d "/nix/var/nix/profiles/default/bin" && ":$PATH:" != *":/nix/var/nix/profiles/default/bin:"* ]]; then
        export PATH="/nix/var/nix/profiles/default/bin:$PATH"
    fi

    for cmd in blockdev flock losetup mkfs.exfat mkfs.ext2 mkfs.fat mknod nix-build nix-env nix-instantiate nix-store openssl parted partprobe partx udevadm; do
        require_cmd "${cmd}"
    done

    default_nix="${SOURCE_DIR}/distro/aster_nixos_installer/default.nix"
    nix_kernel_bin_name="asterinas-osdk-bin"
    if [[ -f "${default_nix}" ]] && grep -q 'aster-kernel-osdk-bin' "${default_nix}"; then
        nix_kernel_bin_name="aster-kernel-osdk-bin"
    else
        case "${actual_version}" in
            0.17.* | 0.18.0)
                nix_kernel_bin_name="aster-kernel-osdk-bin"
                ;;
            *)
                nix_kernel_bin_name="asterinas-osdk-bin"
                ;;
        esac
    fi

    # Stage a self-contained copy of distro/ + flake.lock + bzImage in a temporary
    # directory so upstream trees without the ttyS0 console enum patch build cleanly
    # and the Asterinas git worktree stays completely untouched.
    tmp_distro=$(mktemp -d)
    mkdir -p "${tmp_distro}/distro" "${tmp_distro}/target/osdk/iso_root/boot"
    cp -f "${SOURCE_DIR}/flake.lock" "${tmp_distro}/flake.lock"
    cp -f "${SOURCE_DIR}/distro/nixpkgs.nix" "${tmp_distro}/distro/nixpkgs.nix"
    cp -a "${SOURCE_DIR}/distro/aster_nixos_installer" "${tmp_distro}/distro/aster_nixos_installer"
    cp -a "${SOURCE_DIR}/distro/etc_nixos" "${tmp_distro}/distro/etc_nixos"
    cp --reflink=auto "${bzimage_path}" "${tmp_distro}/target/osdk/iso_root/boot/${nix_kernel_bin_name}" 2>/dev/null ||
        cp -f "${bzimage_path}" "${tmp_distro}/target/osdk/iso_root/boot/${nix_kernel_bin_name}"

    # Ensure "ttyS0" is accepted by aster_configuration.nix on unpatched upstream Asterinas.
    python3 - "${tmp_distro}/distro/aster_nixos_installer/templates/aster_configuration.nix" <<'PY'
import pathlib
import re
import sys

p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
if '"ttyS0"' not in text:
    updated, count = re.subn(
        r'(console\s*=\s*lib\.mkOption\s*\{\s*type\s*=\s*lib\.types\.enum\s*\[\s*)',
        r'\1"ttyS0"\n          ',
        text,
        count=1,
    )
    if count == 0:
        print(f"error: failed to locate console enum in {p}", file=sys.stderr)
        sys.exit(1)
    p.write_text(updated, encoding="utf-8")
PY

    ROOT_PASSWORD_HASH=$(openssl rand -hex 32 | openssl passwd -6 -stdin)
    nix_config_base="syzkaller-${actual_version}.nix"
    nix_config="${tmp_distro}/distro/etc_nixos/${nix_config_base}"

    cat >"${nix_config}" <<EOF
{
  config,
  lib,
  pkgs,
  ...
}:
let
  syzkallerDropbear = pkgs.dropbear.override {
    sftpPath = "\${pkgs.openssh}/libexec/sftp-server";
  };
  syzkallerStage1 = pkgs.writeTextFile {
    name = "stage-1-init";
    executable = true;
    text = ''
      #!/bin/sh
      export PATH=/bin

      NEW_ROOT=""
      NEW_INIT=""
      BREAK=""
      ARGS=""

      for arg in "\$@"; do
        case "\$arg" in
          root=*)
            NEW_ROOT=''\${arg#root=}
            ;;
          init=*)
            NEW_INIT=''\${arg#init=}
            ;;
          rd.break=*)
            BREAK=''\${arg#rd.break=}
            ;;
          *)
            ARGS="\$ARGS \$arg"
            ;;
        esac
      done

      if [ "\$BREAK" = "1" ]; then
        echo "Breaking into initramfs shell..."
        exec /bin/sh
      fi

      if [ -z "\$NEW_ROOT" ] || [ -z "\$NEW_INIT" ]; then
        echo "Error: 'root=' and 'init=' parameters are required."
        exit 1
      fi

      mkdir -p /dev
      mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
      mkdir -p /dev/pts
      mount -t devpts devpts /dev/pts 2>/dev/null || true
      chmod 0666 /dev/pts/ptmx 2>/dev/null || true
      ln -sfn pts/ptmx /dev/ptmx 2>/dev/null || true
      mkdir -p /sysroot
      mount -t ext2 "\$NEW_ROOT" /sysroot
      mount -t proc none /sysroot/proc
      mount --move /dev /sysroot/dev
      if [ ! -c /sysroot/dev/console ]; then
        mknod /sysroot/dev/console c 4 64 2>/dev/null || true
      fi

      exec switch_root /sysroot "\$NEW_INIT" \$ARGS
    '';
  };
  syzkallerInitrd = pkgs.runCommand "syzkaller-initrd" {
    nativeBuildInputs = [
      pkgs.cpio
      pkgs.gzip
    ];
  } ''
    root=\$(mktemp -d)
    mkdir -p "\$root/bin" "\$root/dev" "\$root/proc" "\$root/sys" "\$root/sysroot"
    cp \${pkgs.pkgsStatic.busybox}/bin/busybox "\$root/bin/busybox"
    chmod 0755 "\$root/bin/busybox"
    for cmd in sh ash mkdir mount umount chmod ln mknod switch_root cat ls echo sleep; do
      ln -s busybox "\$root/bin/\$cmd"
    done
    cp \${syzkallerStage1} "\$root/init"
    chmod 0755 "\$root/init"
    mkdir -p "\$out"
    (
      cd "\$root"
      find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z | cpio --null -o -H newc --reproducible 2>/dev/null \
        || find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z | cpio --null -o -H newc
    ) | gzip -9 > "\$out/initrd"
  '';
  syzkallerStage2 = pkgs.writeShellScript "syzkaller-stage2" ''
    export HOME=/root
    export PATH=\${lib.makeBinPath [
      pkgs.coreutils
      pkgs.findutils
      pkgs.openssh
      syzkallerDropbear
      pkgs.util-linux
    ]}:/run/current-system/sw/bin:\$PATH

    echo "Configuring Asterinas syzkaller stage 2..."

    mount -n -o remount,rw none / 2>/dev/null || true

    mkdir -p /proc /sys /dev/pts /dev/shm /run /tmp /root/.ssh /etc/dropbear
    chmod 1777 /tmp
    if [ ! -e /proc/mounts ]; then
      mount -t proc proc /proc 2>/dev/null || true
    fi
    if [ ! -e /sys/class ]; then
      mount -t sysfs sysfs /sys 2>/dev/null || true
    fi
    if [ ! -e /dev/pts/ptmx ]; then
      mount -t devpts devpts /dev/pts 2>/dev/null || true
    fi
    mount -t tmpfs -o nosuid,nodev,strictatime,mode=1777 tmpfs /dev/shm 2>/dev/null || mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
    chmod 1777 /dev/shm 2>/dev/null || true
    mount -t tmpfs -o nosuid,nodev,mode=755 tmpfs /run 2>/dev/null || mount -t tmpfs tmpfs /run 2>/dev/null || true
    mkdir -p /run/keys /run/wrappers/bin
    mount -t ramfs -o nosuid,nodev,mode=750 ramfs /run/keys 2>/dev/null || mount -t ramfs ramfs /run/keys 2>/dev/null || true

    mkdir -p /sys/fs/cgroup 2>/dev/null && mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
    mkdir -p /sys/kernel/config 2>/dev/null && mount -t configfs none /sys/kernel/config 2>/dev/null || true

    mkdir -p /run/syz-overlay /mnt/overlay
    mount -t tmpfs -o mode=0755 tmpfs /run/syz-overlay 2>/dev/null || true
    mkdir -p /run/syz-overlay/lower/dir /run/syz-overlay/upper /run/syz-overlay/work
    echo seed > /run/syz-overlay/lower/seed.txt 2>/dev/null || true
    echo lower > /run/syz-overlay/lower/dir/nested.txt 2>/dev/null || true
    chmod -R 0777 /run/syz-overlay/lower /run/syz-overlay/upper 2>/dev/null || true
    mount -t overlay overlay \
      -o lowerdir=/run/syz-overlay/lower,upperdir=/run/syz-overlay/upper,workdir=/run/syz-overlay/work \
      /mnt/overlay 2>/dev/null || true
    chmod 1777 /mnt/overlay 2>/dev/null || true

    for dir in /dev/dri /dev/input; do
      if [ -d "\$dir" ]; then
        chmod 0755 "\$dir" 2>/dev/null || true
      fi
    done
    for dev in /dev/loop* /dev/dri/* /dev/fb0 /dev/input/* /dev/hwrng /dev/hvc0; do
      if [ -e "\$dev" ]; then
        chmod 0666 "\$dev" 2>/dev/null || true
      fi
    done

    systemConfig=\$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || echo /nix/var/nix/profiles/system)
    ln -sfn "\$systemConfig" /run/current-system
    ln -sfn "\$systemConfig" /run/booted-system
    ln -sfn sh /bin/bash
    echo asterinas-syzkaller > /proc/sys/kernel/hostname 2>/dev/null || true

    if [ -e /dev/kcov ]; then
      if mkdir -p /sys/kernel/debug 2>/dev/null; then
        ln -s /dev/kcov /sys/kernel/debug/kcov 2>/dev/null || true
      fi
    fi

    chmod 700 /root/.ssh
    cat > /root/.ssh/authorized_keys <<'AUTHORIZED_KEYS'
${PUBLIC_KEY}
AUTHORIZED_KEYS
    chmod 600 /root/.ssh/authorized_keys

    if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
      dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null
      chmod 600 /etc/dropbear/dropbear_ed25519_host_key
    fi

    trap "" HUP INT QUIT TERM USR1 USR2 PIPE ALRM TSTP TTIN TTOU
    echo "Starting dropbear for syzkaller..."
    while :; do
      (
        trap - HUP INT QUIT TERM USR1 USR2 PIPE ALRM TSTP TTIN TTOU
        exec \${syzkallerDropbear}/bin/dropbear -F -E -p 10.0.2.15:22 -r /etc/dropbear/dropbear_ed25519_host_key -s -g
      ) || true
      sleep 1
    done
  '';
in
{
  imports = [ ./aster_configuration.nix ];

  nixpkgs.overlays = lib.mkForce [ (import ./overlays/systemd/default.nix) ];

  boot.loader.timeout = lib.mkForce 0;

  aster_nixos.disable-systemd = "true";
  aster_nixos.stage-2-hook = "exec \${syzkallerStage2}";

  system.activationScripts.syzkallerDropbearHostKey = lib.stringAfter [ "etc" ] ''
    \${pkgs.coreutils}/bin/mkdir -p /etc/dropbear
    if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
      \${syzkallerDropbear}/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null
      \${pkgs.coreutils}/bin/chmod 600 /etc/dropbear/dropbear_ed25519_host_key
    fi
  '';

  system.systemBuilderCommands = lib.mkAfter ''
    ln -sfn \${syzkallerInitrd}/initrd \$out/initrd
    if [ -e \$out/stage-2-init ]; then
      rm -f \$out/stage-2-init
      ln -s \${syzkallerStage2} \$out/stage-2-init
    else
      rm -f \$out/init
      ln -s \${syzkallerStage2} \$out/init
    fi
  '';

  networking.hostName = "asterinas-syzkaller";
  networking.resolvconf.enable = false;
  environment.etc."resolv.conf".text = ''
    nameserver 8.8.8.8
  '';

  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "${PUBLIC_KEY}"
  ];
  users.users.root.hashedPassword = lib.mkForce "${ROOT_PASSWORD_HASH}";

  environment.systemPackages = with pkgs; [
    coreutils
    findutils
    gdb
    iproute2
    iputils
    openssh
    procps
    strace
    util-linux
  ];

  system.nixos.distroName = "Asterinas NixOS syzkaller";
  system.stateVersion = "26.05";
}
EOF

    NIX_SYSTEM="x86_64-linux"
    if [[ -x "${SOURCE_DIR}/tools/nixos/print_target_nix_system.sh" ]]; then
        NIX_SYSTEM=$("${SOURCE_DIR}/tools/nixos/print_target_nix_system.sh" x86_64)
    fi

    EXTRA_SUBSTITUTERS="${RELEASE_SUBSTITUTER} ${DEV_SUBSTITUTER}"
    EXTRA_TRUSTED_PUBLIC_KEYS="${RELEASE_TRUSTED_PUBLIC_KEY} ${DEV_TRUSTED_PUBLIC_KEY}"
    COMMON_NIX_ARGS=(
        --option extra-substituters "${EXTRA_SUBSTITUTERS}"
        --option extra-trusted-public-keys "${EXTRA_TRUSTED_PUBLIC_KEYS}"
    )

    NIXPKGS_PATH=$(nix-instantiate --eval --raw --expr "builtins.storePath (import ${tmp_distro}/distro/nixpkgs.nix {}).path")
    if command -v nixos-install >/dev/null 2>&1; then
        NIXOS_INSTALL_BIN=$(command -v nixos-install)
    else
        NIXOS_INSTALL_BIN="$(nix-build "${NIXPKGS_PATH}" -A nixos-install "${COMMON_NIX_ARGS[@]}" --no-out-link)/bin/nixos-install"
    fi

    echo "[create-image] building Asterinas NixOS installer derivation ..."
    INSTALLER_OUT=$(nix-build "${tmp_distro}/distro/aster_nixos_installer/default.nix" \
        --argstr target_platform "${NIX_SYSTEM}" \
        --argstr disable-systemd "false" \
        --argstr stage-2-hook "/bin/sh -l" \
        --argstr log-level "error" \
        --argstr console "ttyS0" \
        --argstr config-file-name "${nix_config_base}" \
        --argstr extra-substituters "${EXTRA_SUBSTITUTERS}" \
        --argstr extra-trusted-public-keys "${EXTRA_TRUSTED_PUBLIC_KEYS}" \
        "${COMMON_NIX_ARGS[@]}" \
        --no-out-link)

    echo "[create-image] building NixOS system closure ..."
    SYSTEM_CLOSURE=$(nix-build "${NIXPKGS_PATH}/nixos" -A system \
        --option extra-platforms "${NIX_SYSTEM}" \
        --argstr system "${NIX_SYSTEM}" \
        -I "nixos-config=${INSTALLER_OUT}/etc_nixos/configuration.nix" \
        "${COMMON_NIX_ARGS[@]}" \
        --no-out-link)

    echo "[create-image] creating and partitioning sparse image (${DISK_SIZE_MB} MiB) ..."
    img_tmp="${OUT_DIR}/.asterinas.img.tmp.$$"
    rm -f "${img_tmp}"
    create_sparse_image "${img_tmp}" "${expected_bytes}"

    loop_disk=$(losetup -fP --show "${img_tmp}")
    boot_dev="${loop_disk}p1"
    root_dev="${loop_disk}p2"

    # Clear any stale /dev/loopXpN device nodes from prior container runs before partitioning.
    sync_block_device_node "${boot_dev}"
    sync_block_device_node "${root_dev}"

    exec 9<"${loop_disk}"
    flock -x 9

    parted -s "${loop_disk}" -- mklabel gpt
    parted -s "${loop_disk}" -- mkpart ESP fat32 1MB 512MB
    parted -s "${loop_disk}" -- mkpart root ext2 512MB 100%
    parted -s "${loop_disk}" -- set 1 esp on

    for _ in $(seq 1 20); do
        blockdev --rereadpt "${loop_disk}" 2>/dev/null || true
        partprobe "${loop_disk}" 2>/dev/null || true
        partx -a "${loop_disk}" 2>/dev/null || partx -u "${loop_disk}" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        sync_block_device_node "${boot_dev}"
        sync_block_device_node "${root_dev}"
        if [[ -b "${boot_dev}" && -b "${root_dev}" && -e "/sys/class/block/${boot_dev#/dev/}" && -e "/sys/class/block/${root_dev#/dev/}" ]]; then
            break
        fi
        sleep 0.2
    done
    if [[ ! -b "${boot_dev}" || ! -b "${root_dev}" || ! -e "/sys/class/block/${boot_dev#/dev/}" || ! -e "/sys/class/block/${root_dev#/dev/}" ]]; then
        echo "error: failed to create partition devices ${boot_dev} and ${root_dev}" >&2
        exit 1
    fi

    mkfs.fat -F 32 -n boot "${boot_dev}" >/dev/null
    mkfs.ext2 -F -q -L nixos "${root_dev}" >/dev/null

    tmp_mount_root=$(mktemp -d)
    mount -t ext2 -o sync,dirsync "${root_dev}" "${tmp_mount_root}"
    root_mounted=1
    mkdir -p "${tmp_mount_root}/boot" "${tmp_mount_root}/tmp" "${tmp_mount_root}/etc/nixos"
    chmod 1777 "${tmp_mount_root}/tmp"
    mount -o umask=077,sync,dirsync "${boot_dev}" "${tmp_mount_root}/boot"
    boot_mounted=1
    exec 9<&-

    cp -L "${INSTALLER_OUT}/etc_nixos/configuration.nix" "${tmp_mount_root}/etc/nixos/configuration.nix"
    cp -L "${INSTALLER_OUT}/etc_nixos/aster_configuration.nix" "${tmp_mount_root}/etc/nixos/aster_configuration.nix"
    cp -rL "${INSTALLER_OUT}/etc_nixos/modules" "${tmp_mount_root}/etc/nixos/"
    cp -rL "${INSTALLER_OUT}/etc_nixos/overlays" "${tmp_mount_root}/etc/nixos/"

    echo "[create-image] installing NixOS closure into disk image ..."
    PATH="${PATH}:/run/current-system/sw/bin" \
        "${NIXOS_INSTALL_BIN}" --root "${tmp_mount_root}" --no-root-passwd \
        --system "${SYSTEM_CLOSURE}" \
        "${COMMON_NIX_ARGS[@]}"

    nix-env --store "${tmp_mount_root}" \
        -p "${tmp_mount_root}/nix/var/nix/profiles/system" \
        --delete-generations old
    nix-store --store "${tmp_mount_root}" --gc >/dev/null

    sync
    umount -d "${tmp_mount_root}/boot"
    boot_mounted=0
    umount -d "${tmp_mount_root}"
    root_mounted=0
    losetup -d "${loop_disk}"
    [[ ! -e "/sys/class/block/${boot_dev#/dev/}" ]] && rm -f "${boot_dev}" 2>/dev/null || true
    [[ ! -e "/sys/class/block/${root_dev#/dev/}" ]] && rm -f "${root_dev}" 2>/dev/null || true
    loop_disk=""
    rm -rf "${tmp_mount_root}"
    tmp_mount_root=""
    rm -rf "${tmp_distro}"
    tmp_distro=""

    mv -f "${img_tmp}" "${IMAGE}"
    img_tmp=""
    updated_slots+=("nixos-install:${nix_kernel_bin_name}")
fi

ensure_scratch_disks() {
    if [[ "${FORCE}" -eq 1 || ! -f "${SCRATCH_EXT2}" ]]; then
        if command -v mkfs.ext2 >/dev/null 2>&1; then
            scratch_tmp="${SCRATCH_EXT2}.tmp.$$"
            rm -f "${scratch_tmp}"
            create_sparse_image "${scratch_tmp}" "${SCRATCH_SIZE_BYTES}"
            mkfs.ext2 -b 4096 -F -q "${scratch_tmp}" >/dev/null
            cp --sparse=always -f "${scratch_tmp}" "${SCRATCH_EXT2}"
            rm -f "${scratch_tmp}"
            scratch_tmp=""
        fi
    fi
    if [[ "${FORCE}" -eq 1 || ! -f "${SCRATCH_EXFAT}" ]]; then
        if command -v mkfs.exfat >/dev/null 2>&1; then
            scratch_tmp="${SCRATCH_EXFAT}.tmp.$$"
            rm -f "${scratch_tmp}"
            create_sparse_image "${scratch_tmp}" "${SCRATCH_SIZE_BYTES}"
            mkfs.exfat "${scratch_tmp}" >/dev/null
            cp --sparse=always -f "${scratch_tmp}" "${SCRATCH_EXFAT}"
            rm -f "${scratch_tmp}"
            scratch_tmp=""
        fi
    fi
}

ensure_scratch_disks

joined_slots=$(
    IFS=','
    echo "${updated_slots[*]}"
)

{
    printf 'TIMESTAMP=%s\n' "$(date -u +%FT%TZ)"
    printf 'BUILD_MODE=%s\n' "${build_mode}"
    printf 'BOOT_LAYOUT=%s\n' "${boot_layout}"
    printf 'IMAGE=%s\n' "${IMAGE}"
    printf 'DISK_SIZE_MB=%s\n' "${DISK_SIZE_MB}"
    printf 'SSH_PUBKEY_SHA256=%s\n' "${ssh_pubkey_sha256}"
    printf 'BZIMAGE_PATH=%s\n' "${bzimage_path}"
    printf 'BZIMAGE_SHA256=%s\n' "${bzimage_sha256}"
    printf 'VMLINUX_PATH=%s\n' "${vmlinux_path:-none}"
    printf 'VMLINUX_SHA256=%s\n' "${vmlinux_sha256:-none}"
    printf 'ASTERINAS_VERSION=%s\n' "${asterinas_version}"
    printf 'ASTERINAS_COMMIT=%s\n' "${asterinas_commit}"
    printf 'KCOV=%s\n' "${kernel_kcov}"
    printf 'KASAN=%s\n' "${kernel_kasan}"
    printf 'KERNEL_SLOTS=%s\n' "${joined_slots}"
} >"${META_FILE}"

{
    printf '%s  %s\n' "${bzimage_sha256}" "${bzimage_path}"
    if [[ -n "${vmlinux_path}" && -n "${vmlinux_sha256}" ]]; then
        printf '%s  %s\n' "${vmlinux_sha256}" "${vmlinux_path}"
    fi
} >"${SHA_FILE}"

cat <<EOF
Asterinas syzkaller image is ready (${build_mode}).

Image:    ${IMAGE}
SSH key:  ${SSH_KEY}
Metadata: ${META_FILE}
Digests:  ${SHA_FILE}
EOF
if [[ -f "${SCRATCH_EXT2}" ]]; then
    echo "Ext2:     ${SCRATCH_EXT2}"
fi
if [[ -f "${SCRATCH_EXFAT}" ]]; then
    echo "ExFAT:    ${SCRATCH_EXFAT}"
fi
if [[ -n "${vmlinux_path}" ]]; then
    echo "vmlinux:  ${vmlinux_path}"
fi
