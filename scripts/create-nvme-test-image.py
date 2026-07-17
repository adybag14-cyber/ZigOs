#!/usr/bin/env python3
from __future__ import annotations

import argparse
import binascii
import json
import math
import struct
from pathlib import Path

EFI_SYSTEM_PARTITION_GUID = bytes.fromhex("28732ac11ff8d211ba4b00a0c93ec93b")
PARTITION_GUID = bytes.fromhex("443322116655887799aabbccddeef001")
DISK_GUID = bytes.fromhex("78563412bc9af0de1122334455667788")
MARKER = b"ZIGOS-NVME-LBA0!"
FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3


def le16(buffer: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<H", buffer, offset, value)


def le32(buffer: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", buffer, offset, value)


def le64(buffer: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<Q", buffer, offset, value)


def fnv1a64(data: bytes) -> int:
    value = FNV_OFFSET
    for byte in data:
        value ^= byte
        value = (value * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return value


def set_fat16_entry(fat: bytearray, cluster: int, value: int) -> None:
    le16(fat, cluster * 2, value)


def set_directory_entry(
    buffer: bytearray,
    offset: int,
    short_name: bytes,
    attributes: int,
    first_cluster: int,
    file_size: int,
) -> None:
    if len(short_name) != 11:
        raise ValueError("FAT short names must contain exactly 11 bytes")
    buffer[offset : offset + 11] = short_name
    buffer[offset + 11] = attributes
    le16(buffer, offset + 20, 0)
    le16(buffer, offset + 26, first_cluster)
    le32(buffer, offset + 28, file_size)


def make_gpt_header(
    block_size: int,
    current_lba: int,
    backup_lba: int,
    first_usable_lba: int,
    last_usable_lba: int,
    entry_lba: int,
    entry_array_crc: int,
) -> bytearray:
    header = bytearray(block_size)
    header[0:8] = b"EFI PART"
    le32(header, 8, 0x00010000)
    le32(header, 12, 92)
    le64(header, 24, current_lba)
    le64(header, 32, backup_lba)
    le64(header, 40, first_usable_lba)
    le64(header, 48, last_usable_lba)
    header[56:72] = DISK_GUID
    le64(header, 72, entry_lba)
    le32(header, 80, 128)
    le32(header, 84, 128)
    le32(header, 88, entry_array_crc)
    le32(header, 16, binascii.crc32(header[:92]) & 0xFFFFFFFF)
    return header


def layout_for(block_size: int) -> dict[str, int]:
    if block_size == 512:
        total_bytes = 16 * 1024 * 1024
        partition_first_lba = 2048
        sectors_per_fat = 120
        root_entry_count = 512
    elif block_size == 4096:
        total_bytes = 64 * 1024 * 1024
        partition_first_lba = 256
        sectors_per_fat = 8
        root_entry_count = 512
    else:
        raise ValueError("block size must be 512 or 4096")

    total_lbas = total_bytes // block_size
    entry_array_bytes = 128 * 128
    entry_array_sectors = math.ceil(entry_array_bytes / block_size)
    first_usable_lba = 2 + entry_array_sectors
    backup_entry_lba = total_lbas - 1 - entry_array_sectors
    last_usable_lba = backup_entry_lba - 1
    partition_last_lba = last_usable_lba
    partition_sectors = partition_last_lba - partition_first_lba + 1
    root_directory_sectors = math.ceil(root_entry_count * 32 / block_size)
    metadata_sectors = 1 + 2 * sectors_per_fat + root_directory_sectors
    first_fat_lba = partition_first_lba + 1
    root_directory_lba = partition_first_lba + 1 + 2 * sectors_per_fat
    first_data_lba = partition_first_lba + metadata_sectors
    cluster_count = partition_sectors - metadata_sectors
    if not (4085 <= cluster_count < 65525):
        raise ValueError(f"layout does not classify as FAT16: {cluster_count} clusters")

    return {
        "block_size": block_size,
        "total_bytes": total_bytes,
        "total_lbas": total_lbas,
        "last_lba": total_lbas - 1,
        "entry_array_sectors": entry_array_sectors,
        "primary_entry_lba": 2,
        "backup_entry_lba": backup_entry_lba,
        "first_usable_lba": first_usable_lba,
        "last_usable_lba": last_usable_lba,
        "partition_first_lba": partition_first_lba,
        "partition_last_lba": partition_last_lba,
        "partition_sectors": partition_sectors,
        "sectors_per_fat": sectors_per_fat,
        "root_entry_count": root_entry_count,
        "root_directory_sectors": root_directory_sectors,
        "first_fat_lba": first_fat_lba,
        "root_directory_lba": root_directory_lba,
        "first_data_lba": first_data_lba,
        "cluster_count": cluster_count,
    }


def build_image(output: Path, efi_image: Path, block_size: int) -> dict[str, int | str]:
    layout = layout_for(block_size)
    efi_bytes = efi_image.read_bytes()

    protective_mbr = bytearray(block_size)
    protective_mbr[: len(MARKER)] = MARKER
    protective_mbr[446:450] = bytes((0x00, 0x00, 0x02, 0x00))
    protective_mbr[450] = 0xEE
    protective_mbr[451:454] = b"\xFF\xFF\xFF"
    le32(protective_mbr, 454, 1)
    le32(protective_mbr, 458, min(layout["total_lbas"] - 1, 0xFFFFFFFF))
    protective_mbr[510:512] = b"\x55\xAA"

    partition_entries = bytearray(128 * 128)
    partition_entries[0:16] = EFI_SYSTEM_PARTITION_GUID
    partition_entries[16:32] = PARTITION_GUID
    le64(partition_entries, 32, layout["partition_first_lba"])
    le64(partition_entries, 40, layout["partition_last_lba"])
    name = "ZigOs NVMe FAT".encode("utf-16le")
    partition_entries[56 : 56 + len(name)] = name
    partition_array_crc = binascii.crc32(partition_entries) & 0xFFFFFFFF

    primary_header = make_gpt_header(
        block_size,
        1,
        layout["last_lba"],
        layout["first_usable_lba"],
        layout["last_usable_lba"],
        layout["primary_entry_lba"],
        partition_array_crc,
    )
    backup_header = make_gpt_header(
        block_size,
        layout["last_lba"],
        1,
        layout["first_usable_lba"],
        layout["last_usable_lba"],
        layout["backup_entry_lba"],
        partition_array_crc,
    )

    boot_sector = bytearray(block_size)
    boot_sector[0:3] = b"\xEB\x3C\x90"
    boot_sector[3:11] = b"ZIGOS   "
    le16(boot_sector, 11, block_size)
    boot_sector[13] = 1
    le16(boot_sector, 14, 1)
    boot_sector[16] = 2
    le16(boot_sector, 17, layout["root_entry_count"])
    if layout["partition_sectors"] <= 0xFFFF:
        le16(boot_sector, 19, layout["partition_sectors"])
    else:
        le16(boot_sector, 19, 0)
        le32(boot_sector, 32, layout["partition_sectors"])
    boot_sector[21] = 0xF8
    le16(boot_sector, 22, layout["sectors_per_fat"])
    le16(boot_sector, 24, 63)
    le16(boot_sector, 26, 255)
    le32(boot_sector, 28, layout["partition_first_lba"])
    boot_sector[36] = 0x80
    boot_sector[38] = 0x29
    le32(boot_sector, 39, 0x5A49474F)
    boot_sector[43:54] = b"ZIGOSNVME  "
    boot_sector[54:62] = b"FAT16   "
    boot_sector[510:512] = b"\x55\xAA"

    file_clusters = math.ceil(len(efi_bytes) / block_size)
    first_file_cluster = 4
    last_file_cluster = first_file_cluster + file_clusters - 1
    if last_file_cluster >= layout["cluster_count"] + 2:
        raise ValueError("EFI image does not fit in FAT16 data area")

    fat = bytearray(layout["sectors_per_fat"] * block_size)
    set_fat16_entry(fat, 0, 0xFFF8)
    set_fat16_entry(fat, 1, 0xFFFF)
    set_fat16_entry(fat, 2, 0xFFFF)
    set_fat16_entry(fat, 3, 0xFFFF)
    for cluster in range(first_file_cluster, last_file_cluster):
        set_fat16_entry(fat, cluster, cluster + 1)
    set_fat16_entry(fat, last_file_cluster, 0xFFFF)

    root_directory = bytearray(layout["root_directory_sectors"] * block_size)
    set_directory_entry(root_directory, 0, b"EFI        ", 0x10, 2, 0)
    root_directory[32] = 0
    efi_directory = bytearray(block_size)
    set_directory_entry(efi_directory, 0, b"BOOT       ", 0x10, 3, 0)
    efi_directory[32] = 0
    boot_directory = bytearray(block_size)
    set_directory_entry(boot_directory, 0, b"BOOTX64 EFI", 0x20, first_file_cluster, len(efi_bytes))
    boot_directory[32] = 0

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as stream:
        stream.truncate(layout["total_bytes"])
        def write_lba(lba: int, data: bytes) -> None:
            stream.seek(lba * block_size)
            stream.write(data)

        write_lba(0, protective_mbr)
        write_lba(1, primary_header)
        write_lba(layout["primary_entry_lba"], partition_entries)
        write_lba(layout["backup_entry_lba"], partition_entries)
        write_lba(layout["last_lba"], backup_header)
        write_lba(layout["partition_first_lba"], boot_sector)
        write_lba(layout["first_fat_lba"], fat)
        write_lba(layout["first_fat_lba"] + layout["sectors_per_fat"], fat)
        write_lba(layout["root_directory_lba"], root_directory)
        write_lba(layout["first_data_lba"], efi_directory)
        write_lba(layout["first_data_lba"] + 1, boot_directory)
        write_lba(layout["first_data_lba"] + 2, efi_bytes)

    metadata: dict[str, int | str] = dict(layout)
    metadata.update(
        {
            "partition_array_crc": f"{partition_array_crc:08X}",
            "primary_header_crc": f"{struct.unpack_from('<I', primary_header, 16)[0]:08X}",
            "backup_header_crc": f"{struct.unpack_from('<I', backup_header, 16)[0]:08X}",
            "lba0_fnv1a64": f"{fnv1a64(bytes(protective_mbr)):016X}",
            "efi_size": len(efi_bytes),
            "efi_fnv1a64": f"{fnv1a64(efi_bytes):016X}",
            "file_cluster_count": file_clusters,
            "file_first_cluster": first_file_cluster,
            "file_last_cluster": last_file_cluster,
        }
    )
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--efi", required=True, type=Path)
    parser.add_argument("--block-size", required=True, type=int, choices=(512, 4096))
    parser.add_argument("--metadata", required=True, type=Path)
    args = parser.parse_args()

    metadata = build_image(args.output, args.efi, args.block_size)
    args.metadata.parent.mkdir(parents=True, exist_ok=True)
    args.metadata.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(metadata, sort_keys=True))


if __name__ == "__main__":
    main()
