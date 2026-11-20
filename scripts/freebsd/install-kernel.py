#!/usr/bin/env python3

# Install a cross-built FreeBSD kernel (from scripts/freebsd/build.sh) into a
# FreeBSD QCOW2 VM image over SSH, without manual VM interaction.
#
# Because QEMU cannot boot FreeBSD directly with -kernel, the rebuilt /boot/kernel
# must be placed inside the disk image before booting with qemu.sh or syz-crush.
#
# usage:
#   # Install into a copy-on-write QCOW2 overlay (leaves base image untouched):
#   scripts/freebsd/install-kernel.py -i image/freebsd/15.0.0.qcow2 \
#       -o repro/freebsd-test.qcow2
#
#   # Install in-place into an image:
#   scripts/freebsd/install-kernel.py -i image/freebsd/freebsd.qcow2

import argparse
import os
import signal
import socket
import subprocess
import sys
import time

WORKSPACE = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))


def log(msg):
    print(f"[install-kernel] {msg}", flush=True)


def run(cmd, **kwargs):
    log("$ " + " ".join(cmd))
    return subprocess.run(cmd, check=True, **kwargs)


class VM:
    """qemu instance booted persistently (no -snapshot), console goes to logfile"""

    def __init__(self, image, ssh_port, mem, smp, logfile):
        cmd = [
            "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
            "-m", mem, "-smp", str(smp), "-hda", image,
            "-net", "nic", "-net", f"user,hostfwd=tcp:127.0.0.1:{ssh_port}-:22",
            "-display", "none", "-serial", f"file:{logfile}", "-monitor", "none",
        ]
        log("$ " + " ".join(cmd))
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)

    def wait_exit(self, timeout=180):
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError("vm did not power off cleanly")

    def kill(self):
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

    def wait(self, timeout=300):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.vm.proc.poll() is not None:
                raise RuntimeError("qemu exited while waiting for ssh")
            if self.run("true", check=False, stderr=subprocess.DEVNULL).returncode == 0:
                return
            time.sleep(2)
        raise RuntimeError("timeout waiting for ssh")

    def upload_tar(self, src_dir, rel_paths, remote_cmd):
        local = ["tar", "-C", src_dir, "--format=ustar", "-cf", "-", *rel_paths]
        log("$ " + " ".join(local) + " | ssh " + remote_cmd)
        p1 = subprocess.Popen(local, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
        assert p1.stdout is not None
        p2 = subprocess.Popen(self.base + [remote_cmd], stdin=p1.stdout)
        p1.stdout.close()
        rc2, rc1 = p2.wait(), p1.wait()
        if rc1 or rc2:
            raise RuntimeError(f"tar upload failed ({rc1}, {rc2})")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def install(args, target_image, key):
    rel_paths = ["boot/kernel"]
    debug_dir = os.path.join(args.dist, "usr", "lib", "debug", "boot", "kernel")
    if not args.no_debug and os.path.isdir(debug_dir):
        rel_paths.append("usr/lib/debug/boot/kernel")

    port = args.ssh_port or free_port()
    os.makedirs(os.path.dirname(args.log), exist_ok=True)
    vm = VM(target_image, port, args.mem, args.jobs, args.log)
    ssh = SSH(key, port, vm)
    try:
        log(f"waiting for ssh on port {port}")
        ssh.wait()

        log("backing up previous /boot/kernel (if /boot/kernel.old does not exist) and preparing target")
        prep_cmd = (
            "set -eux; "
            "if [ -d /boot/kernel ] && [ ! -d /boot/kernel.old ]; then mv /boot/kernel /boot/kernel.old; fi; "
            "rm -rf /boot/kernel && mkdir -p /boot/kernel"
        )
        if "usr/lib/debug/boot/kernel" in rel_paths:
            prep_cmd += " && rm -rf /usr/lib/debug/boot/kernel && mkdir -p /usr/lib/debug/boot/kernel"
        ssh.run(prep_cmd)

        log(f"installing {', '.join(rel_paths)} from {args.dist}")
        ssh.upload_tar(
            args.dist,
            rel_paths,
            "tar --no-same-owner -C / -xf - && chown -R root:wheel /boot/kernel && "
            "(kldxref /boot/kernel || true) && sync",
        )

        ssh.run("ls -lh /boot/kernel/kernel")
        log("powering off vm cleanly")
        ssh.run("shutdown -p now", check=False)
        vm.wait_exit(180)
    except BaseException:
        log(f"failed, see {args.log} for console output")
        vm.kill()
        raise
    finally:
        vm.kill()
    log(f"kernel installed into {target_image}")


def main():
    default_img = os.path.join(WORKSPACE, "image", "freebsd", "freebsd.qcow2")
    default_key = os.path.join(WORKSPACE, "image", "freebsd", "freebsd.id_rsa")
    default_dist = os.path.join(WORKSPACE, "kernel", "freebsd", "build", "dist")
    default_log = os.path.join(WORKSPACE, "repro", "install-kernel.console.log")

    p = argparse.ArgumentParser(description="install a cross-built FreeBSD kernel into a QCOW2 VM image")
    p.add_argument("-i", "--image", default=default_img,
                   help=f"base FreeBSD qcow2 image (default: {default_img})")
    p.add_argument("-o", "--output",
                   help="optional QCOW2 overlay path backed by --image (leaves --image untouched)")
    p.add_argument("-f", "--force", action="store_true",
                   help="with -o/--output, recreate the QCOW2 overlay from --image before installing")
    p.add_argument("-k", "--key", default=default_key,
                   help=f"ssh private key of the image (default: {default_key})")
    p.add_argument("-d", "--dist", default=default_dist,
                   help=f"DESTDIR containing boot/kernel from build.sh (default: {default_dist})")
    p.add_argument("-j", "--jobs", type=int, default=min(os.cpu_count() or 2, 4),
                   help="vm vCPUs (default: min(nproc, 4))")
    p.add_argument("-m", "--mem", default="2G",
                   help="vm memory (default: 2G)")
    p.add_argument("-s", "--ssh-port", type=int, default=0,
                   help="host port forwarded to ssh of the vm (default: pick a free one)")
    p.add_argument("-l", "--log", default=default_log,
                   help=f"console log of the vm (default: {default_log})")
    p.add_argument("--no-debug", action="store_true",
                   help="skip installing /usr/lib/debug/boot/kernel into the image")
    args = p.parse_args()

    if not os.path.isfile(args.image):
        p.error(f"image '{args.image}' does not exist")
    if not os.path.isfile(args.key):
        p.error(f"ssh key '{args.key}' does not exist")
    kernel_bin = os.path.join(args.dist, "boot", "kernel", "kernel")
    if not os.path.isfile(kernel_bin):
        p.error(f"built kernel '{kernel_bin}' does not exist; run 'make freebsd' first")

    args.image = os.path.realpath(args.image)
    args.key = os.path.realpath(args.key)
    args.dist = os.path.realpath(args.dist)
    args.log = os.path.realpath(args.log)

    if args.output:
        target_image = os.path.realpath(args.output)
        if target_image == args.image:
            p.error("--output must differ from --image")
        os.makedirs(os.path.dirname(target_image), exist_ok=True)
        if args.force and os.path.exists(target_image):
            os.remove(target_image)
        if not os.path.exists(target_image):
            run(["qemu-img", "create", "-f", "qcow2", "-b", args.image, "-F", "qcow2", target_image])
    else:
        target_image = args.image

    install(args, target_image, args.key)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as e:
        sys.exit(f"error: {e}")
