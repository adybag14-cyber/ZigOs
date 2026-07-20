#!/usr/bin/env python3
"""Create the deterministic ZigOs legacy FAT12 volume."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

BYTES_PER_SECTOR = 512
TOTAL_SECTORS = 2880
SECTORS_PER_CLUSTER = 1
RESERVED_SECTORS = 1
FAT_COUNT = 2
ROOT_ENTRIES = 224
SECTORS_PER_FAT = 9
ROOT_SECTORS = (ROOT_ENTRIES * 32 + BYTES_PER_SECTOR - 1) // BYTES_PER_SECTOR
FAT_START = RESERVED_SECTORS
ROOT_START = FAT_START + FAT_COUNT * SECTORS_PER_FAT
DATA_START = ROOT_START + ROOT_SECTORS
FILE_NAME = b"HELLO   TXT"
FILE_CONTENT = (
    b"ZigOs legacy FAT12 filesystem is online.\r\n"
    b"Loaded through ATA PIO by the i686 kernel.\r\n"
)


def fnv1a32(data: bytes) -> int:
    value = 0x811C9DC5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return value


def set_fat12_entry(fat: bytearray, cluster: int, value: int) -> None:
    offset = cluster + cluster // 2
    value &= 0x0FFF
    if cluster & 1:
        fat[offset] = (fat[offset] & 0x0F) | ((value << 4) & 0xF0)
        fat[offset + 1] = (value >> 4) & 0xFF
    else:
        fat[offset] = value & 0xFF
        fat[offset + 1] = (fat[offset + 1] & 0xF0) | ((value >> 8) & 0x0F)


def build_volume() -> bytes:
    volume = bytearray(TOTAL_SECTORS * BYTES_PER_SECTOR)
    boot = memoryview(volume)[:BYTES_PER_SECTOR]
    boot[0:3] = b"\xEB\x3C\x90"
    boot[3:11] = b"ZIGOS   "
    struct.pack_into("<H", boot, 11, BYTES_PER_SECTOR)
    boot[13] = SECTORS_PER_CLUSTER
    struct.pack_into("<H", boot, 14, RESERVED_SECTORS)
    boot[16] = FAT_COUNT
    struct.pack_into("<H", boot, 17, ROOT_ENTRIES)
    struct.pack_into("<H", boot, 19, TOTAL_SECTORS)
    boot[21] = 0xF0
    struct.pack_into("<H", boot, 22, SECTORS_PER_FAT)
    struct.pack_into("<H", boot, 24, 18)
    struct.pack_into("<H", boot, 26, 2)
    struct.pack_into("<I", boot, 28, 64)
    struct.pack_into("<I", boot, 32, 0)
    boot[36] = 0x80
    boot[37] = 0
    boot[38] = 0x29
    struct.pack_into("<I", boot, 39, 0x5A49474F)
    boot[43:54] = b"ZIGOS FAT12"
    boot[54:62] = b"FAT12   "
    message = b"ZigOs FAT12 data volume"
    boot[62 : 62 + len(message)] = message
    boot[510:512] = b"\x55\xAA"

    fat = bytearray(SECTORS_PER_FAT * BYTES_PER_SECTOR)
    fat[0:3] = b"\xF0\xFF\xFF"
    set_fat12_entry(fat, 2, 0x0FFF)
    for copy_index in range(FAT_COUNT):
        start = (FAT_START + copy_index * SECTORS_PER_FAT) * BYTES_PER_SECTOR
        volume[start : start + len(fat)] = fat

    root_offset = ROOT_START * BYTES_PER_SECTOR
    volume[root_offset : root_offset + 11] = FILE_NAME
    volume[root_offset + 11] = 0x20
    struct.pack_into("<H", volume, root_offset + 26, 2)
    struct.pack_into("<I", volume, root_offset + 28, len(FILE_CONTENT))

    data_offset = DATA_START * BYTES_PER_SECTOR
    volume[data_offset : data_offset + len(FILE_CONTENT)] = FILE_CONTENT
    return bytes(volume)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    volume = build_volume()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(volume)
    print(
        f"Created FAT12 volume: {args.output} | sectors={TOTAL_SECTORS} "
        f"root={ROOT_START} data={DATA_START} file_bytes={len(FILE_CONTENT)} "
        f"fnv1a32={fnv1a32(FILE_CONTENT):08X}"
    )


if __name__ == "__main__":
    main()
