---
name: freebsd-kernel-bugfix
description: Diagnose, patch, cross-build, install into a FreeBSD VM image, and validate FreeBSD kernel bugs, especially syzkaller reports, crash reproducers, panics, KASSERT failures, Fatal traps, KASAN/WITNESS/INVARIANT reports, use-after-free bugs, NULL dereferences, races, and regressions. Use when asked to fix a FreeBSD kernel issue and every proposed patch must be verified with `make freebsd`, `make freebsd-install`, and `./syzkaller/bin/syz-crush` (or `scripts/freebsd/qemu.sh` + `exec-c.sh`/`exec-syz.sh`).
---

# FreeBSD Kernel Bugfix

## Overview

Use this skill to keep FreeBSD kernel bug fixes narrow, evidence-driven, and verified.
Unlike Linux (`-kernel bzImage`), QEMU boots FreeBSD from `/boot/kernel` inside the QCOW2
disk image. After every patch, cross-build the kernel with `make freebsd`, install it
into the target VM image (preferably a QCOW2 overlay via `FREEBSD_OVERLAY=...` so base
images remain untouched) with `make freebsd-install`, and then run
`./syzkaller/bin/syz-crush` (or single-shot reproduction with `scripts/freebsd/qemu.sh`
and `scripts/freebsd/exec-c.sh` / `exec-syz.sh`) to verify the reported bug no longer
reproduces.

## Workflow

1. Preserve the bug signal before editing:
   - Identify the crash title (`panic:`, `Fatal trap`, `KASSERT`, `KASAN`, `WITNESS`),
     faulting subsystem, KDB stack trace, reproducer, and kernel config (`issue/freebsd.config`
     or `config/freebsd/freebsd.config`).
   - Search the touched subsystem in `kernel/freebsd/sys/` for existing locking (`mtx`, `sx`,
     `rwlock`, `rmlock`, `epoch`), lifetime/refcount (`refcount_acquire`/`release`),
     bounds-checking, and error-path patterns before inventing a new pattern.
   - Treat syzkaller output as a reproducer signal, not proof of root cause. Confirm the
     failing path in source.

2. Patch conservatively:
   - Prefer the smallest fix that addresses the proven lifetime, concurrency, validation,
     or error-handling bug.
   - Follow FreeBSD `style(9)` and nearby subsystem conventions. Avoid broad refactors,
     unrelated cleanups, and behavior changes outside the failing path.
   - Keep syscall/ioctl ABI, locking order (`WITNESS`), `M_NOWAIT` vs `M_WAITOK`
     allocation context, epoch sections, and UMA/malloc ownership in mind.

3. Validate every patch from the repository working directory:

   ```bash
   make freebsd
   FREEBSD_IMAGE=image/freebsd/freebsd.qcow2 \
   FREEBSD_OVERLAY=repro/freebsd-test.qcow2 \
       make freebsd-install
   ./syzkaller/bin/syz-crush -config repro/repro.cfg <repro-log-or-prog>
   ```

   This repo keeps a FreeBSD `syz-crush` manager config template at
   `config/freebsd/repro.cfg`. Make sure the working copy's `image` points to the exact
   QCOW2 image (or overlay) into which `make freebsd-install` just installed the kernel,
   `sandbox` is `"none"` unless reproducing under `"setuid"`, and
   `syzkaller/bin/freebsd_amd64/` exists (built via `make syzutils-freebsd`).

   Do not claim the bug is fixed unless the kernel build succeeds, the kernel is
   installed into the tested VM image, and reproduction no longer triggers the target
   crash.

   Kernel builds (especially the initial `kernel-toolchain` build) and `syz-crush` runs are
   long-running; run them with a generous timeout or in the background.

4. Interpret verification strictly:
   - If `make freebsd` fails, fix the compile error before installing or testing.
   - If `make freebsd-install` fails, check `repro/install-kernel.console.log` and do not
     test against a stale image.
   - If `syz-crush` (or single-shot repro) still reports the same crash, revisit the root
     cause and adjust the patch.
   - If a *different* crash appears, separate that signal from the original fix and state
     the distinction.
   - If validation cannot run because required images, SSH keys, `freebsd_amd64` binaries,
     reproducers, or configs are missing, report that limitation explicitly.

5. Report the result with the files changed, the root-cause reasoning, and the exact
   validation outcome. Include the command status for `make freebsd`,
   `make freebsd-install`, and `./syzkaller/bin/syz-crush` (or `exec-c.sh` / `exec-syz.sh`).

## Validation Helper

Use the bundled helper when a single repeatable command is preferable:

```bash
FREEBSD_IMAGE=image/freebsd/freebsd.qcow2 \
FREEBSD_OVERLAY=repro/freebsd-test.qcow2 \
    bash .claude/skills/freebsd-kernel-bugfix/scripts/verify_kernel_fix.sh \
    -config repro/repro.cfg repro/repro.syz
```

The helper runs `make freebsd`, then `make freebsd-install`, then
`./syzkaller/bin/syz-crush "$@"`, writes logs under
`${TMPDIR:-/tmp}/freebsd-kernel-bugfix-logs`, and exits nonzero on the first failed phase.

## Kernel Fix Checklist

Before finishing, ensure:

- The patch directly addresses the observed failing path and adheres to FreeBSD `style(9)`.
- The change follows subsystem conventions and does not widen locking or lifetime
  assumptions without justification.
- `make freebsd` was run after the final patch.
- `make freebsd-install` installed the freshly built kernel into the image/overlay used
  for testing.
- `./syzkaller/bin/syz-crush` (or single-shot repro) was run against that updated image.
- Remaining failures are clearly identified as compile failures, install failures, the
  original crash, a different crash, or missing validation prerequisites.
