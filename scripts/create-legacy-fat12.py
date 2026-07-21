#!/usr/bin/env python3
"""Create the deterministic ZigOs Capstone 10 FAT12 volume."""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

BPS = 512
TOTAL = 2880
SPC = 1
RESERVED = 1
FATS = 2
ROOT_ENTRIES = 224
SPF = 9
ROOT_SECTORS = (ROOT_ENTRIES * 32 + BPS - 1) // BPS
FAT_START = 1
ROOT_START = 19
DATA_START = 33

OPEN_READ = 0x01
OPEN_WRITE = 0x02
OPEN_CREATE = 0x04
OPEN_TRUNCATE = 0x08
OPEN_APPEND = 0x10

HELLO_NAME = b"HELLO   TXT"
HELLO = (
    b"ZigOs legacy FAT12 filesystem is online.\r\n"
    b"Loaded through ATA PIO by the i686 kernel.\r\n"
)
INIT_NAME = b"INIT    ELF"
INIT_MESSAGE = b"INIT.ELF executed in ring3 via FAT12.\r\n"
CAT_NAME = b"CAT     ELF"
BIG_NAME = b"BIG     TXT"
SPINA_NAME = b"SPINA   ELF"
SPINB_NAME = b"SPINB   ELF"
FAULT_NAME = b"FAULT   ELF"
WRITER_NAME = b"WRITER  ELF"
SERVICE_NAME = b"SERVICE ELF"
NOTES_NAME = b"NOTES   TXT"

BIG_PREFIX = b"ZigOs multi-cluster FAT12 read contract.\r\n"
BIG = (BIG_PREFIX + bytes((ord("A") + (i % 26)) for i in range(1300 - len(BIG_PREFIX))))
WRITER_BASE = bytes((ord("a") + (i % 26)) for i in range(700))
WRITER_SUFFIX = b"APPEND-PERSIST-OK!\r\n"
WRITER_RESULT = WRITER_BASE + WRITER_SUFFIX


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


def build_elf(segment: bytes, memory_size: int = 0x200) -> bytes:
    base = 0x00400000
    file_size = 0x100 + len(segment)
    elf = bytearray(file_size)
    elf[:16] = b"\x7fELF\x01\x01\x01\x00" + bytes(8)
    struct.pack_into("<HHIIIIIHHHHHH", elf, 16, 2, 3, 1, base, 52, 0, 0, 52, 32, 1, 0, 0, 0)
    struct.pack_into("<IIIIIIII", elf, 52, 1, 0x100, base, base, len(segment), memory_size, 5, 0x1000)
    elf[0x100:] = segment
    return bytes(elf)


def build_init_elf() -> bytes:
    base = 0x00400000
    message_va = base + 0x80
    pid_va = base + 0x70
    code = bytearray()
    code += b"\xB8\x01\x00\x00\x00"
    code += b"\xBB" + struct.pack("<I", message_va)
    code += b"\xB9" + struct.pack("<I", len(INIT_MESSAGE))
    code += b"\xCD\x80"
    code += b"\xB8\x02\x00\x00\x00\xCD\x80"
    code += b"\xA3" + struct.pack("<I", pid_va)
    code += b"\xB8\x03\x00\x00\x00"
    code += b"\xBB\x33\x00\x00\x00\xCD\x80\xF4"
    segment = bytearray(0x80 + len(INIT_MESSAGE))
    segment[: len(code)] = code
    segment[0x80:] = INIT_MESSAGE
    return build_elf(bytes(segment))


def build_cat_elf() -> bytes:
    base = 0x00400000
    name_offset = 0x90
    fd_offset = 0xA0
    read_offset = 0xA4
    buffer_offset = 0xA8
    name_va = base + name_offset
    fd_va = base + fd_offset
    read_va = base + read_offset
    buffer_va = base + buffer_offset
    code = bytearray()
    code += b"\xB8\x04\x00\x00\x00"
    code += b"\xBB" + struct.pack("<I", name_va)
    code += b"\xB9\x0B\x00\x00\x00"
    code += b"\xBA" + struct.pack("<I", OPEN_READ)
    code += b"\xCD\x80"
    code += b"\xA3" + struct.pack("<I", fd_va)
    code += b"\x89\xC3"
    code += b"\xB8\x05\x00\x00\x00"
    code += b"\xB9" + struct.pack("<I", buffer_va)
    code += b"\xBA" + struct.pack("<I", len(HELLO))
    code += b"\xCD\x80"
    code += b"\xA3" + struct.pack("<I", read_va)
    code += b"\x89\xC1"
    code += b"\xB8\x01\x00\x00\x00"
    code += b"\xBB" + struct.pack("<I", buffer_va)
    code += b"\xCD\x80"
    code += b"\xB8\x06\x00\x00\x00"
    code += b"\x8B\x1D" + struct.pack("<I", fd_va)
    code += b"\xCD\x80"
    code += b"\xB8\x03\x00\x00\x00"
    code += b"\xBB\x44\x00\x00\x00\xCD\x80\xF4"
    if len(code) > name_offset:
        raise RuntimeError("CAT.ELF code overlaps data")
    segment = bytearray(buffer_offset + len(HELLO))
    segment[: len(code)] = code
    segment[name_offset : name_offset + 11] = HELLO_NAME
    return build_elf(bytes(segment))


def build_spin_elf() -> bytes:
    return build_elf(b"\xFF\x05\x00\x01\x40\x00\xEB\xF8", memory_size=0x200)


def build_fault_elf() -> bytes:
    return build_elf(b"\xA1\x00\x00\x80\x00\xF4", memory_size=0x100)


def mov_imm(reg_opcode: int, value: int) -> bytes:
    return bytes((reg_opcode,)) + struct.pack("<I", value)


def build_writer_elf() -> bytes:
    base = 0x00400000
    name_offset = 0x180
    fd_offset = 0x190
    write_result_offset = 0x194
    read_result_offset = 0x198
    payload_offset = 0x200
    verify_offset = 0x600
    name_va = base + name_offset
    fd_va = base + fd_offset
    payload_va = base + payload_offset
    verify_va = base + verify_offset
    suffix_va = payload_va + len(WRITER_BASE)

    code = bytearray()
    # open NOTES.TXT read/write/create/truncate
    code += mov_imm(0xB8, 4)
    code += mov_imm(0xBB, name_va)
    code += mov_imm(0xB9, 11)
    code += mov_imm(0xBA, OPEN_READ | OPEN_WRITE | OPEN_CREATE | OPEN_TRUNCATE)
    code += b"\xCD\x80\xA3" + struct.pack("<I", base + fd_offset)
    # write 700 bytes
    code += b"\x89\xC3"
    code += mov_imm(0xB8, 7)
    code += mov_imm(0xB9, payload_va)
    code += mov_imm(0xBA, len(WRITER_BASE))
    code += b"\xCD\x80\xA3" + struct.pack("<I", base + write_result_offset)
    # seek to beginning
    code += mov_imm(0xB8, 8)
    code += b"\x8B\x1D" + struct.pack("<I", base + fd_offset)
    code += mov_imm(0xB9, 0)
    code += mov_imm(0xBA, 0)
    code += b"\xCD\x80"
    # read the complete base payload back into BSS
    code += mov_imm(0xB8, 5)
    code += b"\x8B\x1D" + struct.pack("<I", base + fd_offset)
    code += mov_imm(0xB9, verify_va)
    code += mov_imm(0xBA, len(WRITER_BASE))
    code += b"\xCD\x80\xA3" + struct.pack("<I", base + read_result_offset)
    # close first descriptor
    code += mov_imm(0xB8, 6)
    code += b"\x8B\x1D" + struct.pack("<I", base + fd_offset)
    code += b"\xCD\x80"
    # reopen append-only
    code += mov_imm(0xB8, 4)
    code += mov_imm(0xBB, name_va)
    code += mov_imm(0xB9, 11)
    code += mov_imm(0xBA, OPEN_WRITE | OPEN_APPEND)
    code += b"\xCD\x80\xA3" + struct.pack("<I", base + fd_offset)
    # append suffix
    code += b"\x89\xC3"
    code += mov_imm(0xB8, 7)
    code += mov_imm(0xB9, suffix_va)
    code += mov_imm(0xBA, len(WRITER_SUFFIX))
    code += b"\xCD\x80"
    # close and exit
    code += mov_imm(0xB8, 6)
    code += b"\x8B\x1D" + struct.pack("<I", base + fd_offset)
    code += b"\xCD\x80"
    code += mov_imm(0xB8, 3)
    code += mov_imm(0xBB, 0x55)
    code += b"\xCD\x80\xF4"

    if len(code) > name_offset:
        raise RuntimeError(f"WRITER.ELF code overlaps data: {len(code)}")
    segment = bytearray(payload_offset + len(WRITER_RESULT))
    segment[: len(code)] = code
    segment[name_offset : name_offset + 11] = NOTES_NAME
    segment[payload_offset : payload_offset + len(WRITER_RESULT)] = WRITER_RESULT
    return build_elf(bytes(segment), memory_size=0x1000)


def build_service_elf() -> bytes:
    base = 0x00400000
    old_name_offset = 0x350
    new_name_offset = 0x360
    payload_offset = 0x380
    pipe_fds_offset = 0x3A0
    stat_offset = 0x3B0
    results_offset = 0x3D0
    read_buffer_offset = 0x440
    old_name_va = base + old_name_offset
    new_name_va = base + new_name_offset
    payload_va = base + payload_offset
    pipe_fds_va = base + pipe_fds_offset
    stat_va = base + stat_offset
    results_va = base + results_offset
    read_buffer_va = base + read_buffer_offset
    payload = b"SERVICE-PIPE-OK!\r\n"

    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store_result(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    code += mov_imm(0xBB, 0)
    syscall(9); store_result(0)
    code += mov_imm(0xBB, 0x00405000)
    syscall(9); store_result(1)
    code += b"\xC7\x05" + struct.pack("<I", 0x00403000) + struct.pack("<I", 0xDEADBEEF)

    code += mov_imm(0xBB, 0x00405000)
    code += mov_imm(0xB9, 0x1000)
    code += mov_imm(0xBA, 3)
    syscall(10); store_result(2)
    code += b"\xC7\x05" + struct.pack("<I", 0x00405000) + struct.pack("<I", 0xCAFEBABE)
    code += mov_imm(0xBB, 0x00405000)
    code += mov_imm(0xB9, 0x1000)
    syscall(11); store_result(3)

    syscall(12); store_result(4)
    syscall(13); store_result(5)
    code += mov_imm(0xBB, 2)
    syscall(14); store_result(6)
    syscall(13); store_result(7)

    code += mov_imm(0xBB, old_name_va)
    code += mov_imm(0xB9, 11)
    code += mov_imm(0xBA, OPEN_READ | OPEN_WRITE | OPEN_CREATE | OPEN_TRUNCATE)
    syscall(4)
    code += b"\xA3" + struct.pack("<I", pipe_fds_va + 8)
    code += b"\x89\xC3"
    code += mov_imm(0xB9, payload_va)
    code += mov_imm(0xBA, len(payload))
    syscall(7); store_result(8)
    code += mov_imm(0xB8, 6)
    code += b"\x8B\x1D" + struct.pack("<I", pipe_fds_va + 8)
    code += b"\xCD\x80"
    code += mov_imm(0xBB, old_name_va)
    code += mov_imm(0xB9, 11)
    code += mov_imm(0xBA, stat_va)
    syscall(15); store_result(9)
    code += mov_imm(0xBB, old_name_va)
    code += mov_imm(0xB9, 11)
    code += mov_imm(0xBA, new_name_va)
    code += mov_imm(0xBE, 11)
    syscall(16); store_result(10)
    code += mov_imm(0xBB, new_name_va)
    code += mov_imm(0xB9, 11)
    code += mov_imm(0xBA, stat_va)
    syscall(15); store_result(11)
    code += mov_imm(0xBB, new_name_va)
    code += mov_imm(0xB9, 11)
    syscall(17); store_result(12)

    code += mov_imm(0xBB, pipe_fds_va)
    syscall(18); store_result(13)
    code += mov_imm(0xB8, 7)
    code += b"\x8B\x1D" + struct.pack("<I", pipe_fds_va + 4)
    code += mov_imm(0xB9, payload_va)
    code += mov_imm(0xBA, len(payload))
    code += b"\xCD\x80"; store_result(14)
    code += mov_imm(0xB8, 19)
    code += b"\x8B\x1D" + struct.pack("<I", pipe_fds_va)
    code += b"\xCD\x80"; store_result(15)
    code += mov_imm(0xB8, 20)
    code += b"\x8B\x1D" + struct.pack("<I", pipe_fds_va + 4)
    code += mov_imm(0xB9, 7)
    code += b"\xCD\x80"; store_result(16)
    code += mov_imm(0xB8, 5)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 15 * 4)
    code += mov_imm(0xB9, read_buffer_va)
    code += mov_imm(0xBA, len(payload))
    code += b"\xCD\x80"; store_result(17)
    for fd_address in (pipe_fds_va, pipe_fds_va + 4):
        code += mov_imm(0xB8, 6)
        code += b"\x8B\x1D" + struct.pack("<I", fd_address)
        code += b"\xCD\x80"
    code += mov_imm(0xB8, 6) + mov_imm(0xBB, 7) + b"\xCD\x80"
    code += mov_imm(0xB8, 5)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 15 * 4)
    code += mov_imm(0xB9, read_buffer_va)
    code += mov_imm(0xBA, 1)
    code += b"\xCD\x80"; store_result(18)
    code += mov_imm(0xB8, 6)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 15 * 4)
    code += b"\xCD\x80"

    syscall(2); store_result(19)
    code += b"\x89\xC3" + mov_imm(0xB9, 9)
    syscall(21); store_result(20)
    syscall(22); store_result(21)
    code += mov_imm(0xBB, 0x00403000)
    syscall(9); store_result(22)
    code += mov_imm(0xBB, 0x66)
    syscall(3)
    code += b"\xF4"

    if len(code) > old_name_offset:
        raise RuntimeError(f"SERVICE.ELF code overlaps data: {len(code)}")
    segment = bytearray(read_buffer_offset + len(payload))
    segment[: len(code)] = code
    segment[old_name_offset : old_name_offset + 11] = b"TEMP2   BIN"
    segment[new_name_offset : new_name_offset + 11] = b"RENAMED BIN"
    segment[payload_offset : payload_offset + len(payload)] = payload
    return build_elf(bytes(segment), memory_size=0x1000)


INIT_ELF = build_init_elf()
CAT_ELF = build_cat_elf()
SPINA_ELF = build_spin_elf()
SPINB_ELF = build_spin_elf()
FAULT_ELF = build_fault_elf()
WRITER_ELF = build_writer_elf()
SERVICE_ELF = build_service_elf()

FILES = (
    (HELLO_NAME, HELLO),
    (INIT_NAME, INIT_ELF),
    (CAT_NAME, CAT_ELF),
    (BIG_NAME, BIG),
    (SPINA_NAME, SPINA_ELF),
    (SPINB_NAME, SPINB_ELF),
    (FAULT_NAME, FAULT_ELF),
    (WRITER_NAME, WRITER_ELF),
    (SERVICE_NAME, SERVICE_ELF),
)


def root_entry(volume: bytearray, index: int, name: bytes, cluster: int, size: int) -> None:
    offset = ROOT_START * BPS + index * 32
    volume[offset : offset + 11] = name
    volume[offset + 11] = 0x20
    struct.pack_into("<H", volume, offset + 26, cluster)
    struct.pack_into("<I", volume, offset + 28, size)


def build_volume(hidden_sectors: int) -> bytes:
    volume = bytearray(TOTAL * BPS)
    boot = memoryview(volume)[:BPS]
    boot[0:3] = b"\xEB\x3C\x90"
    boot[3:11] = b"ZIGOS   "
    struct.pack_into("<H", boot, 11, BPS)
    boot[13] = SPC
    struct.pack_into("<H", boot, 14, RESERVED)
    boot[16] = FATS
    struct.pack_into("<H", boot, 17, ROOT_ENTRIES)
    struct.pack_into("<H", boot, 19, TOTAL)
    boot[21] = 0xF0
    struct.pack_into("<H", boot, 22, SPF)
    struct.pack_into("<H", boot, 24, 18)
    struct.pack_into("<H", boot, 26, 2)
    struct.pack_into("<I", boot, 28, hidden_sectors)
    boot[36] = 0x80
    boot[38] = 0x29
    struct.pack_into("<I", boot, 39, 0x5A49474F)
    boot[43:54] = b"ZIGOS FAT12"
    boot[54:62] = b"FAT12   "
    message = b"ZigOs Capstone 10 FAT12"
    boot[62 : 62 + len(message)] = message
    boot[510:512] = b"\x55\xAA"

    fat = bytearray(SPF * BPS)
    fat[:3] = b"\xF0\xFF\xFF"
    next_cluster = 2
    allocations: list[tuple[int, tuple[int, ...]]] = []
    for name, data in FILES:
        cluster_count = max(1, (len(data) + BPS - 1) // BPS)
        chain = tuple(range(next_cluster, next_cluster + cluster_count))
        allocations.append((len(data), chain))
        for index, cluster in enumerate(chain):
            set_fat12_entry(fat, cluster, chain[index + 1] if index + 1 < len(chain) else 0x0FFF)
        next_cluster += cluster_count

    for copy in range(FATS):
        offset = (FAT_START + copy * SPF) * BPS
        volume[offset : offset + len(fat)] = fat

    for index, ((name, data), (size, chain)) in enumerate(zip(FILES, allocations, strict=True)):
        root_entry(volume, index, name, chain[0], size)
        for chunk_index, cluster in enumerate(chain):
            chunk = data[chunk_index * BPS : (chunk_index + 1) * BPS]
            offset = (DATA_START + cluster - 2) * BPS
            volume[offset : offset + len(chunk)] = chunk

    return bytes(volume)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--hidden-sectors", type=int, default=256)
    args = parser.parse_args()
    if args.hidden_sectors < 64 or args.hidden_sectors > 0xFFFF:
        raise SystemExit("hidden sector count outside supported range")
    volume = build_volume(args.hidden_sectors)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(volume)
    details = " ".join(
        f"{name.decode('ascii').strip()}={len(data)}/{fnv1a32(data):08X}" for name, data in FILES
    )
    print(
        f"Created Capstone 10 FAT12 volume: {args.output} | hidden={args.hidden_sectors} "
        f"sectors={TOTAL} root={ROOT_START} data={DATA_START} {details} "
        f"notes-result={len(WRITER_RESULT)}/{fnv1a32(WRITER_RESULT):08X}"
    )


if __name__ == "__main__":
    main()
