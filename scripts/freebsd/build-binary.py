#!/usr/bin/env python3

# Build FreeBSD syzkaller target binaries (syzkaller/bin/freebsd_amd64)
# without manual interaction with the VM.
# Modeled after omnislash/scripts/freebsd/build-binary.py.
#
# usage:
#   scripts/freebsd/build-binary.py [-i image/freebsd/dev.qcow2] \
#       [-k image/freebsd/freebsd.id_rsa] [--syzkaller syzkaller]
#
# how it works:
#   - boot the FreeBSD image with -snapshot, so the image is never modified
#   - copy the syzkaller source tree from the host into the VM through ssh,
#     leaving out bin/, .git, and .descriptions; git revision is computed on host
#   - run `gmake target` in the VM and copy bin/freebsd_amd64 back

import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys
import time

WORKSPACE = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))

OS = "freebsd"
TARGET = f"{OS}_amd64"
REMOTE = "/root/syzkaller"
# copying the generated stamp would make gmake skip syz-sysgen, whose binary
# is not copied
EXCLUDES = ["./bin", "./.git", "./.descriptions"]
# files that must exist in bin/freebsd_amd64 after the build
BINARIES = ["syz-executor", "syz-execprog"]


def log(msg):
    print(f"[build-binary] {msg}", flush=True)


def run(cmd, **kwargs):
    log("$ " + " ".join(cmd))
    return subprocess.run(cmd, check=True, **kwargs)


class VM:
    """qemu instance booted from a snapshot of the image, console goes to logfile"""

    def __init__(self, image, ssh_port, mem, smp, logfile):
        cmd = [
            "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
            "-m", mem, "-smp", str(smp), "-hda", image, "-snapshot",
            "-net", "nic", "-net", f"user,hostfwd=tcp:127.0.0.1:{ssh_port}-:22",
            "-display", "none", "-serial", f"file:{logfile}", "-monitor", "none",
        ]
        log("$ " + " ".join(cmd))
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)

    def kill(self):
        # nothing to save thanks to -snapshot, no need to shut down gracefully
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


class SSH:
    def __init__(self, key, port, vm):
        self.vm = vm
        self.base = [
            "ssh", "-i", key, "-p", str(port),
            "-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no",
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30",
            "root@localhost",
        ]

    def run(self, cmd, check=True, **kwargs):
        kwargs.setdefault("stdin", subprocess.DEVNULL)
        return subprocess.run(self.base + [cmd], check=check, **kwargs)

    def wait(self, timeout=600):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.vm.proc.poll() is not None:
                raise RuntimeError("qemu exited while waiting for ssh")
            if self.run("true", check=False, stderr=subprocess.DEVNULL).returncode == 0:
                return
            time.sleep(3)
        raise RuntimeError("timeout waiting for ssh")

    def pipe(self, local, remote, upload):
        """tar stream between a local command and a remote command"""
        log("$ " + " ".join(local) + (" | ssh " if upload else " <- ssh ") + remote)
        src, dst = (local, self.base + [remote]) if upload else (self.base + [remote], local)
        p1 = subprocess.Popen(src, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
        assert p1.stdout is not None
        p2 = subprocess.Popen(dst, stdin=p1.stdout)
        p1.stdout.close()
        rc2, rc1 = p2.wait(), p1.wait()
        if rc1 or rc2:
            raise RuntimeError(f"transfer failed ({rc1}, {rc2}): {remote}")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def git_revision(src):
    """REV and GITREVDATE as computed by tools/version.mk, .git is not copied to the vm"""
    def git(*args):
        return subprocess.run(["git", "-C", src, *args], check=True,
                              stdout=subprocess.PIPE, text=True).stdout.strip()
    rev = git("rev-parse", "HEAD")
    if git("diff", "--shortstat"):
        rev += "+"
    date = git("log", "-n", "1", "--format=%cd", "--date=format:%Y%m%d-%H%M%S")
    return rev, date


def build_script(args, rev, date):
    lines = ["set -eux"]
    if args.proxy:
        lines += [f"export http_proxy={args.proxy} https_proxy={args.proxy}"]
    if args.goproxy:
        lines += [f"export GOPROXY={args.goproxy}"]
    lines += [
        f"cd {REMOTE}",
        f"gmake -j{args.jobs} target REV={rev} GITREVDATE={date}",
    ]
    return "\n".join(lines) + "\n"


def build(args, key):
    rev, date = git_revision(args.syzkaller)
    log(f"syzkaller revision: {rev} ({date})")
    port = args.ssh_port or free_port()
    vm = VM(args.image, port, args.mem, args.jobs, args.log)
    ssh = SSH(key, port, vm)
    staging = os.path.join(args.out, f".{TARGET}.tmp")
    try:
        log(f"waiting for ssh on port {port}")
        ssh.wait()

        log(f"copying {args.syzkaller} into the vm")
        # ustar is understood by the tar of every bsd
        ssh.pipe(["tar", "-C", args.syzkaller, "--format=ustar",
                  *[f"--exclude={e}" for e in EXCLUDES], "-cf", "-", "."],
                 f"rm -rf {REMOTE} && mkdir -p {REMOTE} && tar -C {REMOTE} -xf -", upload=True)

        log("building")
        ssh.run("sh -s", stdin=None, input=build_script(args, rev, date).encode())

        log(f"copying bin/{TARGET} back")
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging)
        ssh.pipe(["tar", "-C", staging, "-xf", "-"], f"tar -C {REMOTE}/bin -cf - {TARGET}", upload=False)
    except BaseException:
        log(f"failed, see {args.log} for console output")
        raise
    finally:
        vm.kill()

    for name in BINARIES:
        path = os.path.join(staging, TARGET, name)
        if not os.path.isfile(path):
            raise RuntimeError(f"{name} is missing in the build output")
        with open(path, "rb") as f:
            if f.read(4) != b"\x7fELF":
                raise RuntimeError(f"{name} is not an elf file")
    dst = os.path.join(args.out, TARGET)
    shutil.rmtree(dst, ignore_errors=True)
    os.rename(os.path.join(staging, TARGET), dst)
    os.rmdir(staging)
    log(f"{dst} is ready: {' '.join(sorted(os.listdir(dst)))}")


def main():
    mem_gb = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") // (2 << 30)
    dev_img = os.path.join(WORKSPACE, "image", "freebsd", "dev.qcow2")
    default_img = dev_img if os.path.isfile(dev_img) else os.path.join(WORKSPACE, "image", "freebsd", "freebsd.qcow2")
    default_key = os.path.join(WORKSPACE, "image", "freebsd", "freebsd.id_rsa")
    default_syz = os.path.join(WORKSPACE, "syzkaller")

    p = argparse.ArgumentParser(description=f"build the {OS} binaries required by syzkaller")
    p.add_argument("-i", "--image", default=default_img,
                   help=f"image used to build, booted with -snapshot and never modified (default: {default_img})")
    p.add_argument("--syzkaller", default=default_syz,
                   help=f"path to the syzkaller source tree on the host (default: {default_syz})")
    p.add_argument("-o", "--out",
                   help=f"binaries are saved to OUT/{TARGET} (default: SYZKALLER/bin)")
    p.add_argument("-k", "--key", default=default_key,
                   help=f"ssh key of the image (default: {default_key})")
    p.add_argument("-j", "--jobs", type=int, default=os.cpu_count(),
                   help="vm cpus and parallel build jobs (default: nproc)")
    p.add_argument("-m", "--mem", default=f"{max(mem_gb, 4)}G",
                   help="vm memory (default: half of the host memory)")
    p.add_argument("-s", "--ssh-port", type=int, default=0,
                   help="host port forwarded to ssh of the vm (default: pick a free one)")
    p.add_argument("-l", "--log",
                   help=f"console log of the vm (default: OUT/{TARGET}.console.log)")
    p.add_argument("--proxy", help="http(s) proxy used inside the vm, e.g. http://10.0.2.2:7890")
    p.add_argument("--goproxy", help="GOPROXY used inside the vm, e.g. https://goproxy.cn,direct")
    args = p.parse_args()

    if not os.path.isfile(args.image):
        p.error(f"'{args.image}' does not exist")
    if not os.path.isfile(os.path.join(args.syzkaller, "Makefile")):
        p.error(f"'{args.syzkaller}' is not a syzkaller source tree")
    args.image = os.path.realpath(args.image)
    args.syzkaller = os.path.realpath(args.syzkaller)
    args.out = os.path.realpath(args.out or os.path.join(args.syzkaller, "bin"))
    os.makedirs(args.out, exist_ok=True)
    args.log = os.path.realpath(args.log or os.path.join(args.out, f"{TARGET}.console.log"))
    if not os.path.isfile(args.key):
        p.error(f"ssh key '{args.key}' does not exist")

    build(args, os.path.realpath(args.key))


if __name__ == "__main__":
    # make sure qemu is killed by the finally block
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as e:
        sys.exit(f"error: {e}")
