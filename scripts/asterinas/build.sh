#!/usr/bin/env bash

# Build the Asterinas kernel (bzImage and matching unstripped vmlinux) from an
# Asterinas TOML build configuration file.
#
# usage:
#   scripts/asterinas/build.sh [-s <SOURCEDIR>] [-c <CONFIG>]

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

SOURCE_DIR="${ASTERINAS_SRC:-$WORKSPACE/kernel/asterinas}"
if [[ -n "${ASTERINAS_CONFIG:-}" ]]; then
    CONFIG_FILE="$ASTERINAS_CONFIG"
else
    CONFIG_FILE="$WORKSPACE/config/asterinas/asterinas.toml"
fi
ARCH_CLI=""
LOG_LEVEL_CLI=""
JOBS_CLI="${JOBS:-}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -s, --sourcedir, --source DIR  Asterinas source tree (default: $SOURCE_DIR)
  -c, --config FILE              Asterinas TOML build config (default: $CONFIG_FILE)
      --arch ARCH                Target architecture: x86_64 (default: config arch or x86_64)
      --log-level LEVEL          Override kernel cmdline loglevel= (error|warn|info|debug|trace)
  -j, --jobs N                   Max parallel Cargo build jobs
  -h, --help                     Show this help

Outputs written to SOURCEDIR:
  bzImage            Bootable Linux EFI64 bzImage for install-kernel.sh / create-image.sh
  vmlinux            Matching unstripped kernel ELF with symbols and debug info
  build-record.txt   Build provenance, config digest, and exact command
  build.log          Full kernel build output log
  kernel.diff        Working-tree diff against HEAD (when SOURCEDIR is a git repo)
  images.sha256      SHA-256 manifest for vmlinux and bzImage
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
        -s | --sourcedir | --source)
            need_arg "$1" "${2-}"
            SOURCE_DIR="$2"
            shift 2
            ;;
        -c | --config)
            need_arg "$1" "${2-}"
            CONFIG_FILE="$2"
            shift 2
            ;;
        --arch)
            need_arg "$1" "${2-}"
            ARCH_CLI="$2"
            shift 2
            ;;
        --log-level)
            need_arg "$1" "${2-}"
            LOG_LEVEL_CLI="$2"
            shift 2
            ;;
        --log-level=*)
            LOG_LEVEL_CLI="${1#--log-level=}"
            shift
            ;;
        -j | --jobs)
            need_arg "$1" "${2-}"
            JOBS_CLI="$2"
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

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "error: Asterinas source directory not found: $SOURCE_DIR" >&2
    exit 1
fi
source_dir=$(realpath "$SOURCE_DIR")
if [[ ! -f "$source_dir/VERSION" || ! -f "$source_dir/osdk/Cargo.toml" || ! -f "$source_dir/kernel/Cargo.toml" ]]; then
    echo "error: $source_dir does not look like an Asterinas source tree" >&2
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "error: Asterinas build config not found: $CONFIG_FILE" >&2
    exit 1
fi
config_file=$(realpath "$CONFIG_FILE")

command -v python3 >/dev/null || {
    echo "error: required tool not found: python3" >&2
    exit 1
}

parse_asterinas_config() {
    python3 - "$config_file" "$ARCH_CLI" "$LOG_LEVEL_CLI" <<'PY'
import pathlib
import re
import sys
import tomllib

cfg_path = pathlib.Path(sys.argv[1])
arch_cli = sys.argv[2]
log_level_cli = sys.argv[3]

SUPPORTED_ARCHES = ("x86_64",)
SUPPORTED_BOOT_METHODS = ("vmm-direct", "qemu-direct", "grub-rescue-iso", "grub-qcow2")
SUPPORTED_BOOT_PROTOCOLS = ("linux", "multiboot", "multiboot2")

TOP_SCALAR_KEYS = {"rust_toolchain", "lto"}
INSTR_KEYS = {"kcov", "kasan"}
BUILD_KEYS = {
    "profile",
    "features",
    "no_default_features",
    "strip_elf",
    "linux_x86_legacy_boot",
    "override_configs",
}
BOOT_KEYS = {"method", "kcmd_args"}
GRUB_KEYS = {"boot_protocol", "grub_mkrescue"}
ARCH_SCALAR_KEYS = {
    "rust_toolchain",
    "lto",
    "kcov",
    "kasan",
    "ostd_task_stack_size_in_pages",
}
ARCH_TABLE_KEYS = ARCH_SCALAR_KEYS | {"build", "boot", "grub"}
TOP_KEYS = TOP_SCALAR_KEYS | INSTR_KEYS | {"arch", "instrumentation", "build", "boot", "grub"}


def die(msg: str) -> None:
    print(f"{cfg_path}: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_flag(val, key: str) -> int:
    if isinstance(val, bool):
        return 1 if val else 0
    if isinstance(val, int) and val in (0, 1):
        return val
    die(f"'{key}' must be boolean (true/false) or 0/1")


def parse_str(val, key: str, allow_empty: bool = False) -> str:
    if not isinstance(val, str) or "\0" in val or "\n" in val or "\r" in val:
        die(f"'{key}' must be a single-line string")
    if not allow_empty and not val.strip():
        die(f"'{key}' must not be empty")
    return val


def parse_pos_int(val, key: str) -> int:
    if isinstance(val, bool) or not isinstance(val, int) or val <= 0:
        die(f"'{key}' must be a positive integer")
    return val


def parse_features(val, key: str) -> list[str]:
    if isinstance(val, str):
        tokens = val.replace(",", " ").split()
    elif isinstance(val, list) and all(isinstance(x, str) for x in val):
        tokens = []
        for item in val:
            tokens.extend(item.replace(",", " ").split())
    else:
        die(f"'{key}' must be a list of strings or a feature string")
    for tok in tokens:
        if any(c in tok for c in ("\0", "\n", "\r")) or not re.fullmatch(r"[A-Za-z0-9_/-]+", tok):
            die(f"'{key}' contains invalid feature token: {tok!r}")
    return tokens


def parse_str_list(val, key: str) -> list[str]:
    if not isinstance(val, list) or not all(isinstance(x, str) for x in val):
        die(f"'{key}' must be a list of strings")
    items = []
    for idx, item in enumerate(val):
        items.append(parse_str(item, f"{key}[{idx}]"))
    return items


try:
    with cfg_path.open("rb") as f:
        data = tomllib.load(f)
except tomllib.TOMLDecodeError as exc:
    die(f"invalid TOML syntax: {exc}")

if not isinstance(data, dict):
    die("root configuration must be a TOML table")

unknown_top = sorted(set(data.keys()) - TOP_KEYS)
if unknown_top:
    die(f"unknown top-level key(s): {', '.join(unknown_top)}")

instr_tbl = data.get("instrumentation", {})
if not isinstance(instr_tbl, dict):
    die("[instrumentation] must be a TOML table")
unknown_instr = sorted(set(instr_tbl.keys()) - INSTR_KEYS)
if unknown_instr:
    die(f"unknown [instrumentation] key(s): {', '.join(unknown_instr)}")
for k in INSTR_KEYS:
    if k in data and k in instr_tbl:
        die(f"'{k}' specified both at top level and under [instrumentation]")

build_tbl = data.get("build", {})
if not isinstance(build_tbl, dict):
    die("[build] must be a TOML table")
unknown_build = sorted(set(build_tbl.keys()) - BUILD_KEYS)
if unknown_build:
    die(f"unknown [build] key(s): {', '.join(unknown_build)}")

boot_tbl = data.get("boot", {})
if not isinstance(boot_tbl, dict):
    die("[boot] must be a TOML table")
unknown_boot = sorted(set(boot_tbl.keys()) - BOOT_KEYS)
if unknown_boot:
    die(f"unknown [boot] key(s): {', '.join(unknown_boot)}")

grub_tbl = data.get("grub", {})
if not isinstance(grub_tbl, dict):
    die("[grub] must be a TOML table")
unknown_grub = sorted(set(grub_tbl.keys()) - GRUB_KEYS)
if unknown_grub:
    die(f"unknown [grub] key(s): {', '.join(unknown_grub)}")

arch_tbl_all = data.get("arch", {})
if isinstance(arch_tbl_all, str):
    target_arch_default = arch_tbl_all
    arch_tables = {}
elif isinstance(arch_tbl_all, dict):
    target_arch_default = "x86_64"
    unknown_arches = sorted(set(arch_tbl_all.keys()) - set(SUPPORTED_ARCHES))
    if unknown_arches:
        die(f"unsupported [arch.*] table(s): {', '.join(unknown_arches)}")
    arch_tables = arch_tbl_all
else:
    die("'arch' must be an architecture string or [arch.<name>] table(s)")

arch = arch_cli or target_arch_default
if arch not in SUPPORTED_ARCHES:
    die(f"Asterinas build supports ARCH=x86_64 (got '{arch}')")

arch_cfg = arch_tables.get(arch, {})
if not isinstance(arch_cfg, dict):
    die(f"[arch.{arch}] must be a TOML table")
unknown_arch_keys = sorted(set(arch_cfg.keys()) - ARCH_TABLE_KEYS)
if unknown_arch_keys:
    die(f"unknown [arch.{arch}] key(s): {', '.join(unknown_arch_keys)}")

merged_top = {}
for k in TOP_SCALAR_KEYS:
    if k in data:
        merged_top[k] = data[k]
for k in INSTR_KEYS:
    if k in data:
        merged_top[k] = data[k]
    elif k in instr_tbl:
        merged_top[k] = instr_tbl[k]

merged_build = dict(build_tbl)
merged_boot = dict(boot_tbl)
merged_grub = dict(grub_tbl)

for k in ARCH_SCALAR_KEYS:
    if k in arch_cfg:
        merged_top[k] = arch_cfg[k]

for sub_name, sub_allowed, target in (
    ("build", BUILD_KEYS, merged_build),
    ("boot", BOOT_KEYS, merged_boot),
    ("grub", GRUB_KEYS, merged_grub),
):
    if sub_name in arch_cfg:
        sub_val = arch_cfg[sub_name]
        if not isinstance(sub_val, dict):
            die(f"[arch.{arch}.{sub_name}] must be a TOML table")
        unknown_sub = sorted(set(sub_val.keys()) - sub_allowed)
        if unknown_sub:
            die(f"unknown [arch.{arch}.{sub_name}] key(s): {', '.join(unknown_sub)}")
        if sub_name == "build" and "features" in sub_val and "features" in target:
            merged_feats = parse_features(target["features"], "build.features")
            merged_feats.extend(parse_features(sub_val["features"], f"arch.{arch}.build.features"))
            target.update(sub_val)
            target["features"] = merged_feats
        else:
            target.update(sub_val)

rust_toolchain = (
    parse_str(merged_top["rust_toolchain"], "rust_toolchain")
    if "rust_toolchain" in merged_top
    else ""
)
lto = parse_flag(merged_top.get("lto", False), "lto")
kcov = parse_flag(merged_top.get("kcov", False), "kcov")
kasan = parse_flag(merged_top.get("kasan", False), "kasan")
ostd_stack_pages = parse_pos_int(
    merged_top.get("ostd_task_stack_size_in_pages", 64),
    "ostd_task_stack_size_in_pages",
)

profile = parse_str(merged_build.get("profile", "dev"), "build.profile")
if not re.fullmatch(r"[A-Za-z0-9_-]+", profile):
    die(f"'build.profile' contains invalid characters: {profile!r}")
features = parse_features(merged_build.get("features", []), "build.features")
features = list(dict.fromkeys(features))
no_default_features = parse_flag(
    merged_build.get("no_default_features", False),
    "build.no_default_features",
)
strip_elf = parse_flag(merged_build.get("strip_elf", False), "build.strip_elf")
linux_x86_legacy_boot = parse_flag(
    merged_build.get("linux_x86_legacy_boot", False),
    "build.linux_x86_legacy_boot",
)
override_configs = parse_str_list(
    merged_build.get("override_configs", []),
    "build.override_configs",
)
for item in override_configs:
    if "=" not in item:
        die(f"'build.override_configs' entry must be KEY=VALUE (got {item!r})")
    if lto == 0 or kcov == 1 or kasan == 1:
        try:
            parsed_ov = tomllib.loads(item)
        except tomllib.TOMLDecodeError:
            key, val = item.split("=", 1)
            if re.fullmatch(r"profile\.[^.]+\.lto", key.strip()) and val.strip().strip("\"'").lower() not in ("false", "off"):
                die(
                    f"'build.override_configs' must not enable LTO ({item!r}) "
                    "when 'lto' is false or 'kcov'/'kasan' is enabled"
                )
            parsed_ov = {}
        prof_tbl = parsed_ov.get("profile")
        if isinstance(prof_tbl, dict):
            for prof_name, prof_cfg in prof_tbl.items():
                if isinstance(prof_cfg, dict) and "lto" in prof_cfg:
                    lto_val = prof_cfg["lto"]
                    if lto_val not in (False, "off"):
                        die(
                            f"'build.override_configs' must not enable LTO "
                            f"(profile.{prof_name}.lto={lto_val!r}) when 'lto' is false or 'kasan'/'kcov' is enabled"
                        )

boot_method = parse_str(merged_boot.get("method", "vmm-direct"), "boot.method")
if boot_method not in SUPPORTED_BOOT_METHODS:
    die(
        f"'boot.method' must be one of {', '.join(SUPPORTED_BOOT_METHODS)} "
        f"(got '{boot_method}')"
    )
kcmd_args = parse_str_list(
    merged_boot.get("kcmd_args", ["loglevel=error", "earlycon", "console=ttyS0"]),
    "boot.kcmd_args",
)
if log_level_cli:
    if log_level_cli not in ("error", "warn", "info", "debug", "trace", "off"):
        die(f"--log-level must be one of error, warn, info, debug, trace, off (got {log_level_cli!r})")
    replaced = False
    for idx, item in enumerate(kcmd_args):
        if item.startswith("loglevel="):
            kcmd_args[idx] = f"loglevel={log_level_cli}"
            replaced = True
    if not replaced:
        kcmd_args.insert(0, f"loglevel={log_level_cli}")

boot_protocol = parse_str(merged_grub.get("boot_protocol", "linux"), "grub.boot_protocol")
if boot_protocol not in SUPPORTED_BOOT_PROTOCOLS:
    die(
        f"'grub.boot_protocol' must be one of {', '.join(SUPPORTED_BOOT_PROTOCOLS)} "
        f"(got '{boot_protocol}')"
    )
grub_mkrescue = (
    parse_str(merged_grub["grub_mkrescue"], "grub.grub_mkrescue")
    if "grub_mkrescue" in merged_grub
    else ""
)

if (kcov == 1 or kasan == 1) and (lto == 1 or profile == "release-lto"):
    die("'lto' must be false and 'build.profile' must not be 'release-lto' when 'kcov' or 'kasan' is enabled")
if boot_protocol != "linux":
    die("'grub.boot_protocol' must be 'linux' to produce a NixOS-bootable bzImage")

fields = [
    arch,
    rust_toolchain,
    str(lto),
    str(kcov),
    str(kasan),
    str(ostd_stack_pages),
    profile,
    ",".join(features),
    str(no_default_features),
    str(strip_elf),
    str(linux_x86_legacy_boot),
    boot_method,
    boot_protocol,
    grub_mkrescue,
    str(len(kcmd_args)),
    *kcmd_args,
    str(len(override_configs)),
    *override_configs,
]
sys.stdout.buffer.write("\0".join(fields).encode("utf-8") + b"\0")
PY
}

cfg_tmp=$(mktemp)
cargo_shim_dir=""
cleanup() {
    rm -f "${cfg_tmp:-}"
    if [[ -n "${cargo_shim_dir:-}" && -d "${cargo_shim_dir}" ]]; then
        rm -rf "${cargo_shim_dir}"
    fi
}
trap cleanup EXIT

parse_asterinas_config >"$cfg_tmp"
mapfile -d '' -t cfg_fields <"$cfg_tmp"
rm -f "$cfg_tmp"
cfg_tmp=""

arch=${cfg_fields[0]}
rust_toolchain=${cfg_fields[1]}
lto=${cfg_fields[2]}
kcov=${cfg_fields[3]}
kasan=${cfg_fields[4]}
ostd_stack_pages=${cfg_fields[5]}
profile=${cfg_fields[6]}
extra_features=${cfg_fields[7]}
no_default_features=${cfg_fields[8]}
strip_elf=${cfg_fields[9]}
linux_x86_legacy_boot=${cfg_fields[10]}
boot_method=${cfg_fields[11]}
boot_protocol=${cfg_fields[12]}
grub_mkrescue_cfg=${cfg_fields[13]}
kcmd_count=${cfg_fields[14]}
kcmd_args=("${cfg_fields[@]:15:$kcmd_count}")
override_offset=$((15 + kcmd_count))
override_count=${cfg_fields[$override_offset]}
override_configs=("${cfg_fields[@]:$((override_offset + 1)):$override_count}")

out="$source_dir"
actual_version=$(tr -d '[:space:]' <"$source_dir/VERSION")
if [[ -z "$actual_version" ]]; then
    echo "error: $source_dir/VERSION is empty" >&2
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1 && [[ -x "${HOME:-/root}/.cargo/bin/cargo" ]]; then
    export PATH="${HOME:-/root}/.cargo/bin:${PATH}"
fi
for cmd in cargo readelf sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: required tool not found: $cmd" >&2
        exit 1
    fi
done
if [[ "$strip_elf" == "1" ]]; then
    if ! command -v rust-strip >/dev/null 2>&1 && [[ -x "${HOME:-/root}/.cargo/bin/rust-strip" ]]; then
        export PATH="${HOME:-/root}/.cargo/bin:${PATH}"
    fi
    if ! command -v rust-strip >/dev/null 2>&1; then
        echo "error: required tool not found for build.strip_elf=true: rust-strip (install cargo-binutils)" >&2
        exit 1
    fi
fi

if [[ -z "${VDSO_LIBRARY_DIR:-}" ]]; then
    for vdso_cand in "/root/linux_vdso" "${HOME:-/root}/linux_vdso" "/usr/local/share/asterinas/vdso"; do
        if [[ -f "${vdso_cand}/vdso_${arch}.so" ]]; then
            export VDSO_LIBRARY_DIR="$vdso_cand"
            break
        fi
    done
fi
if [[ -z "${VDSO_LIBRARY_DIR:-}" ]]; then
    echo "error: VDSO_LIBRARY_DIR is required to build Asterinas" >&2
    exit 1
fi
if [[ ! -f "${VDSO_LIBRARY_DIR}/vdso_${arch}.so" ]]; then
    echo "error: VDSO_LIBRARY_DIR does not contain vdso_${arch}.so: ${VDSO_LIBRARY_DIR}" >&2
    exit 1
fi

if [[ "$kasan" == "1" && ! -f "$source_dir/ostd/src/mm/kasan.rs" ]]; then
    echo "error: KASAN is enabled in $config_file, but $source_dir/ostd/src/mm/kasan.rs is missing." >&2
    echo "hint: apply the Asterinas KASAN patch or set kasan = false under [instrumentation] in $config_file." >&2
    exit 1
fi
if [[ "$kcov" == "1" || "$kasan" == "1" ]]; then
    if [[ ! -x "$source_dir/tools/kcov-rustc.sh" ]]; then
        echo "error: missing executable $source_dir/tools/kcov-rustc.sh for KCOV/KASAN instrumentation." >&2
        echo "hint: apply the Asterinas KCOV/KASAN patches for v${actual_version} or disable kcov/kasan in $config_file." >&2
        exit 1
    fi
    if [[ -n "${RUSTC_WRAPPER:-}" || -n "${RUSTC_WORKSPACE_WRAPPER:-}" ]]; then
        echo "error: KCOV/KASAN require exclusive use of RUSTC_WRAPPER; unset RUSTC_WRAPPER/RUSTC_WORKSPACE_WRAPPER" >&2
        exit 1
    fi
fi

grub_mkrescue_bin=""
if [[ "$boot_method" == "grub-rescue-iso" || "$boot_method" == "grub-qcow2" ]]; then
    if [[ -n "$grub_mkrescue_cfg" ]]; then
        grub_mkrescue_bin="$grub_mkrescue_cfg"
    elif [[ -x /usr/bin/grub-mkrescue ]]; then
        grub_mkrescue_bin="/usr/bin/grub-mkrescue"
    else
        grub_mkrescue_bin=$(command -v grub-mkrescue || true)
    fi
    if [[ -z "$grub_mkrescue_bin" || ! -x "$grub_mkrescue_bin" ]]; then
        echo "error: boot.method=$boot_method requires grub-mkrescue" >&2
        exit 1
    fi
fi

if [[ -n "$rust_toolchain" ]] && [[ -z "${RUSTUP_TOOLCHAIN:-}" ]] && command -v rustup >/dev/null 2>&1; then
    if rustup toolchain list | grep -q "^${rust_toolchain}"; then
        export RUSTUP_TOOLCHAIN="$rust_toolchain"
    else
        echo "note: configured rust_toolchain '$rust_toolchain' not found via rustup; using active rustc" >&2
    fi
fi

case "$actual_version" in
    0.17.* | 0.18.0)
        kernel_pkg_name="aster-kernel"
        ;;
    *)
        kernel_pkg_name="asterinas"
        ;;
esac
kernel_bin_name="${kernel_pkg_name}-osdk-bin"

if [[ "$actual_version" == "0.17.1" && "$boot_method" != "grub-rescue-iso" && "$boot_method" != "grub-qcow2" ]]; then
    echo "error: Asterinas v0.17.1 requires boot.method = 'grub-rescue-iso' (or 'grub-qcow2') to produce bzImage (got '$boot_method')" >&2
    exit 1
fi

is_git_repo=0
if git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is_git_repo=1
fi

# Prevent Cargo from mixing -Zsanitizer=kernel-address artifacts across builds.
kasan_stamp="$source_dir/target/.asterinas-kasan-mode"
if [[ -f "$kasan_stamp" ]] && [[ "$(<"$kasan_stamp")" != "$kasan" ]]; then
    rm -rf "$source_dir/target/${arch}-unknown-none"
fi
mkdir -p "$source_dir/target"
printf '%s\n' "$kasan" >"$kasan_stamp"

if [[ -n "$JOBS_CLI" ]]; then
    export CARGO_BUILD_JOBS="$JOBS_CLI"
fi

# Install or reuse the workspace-local cargo-osdk binary without RUSTC_WRAPPER.
osdk_root="$source_dir/target/local-osdk"
osdk_target="$source_dir/target/local-osdk-target"
osdk_bin="$osdk_root/bin/cargo-osdk"
osdk_stamp="$osdk_root/.local-osdk.sha256"
desired_osdk_stamp=$(python3 - "$source_dir/osdk" "${RUSTUP_TOOLCHAIN:-default}" <<'PY'
import hashlib
import pathlib
import sys

osdk_dir = pathlib.Path(sys.argv[1])
toolchain = sys.argv[2]
h = hashlib.sha256()
h.update(f"toolchain={toolchain}\n".encode())
files = []
for rel in ("Cargo.toml", "Cargo.lock"):
    p = osdk_dir / rel
    if p.is_file():
        files.append(p)
src_dir = osdk_dir / "src"
if src_dir.is_dir():
    files.extend(sorted(p for p in src_dir.rglob("*") if p.is_file()))
for p in files:
    h.update(str(p.relative_to(osdk_dir)).encode())
    h.update(b"\0")
    h.update(p.read_bytes())
    h.update(b"\0")
print(h.hexdigest())
PY
)
if [[ ! -x "$osdk_bin" || ! -f "$osdk_stamp" || "$(<"$osdk_stamp")" != "$desired_osdk_stamp" ]]; then
    (
        cd "$source_dir"
        env -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
            -u ASTERINAS_KCOV -u ASTERINAS_KASAN \
            OSDK_LOCAL_DEV=1 CARGO_TARGET_DIR="$osdk_target" \
            cargo install --path osdk --root "$osdk_root" --locked --force
    )
    mkdir -p "$osdk_root"
    printf '%s\n' "$desired_osdk_stamp" >"$osdk_stamp"
fi

# Upstream OSDK generates target/osdk/*-run-base/Cargo.toml without copying the
# workspace Cargo.lock, which can pull incompatible newer crates (e.g. unwinding
# 0.2.11 on nightly-2026-07-21). Seed Cargo.lock into generated *-base crates
# transparently without modifying the Asterinas git worktree.
real_cargo=$(command -v cargo)
if [[ -f "$source_dir/Cargo.lock" ]]; then
    cargo_shim_dir=$(mktemp -d)
    export KBA_ASTERINAS_CARGO_LOCK="$source_dir/Cargo.lock"
    cat >"$cargo_shim_dir/cargo" <<EOF
#!/usr/bin/env bash
if [[ "\$PWD" == *-run-base || "\$PWD" == *-test-base || "\$PWD" == *-base ]] &&
   [[ -f Cargo.toml && ! -f Cargo.lock && -n "\${KBA_ASTERINAS_CARGO_LOCK:-}" && -f "\${KBA_ASTERINAS_CARGO_LOCK}" ]]; then
    cp -f "\${KBA_ASTERINAS_CARGO_LOCK}" Cargo.lock
fi
exec "${real_cargo}" "\$@"
EOF
    chmod 0755 "$cargo_shim_dir/cargo"
    export PATH="$cargo_shim_dir:$osdk_root/bin:$PATH"
else
    export PATH="$osdk_root/bin:$PATH"
fi

export CARGO_TARGET_DIR="$source_dir/target"
export OSDK_TARGET_ARCH="$arch"
export OSTD_TASK_STACK_SIZE_IN_PAGES="$ostd_stack_pages"
export OSDK_LOCAL_DEV=1

if [[ "$lto" == "0" || "$kcov" == "1" || "$kasan" == "1" ]]; then
    export CARGO_PROFILE_DEV_LTO=false
    export CARGO_PROFILE_RELEASE_LTO=false
fi

if [[ "$kcov" == "1" || "$kasan" == "1" ]]; then
    export RUSTC_WRAPPER="$source_dir/tools/kcov-rustc.sh"
    export ASTERINAS_KCOV="$kcov"
    export ASTERINAS_KASAN="$kasan"
fi

declare -a build_features=()
if [[ -n "$extra_features" ]]; then
    IFS=',' read -r -a build_features <<<"$extra_features"
fi
if [[ "$kcov" == "1" ]]; then
    build_features+=("kcov")
fi
if [[ "$kasan" == "1" ]]; then
    build_features+=("kasan")
fi

declare -a unique_features=()
for feat in "${build_features[@]}"; do
    [[ -n "$feat" ]] || continue
    seen=0
    for existing in "${unique_features[@]}"; do
        if [[ "$existing" == "$feat" ]]; then
            seen=1
            break
        fi
    done
    if [[ "$seen" == "0" ]]; then
        unique_features+=("$feat")
    fi
done

cmd=("$osdk_bin" osdk build --target-arch="$arch" --boot-method="$boot_method" --grub-boot-protocol="$boot_protocol")
if [[ -n "$grub_mkrescue_bin" ]]; then
    cmd+=(--grub-mkrescue="$grub_mkrescue_bin")
fi
if [[ "$profile" == "release" ]]; then
    cmd+=(--release)
elif [[ "$profile" != "dev" ]]; then
    cmd+=(--profile="$profile")
fi
if [[ "$no_default_features" == "1" ]]; then
    cmd+=(--no-default-features)
fi
if [[ ${#unique_features[@]} -gt 0 ]]; then
    joined_features=$(
        IFS=','
        echo "${unique_features[*]}"
    )
    cmd+=(--features="$joined_features")
fi
if [[ "$strip_elf" == "1" ]]; then
    cmd+=(--strip-elf)
fi
if [[ "$linux_x86_legacy_boot" == "1" ]]; then
    cmd+=(--linux-x86-legacy-boot)
fi
for arg in "${kcmd_args[@]}"; do
    cmd+=(--kcmd-args="$arg")
done
for ov in "${override_configs[@]}"; do
    cmd+=(--config "$ov")
done

{
    date -u +%FT%TZ
    printf 'Workspace: '
    git -C "$WORKSPACE" rev-parse --short=12 HEAD 2>/dev/null || echo "unknown"
    if [[ -e "$WORKSPACE/syzkaller/.git" ]]; then
        printf 'syzkaller: '
        git -C "$WORKSPACE/syzkaller" rev-parse --short=12 HEAD 2>/dev/null || echo "unknown"
    fi
    printf 'Asterinas version: %s\n' "$actual_version"
    if [[ "$is_git_repo" == "1" ]]; then
        printf 'Asterinas commit: '
        git -C "$source_dir" rev-parse --short=12 HEAD 2>/dev/null || echo "unknown"
    else
        printf 'Asterinas commit: non-git source (%s)\n' "$source_dir"
    fi
    printf 'Config: %s\n' "$config_file"
    sha256sum "$config_file"
    (cd "$source_dir" && rustc -vV && "${real_cargo}" -V) 2>/dev/null || true
    printf 'Arch=%s Profile=%s BootMethod=%s BootProtocol=%s LegacyBoot=%s StripElf=%s\n' \
        "$arch" "$profile" "$boot_method" "$boot_protocol" "$linux_x86_legacy_boot" "$strip_elf"
    printf 'Features=%s NoDefaultFeatures=%s StackPages=%s\n' \
        "${joined_features:-none}" "$no_default_features" "$ostd_stack_pages"
    if [[ ${#override_configs[@]} -gt 0 ]]; then
        printf 'OverrideConfigs=%s\n' "$(
            IFS=','
            echo "${override_configs[*]}"
        )"
    else
        printf 'OverrideConfigs=none\n'
    fi
    printf 'LTO=%s (dev=%s release=%s)\n' \
        "$lto" "${CARGO_PROFILE_DEV_LTO:-default}" "${CARGO_PROFILE_RELEASE_LTO:-default}"
    printf 'RUSTC_WRAPPER: %s\n' "${RUSTC_WRAPPER:-none}"
    printf 'KCOV=%s KASAN=%s\n' "$kcov" "$kasan"
    printf 'CARGO_TARGET_DIR: %s\n' "$CARGO_TARGET_DIR"
    printf 'Command: (cd %q && ' "$source_dir/kernel"
    printf '%q ' "${cmd[@]}"
    printf ')\n'
} >"$out/build-record.txt"

(
    cd "$source_dir/kernel"
    "${cmd[@]}"
) 2>&1 | tee "$out/build.log"

cargo_profile_dir="$profile"
if [[ "$profile" == "dev" ]]; then
    cargo_profile_dir="debug"
fi

kernel_elf="$source_dir/target/${arch}-unknown-none/${cargo_profile_dir}/${kernel_bin_name}"
if [[ ! -f "$kernel_elf" ]]; then
    alt_elf="$source_dir/target/${arch}-unknown-none/${cargo_profile_dir}/asterinas-osdk-bin"
    if [[ "$kernel_bin_name" != "aster-kernel-osdk-bin" ]]; then
        alt_elf="$source_dir/target/${arch}-unknown-none/${cargo_profile_dir}/aster-kernel-osdk-bin"
    fi
    if [[ -f "$alt_elf" ]]; then
        kernel_elf="$alt_elf"
    else
        echo "error: build failed: unstripped kernel ELF not found: $kernel_elf" >&2
        exit 1
    fi
fi

# Validate unstripped ELF sections and required sanitizer symbols.
if ! sections=$(readelf -SW "$kernel_elf") ||
    [[ "$sections" != *".symtab"* || "$sections" != *".debug_info"* ]]; then
    echo "error: kernel ELF must be unstripped with debug info (.symtab and .debug_info): $kernel_elf" >&2
    exit 1
fi
if ! symbols=$(readelf -sW "$kernel_elf"); then
    echo "error: failed to read symbols from kernel ELF: $kernel_elf" >&2
    exit 1
fi
if [[ "$kcov" == "1" ]] &&
    ! awk '$7 != "UND" && $8 == "__sanitizer_cov_trace_pc" { found = 1 } END { exit !found }' <<<"$symbols"; then
    echo "error: KCOV=1 requires a kernel ELF defining __sanitizer_cov_trace_pc: $kernel_elf" >&2
    exit 1
fi
if [[ "$kasan" == "1" ]] &&
    (! awk '$7 != "UND" && $8 == "__asan_load1" { found = 1 } END { exit !found }' <<<"$symbols" ||
        ! awk '$7 != "UND" && $8 == "__asan_store1" { found = 1 } END { exit !found }' <<<"$symbols"); then
    echo "error: KASAN=1 requires a kernel ELF defining __asan_load1 and __asan_store1: $kernel_elf" >&2
    exit 1
fi

declare -a bzimage_candidates=()
if [[ "$boot_method" == "grub-rescue-iso" || "$boot_method" == "grub-qcow2" ]]; then
    bzimage_candidates=(
        "$source_dir/target/osdk/iso_root/boot/${kernel_bin_name}"
        "$source_dir/target/osdk/iso_root/boot/asterinas-osdk-bin"
        "$source_dir/target/osdk/iso_root/boot/aster-kernel-osdk-bin"
    )
else
    bzimage_candidates=(
        "$source_dir/target/osdk/${kernel_pkg_name}/${kernel_bin_name}"
        "$source_dir/target/osdk/${kernel_bin_name}"
        "$source_dir/target/osdk/asterinas/asterinas-osdk-bin"
        "$source_dir/target/osdk/aster-kernel/aster-kernel-osdk-bin"
    )
fi

built_bzimage=""
for cand in "${bzimage_candidates[@]}"; do
    if [[ -f "$cand" ]]; then
        built_bzimage="$cand"
        break
    fi
done
if [[ -z "$built_bzimage" ]]; then
    echo "error: build failed: could not locate built bzImage in target/osdk" >&2
    exit 1
fi

verify_bzimage_header() {
    python3 - "$1" <<'PY'
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    hdr = f.read(0x206)
if len(hdr) < 0x206 or hdr[0x1FE:0x200] != b"\x55\xaa" or hdr[0x202:0x206] != b"HdrS":
    print(f"error: not a valid Linux x86 bzImage (missing 0x55aa/HdrS header): {path}", file=sys.stderr)
    sys.exit(1)
PY
}
verify_bzimage_header "$built_bzimage"

if [[ ! "$kernel_elf" -ef "$out/vmlinux" ]]; then
    cp --reflink=auto "$kernel_elf" "$out/vmlinux" 2>/dev/null || cp -f "$kernel_elf" "$out/vmlinux"
fi
if [[ ! "$built_bzimage" -ef "$out/bzImage" ]]; then
    cp --reflink=auto "$built_bzimage" "$out/bzImage" 2>/dev/null || cp -f "$built_bzimage" "$out/bzImage"
fi

if [[ "$is_git_repo" == "1" ]]; then
    if git -C "$source_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
        git -C "$source_dir" diff HEAD >"$out/kernel.diff" 2>/dev/null || true
    else
        git -C "$source_dir" diff >"$out/kernel.diff" 2>/dev/null || true
    fi
fi

(cd "$out" && sha256sum vmlinux bzImage >images.sha256)

echo "Matching vmlinux, bzImage, and build record saved in $out"
echo "Run 'make asterinas-install' (or scripts/asterinas/install-kernel.sh) to install into an Asterinas VM image"
