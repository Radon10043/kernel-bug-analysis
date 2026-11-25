#!/usr/bin/env python3

# Create FreeBSD VM images for kernel bug analysis without manual VM interaction.
# Modeled after omnislash/scripts/freebsd/create-image.py.
#
# usage:
#   # freebsd.qcow2: VM used to build syzkaller target binaries, stock kernel
#   scripts/freebsd/create-image.py -i 15.0
#   # 15.0.0.qcow2: VM running kernel release/15.0.0 built with the given config
#   scripts/freebsd/create-image.py -i 15.0 -k 15.0.0 -c config/freebsd/freebsd.config
#
# how it works:
#   - download the official VM image and resize it
#   - drive the serial console to escape to the loader prompt, switch console
#     to comconsole, log in as root and enable sshd with our public key
#   - everything else (packages, kernel build, reboot, verify) goes through ssh

import argparse
import lzma
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

WORKSPACE = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))

URLS = [
    "https://archive.freebsd.org/old-releases/VM-IMAGES/{rel}-RELEASE/amd64/Latest/{file}",
    "https://download.freebsd.org/releases/VM-IMAGES/{rel}-RELEASE/amd64/Latest/{file}",
]
PACKAGES = [
    "bash", "curl", "gcc", "git", "gmake", "go", "golangci-lint", "llvm", "cmake",
    "vim", "dnsmasq", "wget", "tmux", "ccache", "pkgconf", "sqlite3", "python3",
]
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
MARK = "__KBA_"


def log(msg):
    print(f"[create-image] {msg}", flush=True)


def run(cmd, **kwargs):
    log("$ " + " ".join(cmd))
    return subprocess.run(cmd, check=True, **kwargs)


def parse_kernconf(config_path):
    with open(config_path) as f:
        for line in f:
            m = re.match(r"^\s*ident\s+(\S+)", line)
            if m:
                return m.group(1)
    return "SYZKALLER"


class VM:
    """qemu instance whose serial console is attached to our pipes"""

    def __init__(self, image, ssh_port, mem, smp, logfile):
        self.buf = ""
        self.cond = threading.Condition()
        self.logfile = open(logfile, "wb")
        # -nographic is required, it makes seabios mirror the vga text console
        # (i.e., the loader menu) to the serial port
        cmd = [
            "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
            "-m", mem, "-smp", str(smp), "-hda", image,
            "-net", "nic", "-net", f"user,hostfwd=tcp:127.0.0.1:{ssh_port}-:22",
            "-nographic", "-serial", "stdio", "-monitor", "none",
        ]
        log("$ " + " ".join(cmd))
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, bufsize=0)
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        # keep draining the console, otherwise qemu blocks once the pipe is full
        while True:
            assert self.proc.stdout is not None
            data = os.read(self.proc.stdout.fileno(), 4096)
            if not data:
                break
            self.logfile.write(data)
            self.logfile.flush()
            with self.cond:
                self.buf = ANSI.sub("", self.buf + data.decode("utf-8", "replace"))
                self.cond.notify_all()
        with self.cond:
            self.cond.notify_all()

    def expect(self, pattern, timeout):
        """wait until pattern shows up on the console, consume output up to the match"""
        deadline = time.time() + timeout
        with self.cond:
            while True:
                m = re.search(pattern, self.buf)
                if m:
                    self.buf = self.buf[m.end():]
                    return m
                if self.proc.poll() is not None:
                    raise RuntimeError(f"qemu exited while waiting for {pattern!r}")
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise RuntimeError(f"timeout waiting for {pattern!r} on the console")
                self.cond.wait(min(remaining, 1))

    def send(self, text):
        # feed the uart slowly, it has no flow control
        data = text.encode()
        for i in range(0, len(data), 32):
            assert self.proc.stdin is not None
            self.proc.stdin.write(data[i:i + 32])
            time.sleep(0.02)

    def sh(self, cmd, timeout=120):
        """run a command in the root shell on the console and check its exit code"""
        # the marker is split in the command line so that the echo of what we
        # typed can not be mistaken for the output
        self.send(f'{cmd}; echo "{MARK}""RC=$?"\r')
        rc = self.expect(MARK + r"RC=(\d+)", timeout).group(1)
        if rc != "0":
            raise RuntimeError(f"console command failed with {rc}: {cmd}")

    def wait_exit(self, timeout):
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError("vm did not power off")

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


class SSH:
    def __init__(self, key, port):
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

    def output(self, cmd):
        return self.run(cmd, stdout=subprocess.PIPE, text=True).stdout.strip()

    def wait(self, timeout=300):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.run("true", check=False, stderr=subprocess.DEVNULL).returncode == 0:
                return
            time.sleep(3)
        raise RuntimeError("timeout waiting for ssh")

    def put(self, content, path):
        self.run(f"cat > {path}", stdin=None, input=content.encode())


def fetch_image(outdir, rel):
    """download FreeBSD-<rel>-RELEASE-amd64-ufs.qcow2.xz into outdir (cached)"""
    name = f"FreeBSD-{rel}-RELEASE-amd64-ufs.qcow2.xz"
    path = os.path.join(outdir, name)
    if os.path.exists(path):
        return path
    for url in URLS:
        url = url.format(rel=rel, file=name)
        try:
            run(["wget", "-c", "--progress=dot:giga", "-O", path + ".part", url])
        except subprocess.CalledProcessError:
            continue
        os.rename(path + ".part", path)
        return path
    raise RuntimeError(f"failed to download {name}")


def bootstrap(vm, pubkey, args):
    """the only part that needs the serial console: get sshd up with our key"""
    log("waiting for the loader menu")
    vm.expect(r"Autoboot|Escape to loader|Boot Multi", 120)
    vm.send("3")
    vm.expect(r"OK\s*$", 30)
    vm.send('set console="comconsole"\r')
    vm.expect(r"OK\s*$", 30)
    vm.send("boot\r")
    log("booting, waiting for the login prompt")
    vm.expect(r"login: ", 600)
    vm.send("root\r")
    vm.expect(r"root@\S*:~ # ", 60)
    log("configuring loader, growfs and sshd through the console")
    # no line editing and no echo, they garble long lines on the console
    vm.sh("set +o emacs +o vi; stty -echo")
    for cmd in [
        "echo 'autoboot_delay=\"-1\"' >> /boot/loader.conf",
        "echo 'console=\"comconsole\"' >> /boot/loader.conf",
        "/etc/rc.d/growfs onestart",
        "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config",
        "echo 'PermitEmptyPasswords yes' >> /etc/ssh/sshd_config",
        "echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config",
        "echo 'UseDNS no' >> /etc/ssh/sshd_config",
        "echo 'GSSAPIAuthentication no' >> /etc/ssh/sshd_config",
        "grep -q '^Subsystem' /etc/ssh/sshd_config || "
        "echo 'Subsystem sftp /usr/libexec/sftp-server' >> /etc/ssh/sshd_config",
        "mkdir -p /root/.ssh && chmod 700 /root/.ssh",
        f"echo '{pubkey}' >> /root/.ssh/authorized_keys",
        "chmod 600 /root/.ssh/authorized_keys",
        "sysrc sshd_enable=YES ifconfig_DEFAULT=DHCP",
        # not restart: only start generates the host keys before the config check
        "service sshd start",
    ]:
        vm.sh(cmd)
    if args.password is not None:
        vm.sh(f"echo '{args.password}' | pw usermod root -h 0")


def provision_script(args, version, kernconf):
    lines = ["set -eux"]
    if args.proxy:
        lines += [
            f"echo 'export http_proxy={args.proxy}' >> /root/.shrc",
            f"echo 'export https_proxy={args.proxy}' >> /root/.shrc",
            f"export http_proxy={args.proxy} https_proxy={args.proxy}",
        ]
    lines += [
        "export ASSUME_ALWAYS_YES=true",
        "pkg update -f",
        "pkg install " + " ".join(PACKAGES),
    ]
    if version:
        branch = f"release/{version}" if re.fullmatch(r"\d+\.\d+\.\d+", version) else version
        srcdir = re.sub(r"[^A-Za-z0-9._-]", "_", version)
        lines += [
            "cd /root",
            f"git clone -b {branch} --depth 1 --progress https://github.com/freebsd/freebsd-src {srcdir}",
            f"cd {srcdir}",
            f"cp /root/freebsd.config sys/amd64/conf/{kernconf}",
            f"cd sys/amd64/conf && config {kernconf}",
            f"cd ../compile/{kernconf}",
            "make cleandepend && make depend",
            f"make -j{args.jobs} && make install",
        ]
    return "\n".join(lines) + "\n"


def create(args, key):
    version, rel = args.kernel_version, args.image_version
    target = re.sub(r"[^A-Za-z0-9._-]", "-", version) if version else "freebsd"
    image = os.path.join(args.outdir, f"{target}.qcow2")
    # work on a temporary name so that a half-configured image is never picked up
    tmp = image + ".tmp"
    if os.path.exists(image):
        if not args.force:
            log(f"{image} already exists, skipping (use --force to recreate)")
            return
        os.remove(image)

    kernconf = parse_kernconf(args.config) if version else None

    xz = fetch_image(args.outdir, rel)
    log(f"extracting {xz} -> {tmp}")
    with lzma.open(xz) as src, open(tmp, "wb") as dst:
        shutil.copyfileobj(src, dst, 4 << 20)
    run(["qemu-img", "resize", tmp, args.size])

    with open(key + ".pub") as f:
        pubkey = f.read().strip()
    ssh = SSH(key, args.ssh_port)
    vm = VM(tmp, args.ssh_port, args.mem, args.jobs, os.path.join(args.outdir, f"{target}.console.log"))
    try:
        bootstrap(vm, pubkey, args)
        ssh.wait()

        log("provisioning through ssh")
        if version:
            with open(args.config) as f:
                ssh.put(f.read(), "/root/freebsd.config")
        ssh.put(provision_script(args, version, kernconf), "/root/provision.sh")
        ssh.run("sh /root/provision.sh")

        if version:
            log("rebooting into the new kernel")
            ssh.run("shutdown -r now", check=False)
            vm.expect(r"login: ", 600)
            ssh.wait()
            uname = ssh.output("uname -a")
            log(f"uname: {uname}")

        ssh.run("shutdown -p now", check=False)
        vm.wait_exit(300)
    except BaseException:
        log(f"failed, the image is kept at {tmp}, see {vm.logfile.name} for console output")
        raise
    finally:
        vm.kill()
    os.rename(tmp, image)
    log(f"{image} is ready")


def main():
    mem_gb = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") // (2 << 30)
    default_outdir = os.path.join(WORKSPACE, "image", "freebsd")
    default_config = os.path.join(WORKSPACE, "config", "freebsd", "freebsd.config")

    p = argparse.ArgumentParser(description="create a FreeBSD VM image for bug analysis")
    p.add_argument("-o", "--outdir", default=default_outdir,
                   help=f"directory for images and the ssh key (default: {default_outdir})")
    p.add_argument("-i", "--image-version", required=True, metavar="X.Y",
                   help="release of the official vm image to start from, e.g. 15.0")
    p.add_argument("-k", "--kernel-version", metavar="VER",
                   help="build and install kernel release/X.Y.Z (e.g. 15.0.0) or git branch/tag "
                        "(e.g. main, releng/15.0); omit to skip kernel build and save freebsd.qcow2")
    p.add_argument("-c", "--config", default=default_config,
                   help=f"kernel config used with --kernel-version (default: {default_config})")
    p.add_argument("-j", "--jobs", type=int, default=os.cpu_count(),
                   help="vm cpus and parallel build jobs (default: nproc)")
    p.add_argument("-m", "--mem", default=f"{max(mem_gb, 4)}G",
                   help="vm memory (default: half of the host memory)")
    p.add_argument("-s", "--ssh-port", type=int, default=3733,
                   help="host port forwarded to ssh of the vm (default: 3733)")
    p.add_argument("--size", default="100G", help="image size (default: 100G)")
    p.add_argument("--proxy", help="http(s) proxy used inside the vm, e.g. http://10.0.2.2:7890")
    p.add_argument("--password", help="set root password (default: left empty, login with the ssh key)")
    p.add_argument("-f", "--force", action="store_true", help="recreate the image if it already exists")
    args = p.parse_args()

    if not re.fullmatch(r"\d+\.\d+", args.image_version):
        p.error(f"invalid image version: {args.image_version}")
    if args.kernel_version:
        if not args.config or not os.path.isfile(args.config):
            p.error(f"kernel config '{args.config}' does not exist")

    args.outdir = os.path.realpath(args.outdir)
    os.makedirs(args.outdir, exist_ok=True)
    key = os.path.join(args.outdir, "freebsd.id_rsa")
    if not os.path.exists(key):
        run(["ssh-keygen", "-t", "rsa", "-f", key, "-N", ""])
    else:
        log(f"using existing ssh key at {key}")

    create(args, key)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as e:
        sys.exit(f"error: {e}")
