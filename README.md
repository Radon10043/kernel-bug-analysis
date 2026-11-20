# workspace for Linux and FreeBSD kernel bug analysis

## Setup

Clone the kernel trees and syzkaller:
```bash
git clone https://github.com/torvalds/linux kernel/linux
git clone https://github.com/freebsd/freebsd-src kernel/freebsd
git clone https://github.com/google/syzkaller
```

Set max size of ccache:
```bash
ccache -M 50G
```

### Linux

```bash
# Build syzkaller host + linux_amd64 tools
make syzutils-linux

# Create Debian VM image under image/debian/trixie/
mkdir -p image/debian/trixie && (cd image/debian/trixie && ../../../scripts/linux/create-image.sh)

# Build Linux kernel
make linux

# Single-shot repro
scripts/linux/qemu.sh
scripts/linux/exec-c.sh      # or scripts/linux/exec-syz.sh
scripts/linux/symbolize.sh
```

### FreeBSD

```bash
# 1. Create FreeBSD VM image(s) under image/freebsd/ (or symlink existing images there)
#    dev.qcow2 (stock kernel, used to build syzkaller freebsd_amd64 binaries):
scripts/freebsd/create-image.py -i 15.0
#    15.0.0.qcow2 (with custom KCOV/KASAN kernel):
scripts/freebsd/create-image.py -i 15.0 -k 15.0.0 -c config/freebsd/freebsd.config

# 2. Build syzkaller host tools + bin/freebsd_amd64 inside the FreeBSD VM
make syzutils-freebsd

# 3. Cross-build FreeBSD kernel on Linux host (outputs to kernel/freebsd/build/dist/boot/kernel)
make freebsd

# 4. Install the newly built kernel into a QCOW2 overlay (leaves base image untouched)
FREEBSD_IMAGE=image/freebsd/15.0.0.qcow2 \
FREEBSD_OVERLAY=repro/freebsd-test.qcow2 \
    make freebsd-install

# 5. Single-shot repro
scripts/freebsd/qemu.sh -i repro/freebsd-test.qcow2
scripts/freebsd/exec-c.sh    # or scripts/freebsd/exec-syz.sh
scripts/freebsd/symbolize.sh
```

## How to print debug messages with low cost

### Linux

Use `trace_printk` (same usage as `printk`), e.g.:
```c
trace_printk("ptr=%p\n", ptr);
```

Remember to add `ftrace_dump_on_oops` to the QEMU command (already included in `scripts/linux/qemu.sh`); debug info will be printed after a kernel crash:
```bash
qemu-system-x86_64 \
    ...
    -append "root=/dev/sda console=ttyS0 ftrace_dump_on_oops"
```

### FreeBSD

Use `printf()` (or `CTR*` with `options KTR`) for kernel diagnostics; FreeBSD KDB automatically prints symbolic stack backtraces to the serial console on panic/trap.
