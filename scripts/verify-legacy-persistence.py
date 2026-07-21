#!/usr/bin/env python3
"""Verify the on-disk NOTES.TXT mutation produced by Capstone 9 userspace."""
from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

BPS = 512
FAT_LBA = 256
ROOT_START = 19
DATA_START = 33
SPF = 9
EXPECTED = bytes((ord("a") + (i % 26)) for i in range(700)) + b"APPEND-PERSIST-OK!\r\n"
EXPECTED_HASH = 0xC6181D2F


def fnv1a32(data: bytes) -> int:
    value = 0x811C9DC5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return value


def entry(fat: bytes, cluster: int) -> int:
    offset = cluster + cluster // 2
    pair = fat[offset] | fat[offset + 1] << 8
    return ((pair >> 4) & 0xFFF) if cluster & 1 else pair & 0xFFF


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    args = parser.parse_args()
    image = args.image.read_bytes()
    if len(image) != 2 * 1024 * 1024:
        raise SystemExit("persistent disk image size invalid")
    volume = image[FAT_LBA * BPS : (FAT_LBA + 2880) * BPS]
    fat1 = volume[BPS : (1 + SPF) * BPS]
    fat2 = volume[(1 + SPF) * BPS : (1 + 2 * SPF) * BPS]
    if fat1 != fat2:
        raise SystemExit("persistent FAT12 copies differ")
    root = ROOT_START * BPS + 8 * 32
    if volume[root : root + 11] != b"NOTES   TXT" or volume[root + 11] != 0x20:
        raise SystemExit("persistent NOTES.TXT root entry invalid")
    first = struct.unpack_from("<H", volume, root + 26)[0]
    size = struct.unpack_from("<I", volume, root + 28)[0]
    if first != 14 or size != 720:
        raise SystemExit(f"persistent NOTES.TXT geometry invalid: cluster={first} size={size}")
    second = entry(fat1, first)
    end = entry(fat1, second)
    if second != 15 or end < 0xFF8:
        raise SystemExit(f"persistent NOTES.TXT chain invalid: {first}->{second}->{end:#x}")
    content = bytearray()
    for cluster in (14, 15):
        offset = (DATA_START + cluster - 2) * BPS
        content += volume[offset : offset + BPS]
    content = bytes(content[:size])
    if content != EXPECTED:
        raise SystemExit("persistent NOTES.TXT content invalid")
    digest = fnv1a32(content)
    if digest != EXPECTED_HASH:
        raise SystemExit(f"persistent NOTES.TXT hash invalid: {digest:08X}")
    if entry(fat1, 16) != 0:
        raise SystemExit("unexpected allocation beyond deterministic two-cluster file")
    print("Verified Capstone 9 persistent FAT12 mutation")
    print("  NOTES.TXT: root slot 8, 720 bytes, clusters 14->15->EOC")
    print(f"  FNV-1a32: 0x{digest:08X}")
    print(f"  image sha256: {hashlib.sha256(image).hexdigest().upper()}")


if __name__ == "__main__":
    main()
