#!/usr/bin/env python3

# Extract compressed filesystem or partition-table disk images embedded in
# syzkaller C reproducers (repro.c) or syzkaller programs (repro.syz).
#
# Upstream Asterinas does not include /dev/loop* devices, so syz_mount_image
# and syz_read_part_table C reproducers fail before reaching mount(). Extracting
# the raw disk image lets QEMU attach it directly via --scratch-exfat
# (/dev/nvme0n1) or --scratch-ext2 (/dev/vdb) on an unpatched kernel.
#
# Usage:
#   scripts/asterinas/extract-image.py repro/repro.c -o repro/exfat.img
#   scripts/asterinas/extract-image.py repro/repro.syz -o repro/exfat.img
#   scripts/asterinas/extract-image.py --list repro/repro.c
#   scripts/asterinas/extract-image.py --all repro/repro.c -o repro/extracted

import argparse
import base64
import hashlib
import os
import pathlib
import re
import sys
import zlib
from dataclasses import dataclass

WORKSPACE = pathlib.Path(__file__).resolve().parents[2]
ZLIB_HEADER_WIDTH = 2
SECTOR_SIZE = 512


@dataclass
class EmbeddedImage:
    call: str
    fs_type: str
    declared_size: int | None
    compressed: bytes
    raw: bytes


def unescape_c_string(literal: str) -> bytes:
    """Decode the body of a C string literal into raw bytes."""
    out = bytearray()
    i = 0
    n = len(literal)
    simple = {
        "a": 0x07,
        "b": 0x08,
        "f": 0x0C,
        "n": 0x0A,
        "r": 0x0D,
        "t": 0x09,
        "v": 0x0B,
        "\\": 0x5C,
        "'": 0x27,
        '"': 0x22,
        "?": 0x3F,
    }
    while i < n:
        ch = literal[i]
        if ch != "\\":
            out.append(ord(ch) & 0xFF)
            i += 1
            continue
        i += 1
        if i >= n:
            break
        esc = literal[i]
        if esc in simple:
            out.append(simple[esc])
            i += 1
        elif esc == "x":
            i += 1
            start = i
            while i < n and literal[i] in "0123456789abcdefABCDEF":
                i += 1
            if i == start:
                raise ValueError(f"invalid hex escape near offset {start}")
            out.append(int(literal[start:i], 16) & 0xFF)
        elif esc in "01234567":
            start = i
            end = min(n, i + 3)
            while i < end and literal[i] in "01234567":
                i += 1
            out.append(int(literal[start:i], 8) & 0xFF)
        else:
            out.append(ord(esc) & 0xFF)
            i += 1
    return bytes(out)


def parse_c_int(expr: str) -> int | None:
    """Extract an integer literal (possibly prefixed by a comment or cast)."""
    cleaned = re.sub(r"/\*.*?\*/", " ", expr, flags=re.S)
    m = re.search(r"(0x[0-9a-fA-F]+|\d+)", cleaned)
    if not m:
        return None
    return int(m.group(1), 0)


def inflate_syz_image(compressed: bytes, declared_size: int | None) -> bytes:
    """Decompress a syzkaller zlib image matching puff_zlib_to_file() semantics."""
    candidates: list[bytes] = []
    if declared_size is not None and ZLIB_HEADER_WIDTH < declared_size <= len(compressed):
        candidates.append(compressed[:declared_size])
    if not candidates or candidates[0] != compressed:
        candidates.append(compressed)

    last_err: Exception | None = None
    for buf in candidates:
        if len(buf) < ZLIB_HEADER_WIDTH:
            continue
        # Match syzkaller puff_zlib_to_file(): skip the 2-byte zlib header and
        # inflate raw DEFLATE without failing on truncated/mutated adler32 trailers.
        try:
            decomp = zlib.decompressobj(-zlib.MAX_WBITS)
            data = decomp.decompress(buf[ZLIB_HEADER_WIDTH:]) + decomp.flush()
            if data:
                return data
        except zlib.error as exc:
            last_err = exc
        try:
            return zlib.decompress(buf)
        except zlib.error as exc:
            last_err = exc

    raise ValueError(f"failed to decompress embedded zlib image: {last_err}")


def extract_from_syz(text: str) -> list[EmbeddedImage]:
    """Extract embedded images from a syzkaller .syz program or log."""
    results: list[EmbeddedImage] = []
    seen: set[tuple[str, str, int | None, bytes]] = set()

    call_re = re.compile(
        r"\b(syz_mount_image(?:\$([A-Za-z0-9_]+))?|syz_read_part_table)\s*\(([^\n]+)\)"
    )
    blob_re = re.compile(r'"\$([A-Za-z0-9+/=_-]+)"')

    for m in call_re.finditer(text):
        call_full = m.group(1)
        fs_type = m.group(2) or ("parttable" if call_full == "syz_read_part_table" else "unknown")
        args_str = m.group(3)
        blob_m = blob_re.search(args_str)
        if not blob_m:
            continue
        b64_str = blob_m.group(1)
        # Recover declared compressed size argument immediately preceding the buffer.
        prefix = args_str[: blob_m.start()]
        size_matches = re.findall(r"(0x[0-9a-fA-F]+|\d+)\s*,\s*&\([^)]*\)\s*=\s*$", prefix)
        declared_size = int(size_matches[-1], 0) if size_matches else None

        compressed = base64.b64decode(b64_str)
        key = (call_full, fs_type, declared_size, compressed)
        if key in seen:
            continue
        seen.add(key)

        raw = inflate_syz_image(compressed, declared_size)
        results.append(
            EmbeddedImage(
                call=call_full,
                fs_type=fs_type,
                declared_size=declared_size,
                compressed=compressed,
                raw=raw,
            )
        )

    return results


def extract_from_c(text: str) -> list[EmbeddedImage]:
    """Extract embedded images from a syzkaller C reproducer in source order."""
    memcpy_re = re.compile(
        r"memcpy\s*\(\s*\(void\s*\*\)\s*(0x[0-9a-fA-F]+|\d+)[uUlL]*\s*,\s*"
        r'((?:"(?:\\.|[^"\\])*"\s*)+)\s*,\s*(0x[0-9a-fA-F]+|\d+)[uUlL]*\s*\)\s*;',
        re.S,
    )
    str_re = re.compile(r'"((?:\\.|[^"\\])*)"')
    mount_re = re.compile(r"\bsyz_mount_image\s*\(([^;]+?)\)\s*;", re.S)
    part_re = re.compile(r"\bsyz_read_part_table\s*\(([^;]+?)\)\s*;", re.S)

    events: list[tuple[int, str, re.Match[str]]] = []
    for m in memcpy_re.finditer(text):
        events.append((m.start(), "memcpy", m))
    for m in mount_re.finditer(text):
        events.append((m.start(), "mount", m))
    for m in part_re.finditer(text):
        events.append((m.start(), "part", m))
    events.sort(key=lambda item: item[0])

    buffers: dict[int, bytes] = {}
    results: list[EmbeddedImage] = []
    seen: set[tuple[str, str, int | None, bytes]] = set()

    for _, kind, m in events:
        if kind == "memcpy":
            addr = int(m.group(1), 0)
            chunks = [unescape_c_string(s.group(1)) for s in str_re.finditer(m.group(2))]
            data = b"".join(chunks)
            declared_len = int(m.group(3), 0)
            if len(data) < declared_len:
                data += b"\x00" * (declared_len - len(data))
            elif len(data) > declared_len:
                data = data[:declared_len]
            buffers[addr] = data
            continue

        if kind == "mount":
            args = m.group(1).split(",")
            if len(args) < 7:
                continue
            fs_addr = parse_c_int(args[0])
            declared_size = parse_c_int(args[5])
            img_addr = parse_c_int(args[6])
            if img_addr is None or img_addr not in buffers:
                continue

            fs_type = "unknown"
            if fs_addr is not None and fs_addr in buffers:
                raw_fs = buffers[fs_addr].split(b"\x00", 1)[0]
                decoded = raw_fs.decode("ascii", errors="ignore").strip()
                if decoded:
                    fs_type = decoded

            compressed = buffers[img_addr]
            key = ("syz_mount_image", fs_type, declared_size, compressed)
            if key in seen:
                continue
            seen.add(key)

            raw = inflate_syz_image(compressed, declared_size)
            results.append(
                EmbeddedImage(
                    call=f"syz_mount_image${fs_type}" if fs_type != "unknown" else "syz_mount_image",
                    fs_type=fs_type,
                    declared_size=declared_size,
                    compressed=compressed,
                    raw=raw,
                )
            )
            continue

        if kind == "part":
            args = m.group(1).split(",")
            if len(args) < 2:
                continue
            declared_size = parse_c_int(args[0])
            img_addr = parse_c_int(args[1])
            if img_addr is None or img_addr not in buffers:
                continue

            compressed = buffers[img_addr]
            key = ("syz_read_part_table", "parttable", declared_size, compressed)
            if key in seen:
                continue
            seen.add(key)

            raw = inflate_syz_image(compressed, declared_size)
            results.append(
                EmbeddedImage(
                    call="syz_read_part_table",
                    fs_type="parttable",
                    declared_size=declared_size,
                    compressed=compressed,
                    raw=raw,
                )
            )

    return results


def extract_images(path: pathlib.Path, fmt: str) -> list[EmbeddedImage]:
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    if fmt == "syz":
        return extract_from_syz(text)
    if fmt == "c":
        return extract_from_c(text)

    # Auto-detect format by file extension first, then fall back to the other parser.
    if path.suffix == ".c":
        images = extract_from_c(text)
        return images if images else extract_from_syz(text)
    images = extract_from_syz(text)
    return images if images else extract_from_c(text)


def sanitize_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", name).strip("_")
    return cleaned or "image"


def suggest_commands(img: EmbeddedImage, out_path: pathlib.Path) -> tuple[str, str | None]:
    rel = os.path.relpath(out_path, WORKSPACE) if out_path.is_relative_to(WORKSPACE) else str(out_path)
    if img.fs_type == "ext2":
        qemu_cmd = f"scripts/asterinas/qemu.sh --scratch-ext2 {rel}"
        mount_cmd = "mkdir -p /tmp/mnt && mount -t ext2 /dev/vdb /tmp/mnt"
    elif img.fs_type == "parttable":
        qemu_cmd = f"scripts/asterinas/qemu.sh --scratch-ext2 {rel}"
        mount_cmd = None
    else:
        qemu_cmd = f"scripts/asterinas/qemu.sh --scratch-exfat {rel}"
        fs_arg = img.fs_type if img.fs_type != "unknown" else "exfat"
        mount_cmd = f"mkdir -p /tmp/mnt && mount -t {fs_arg} /dev/nvme0n1 /tmp/mnt"
    return qemu_cmd, mount_cmd


def default_input_path() -> pathlib.Path:
    for rel in ("repro/repro.c", "repro/repro.syz"):
        cand = WORKSPACE / rel
        if cand.is_file():
            return cand
    return WORKSPACE / "repro/repro.c"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Extract compressed filesystem or partition-table images embedded in "
            "syzkaller C reproducers (repro.c) or syz programs (repro.syz)."
        )
    )
    parser.add_argument(
        "input",
        nargs="?",
        help="Path to repro.c or repro.syz (default: repro/repro.c, or repro/repro.syz)",
    )
    parser.add_argument(
        "-i",
        "--input",
        dest="input_opt",
        metavar="FILE",
        help="Input reproducer path (alternative to positional input)",
    )
    parser.add_argument(
        "-o",
        "--output",
        metavar="PATH",
        help=(
            "Output image file path (single image) or output directory "
            "(with --all or when path is an existing directory). "
            "Default: repro/<fs>.img"
        ),
    )
    parser.add_argument(
        "--format",
        choices=("auto", "c", "syz"),
        default="auto",
        help="Force input parser format instead of auto-detection (default: auto)",
    )
    parser.add_argument(
        "--index",
        type=int,
        default=None,
        help="Zero-based index of the image to extract when multiple images exist",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Extract all embedded images into the output directory",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List embedded images without writing any files",
    )
    parser.add_argument(
        "--pad-512",
        action="store_true",
        help="Zero-pad output image up to a 512-byte sector boundary if unaligned",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.input and args.input_opt:
        print("error: specify input either positionally or via -i/--input, not both", file=sys.stderr)
        return 1
    if args.all and args.index is not None:
        print("error: --all and --index cannot be combined", file=sys.stderr)
        return 1

    input_path = pathlib.Path(args.input_opt or args.input) if (args.input or args.input_opt) else default_input_path()
    if not input_path.is_file():
        print(f"error: input file not found: {input_path}", file=sys.stderr)
        return 1

    try:
        images = extract_images(input_path, args.format)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not images:
        print(f"error: no embedded syz_mount_image or syz_read_part_table images found in {input_path}", file=sys.stderr)
        return 1

    if args.list:
        for idx, img in enumerate(images):
            digest = hashlib.sha256(img.raw).hexdigest()[:12]
            print(
                f"[{idx}] call={img.call} fs={img.fs_type} "
                f"compressed={len(img.compressed)}B raw={len(img.raw)}B sha256={digest}"
            )
        return 0

    if args.all:
        selected = list(enumerate(images))
    elif args.index is not None:
        if args.index < 0 or args.index >= len(images):
            print(f"error: --index {args.index} out of range (found {len(images)} image(s))", file=sys.stderr)
            return 1
        selected = [(args.index, images[args.index])]
    elif len(images) == 1:
        selected = [(0, images[0])]
    else:
        print(
            f"error: found {len(images)} embedded images in {input_path}; "
            "pass --index N or --all (use --list to inspect)",
            file=sys.stderr,
        )
        for idx, img in enumerate(images):
            print(f"  [{idx}] call={img.call} fs={img.fs_type} raw={len(img.raw)}B", file=sys.stderr)
        return 1

    out_arg = pathlib.Path(args.output) if args.output else None
    written: list[tuple[EmbeddedImage, pathlib.Path]] = []

    for idx, img in selected:
        data = img.raw
        if args.pad_512 and len(data) % SECTOR_SIZE != 0:
            data = data + b"\x00" * (SECTOR_SIZE - (len(data) % SECTOR_SIZE))

        fs_slug = sanitize_name(img.fs_type)
        if len(selected) == 1 and out_arg is not None and not out_arg.is_dir():
            dest = out_arg
        else:
            out_dir = out_arg if out_arg is not None else (WORKSPACE / "repro")
            filename = f"{fs_slug}.img" if len(images) == 1 else f"{fs_slug}-{idx}.img"
            dest = out_dir / filename

        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        print(
            f"[extract-image] wrote {dest} "
            f"(call={img.call}, fs={img.fs_type}, size={len(data)} bytes, sha256={digest[:16]})"
        )
        written.append((img, dest.resolve()))

    if len(written) == 1:
        img, dest = written[0]
        qemu_cmd, mount_cmd = suggest_commands(img, dest)
        print(f"[extract-image] QEMU:  {qemu_cmd}")
        if mount_cmd:
            print(f"[extract-image] Guest: {mount_cmd}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
