#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: verify_kernel_fix.sh [syz-crush-args...]

Run from the kernel-bug-analysis repository root after applying a FreeBSD patch.
The script runs:
  - make freebsd
  - make freebsd-install
  - ./syzkaller/bin/syz-crush [syz-crush-args...]

Environment variables forwarded to make:
  FREEBSD_SRC, FREEBSD_CONFIG, FREEBSD_IMAGE, FREEBSD_SSHKEY, FREEBSD_OVERLAY, JOBS

Logs are written under ${TMPDIR:-/tmp}/freebsd-kernel-bugfix-logs by default.
Set LOG_DIR to override the log root.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(pwd)"
syz_crush="./syzkaller/bin/syz-crush"
log_root="${LOG_DIR:-${TMPDIR:-/tmp}/freebsd-kernel-bugfix-logs}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_dir="${log_root}/${stamp}"
build_log="${log_dir}/make-freebsd.log"
install_log="${log_dir}/make-freebsd-install.log"
crush_log="${log_dir}/syz-crush.log"

mkdir -p "${log_dir}"

printf 'Repository: %s\n' "${repo_root}"
printf 'Log directory: %s\n' "${log_dir}"

if [[ ! -e "Makefile" ]]; then
  printf 'error: no Makefile found in %s; run this from the repository root\n' "${repo_root}" >&2
  exit 2
fi

if [[ ! -x "${syz_crush}" ]]; then
  printf 'error: %s is missing or not executable\n' "${syz_crush}" >&2
  exit 2
fi

printf '\n==> Building FreeBSD kernel: make freebsd\n'
if ! make freebsd 2>&1 | tee "${build_log}"; then
  printf '\nmake freebsd failed; see %s\n' "${build_log}" >&2
  exit 1
fi

printf '\n==> Installing FreeBSD kernel into VM image: make freebsd-install\n'
if ! make freebsd-install 2>&1 | tee "${install_log}"; then
  printf '\nmake freebsd-install failed; see %s\n' "${install_log}" >&2
  exit 1
fi

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
