#!/usr/bin/env python3
"""Verify the complete Capstone 13 BIOS, kernel, and deterministic FAT12 image."""
from __future__ import annotations

import argparse
import hashlib
import math
import struct
from pathlib import Path

BPS = 512
FAT_LBA = 256
FAT_SECTORS = 2880
ROOT_START = 19
DATA_START = 33
SPF = 9

EXPECTED = {
    b"HELLO   TXT": (2, 86, 0xA9F660F2, (2,)),
    b"INIT    ELF": (3, 423, 0x4E34353F, (3,)),
    b"CAT     ELF": (4, 510, 0x9CD11469, (4,)),
    b"BIG     TXT": (5, 1300, 0xE5D120DF, (5, 6, 7)),
    b"SPINA   ELF": (8, 264, 0xFD5D48A0, (8,)),
    b"SPINB   ELF": (9, 264, 0xFD5D48A0, (9,)),
    b"FAULT   ELF": (10, 262, 0x3A59C4D6, (10,)),
    b"WRITER  ELF": (11, 1488, 0x267B866B, (11, 12, 13)),
    b"SERVICE ELF": (14, 1362, 0x7C65C5CE, (14, 15, 16)),
    b"ORCH    ELF": (17, 1937, 0x11986FD8, (17, 18, 19, 20)),
    b"CHILD   ELF": (21, 913, 0x7E1C062C, (21, 22)),
    b"ASYNC   ELF": (23, 2336, 0x21F68871, (23, 24, 25, 26, 27)),
    b"WORKA   ELF": (28, 824, 0xC83AFC14, (28, 29)),
    b"WORKB   ELF": (30, 784, 0xCD43E95A, (30, 31)),
    b"LEAF    ELF": (32, 692, 0x769A282E, (32, 33)),
    b"PATHS   ELF": (34, 4024, 0x38C1C0AD, (34, 35, 36, 37, 38, 39, 40, 41)),
}


def fail(message: str) -> None:
    raise SystemExit(message)


def fnv1a32(data: bytes) -> int:
    value = 0x811C9DC5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return value


def fat_entry(fat: bytes, cluster: int) -> int:
    offset = cluster + cluster // 2
    pair = fat[offset] | (fat[offset + 1] << 8)
    return ((pair >> 4) & 0xFFF) if cluster & 1 else (pair & 0xFFF)


def read_chain(volume: bytes, first: int, size: int) -> tuple[bytes, tuple[int, ...]]:
    fat = volume[BPS : (1 + SPF) * BPS]
    result = bytearray()
    chain: list[int] = []
    cluster = first
    limit = FAT_SECTORS
    while len(result) < size and limit:
        if cluster < 2 or cluster >= 0xFF0:
            fail(f"invalid FAT12 data cluster {cluster:#x}")
        chain.append(cluster)
        offset = (DATA_START + cluster - 2) * BPS
        result += volume[offset : offset + BPS]
        nxt = fat_entry(fat, cluster)
        if len(result) >= size:
            if nxt < 0xFF8:
                fail(f"file chain does not terminate at cluster {cluster}: {nxt:#x}")
            break
        if nxt >= 0xFF8:
            fail(f"file chain ended early at cluster {cluster}")
        cluster = nxt
        limit -= 1
    if not limit:
        fail("FAT12 chain loop")
    return bytes(result[:size]), tuple(chain)


def verify_elf(name: bytes, data: bytes) -> None:
    label = name.decode("ascii")
    if len(data) < 84 or data[:4] != b"\x7fELF":
        fail(f"{label} ELF identity invalid")
    if data[4:7] != b"\x01\x01\x01":
        fail(f"{label} ELF class/data/version invalid")
    if struct.unpack_from("<H", data, 16)[0] != 2 or struct.unpack_from("<H", data, 18)[0] != 3:
        fail(f"{label} ELF type/machine invalid")
    if struct.unpack_from("<I", data, 24)[0] != 0x00400000:
        fail(f"{label} entry invalid")
    if struct.unpack_from("<I", data, 28)[0] != 52:
        fail(f"{label} program-header offset invalid")
    if struct.unpack_from("<H", data, 42)[0] != 32 or struct.unpack_from("<H", data, 44)[0] != 1:
        fail(f"{label} program-header geometry invalid")
    ph = 52
    p_type, p_offset, p_vaddr, _, p_filesz, p_memsz, p_flags, _ = struct.unpack_from("<IIIIIIII", data, ph)
    if p_type != 1 or p_offset != 0x100 or p_vaddr != 0x00400000:
        fail(f"{label} PT_LOAD identity invalid")
    if p_offset + p_filesz != len(data) or p_memsz < p_filesz or p_memsz > 4096 or p_flags != 5:
        fail(f"{label} PT_LOAD bounds/flags invalid")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--boot", type=Path, required=True)
    parser.add_argument("--stage1", type=Path, required=True)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--fat", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    args = parser.parse_args()

    boot = args.boot.read_bytes()
    stage1 = args.stage1.read_bytes()
    kernel = args.kernel.read_bytes()
    volume = args.fat.read_bytes()
    image = args.image.read_bytes()

    if len(boot) != 512 or boot[510:512] != b"\x55\xAA":
        fail("stage0 size/signature invalid")
    if len(stage1) != 4096:
        fail("stage1 must be exactly 4096 bytes")
    if not 0 < len(kernel) <= 247 * BPS:
        fail("kernel payload size invalid")
    if len(volume) != FAT_SECTORS * BPS:
        fail("FAT12 volume size invalid")
    if len(image) != 2 * 1024 * 1024:
        fail("disk image size invalid")

    if boot[:446] != image[:446] or boot[462:510] != image[462:510] or image[510:512] != b"\x55\xAA":
        fail("stage0/MBR bytes differ")
    if image[BPS : 9 * BPS] != stage1:
        fail("stage1 image bytes differ")
    if image[9 * BPS : 9 * BPS + len(kernel)] != kernel:
        fail("kernel image bytes differ")
    fat_offset = FAT_LBA * BPS
    if image[fat_offset : fat_offset + len(volume)] != volume:
        fail("FAT12 volume bytes differ from disk")

    partition = 446
    if image[partition + 4] != 0x01:
        fail("partition is not FAT12 type 0x01")
    if struct.unpack_from("<I", image, partition + 8)[0] != FAT_LBA:
        fail("partition LBA invalid")
    if struct.unpack_from("<I", image, partition + 12)[0] != FAT_SECTORS:
        fail("partition sector count invalid")

    if volume[510:512] != b"\x55\xAA":
        fail("FAT12 boot signature invalid")
    bpb = {
        "bps": struct.unpack_from("<H", volume, 11)[0],
        "spc": volume[13],
        "reserved": struct.unpack_from("<H", volume, 14)[0],
        "fats": volume[16],
        "root": struct.unpack_from("<H", volume, 17)[0],
        "total": struct.unpack_from("<H", volume, 19)[0],
        "spf": struct.unpack_from("<H", volume, 22)[0],
        "hidden": struct.unpack_from("<I", volume, 28)[0],
    }
    if bpb != {"bps": 512, "spc": 1, "reserved": 1, "fats": 2, "root": 224, "total": 2880, "spf": 9, "hidden": 256}:
        fail(f"FAT12 BPB invalid: {bpb}")
    fat1 = volume[BPS : (1 + SPF) * BPS]
    fat2 = volume[(1 + SPF) * BPS : (1 + 2 * SPF) * BPS]
    if fat1 != fat2 or fat1[:3] != b"\xF0\xFF\xFF":
        fail("FAT12 copies/reserved entries invalid")

    root_offset = ROOT_START * BPS
    for index, (name, expected) in enumerate(EXPECTED.items()):
        offset = root_offset + index * 32
        actual_name = volume[offset : offset + 11]
        attributes = volume[offset + 11]
        cluster = struct.unpack_from("<H", volume, offset + 26)[0]
        size = struct.unpack_from("<I", volume, offset + 28)[0]
        expected_cluster, expected_size, expected_hash, expected_chain = expected
        if actual_name != name or attributes != 0x20 or cluster != expected_cluster or size != expected_size:
            fail(f"root entry {index} invalid for {name!r}")
        data, chain = read_chain(volume, cluster, size)
        if chain != expected_chain:
            fail(f"chain mismatch for {name!r}: {chain}")
        if fnv1a32(data) != expected_hash:
            fail(f"hash mismatch for {name!r}: {fnv1a32(data):08X}")
        if name.endswith(b"ELF"):
            verify_elf(name, data)
    notes_slot = root_offset + len(EXPECTED) * 32
    if volume[notes_slot] != 0:
        fail("initial NOTES.TXT root slot is not free")
    for cluster in range(42, 49):
        if fat_entry(fat1, cluster) != 0:
            fail(f"runtime-reserved cluster {cluster} is not initially free")

    hello, _ = read_chain(volume, 2, 86)
    if hello != b"ZigOs legacy FAT12 filesystem is online.\r\nLoaded through ATA PIO by the i686 kernel.\r\n":
        fail("HELLO.TXT content invalid")
    cat, _ = read_chain(volume, 4, 510)
    if cat[0x190:0x19B] != b"HELLO   TXT":
        fail("CAT.ELF embedded filename invalid")
    writer, _ = read_chain(volume, 11, 1488)
    if writer[0x280:0x28B] != b"NOTES   TXT":
        fail("WRITER.ELF embedded filename invalid")
    service, _ = read_chain(volume, 14, 1362)
    if service[0x450:0x45B] != b"TEMP2   BIN" or service[0x460:0x46B] != b"RENAMED BIN":
        fail("SERVICE.ELF embedded namespace names invalid")
    if service[0x480:0x492] != b"SERVICE-PIPE-OK!\r\n":
        fail("SERVICE.ELF embedded payload invalid")
    orch, _ = read_chain(volume, 17, 1937)
    if orch[0x600:0x60B] != b"CHILD   ELF" or orch[0x610:0x61B] != b"HELLO   TXT":
        fail("ORCH.ELF embedded filenames invalid")
    if orch[0x630:0x641] != b"PARENT-TO-CHILD\r\n":
        fail("ORCH.ELF embedded request invalid")
    child, _ = read_chain(volume, 21, 913)
    if child[0x380:0x391] != b"CHILD-TO-PARENT\r\n":
        fail("CHILD.ELF embedded reply invalid")

    async_parent, _ = read_chain(volume, 23, 2336)
    if async_parent[0x700:0x70B] != b"WORKA   ELF" or async_parent[0x710:0x71B] != b"WORKB   ELF":
        fail("ASYNC.ELF worker names invalid")
    if async_parent[0x720:0x72B] != b"MISSING ELF":
        fail("ASYNC.ELF rejection name invalid")
    if async_parent.count(b"\xB8\x2A\x00\x00\x00\xCD\x80") != 3:
        fail("ASYNC.ELF spawn syscall sequence invalid")
    worka, _ = read_chain(volume, 28, 824)
    if worka[0x300:0x30B] != b"LEAF    ELF":
        fail("WORKA.ELF leaf name invalid")
    if worka.count(b"\xB8\x2B\x00\x00\x00\xCD\x80") != 1:
        fail("WORKA.ELF yield syscall invalid")
    workb, _ = read_chain(volume, 30, 784)
    if struct.pack("<I", 100_000_000) not in workb:
        fail("WORKB.ELF preemption loop bound invalid")
    if workb.count(b"\xB8\x16\x00\x00\x00\xCD\x80") != 1:
        fail("WORKB.ELF signal consume invalid")
    leaf, _ = read_chain(volume, 32, 692)
    if leaf.count(b"\xBB\x14\x00\x00\x00") != 10 or leaf.count(b"\xB8\x2C\x00\x00\x00\xCD\x80") != 10:
        fail("LEAF.ELF bounded sleep sequence invalid")

    paths, _ = read_chain(volume, 34, 4024)
    if paths[0x700:0x701] != b"/" or paths[0x710:0x715] != b"/HOME" or paths[0x720:0x724] != b"DOCS":
        fail("PATHS.ELF root/home/docs strings invalid")
    if paths[0x730:0x736] != b"./DOCS" or paths[0x740:0x748] != b"../EMPTY":
        fail("PATHS.ELF relative path strings invalid")
    if paths[0x750:0x758] != b"TEMP.BIN" or paths[0x770:0x77C] != b"../MOVED.BIN":
        fail("PATHS.ELF move source/target strings invalid")
    if paths[0x7B0:0x7BB] != b"RENAMED.BIN":
        fail("PATHS.ELF same-directory rename string invalid")
    if paths[0x780:0x787] != b"ARCHIVE" or paths[0x7A0:0x7AF] != b"ARCHIVE/LOG.TXT":
        fail("PATHS.ELF archive strings invalid")
    if paths[0x7F0:0x808] != b"/HOME//ARCHIVE///LOG.TXT":
        fail("PATHS.ELF absolute log path invalid")
    path_payload = paths[0xB00:0xB00 + 600]
    if fnv1a32(path_payload) != 0x36F73195:
        fail("PATHS.ELF embedded payload invalid")

    kernel_sectors = math.ceil(len(kernel) / BPS)
    padded = kernel + bytes(kernel_sectors * BPS - len(kernel))
    checksum = sum(struct.unpack_from("<H", padded, offset)[0] for offset in range(0, len(padded), 2)) & 0xFFFF
    kernel_end_lba = 9 + kernel_sectors - 1
    if kernel_end_lba >= FAT_LBA:
        fail("kernel overlaps FAT12 partition")
    if any(image[(9 + kernel_sectors) * BPS : FAT_LBA * BPS]):
        fail("protected kernel/FAT gap is not zero")

    print(f"Verified Capstone 13 legacy BIOS/FAT12 image: {args.image}")
    print("  stage0: 512 bytes, signature 0x55AA, partition type 0x01")
    print("  stage1: 4096 bytes, LBA 1..8, address 0x00008000")
    print(f"  kernel: {len(kernel)} bytes, {kernel_sectors} sectors, LBA 9..{kernel_end_lba}, checksum16 0x{checksum:04X}")
    print("  FAT12: 16 files, mirrored FATs, ASYNC.ELF 23->24->25->26->27, WORKA.ELF 28->29, WORKB.ELF 30->31, LEAF.ELF 32->33, PATHS.ELF 34->35->36->37->38->39->40->41, clusters 42-48 free")
    print(f"  image sha256: {hashlib.sha256(image).hexdigest().upper()}")


if __name__ == "__main__":
    main()
