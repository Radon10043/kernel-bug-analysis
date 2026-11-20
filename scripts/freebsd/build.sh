#!/bin/bash

# Build FreeBSD kernel on Linux (cross-build) or natively on FreeBSD.
# Modeled after omnislash/scripts/freebsd/build.sh.
#
# usage:
#   scripts/freebsd/build.sh [-s <SOURCEDIR>] [-c <CONFIG>] [-j <JOBS>]

set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")/../.." && pwd)

# defaults
SOURCEDIR="${FREEBSD_SRC:-$WORKSPACE/kernel/freebsd}"
if [[ -n "${FREEBSD_CONFIG:-}" ]]; then
    CONFIG="$FREEBSD_CONFIG"
elif [[ -f "$WORKSPACE/issue/freebsd.config" ]]; then
    CONFIG="$WORKSPACE/issue/freebsd.config"
else
    CONFIG="$WORKSPACE/config/freebsd/freebsd.config"
fi
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 16)}"
KERNCONF=""
CLEAN=false
FORCE_TOOLCHAIN=false
BUILDWORLD=false

HOSTOS=$(go env GOHOSTOS 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')
HOSTARCH=$(go env GOHOSTARCH 2>/dev/null || uname -m)
case "$HOSTARCH" in
    x86_64) HOSTARCH=amd64 ;;
    aarch64) HOSTARCH=arm64 ;;
esac

print_help() {
    echo "usage: $0 [ARGS]"
    echo "  args (optional, defaults to workspace paths):"
    echo "    -s, --sourcedir   <SOURCEDIR> path to freebsd source directory (default: $SOURCEDIR)"
    echo "    -c, --config      <CONFIG>    path to the kernel config file (default: $CONFIG)"
    echo "    -j, --jobs        <JOBS>      number of parallel build jobs (default: $JOBS)"
    echo "    -k, --kernconf    <KERNCONF>  kernel config name (default: ident from CONFIG, or SYZKALLER)"
    echo "        --toolchain               rebuild kernel-toolchain before buildkernel (Linux host)"
    echo "        --buildworld              run full buildworld instead of kernel-toolchain (Linux host)"
    echo "        --clean                   do a clean rebuild instead of incremental build"
    echo "    -h, --help                    print help message"
}

resolve_cross_bindir() {
    if [[ -n "${LLVM_HOME:-}" && -x "$LLVM_HOME/bin/clang" ]]; then
        echo "$LLVM_HOME/bin"
    elif command -v clang >/dev/null 2>&1; then
        dirname "$(command -v clang)"
    else
        echo "error: clang not found; set LLVM_HOME or add clang to PATH" >&2
        exit 1
    fi
}

build_freebsd_on_linux() {
    local cross_bindir
    cross_bindir=$(resolve_cross_bindir)
    local clean_arg="--no-clean"
    if [[ "$CLEAN" == true ]]; then
        clean_arg="--clean"
    fi

    local objdir="$SOURCEDIR/build"
    local distdir="$objdir/dist"
    local toolchain_stamp="$objdir/.kernel-toolchain.${HOSTARCH}.done"
    mkdir -p "$objdir" "$distdir"

    if [[ "$BUILDWORLD" == true ]]; then
        MAKEOBJDIRPREFIX="$objdir" "$SOURCEDIR/tools/build/make.py" \
            -j "$JOBS" "$clean_arg" --cross-bindir="$cross_bindir" \
            TARGET="$HOSTARCH" TARGET_ARCH="$HOSTARCH" \
            buildworld
        touch "$toolchain_stamp"
    elif [[ "$FORCE_TOOLCHAIN" == true || "$CLEAN" == true || ! -f "$toolchain_stamp" ]]; then
        MAKEOBJDIRPREFIX="$objdir" "$SOURCEDIR/tools/build/make.py" \
            -j "$JOBS" "$clean_arg" --cross-bindir="$cross_bindir" \
            TARGET="$HOSTARCH" TARGET_ARCH="$HOSTARCH" \
            kernel-toolchain
        touch "$toolchain_stamp"
    fi

    MAKEOBJDIRPREFIX="$objdir" ${BEAR:-} "$SOURCEDIR/tools/build/make.py" \
        -j "$JOBS" "$clean_arg" --cross-bindir="$cross_bindir" \
        TARGET="$HOSTARCH" TARGET_ARCH="$HOSTARCH" \
        buildkernel KERNCONF="$KERNCONF"

    rm -rf "$distdir/boot/kernel" "$distdir/usr/lib/debug/boot/kernel"
    mkdir -p "$distdir/boot/kernel"
    MAKEOBJDIRPREFIX="$objdir" "$SOURCEDIR/tools/build/make.py" \
        -j "$JOBS" --no-clean --cross-bindir="$cross_bindir" \
        TARGET="$HOSTARCH" TARGET_ARCH="$HOSTARCH" \
        installkernel KERNCONF="$KERNCONF" DESTDIR="$distdir"

    echo "kernel installed to $distdir/boot/kernel"
    echo "run 'make freebsd-install' (or scripts/freebsd/install-kernel.py) to install it into a FreeBSD VM image"
}

build_freebsd_on_freebsd() {
    cd "$SOURCEDIR/sys/$HOSTARCH/conf"
    config "$KERNCONF"
    cd "../compile/$KERNCONF"
    if [[ "$CLEAN" == true ]]; then
        make cleandepend && make depend
    fi
    make -j"$JOBS"
    echo "you can run 'make install' under '$SOURCEDIR/sys/$HOSTARCH/compile/$KERNCONF' to install the kernel on the machine"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -s | --sourcedir)
            SOURCEDIR="$2"
            shift 2
            ;;
        -c | --config)
            CONFIG="$2"
            shift 2
            ;;
        -j | --jobs)
            JOBS="$2"
            shift 2
            ;;
        -k | --kernconf)
            KERNCONF="$2"
            shift 2
            ;;
        --toolchain)
            FORCE_TOOLCHAIN=true
            shift
            ;;
        --buildworld)
            BUILDWORLD=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        -h | --help)
            print_help
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            print_help >&2
            exit 1
            ;;
    esac
done

# validation
if [[ ! -d "$SOURCEDIR" ]]; then
    echo "error: '$SOURCEDIR' does not exist." >&2
    exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
    echo "error: '$CONFIG' does not exist." >&2
    exit 1
fi

SOURCEDIR=$(realpath "$SOURCEDIR")
CONFIG=$(realpath "$CONFIG")

if [[ -z "$KERNCONF" ]]; then
    KERNCONF=$(awk '/^[[:space:]]*ident[[:space:]]+/{print $2; exit}' "$CONFIG" || true)
    KERNCONF="${KERNCONF:-SYZKALLER}"
fi

CONF_DST="$SOURCEDIR/sys/$HOSTARCH/conf/$KERNCONF"
if [[ "$CONFIG" != "$(realpath -m "$CONF_DST")" ]]; then
    cp "$CONFIG" "$CONF_DST"
fi

echo "building freebsd kernel ($KERNCONF) on $HOSTOS ($HOSTARCH) ..."
cd "$SOURCEDIR"
"build_freebsd_on_$HOSTOS"
echo "done!"
