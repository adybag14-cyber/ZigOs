#!/usr/bin/env python3
"""Verify Capstone 12 nested FAT12 and NOTES.TXT persistence."""
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
    paths_offset = 11 * 32
    if root[paths_offset : paths_offset + 11] != b"PATHS   ELF":
        fail("PATHS.ELF static root slot invalid")
    home_offset = 12 * 32
    check_dir_entry(root, 12, b"HOME       ", 0x10, 31)
    notes_offset = 13 * 32
    check_dir_entry(root, 13, b"NOTES   TXT", 0x20, 36, 720)
    if root[14 * 32] != 0:
        fail("unexpected root entry beyond HOME and NOTES.TXT")

    home = cluster_sector(volume, 31)
    check_dir_entry(home, 0, b".          ", 0x10, 31)
    check_dir_entry(home, 1, b"..         ", 0x10, 0)
    check_dir_entry(home, 2, b"DOCS       ", 0x10, 32)
    if home[3 * 32] != 0xE5:
        fail("cross-directory source slot was not deleted")
    check_dir_entry(home, 4, b"ARCHIVE    ", 0x10, 35)
    if home[5 * 32] != 0:
        fail("unexpected HOME directory residue")

    docs = cluster_sector(volume, 32)
    check_dir_entry(docs, 0, b".          ", 0x10, 32)
    check_dir_entry(docs, 1, b"..         ", 0x10, 31)
    if docs[2 * 32] != 0xE5 or docs[3 * 32] != 0:
        fail("DOCS temporary reuse residue invalid")

    archive = cluster_sector(volume, 35)
    check_dir_entry(archive, 0, b".          ", 0x10, 35)
    check_dir_entry(archive, 1, b"..         ", 0x10, 31)
    check_dir_entry(archive, 2, b"LOG     TXT", 0x20, 33, 600)
    if archive[3 * 32] != 0:
        fail("unexpected ARCHIVE directory residue")

    expected_fat = {
        31: 0xFFF,
        32: 0xFFF,
        33: 34,
        34: 0xFFF,
        35: 0xFFF,
        36: 37,
        37: 0xFFF,
        38: 0,
    }
    for cluster, expected in expected_fat.items():
        actual = entry(fat1, cluster)
        if (actual >= 0xFF8 and expected >= 0xFF8):
            continue
        if actual != expected:
            fail(f"persistent FAT entry {cluster} invalid: {actual:#x} != {expected:#x}")

    log = read_two_clusters(volume, 33, 34, 600)
    if log != PATH_PAYLOAD or fnv1a32(log) != PATH_HASH:
        fail("persistent /HOME/ARCHIVE/LOG.TXT content invalid")
    notes = read_two_clusters(volume, 36, 37, 720)
    if notes != NOTES or fnv1a32(notes) != NOTES_HASH:
        fail("persistent NOTES.TXT content invalid")

    print("Verified Capstone 12 persistent FAT12 hierarchy")
    print("  /HOME: cluster 31, DOCS 32, ARCHIVE 35")
    print("  /HOME/ARCHIVE/LOG.TXT: 600 bytes, clusters 33->34->EOC, FNV-1a32 0x36F73195")
    print("  NOTES.TXT: root slot 13, 720 bytes, clusters 36->37->EOC, FNV-1a32 0xC6181D2F")
    print(f"  image sha256: {hashlib.sha256(image).hexdigest().upper()}")


if __name__ == "__main__":
    main()
