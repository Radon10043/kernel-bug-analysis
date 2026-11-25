---
name: asterinas-kernel-bugfix
description: Diagnose, patch, build, install into an Asterinas VM image, and validate Asterinas Rust framekernel bugs, especially syzkaller reports, uncaught panics, arithmetic overflows, unwrap/expect failures, KASAN reports, deadlocks, and Linux-ABI syscall bugs. Use when asked to fix an Asterinas kernel issue and every proposed patch must be verified with `make asterinas`, `make asterinas-install`, and reproduction inside QEMU (`scripts/asterinas/qemu.sh` + `exec-c.sh`, or `./syzkaller/bin/syz-crush`).
---

# Asterinas Kernel Bugfix

## Overview

Use this skill to keep Asterinas kernel bug fixes narrow, safe-Rust-idiomatic, and
verified. Like FreeBSD (and unlike Linux `-kernel bzImage`), QEMU boots Asterinas via
OVMF UEFI from the GPT disk image (`asterinas.img`). After every patch, build the kernel
with `make asterinas`, install the freshly built `bzImage` into a target image copy via
`ASTERINAS_OVERLAY=repro/asterinas-test.img make asterinas-install` (leaving the base
image untouched), and run single-shot reproduction (`scripts/asterinas/qemu.sh` and
`scripts/asterinas/exec-c.sh`) or `./syzkaller/bin/syz-crush` to verify that the bug no
longer reproduces.

## Workflow

### Preserve the bug signal before editing

- Identify the crash title (`Uncaught panic:`, `panicked at`, `BUG: KASAN:`),
  assertion/overflow message, source path and line, stack trace (`fn 0x... - pc 0x...`),
  reproducer, and build TOML (`config/asterinas/asterinas.toml`).
- Note that `config/asterinas/asterinas.toml` defaults to `kcov = false` and
  `kasan = false` so upstream Asterinas checkouts build out of the box. When
  reproducing a KASAN bug on a KASAN-patched Asterinas tree, enable `kasan = true`
  (and `kcov = true` if needed) in `config/asterinas/asterinas.toml` (or pass a custom
  TOML via `ASTERINAS_CONFIG`).
- Search the touched crate (`kernel/core/`, `kernel/comps/`, `ostd/`) for existing
  error returns (`return_errno_with_message!`), `checked_*` / `saturating_*` arithmetic,
  `VmReader` / `VmWriter` user-memory access, and lock-ordering (`SpinLock`, `Mutex`,
  `RwLock`, `RwMutex`, `LocalIrqDisabled`, `PreemptDisabled`) conventions.
- Treat syzkaller output as a reproducer signal, not proof of root cause. Confirm the
  faulting path in source.

### Patch conservatively and respect the framekernel boundary

- `unsafe` Rust is strictly confined to `ostd/`. Never introduce `unsafe` in `kernel/`
  (`#![deny(unsafe_code)]`); any `unsafe` change inside `ostd/` must carry a precise
  `// SAFETY:` justification.
- Prefer returning the appropriate Linux `Errno` (`EINVAL`, `EFAULT`, `ENOMEM`,
  `EOPNOTSUPP`, `EOVERFLOW`, ...) over `unwrap()`, `expect()`, or unchecked arithmetic
  on untrusted userspace inputs, network packets, or filesystem metadata.
- Follow Asterinas `rustfmt.toml` (`imports_granularity = "Crate"`,
  `group_imports = "StdExternalCrate"`) and avoid unrelated refactors.

### Validate every patch from the repository working directory

```bash
make asterinas

ASTERINAS_IMAGE=image/asterinas/asterinas.img \
ASTERINAS_OVERLAY=repro/asterinas-test.img \
    make asterinas-install

scripts/asterinas/qemu.sh -i repro/asterinas-test.img
scripts/asterinas/exec-c.sh
```

Do not claim the bug is fixed unless `make asterinas` succeeds, `make asterinas-install`
installs the new `bzImage` into the tested image, and reproduction no longer triggers
the crash.

### Interpret verification strictly

- If `make asterinas` fails, fix all Rust/Clippy compile errors before installing or testing.
- If `make asterinas-install` fails, do not test against a stale disk image.
- If reproduction still triggers the same panic or KASAN fault, revisit the root cause.
- If a *different* panic or KASAN fault appears, separate that signal from the original
  bug and report it distinctly.
- If validation cannot run because images, SSH keys, `VDSO_LIBRARY_DIR`, target
  binaries, or reproducers are missing, state that limitation explicitly.

### Report the result

Include the files changed, the root-cause reasoning in plain language, and the exact
status of `make asterinas`, `make asterinas-install`, and the reproducer run (`qemu.sh` +
`exec-c.sh` or `syz-crush`).

## Validation Helper

Use the bundled helper when a single repeatable command is preferable:

```bash
# Single-VM reproduction check (boots QEMU, runs repro/repro.c, checks console log):
ASTERINAS_IMAGE=image/asterinas/asterinas.img \
ASTERINAS_OVERLAY=repro/asterinas-test.img \
    bash .claude/skills/asterinas-kernel-bugfix/scripts/verify_kernel_fix.sh \
    --repro repro/repro.c

# Or with syz-crush when a patched syzkaller and manager config are available:
ASTERINAS_IMAGE=image/asterinas/asterinas.img \
ASTERINAS_OVERLAY=repro/asterinas-test.img \
    bash .claude/skills/asterinas-kernel-bugfix/scripts/verify_kernel_fix.sh \
    -config repro/repro.cfg repro/repro.c
```

The helper runs `make asterinas`, then `make asterinas-install`, then either boots a
single QEMU VM to run `--repro <repro.c>` (checking for panics/KASAN reports) or runs
`./syzkaller/bin/syz-crush "$@"`, writing logs under
`${TMPDIR:-/tmp}/asterinas-kernel-bugfix-logs`.

## Kernel Fix Checklist

Before finishing, ensure:

- The patch directly addresses the observed failing path without violating the `ostd` vs
  `kernel` framekernel safety boundary.
- Untrusted inputs use checked arithmetic and return proper `Errno` values rather than panicking.
- `make asterinas` succeeded after the final edit.
- `make asterinas-install` installed the rebuilt `bzImage` into the exact image booted in QEMU.
- Reproduction was run against the updated image and no longer triggers the crash.
- Any remaining failures or unverified items are stated plainly.
