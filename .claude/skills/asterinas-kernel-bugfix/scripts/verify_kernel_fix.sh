#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  verify_kernel_fix.sh [--repro <repro.c>] [--duration <SEC>]
  verify_kernel_fix.sh -config <manager.cfg> [syz-crush-args...]

Run from the kernel-bug-analysis repository root after applying an Asterinas patch.
The script runs:
  - make asterinas
  - make asterinas-install
  - Either:
     - Single-VM QEMU boot + C reproducer run (default: repro/repro.c)
       when -config is NOT passed, verifying no panic or KASAN fault occurs; or
     - ./syzkaller/bin/syz-crush [args...] when -config is passed.

Environment variables forwarded to make / scripts:
  ASTERINAS_SRC, ASTERINAS_CONFIG, ASTERINAS_IMAGE, ASTERINAS_SSHKEY, ASTERINAS_OVERLAY, JOBS

Logs are written under ${TMPDIR:-/tmp}/asterinas-kernel-bugfix-logs by default.
Set LOG_DIR to override the log root.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(pwd)"
if [[ ! -e "Makefile" ]]; then
  printf 'error: no Makefile found in %s; run this from the repository root\n' "${repo_root}" >&2
  exit 2
fi

use_crush=0
for arg in "$@"; do
  if [[ "$arg" == "-config" || "$arg" == -config=* || "$arg" == "--config" || "$arg" == --config=* ]]; then
    use_crush=1
    break
  fi
done

repro_file=""
duration_sec=30
if [[ "$use_crush" -eq 0 ]]; then
  args_copy=("$@")
  idx=0
  while ((idx < ${#args_copy[@]})); do
    case "${args_copy[$idx]}" in
      --repro | -f)
        repro_file="${args_copy[$((idx + 1))]:-}"
        idx=$((idx + 2))
        ;;
      --duration)
        duration_sec="${args_copy[$((idx + 1))]:-30}"
        idx=$((idx + 2))
        ;;
      *)
        if [[ -z "$repro_file" && -f "${args_copy[$idx]}" ]]; then
          repro_file="${args_copy[$idx]}"
          idx=$((idx + 1))
        else
          printf 'error: unknown argument %s\n' "${args_copy[$idx]}" >&2
          usage >&2
          exit 2
        fi
        ;;
    esac
  done
  if [[ -z "$repro_file" ]]; then
    repro_file="repro/repro.c"
  fi
  if [[ ! -f "$repro_file" ]]; then
    printf 'error: reproducer %s does not exist\n' "$repro_file" >&2
    exit 2
  fi
else
  syz_crush="./syzkaller/bin/syz-crush"
  if [[ ! -x "${syz_crush}" ]]; then
    printf 'error: %s is missing or not executable\n' "${syz_crush}" >&2
    exit 2
  fi
fi

log_root="${LOG_DIR:-${TMPDIR:-/tmp}/asterinas-kernel-bugfix-logs}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_dir="${log_root}/${stamp}"
build_log="${log_dir}/make-asterinas.log"
install_log="${log_dir}/make-asterinas-install.log"

mkdir -p "${log_dir}"

printf 'Repository: %s\n' "${repo_root}"
printf 'Log directory: %s\n' "${log_dir}"

printf '\n==> Building Asterinas kernel: make asterinas\n'
if ! make asterinas 2>&1 | tee "${build_log}"; then
  printf '\nmake asterinas failed; see %s\n' "${build_log}" >&2
  exit 1
fi

printf '\n==> Installing Asterinas kernel into VM image: make asterinas-install\n'
if ! make asterinas-install 2>&1 | tee "${install_log}"; then
  printf '\nmake asterinas-install failed; see %s\n' "${install_log}" >&2
  exit 1
fi

if [[ "$use_crush" -eq 1 ]]; then
  crush_log="${log_dir}/syz-crush.log"
  printf '\n==> Running syz-crush: %s' "${syz_crush}"
  for arg in "$@"; do
    printf ' %q' "${arg}"
  done
  printf '\n'

  if ! "${syz_crush}" "$@" 2>&1 | tee "${crush_log}"; then
    printf '\nsyz-crush failed or reproduced a crash; see %s\n' "${crush_log}" >&2
    exit 1
  fi
  printf '\nValidation completed successfully.\n'
  printf 'Build log: %s\n' "${build_log}"
  printf 'Install log: %s\n' "${install_log}"
  printf 'syz-crush log: %s\n' "${crush_log}"
  exit 0
fi

vm_image="${ASTERINAS_OVERLAY:-${ASTERINAS_IMAGE:-image/asterinas/asterinas.img}}"
ssh_key="${ASTERINAS_SSHKEY:-image/asterinas/asterinas.id_rsa}"
kernel_log="${log_dir}/kernel.log"
repro_log="${log_dir}/repro-exec.log"

ssh_port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)

qemu_pid=""
cleanup_vm() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
}
trap cleanup_vm EXIT

printf '\n==> Booting Asterinas VM (%s) on SSH port %s\n' "${vm_image}" "${ssh_port}"
bash scripts/asterinas/qemu.sh \
  -i "${vm_image}" \
  -p "${ssh_port}" \
  -q 0 \
  -m 0 \
  -l "${kernel_log}" >/dev/null 2>&1 &
qemu_pid=$!

ssh_ready=0
for _ in $(seq 1 90); do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    printf 'error: QEMU exited before SSH became ready; see %s\n' "${kernel_log}" >&2
    exit 1
  fi
  if ssh -p "${ssh_port}" -F /dev/null -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=2 -i "${ssh_key}" root@127.0.0.1 true >/dev/null 2>&1; then
    ssh_ready=1
    break
  fi
  sleep 2
done

if [[ "$ssh_ready" -ne 1 ]]; then
  printf 'error: timed out waiting for VM SSH; see %s\n' "${kernel_log}" >&2
  exit 1
fi

printf '==> Running reproducer (%s) for up to %ss\n' "${repro_file}" "${duration_sec}"
set +e
timeout "${duration_sec}" bash scripts/asterinas/exec-c.sh \
  -f "${repro_file}" -p "${ssh_port}" -k "${ssh_key}" >"${repro_log}" 2>&1
exec_rc=$?
set -e

sleep 2
vm_alive=1
if ! kill -0 "$qemu_pid" 2>/dev/null; then
  vm_alive=0
fi
cleanup_vm
qemu_pid=""

if grep -Eq 'Uncaught panic:|panicked at |BUG: KASAN:' "${kernel_log}"; then
  printf '\nCrash reproduced in kernel log; see %s\n' "${kernel_log}" >&2
  exit 1
fi
if [[ "$vm_alive" -eq 0 && "$exec_rc" -ne 0 && "$exec_rc" -ne 124 ]]; then
  printf '\nVM exited unexpectedly during reproduction (rc=%d); see %s\n' "${exec_rc}" "${kernel_log}" >&2
  exit 1
fi

printf '\nValidation completed successfully (no panic or KASAN report).\n'
printf 'Build log: %s\n' "${build_log}"
printf 'Install log: %s\n' "${install_log}"
printf 'Kernel log: %s\n' "${kernel_log}"
