#!/usr/bin/env bash

# Install a freshly built Asterinas kernel (bzImage from scripts/asterinas/build.sh)
# into an Asterinas NixOS raw disk image (ESP + ext2 rootfs partitions) on the host.
#
# Because QEMU boots Asterinas via OVMF UEFI from the GPT disk image rather than
# -kernel, the rebuilt bzImage must be installed into the image before booting
# with scripts/asterinas/qemu.sh or syz-crush.
#
# Prefer passing -o / --output (or ASTERINAS_OVERLAY=repro/asterinas-test.img)
# so the base image under image/asterinas/ remains untouched.
#
# usage:
#   # Install into a sparse copy (leaves base image untouched):
#   scripts/asterinas/install-kernel.sh \
#       -i image/asterinas/asterinas.img \
#       -o repro/asterinas-test.img
#
#   # Install in-place into an existing image:
#   scripts/asterinas/install-kernel.sh -i repro/asterinas-test.img

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

IMAGE="${ASTERINAS_IMAGE:-$WORKSPACE/image/asterinas/asterinas.img}"
OUTPUT="${ASTERINAS_OVERLAY:-}"
KERNEL_PATH="${ASTERINAS_SRC:-$WORKSPACE/kernel/asterinas}"
FORCE=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -i, --image FILE     Base Asterinas raw disk image (default: $IMAGE)
  -o, --output FILE    Target raw disk image copy to create/update, leaving --image
                       untouched (default: ${OUTPUT:-none, updates --image in-place})
  -f, --force          With -o/--output, re-copy --image to --output before installing
  -k, --kernel PATH    Built Asterinas source dir or bzImage file (default: $KERNEL_PATH)
  -h, --help           Show this help
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
        -i | --image)
            need_arg "$1" "${2-}"
            IMAGE="$2"
            shift 2
            ;;
        -o | --output)
            need_arg "$1" "${2-}"
            OUTPUT="$2"
            shift 2
            ;;
        -f | --force)
            FORCE=1
            shift
            ;;
        -k | --kernel)
            need_arg "$1" "${2-}"
            KERNEL_PATH="$2"
            shift 2
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

for cmd in cp losetup mknod mount python3 realpath sha256sum stat sync umount; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: missing required command: $cmd" >&2
        exit 1
    fi
done

if [[ ! -f "$IMAGE" ]]; then
    echo "error: base image '$IMAGE' does not exist" >&2
    exit 1
fi
if [[ ! -e "$KERNEL_PATH" ]]; then
    echo "error: kernel path '$KERNEL_PATH' does not exist; run 'make asterinas' first" >&2
    exit 1
fi

base_image=$(realpath "$IMAGE")
kernel_abs=$(realpath "$KERNEL_PATH")

if [[ -d "$kernel_abs" ]]; then
    kernel_dir="$kernel_abs"
    bzimage_path="$kernel_dir/bzImage"
    if [[ ! -f "$bzimage_path" ]]; then
        echo "error: '$bzimage_path' does not exist; run 'make asterinas' first" >&2
        exit 1
    fi
else
    bzimage_path="$kernel_abs"
    kernel_dir=$(dirname "$kernel_abs")
fi

vmlinux_path=""
manifest_path=""
build_record_path=""
[[ -f "$kernel_dir/vmlinux" ]] && vmlinux_path="$kernel_dir/vmlinux"
[[ -f "$kernel_dir/images.sha256" ]] && manifest_path="$kernel_dir/images.sha256"
[[ -f "$kernel_dir/build-record.txt" ]] && build_record_path="$kernel_dir/build-record.txt"

python3 - "$bzimage_path" <<'PY'
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    hdr = f.read(0x206)
if len(hdr) < 0x206 or hdr[0x1FE:0x200] != b"\x55\xaa" or hdr[0x202:0x206] != b"HdrS":
    print(f"error: not a valid Linux x86 bzImage (missing 0x55aa/HdrS header): {path}", file=sys.stderr)
    sys.exit(1)
PY

bzimage_sha256=$(sha256sum "$bzimage_path" | awk '{print $1}')
vmlinux_sha256=""
if [[ -n "$vmlinux_path" ]]; then
    vmlinux_sha256=$(sha256sum "$vmlinux_path" | awk '{print $1}')
fi

if [[ -n "$manifest_path" ]]; then
    python3 - "$manifest_path" "$bzimage_path" "$bzimage_sha256" "$vmlinux_path" "$vmlinux_sha256" <<'PY'
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

if [[ -n "$OUTPUT" ]]; then
    target_image=$(realpath -m "$OUTPUT")
    if [[ "$target_image" == "$base_image" ]]; then
        echo "error: --output must differ from --image" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$target_image")"
    if [[ "$FORCE" -eq 1 || ! -f "$target_image" ]]; then
        echo "[install-kernel] copying base image to $target_image (sparse/reflink) ..."
        rm -f "$target_image"
        cp --reflink=auto --sparse=always "$base_image" "$target_image"
    fi
else
    target_image="$base_image"
fi

loop_disk=""
tmp_mount_root=""
esp_mounted=0
root_mounted=0

cleanup() {
    if [[ "$esp_mounted" -eq 1 && -n "$tmp_mount_root" ]]; then
        umount "$tmp_mount_root/esp" 2>/dev/null || true
    fi
    if [[ "$root_mounted" -eq 1 && -n "$tmp_mount_root" ]]; then
        umount "$tmp_mount_root/root" 2>/dev/null || true
    fi
    if [[ -n "$loop_disk" ]]; then
        local bdev="${loop_disk}p1"
        local rdev="${loop_disk}p2"
        losetup -d "$loop_disk" 2>/dev/null || true
        [[ ! -e "/sys/class/block/${bdev#/dev/}" ]] && rm -f "$bdev" 2>/dev/null || true
        [[ ! -e "/sys/class/block/${rdev#/dev/}" ]] && rm -f "$rdev" 2>/dev/null || true
    fi
    if [[ -n "$tmp_mount_root" && -d "$tmp_mount_root" ]]; then
        rm -rf "$tmp_mount_root"
    fi
}
trap cleanup EXIT

sync_block_device_node() {
    local device_path=$1
    local device_name=${device_path#/dev/}
    local sysfs_dev="/sys/class/block/${device_name}/dev"
    if [[ ! -r "$sysfs_dev" ]]; then
        if [[ -b "$device_path" ]]; then
            rm -f "$device_path"
        fi
        return 0
    fi
    local major minor
    IFS=: read -r major minor <"$sysfs_dev"
    if [[ -b "$device_path" ]]; then
        local cur_maj cur_min
        cur_maj=$((16#$(stat -c '%t' "$device_path")))
        cur_min=$((16#$(stat -c '%T' "$device_path")))
        if [[ "$cur_maj" != "$major" || "$cur_min" != "$minor" ]]; then
            rm -f "$device_path"
        fi
    elif [[ -e "$device_path" ]]; then
        rm -f "$device_path"
    fi
    if [[ ! -b "$device_path" ]]; then
        mknod "$device_path" b "$major" "$minor"
    fi
}

overwrite_slot_and_verify() {
    local src=$1
    local dst=$2
    local expected_sha=$3
    local orig_mode
    orig_mode=$(stat -c '%a' "$dst" 2>/dev/null || echo "")
    chmod u+w "$dst" 2>/dev/null || true
    cp -f "$src" "$dst"
    if [[ -n "$orig_mode" ]]; then
        chmod "$orig_mode" "$dst" 2>/dev/null || true
    fi
    local actual_sha
    actual_sha=$(sha256sum "$dst" | awk '{print $1}')
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "error: verification failed after writing $dst: expected $expected_sha, got $actual_sha" >&2
        exit 1
    fi
}

tmp_mount_root=$(mktemp -d)
mkdir -p "$tmp_mount_root/esp" "$tmp_mount_root/root"

loop_disk=$(losetup -fP --show "$target_image")
boot_dev="${loop_disk}p1"
root_dev="${loop_disk}p2"

for _ in $(seq 1 20); do
    blockdev --rereadpt "$loop_disk" 2>/dev/null || true
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$loop_disk" 2>/dev/null || true
    fi
    if command -v partx >/dev/null 2>&1; then
        partx -a "$loop_disk" 2>/dev/null || partx -u "$loop_disk" 2>/dev/null || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>/dev/null || true
    fi
    sync_block_device_node "$boot_dev"
    sync_block_device_node "$root_dev"
    if [[ -b "$boot_dev" && -b "$root_dev" && -e "/sys/class/block/${boot_dev#/dev/}" && -e "/sys/class/block/${root_dev#/dev/}" ]]; then
        break
    fi
    sleep 0.2
done

if [[ ! -b "$boot_dev" || ! -b "$root_dev" || ! -e "/sys/class/block/${boot_dev#/dev/}" || ! -e "/sys/class/block/${root_dev#/dev/}" ]]; then
    echo "error: failed to expose GPT partitions ($boot_dev, $root_dev) for $target_image" >&2
    exit 1
fi

declare -a updated_slots=()

mount "$boot_dev" "$tmp_mount_root/esp"
esp_mounted=1
rm -f "$tmp_mount_root/esp/NvVars"

shopt -s nullglob
esp_candidates=(
    "$tmp_mount_root/esp/kernels/"*-asterinas-osdk-bin
    "$tmp_mount_root/esp/kernels/"*-aster-kernel-osdk-bin
)
esp_hits=0
for slot in "${esp_candidates[@]}"; do
    if [[ -f "$slot" && ! -L "$slot" ]]; then
        overwrite_slot_and_verify "$bzimage_path" "$slot" "$bzimage_sha256"
        updated_slots+=("esp:${slot#"$tmp_mount_root/esp"}")
        esp_hits=$((esp_hits + 1))
    fi
done
if [[ "$esp_hits" -eq 0 ]]; then
    echo "error: no Asterinas kernel slot found on ESP partition of $target_image" >&2
    exit 1
fi

mount "$root_dev" "$tmp_mount_root/root"
root_mounted=1
root_candidates=(
    "$tmp_mount_root/root/nix/store/"*-asterinas-osdk-bin
    "$tmp_mount_root/root/nix/store/"*-aster-kernel-osdk-bin
    "$tmp_mount_root/root/nix/store/"*-asterinas-osdk-bin/bzImage
    "$tmp_mount_root/root/nix/store/"*-aster-kernel-osdk-bin/bzImage
)
root_hits=0
for slot in "${root_candidates[@]}"; do
    if [[ -f "$slot" && ! -L "$slot" ]]; then
        overwrite_slot_and_verify "$bzimage_path" "$slot" "$bzimage_sha256"
        updated_slots+=("rootfs:${slot#"$tmp_mount_root/root"}")
        root_hits=$((root_hits + 1))
    fi
done
shopt -u nullglob
if [[ "$root_hits" -eq 0 ]]; then
    echo "error: no Asterinas kernel slot found on ext2 rootfs of $target_image" >&2
    exit 1
fi

sync
umount "$tmp_mount_root/root"
root_mounted=0
umount "$tmp_mount_root/esp"
esp_mounted=0
losetup -d "$loop_disk"
[[ ! -e "/sys/class/block/${boot_dev#/dev/}" ]] && rm -f "$boot_dev" 2>/dev/null || true
[[ ! -e "/sys/class/block/${root_dev#/dev/}" ]] && rm -f "$root_dev" 2>/dev/null || true
loop_disk=""
rm -rf "$tmp_mount_root"
tmp_mount_root=""

asterinas_version="unknown"
asterinas_commit="unknown"
kernel_kcov="unknown"
kernel_kasan="unknown"
if [[ -n "$build_record_path" ]]; then
    rec_ver=$(sed -n 's/^Asterinas version: //p' "$build_record_path" | head -n1 || true)
    rec_commit=$(sed -n 's/^Asterinas commit: //p' "$build_record_path" | head -n1 || true)
    rec_instr=$(grep -m1 '^KCOV=' "$build_record_path" || true)
    [[ -n "$rec_ver" ]] && asterinas_version="$rec_ver"
    [[ -n "$rec_commit" ]] && asterinas_commit="$rec_commit"
    if [[ "$rec_instr" =~ KCOV=([01])[[:space:]]+KASAN=([01]) ]]; then
        kernel_kcov="${BASH_REMATCH[1]}"
        kernel_kasan="${BASH_REMATCH[2]}"
    fi
fi

joined_slots=$(
    IFS=','
    echo "${updated_slots[*]}"
)

if [[ -n "$OUTPUT" ]]; then
    meta_file="${target_image}.meta"
else
    meta_file="$(dirname "$target_image")/image-meta.txt"
    sha_file="$(dirname "$target_image")/kernel.sha256"
    {
        printf '%s  %s\n' "$bzimage_sha256" "$bzimage_path"
        if [[ -n "$vmlinux_path" && -n "$vmlinux_sha256" ]]; then
            printf '%s  %s\n' "$vmlinux_sha256" "$vmlinux_path"
        fi
    } >"$sha_file"
fi

{
    printf 'TIMESTAMP=%s\n' "$(date -u +%FT%TZ)"
    printf 'BASE_IMAGE=%s\n' "$base_image"
    printf 'IMAGE=%s\n' "$target_image"
    printf 'BZIMAGE_PATH=%s\n' "$bzimage_path"
    printf 'BZIMAGE_SHA256=%s\n' "$bzimage_sha256"
    printf 'VMLINUX_PATH=%s\n' "${vmlinux_path:-none}"
    printf 'VMLINUX_SHA256=%s\n' "${vmlinux_sha256:-none}"
    printf 'ASTERINAS_VERSION=%s\n' "$asterinas_version"
    printf 'ASTERINAS_COMMIT=%s\n' "$asterinas_commit"
    printf 'KCOV=%s\n' "$kernel_kcov"
    printf 'KASAN=%s\n' "$kernel_kasan"
    printf 'KERNEL_SLOTS=%s\n' "$joined_slots"
} >"$meta_file"

echo "[install-kernel] installed $bzimage_path ($bzimage_sha256) into $target_image"
echo "[install-kernel] updated slots: $joined_slots"
