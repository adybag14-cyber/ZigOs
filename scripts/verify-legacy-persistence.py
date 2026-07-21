#!/usr/bin/env python3
"""Verify Capstone 13 nested FAT12 and NOTES.TXT persistence."""
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
NOTES = bytes((ord("a") + (i % 26)) for i in range(700)) + b"APPEND-PERSIST-OK!\r\n"
NOTES_HASH = 0xC6181D2F
PATH_PAYLOAD = bytes(((index * 29 + 7) & 0xFF) for index in range(600))
PATH_HASH = 0x36F73195


def fail(message: str) -> None:
    raise SystemExit(message)


def fnv1a32(data: bytes) -> int:
    value = 0x811C9DC5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return value


def entry(fat: bytes, cluster: int) -> int:
    offset = cluster + cluster // 2
    pair = fat[offset] | fat[offset + 1] << 8
    return ((pair >> 4) & 0xFFF) if cluster & 1 else pair & 0xFFF


def cluster_sector(volume: bytes, cluster: int) -> bytes:
    offset = (DATA_START + cluster - 2) * BPS
    return volume[offset : offset + BPS]


def check_dir_entry(sector: bytes, index: int, name: bytes, attributes: int, cluster: int, size: int = 0) -> None:
    offset = index * 32
    actual = sector[offset : offset + 11]
    attr = sector[offset + 11]
    first = struct.unpack_from("<H", sector, offset + 26)[0]
    actual_size = struct.unpack_from("<I", sector, offset + 28)[0]
    if actual != name or attr != attributes or first != cluster or actual_size != size:
        fail(f"directory entry {index} invalid: {actual!r}/{attr:#x}/{first}/{actual_size}")


def read_two_clusters(volume: bytes, first: int, second: int, size: int) -> bytes:
    return (cluster_sector(volume, first) + cluster_sector(volume, second))[:size]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    args = parser.parse_args()
    image = args.image.read_bytes()
    if len(image) != 2 * 1024 * 1024:
        fail("persistent disk image size invalid")
    volume = image[FAT_LBA * BPS : (FAT_LBA + 2880) * BPS]
    fat1 = volume[BPS : (1 + SPF) * BPS]
    fat2 = volume[(1 + SPF) * BPS : (1 + 2 * SPF) * BPS]
    if fat1 != fat2:
        fail("persistent FAT12 copies differ")

    root = volume[ROOT_START * BPS : ROOT_START * BPS + 14 * BPS]
    paths_offset = 15 * 32
    if root[paths_offset : paths_offset + 11] != b"PATHS   ELF":
        fail("PATHS.ELF static root slot invalid")
    home_offset = 16 * 32
    check_dir_entry(root, 16, b"HOME       ", 0x10, 42)
    notes_offset = 17 * 32
    check_dir_entry(root, 17, b"NOTES   TXT", 0x20, 47, 720)
    if root[18 * 32] != 0:
        fail("unexpected root entry beyond HOME and NOTES.TXT")

    home = cluster_sector(volume, 42)
    check_dir_entry(home, 0, b".          ", 0x10, 42)
    check_dir_entry(home, 1, b"..         ", 0x10, 0)
    check_dir_entry(home, 2, b"DOCS       ", 0x10, 43)
    if home[3 * 32] != 0xE5:
        fail("cross-directory source slot was not deleted")
    check_dir_entry(home, 4, b"ARCHIVE    ", 0x10, 46)
    if home[5 * 32] != 0:
        fail("unexpected HOME directory residue")

    docs = cluster_sector(volume, 43)
    check_dir_entry(docs, 0, b".          ", 0x10, 43)
    check_dir_entry(docs, 1, b"..         ", 0x10, 42)
    if docs[2 * 32] != 0xE5 or docs[3 * 32] != 0:
        fail("DOCS temporary reuse residue invalid")

    archive = cluster_sector(volume, 46)
    check_dir_entry(archive, 0, b".          ", 0x10, 46)
    check_dir_entry(archive, 1, b"..         ", 0x10, 42)
    check_dir_entry(archive, 2, b"LOG     TXT", 0x20, 44, 600)
    if archive[3 * 32] != 0:
        fail("unexpected ARCHIVE directory residue")

    expected_fat = {
        42: 0xFFF,
        43: 0xFFF,
        44: 45,
        45: 0xFFF,
        46: 0xFFF,
        47: 48,
        48: 0xFFF,
        49: 0,
    }
    for cluster, expected in expected_fat.items():
        actual = entry(fat1, cluster)
        if (actual >= 0xFF8 and expected >= 0xFF8):
            continue
        if actual != expected:
            fail(f"persistent FAT entry {cluster} invalid: {actual:#x} != {expected:#x}")

    log = read_two_clusters(volume, 44, 45, 600)
    if log != PATH_PAYLOAD or fnv1a32(log) != PATH_HASH:
        fail("persistent /HOME/ARCHIVE/LOG.TXT content invalid")
    notes = read_two_clusters(volume, 47, 48, 720)
    if notes != NOTES or fnv1a32(notes) != NOTES_HASH:
        fail("persistent NOTES.TXT content invalid")

    print("Verified Capstone 13 persistent FAT12 hierarchy")
    print("  /HOME: cluster 42, DOCS 43, ARCHIVE 46")
    print("  /HOME/ARCHIVE/LOG.TXT: 600 bytes, clusters 44->45->EOC, FNV-1a32 0x36F73195")
    print("  NOTES.TXT: root slot 17, 720 bytes, clusters 47->48->EOC, FNV-1a32 0xC6181D2F")
    print(f"  image sha256: {hashlib.sha256(image).hexdigest().upper()}")


if __name__ == "__main__":
    main()
