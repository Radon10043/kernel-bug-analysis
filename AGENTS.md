# CLAUDE.md

Workspace for analyzing and fixing Linux, FreeBSD, and Asterinas kernel bugs found by
syzkaller, and for preparing the resulting patches for upstream submission.
Read this before touching anything; the `/linux-kernel-bugfix`, `/freebsd-kernel-bugfix`,
and `/asterinas-kernel-bugfix` skills carry the longer per-patch checklists.

## Layout

| Path | What it is |
|---|---|
| `kernel/linux/` | Linux kernel tree under test. Built by `make linux`; config has KASAN, UBSAN, PROVE_LOCKING, KCOV, FAULT_INJECTION on. |
| `kernel/freebsd/` | FreeBSD (`freebsd-src`) kernel tree under test. Cross-built by `make freebsd` (outputs to `kernel/freebsd/build/dist/boot/kernel`) and installed into a VM image by `make freebsd-install`. |
| `kernel/asterinas/` | Asterinas (`asterinas`) Rust framekernel tree under test. Built by `make asterinas` (outputs `bzImage` and unstripped `vmlinux` to `kernel/asterinas/`) and installed into a VM image by `make asterinas-install`. |
| `syzkaller/` | syzkaller checkout; host binaries in `syzkaller/bin/` (`syz-crush`, `syz-symbolize`, ...) and target binaries in `syzkaller/bin/linux_amd64/` and `syzkaller/bin/freebsd_amd64/`. Built by `make syzutils-linux` / `make syzutils-freebsd` / `make syzutils-asterinas`. |
| `config/linux/repro.cfg` | Linux syz-manager/syz-crush config **template**; `__WORKDIR__` / `__KERNEL__` / `__TRIXIE__` / `__SYZKALLER__` are placeholders to resolve into a working copy. |
| `config/freebsd/repro.cfg` | FreeBSD syz-manager/syz-crush config **template**; `__WORKDIR__` / `__KERNEL_OBJ__` / `__KERNEL_SRC__` / `__IMAGE__` / `__SSHKEY__` / `__SYZKALLER__` are placeholders to resolve into a working copy. |
| `config/freebsd/freebsd.config` | Default FreeBSD kernel config (`COVERAGE`, `KCOV`, `KASAN`, `DIAGNOSTIC`, `TCPHPTS`, `RATELIMIT`). |
| `config/asterinas/asterinas.toml` | Default Asterinas TOML build config (`kcov = false`, `kasan = false`, `debug-assertions = true`, `overflow-checks = true`); enable `kcov` / `kasan` in the TOML when testing a KCOV/KASAN-patched tree. |
| `scripts/linux/` | Linux helpers: `qemu.sh` (boot), `exec-c.sh` / `exec-syz.sh` (run reproducer in the VM), `symbolize.sh`, `create-image.sh`. |
| `scripts/freebsd/` | FreeBSD helpers: `build.sh` (cross-build or native build), `install-kernel.py` (install built kernel into a QCOW2 image or overlay), `create-image.py` (create FreeBSD VM image), `build-binary.py` (build `syzkaller/bin/freebsd_amd64/*` inside a VM), `qemu.sh`, `exec-c.sh`, `exec-syz.sh`, `symbolize.sh`, `prog2c.sh`. |
| `scripts/asterinas/` | Asterinas helpers: `build.sh` (build `bzImage` + `vmlinux`), `install-kernel.sh` (install `bzImage` into a raw disk image or sparse copy), `create-image.sh` (create/update NixOS VM image and scratch disks), `qemu.sh`, `exec-c.sh`. |

Everything else — VM images and keys (`image/debian/`, `image/freebsd/`, `image/asterinas/`),
reproducers (`repro/`), boot logs, exported patches (`patch/`), mail (`email/`) —
is untracked and its layout is not fixed. Read the Makefile and `scripts/` for the paths
actually in use rather than assuming; other kernel checkouts or images may exist outside
this repository, but `kernel/linux/`, `kernel/freebsd/`, and `kernel/asterinas/` here are
the trees under test.

## Hard rules

- **Never claim a bug is fixed without evidence.** "Fixed" means the kernel built (and for
  FreeBSD and Asterinas, was installed into the tested VM image) and the reproducer no
  longer triggers the crash. Anything less gets reported as what it is: not built, not
  installed, not run, or ran differently.
- Do not modify or delete VM images, SSH keys, saved crash artifacts, or exported
  patches unless asked. They are untracked and there is no second copy. For FreeBSD
  testing, prefer installing kernels into a copy-on-write QCOW2 overlay via
  `FREEBSD_OVERLAY=repro/freebsd-test.qcow2 make freebsd-install` (or
  `scripts/freebsd/install-kernel.py -o ...`); for Asterinas testing, prefer installing
  kernels into a sparse image copy via `ASTERINAS_OVERLAY=repro/asterinas-test.img make asterinas-install`
  (or `scripts/asterinas/install-kernel.sh -o ...`) so base images stay untouched.
- When answer the user, explain the root cause of the issue, or write the patch commit
  message, please in a way that even a fool could understand.

## Build and run

```bash
# Linux
make linux               # make -C kernel/linux CC="ccache clang" olddefconfig all -j16
make syzutils-linux      # rebuild Linux host + target syzkaller binaries (alias: make syzutils)

# FreeBSD
make freebsd             # cross-build FreeBSD kernel into kernel/freebsd/build/dist/boot/kernel
make freebsd-install     # install built kernel into $(FREEBSD_IMAGE) (or $(FREEBSD_OVERLAY))
make syzutils-freebsd    # build host syzkaller tools + bin/freebsd_amd64 inside a FreeBSD VM

# Asterinas
make asterinas           # build Asterinas bzImage + unstripped vmlinux into kernel/asterinas/
make asterinas-install   # install built bzImage into $(ASTERINAS_IMAGE) (or $(ASTERINAS_OVERLAY))
make syzutils-asterinas  # rebuild Linux-ABI host + target syzkaller binaries

# Shared
make cleanrepro          # clear reproduction artifacts between runs
```

`make cleanrepro` deletes the reproducer along with the logs and saved crashes. Copy
anything worth keeping before running it.

A kernel build takes tens of minutes on a cold tree (incremental FreeBSD `buildkernel`
after `kernel-toolchain` and incremental Asterinas Cargo builds are much faster), and a
`syz-crush` run is longer. Run both with a large explicit timeout or in the background —
never assume the default tool timeout is enough, and never kill a build early and guess
at the result.

### Single-shot reproduction, one VM

Linux:
```bash
scripts/linux/qemu.sh           # boots the freshly built bzImage, ssh on port 2324,
                                # serial console teed to repro/kernel.log
scripts/linux/exec-c.sh         # scp + compile + run repro/repro.c inside the VM
scripts/linux/exec-syz.sh       # run repro/repro.syz under syz-execprog
scripts/linux/symbolize.sh      # symbolize repro/kernel.log
```

FreeBSD:
```bash
# Unlike Linux (-kernel bzImage), FreeBSD boots /boot/kernel from the disk image.
# After `make freebsd`, install into a QCOW2 overlay before booting:
scripts/freebsd/install-kernel.py -i image/freebsd/freebsd.qcow2 -o repro/freebsd-test.qcow2

scripts/freebsd/qemu.sh -i repro/freebsd-test.qcow2  # boots VM (-snapshot), ssh on port 37331,
                                                     # serial console teed to repro/kernel.log
scripts/freebsd/exec-c.sh                            # scp + compile (cc) + run repro/repro.c
scripts/freebsd/exec-syz.sh                          # run repro/repro.syz under freebsd_amd64/syz-execprog
scripts/freebsd/symbolize.sh                         # parse/extract crash reports from repro/kernel.log
```

Asterinas:
```bash
# QEMU boots Asterinas via OVMF UEFI from the GPT disk image.
# After `make asterinas`, install into a sparse image copy before booting:
scripts/asterinas/install-kernel.sh -i image/asterinas/asterinas.img -o repro/asterinas-test.img

scripts/asterinas/qemu.sh -i repro/asterinas-test.img  # boots VM (-snapshot), ssh on port 10022,
                                                       # serial console teed to repro/kernel.log
scripts/asterinas/exec-c.sh                            # static-compile on host + scp + run repro/repro.c
```

### Statistical reproduction / fix verification, many VMs

```bash
./syzkaller/bin/syz-crush -config <manager.cfg> <repro-log-or-prog>
#   -infinite=false   stop at the first crash instead of running forever
#   -restart_time     bound each run
```

Before trusting a `syz-crush` result, check the manager config:
- **Linux**: `vm.kernel` must be the `bzImage` you just built and `kernel_obj` the tree it
  came from. Both can point at another checkout, and symbolization then silently describes
  a different kernel.
- **FreeBSD**: `image` must be the `.qcow2` image (or overlay) into which you installed
  the kernel you just built, `sandbox` should be `"none"` unless reproducing under
  `"setuid"`, and `syzkaller/bin/freebsd_amd64/` must exist.
- **Asterinas**: `image` must be the raw `.img` file (or copy) into which you installed
  the `bzImage` you just built, `kernel_obj` and `kernel_src` must point to the matching
  `kernel/asterinas` tree containing `vmlinux`, and `syzkaller/` must include Asterinas
  report/executor support so `syz-crush` recognizes Rust panics and KASAN splats.

### Low-cost debug logging

- **Linux**: `ftrace_dump_on_oops` is already on the QEMU command line, so `trace_printk()`
  output is dumped after a crash (see README.md).
- **FreeBSD**: use `printf()` or `KTR` (`CTR*`) for serial/panic diagnostics; KDB prints
  symbolic stack backtraces directly on panic/trap.
- **Asterinas**: use `ostd::early_println!()` (or `log::error!()`, since default
  `loglevel=error`) for serial console diagnostics; pass `--log-level info` (or `debug`)
  to `scripts/asterinas/build.sh` when broader subsystem logs are needed.

## Analysis

- The crash title and the syzkaller stack are a *signal*, not a root cause. Confirm the
  faulting path by reading the source at the version that crashed, and say which line
  produces the bad value.
- Everything read from a crafted image or from userspace is attacker-controlled. Ask
  which on-disk / user field is unvalidated, what range it can actually take, and which
  consumer misuses it — that reasoning belongs in the commit message.
- Look at how the surrounding subsystem already validates, locks, refcounts, and handles
  errors before inventing a new pattern. Match it.
- Separate signals: the original crash, a *different* crash, a build failure, and
  "could not run" are four distinct outcomes. Never merge them into "still failing".
- A hang is not always a deadlock — a flood of slow-path work under a held lock looks
  the same from `INFO: task hung` (or FreeBSD witness/deadlkres panic). Explain the
  mechanism.

## Patches

- Smallest fix that closes the proven hole. No drive-by cleanups, no renames outside
  the failing path, no behavior changes the report does not justify.
- Respect UAPI/ABI, locking order (Linux lockdep/RCU; FreeBSD WITNESS/sx/mtx/epoch/UMA;
  Asterinas `SpinLock`/`Mutex`/`RwLock`/`RwMutex` and IRQ/preempt guards), allocation
  context (`M_NOWAIT` vs `M_WAITOK` on FreeBSD; `GFP_*` on Linux), and error paths.
- **Linux**: run `kernel/linux/scripts/checkpatch.pl --strict` on the patch before
  handing it over. Export each revision as `vN-0001-<subject>.patch` and keep the older
  ones.
- **FreeBSD**: follow FreeBSD `style(9)` (tabs, indentation, declarations at block top,
  no C++ comments in C files) and FreeBSD Phabricator / Bugzilla / commit-message
  conventions (`Fixes:`, `MFC after:`, `Reported by:`, `Reviewed by:`).
- **Asterinas**: respect the framekernel safety boundary (`unsafe` is strictly confined to
  `ostd/`; `kernel/` forbids `unsafe`), return appropriate `Errno` values instead of
  panicking on untrusted input, and format with `rustfmt` (`make format` / `make check` in
  `kernel/asterinas`).

Linux commit-message shape used here (the most recent exported revision is the reference):

- What a crafted input can contain / what the unvalidated field is.
- Which helper consumes it before validating, quoted as an indented code excerpt,
  and the concrete consequence (OOB read, negative length, lock flood, hang).
- What the patch does about it, in imperative mood.
- Trailers: `Reported-by:`, `Closes:` (lore.kernel.org link), `Assisted-by:` naming the
  assisting model, `Signed-off-by:`.
- A `Changes in vN:` block **below the `---`** so it stays out of git history. Keep the
  whole revision list, newest first. Reference code with version-pinned
  `elixir.bootlin.com` links.

Every one of those parts is prose for a maintainer who has never opened this file:
plain language, one idea per sentence, each term explained where it first appears.

## Reporting back

Every hand-off states: files changed, the root cause in one or two sentences, the exact
status of `make linux`, `make freebsd` + `make freebsd-install`, or `make asterinas` +
`make asterinas-install`, the exact status of the reproducer run (including how long it
ran), and anything left unverified. If validation could not run — missing image, missing
reproducer, misconfigured manager config — say so instead of implying it passed.

Write the hand-off the way Plain language demands: the verdict in the first line, one
idea per sentence, no term left unexplained, and a plain statement of what was not
checked.

---

## Git Commit & Self-Containment Principles

The rules below apply to commits in **this workspace repository** (upstream Linux,
FreeBSD, and Asterinas kernel patches follow their own upstream conventions under
`## Patches`).

- **Atomic Commits (Keep Commits Small)**:
  - Each commit should focus strictly on a single logical change (e.g., split
    changes to `Makefile`, `scripts/freebsd`, `config/freebsd`, `.claude/skills`,
    and documentation into separate commits).
  - Avoid combining unrelated modifications into a single commit.

- **Self-Containment & Consistency**:
  - **The repository must remain self-contained and runnable after every commit**.
  - Checking out any historical commit at any point in time must have consistent
    paths, valid configs (`config/*/*.cfg`, `config/*/*.toml`), clean script syntax
    (`bash -n`, `python3 -m py_compile`), and working `Makefile` targets without
    breaking existing Linux, FreeBSD, or Asterinas analysis workflows.

- **No Numbered Content**:
  - Avoid numbered lists, numbered headings, and numbered step prefixes anywhere
    in documentation, skills, configs, or script comments and `--help` output,
    because hard-coded numbers become stale and brittle to maintain when items
    are inserted, reordered, or removed.
  - Use bullet points (`-`) and unnumbered descriptive headings or comments
    instead.

---

## Commit Message Conventions

Workspace repository commit messages must strictly adhere to the following
structure:

```
[LOC]: [BRIEF]

[DETAILS]
```

### LOC (Location of Changes)
- **Root-level files**: Use the file name directly (e.g., `Makefile:`,
  `AGENTS.md:`, `README.md:`, `.gitignore:`).
- **Subdirectory files**: Use the relative folder path (e.g., `scripts/linux:`,
  `scripts/freebsd:`, `scripts/asterinas:`, `config/linux:`, `config/freebsd:`,
  `config/asterinas:`, `.claude/skills:`, `.claude/hooks:`, `docs:`).
- **Common parent rollup**: When modifications are distributed across multiple
  subdirectories under the same top-level directory (e.g., `scripts/linux` and
  `scripts/freebsd` both under `scripts/`, or `config/linux` and `config/freebsd`
  both under `config/`, or `.claude/skills` and `.claude/hooks` both under
  `.claude/`), use their common ancestor directory as LOC (e.g., `scripts:`,
  `config:`, or `.claude:`). Never use `all:` if changes are confined within a
  single top-level directory.
- **Path depth limit**: Directory depth must not exceed three levels (e.g.,
  `.claude/skills/freebsd-kernel-bugfix:`); truncate at the third level if deeper
  (or roll up to their common parent), explaining specifics in BRIEF or DETAILS.
- **Multiple distinct locations**:
  - One to three distinct top-level locations: Separate with commas (e.g.,
    `Makefile, scripts:`, `scripts, config:`).
  - More than three distinct top-level locations, or repository-wide changes:
    Use `all: [BRIEF]`.

### BRIEF (Summary)
- Succinctly summarize the core change of the commit.
- **Line length limit**: The entire first line (`[LOC]: [BRIEF]`) **must not
  exceed 80 columns**.

### DETAILS (Detailed Description)
- Leave one empty line after BRIEF, then provide a detailed list of changes,
  reasons, and implementation details.
- **Line length limit**: **Every line in DETAILS must not exceed 80 columns**;
  wrap lines manually when necessary.
- **Total length limit**: The total commit message must not exceed 80 lines.
