#!/usr/bin/env python3
"""Create the deterministic ZigOs Capstone 14 FAT12 volume."""
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
OPEN_CLOEXEC = 0x20

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
ORCH_NAME = b"ORCH    ELF"
CHILD_NAME = b"CHILD   ELF"
ASYNC_NAME = b"ASYNC   ELF"
WORKA_NAME = b"WORKA   ELF"
WORKB_NAME = b"WORKB   ELF"
LEAF_NAME = b"LEAF    ELF"
GENRUN_NAME = b"GENRUN  ELF"
REUSE_NAME = b"REUSE   ELF"
FORKER_NAME = b"FORKER  ELF"
EXECA_NAME = b"EXECA   ELF"
EXECB_NAME = b"EXECB   ELF"
PATHS_NAME = b"PATHS   ELF"
NOTES_NAME = b"NOTES   TXT"

BIG_PREFIX = b"ZigOs multi-cluster FAT12 read contract.\r\n"
BIG = (BIG_PREFIX + bytes((ord("A") + (i % 26)) for i in range(1300 - len(BIG_PREFIX))))
WRITER_BASE = bytes((ord("a") + (i % 26)) for i in range(700))
WRITER_SUFFIX = b"APPEND-PERSIST-OK!\r\n"
WRITER_RESULT = WRITER_BASE + WRITER_SUFFIX
ORCH_REQUEST = b"PARENT-TO-CHILD\r\n"
CHILD_REPLY = b"CHILD-TO-PARENT\r\n"


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



def build_worka_elf() -> bytes:
    base = 0x00400000
    leaf_name_offset = 0x200
    results_offset = 0x220
    leaf_name_va = base + leaf_name_offset
    results_va = base + results_offset
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    syscall(2); store(0)
    syscall(12); store(1)
    code += mov_imm(0xBB, leaf_name_va) + mov_imm(0xB9, 11)
    syscall(42); store(2)
    syscall(43); store(3)
    code += mov_imm(0xBB, 2)
    syscall(44); store(4)
    syscall(12); store(5)
    code += mov_imm(0xBB, 0x81)
    syscall(3)
    code += b"\xF4"
    if len(code) > leaf_name_offset:
        raise RuntimeError(f"WORKA.ELF code overlaps data: {len(code)}")
    segment = bytearray(results_offset + 6 * 4)
    segment[:len(code)] = code
    segment[leaf_name_offset:leaf_name_offset + 11] = LEAF_NAME
    return build_elf(bytes(segment), memory_size=0x1000)


def build_workb_elf() -> bytes:
    base = 0x00400000
    results_offset = 0x200
    results_va = base + results_offset
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    syscall(2); store(0)
    syscall(12); store(1)
    syscall(43); store(2)
    code += mov_imm(0xB9, 100_000_000)
    spin = len(code)
    code += b"\x49"
    jnz_spin = len(code)
    code += b"\x0F\x85\x00\x00\x00\x00"
    struct.pack_into("<i", code, jnz_spin + 2, spin - (jnz_spin + 6))
    syscall(22); store(3)
    code += mov_imm(0xBB, 0x8F)
    syscall(3)
    code += b"\xF4"
    if len(code) > results_offset:
        raise RuntimeError(f"WORKB.ELF code overlaps data: {len(code)}")
    segment = bytearray(results_offset + 4 * 4)
    segment[:len(code)] = code
    return build_elf(bytes(segment), memory_size=0x1000)

def build_leaf_elf() -> bytes:
    base = 0x00400000
    results_offset = 0x180
    results_va = base + results_offset
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    syscall(2); store(0)
    syscall(12); store(1)
    for index in range(10):
        code += mov_imm(0xBB, 20)
        syscall(44); store(2 + index)
    syscall(12); store(12)
    code += mov_imm(0xBB, 0x83)
    syscall(3)
    code += b"\xF4"
    if len(code) > results_offset:
        raise RuntimeError(f"LEAF.ELF code overlaps data: {len(code)}")
    segment = bytearray(results_offset + 13 * 4)
    segment[:len(code)] = code
    return build_elf(bytes(segment), memory_size=0x1000)

def build_async_elf() -> bytes:
    base = 0x00400000
    offsets = {
        "worka": 0x600,
        "workb": 0x610,
        "missing": 0x620,
        "results": 0x680,
        "status_a_poll": 0x740,
        "status_a_wait": 0x760,
        "status_b": 0x780,
        "status_leaf_before": 0x7A0,
        "info_leaf": 0x7C0,
        "status_leaf_after": 0x7E0,
        "scratch": 0x800,
    }
    results_va = base + offsets["results"]
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    def load_result_ebx(index: int) -> None:
        code.extend(b"\x8B\x1D" + struct.pack("<I", results_va + index * 4))

    code += mov_imm(0xBB, base + offsets["worka"]) + mov_imm(0xB9, 11)
    syscall(42); store(0)
    code += mov_imm(0xBB, base + offsets["workb"]) + mov_imm(0xB9, 11)
    syscall(42); store(1)
    code += b"\xA1" + struct.pack("<I", results_va + 4) + b"\x40"
    store(2)

    load_result_ebx(0)
    code += mov_imm(0xB9, base + offsets["status_a_poll"])
    syscall(45); store(3)

    code += mov_imm(0xBB, base + offsets["status_a_wait"])
    syscall(47); store(4)

    load_result_ebx(2)
    code += mov_imm(0xB9, base + offsets["info_leaf"])
    syscall(31); store(5)
    load_result_ebx(2)
    code += mov_imm(0xB9, base + offsets["status_leaf_before"])
    syscall(45); store(6)

    load_result_ebx(1)
    code += mov_imm(0xB9, 15)
    syscall(21); store(7)
    load_result_ebx(1)
    code += mov_imm(0xB9, base + offsets["status_b"])
    syscall(46); store(8)

    syscall(48); store(9)
    load_result_ebx(2)
    code += mov_imm(0xB9, base + offsets["status_leaf_after"])
    syscall(45); store(10)

    load_result_ebx(0)
    code += mov_imm(0xB9, base + offsets["scratch"])
    syscall(46); store(11)
    code += mov_imm(0xBB, base + offsets["scratch"])
    syscall(47); store(12)

    code += mov_imm(0xBB, base + offsets["missing"]) + mov_imm(0xB9, 11)
    syscall(42); store(13)
    code += mov_imm(0xBB, 0xFFFF) + mov_imm(0xB9, base + offsets["scratch"])
    syscall(45); store(14)

    syscall(2); store(15)
    syscall(12); store(16)
    code += mov_imm(0xBB, 0x73)
    syscall(3)
    code += b"\xF4"

    if len(code) > offsets["worka"]:
        raise RuntimeError(f"ASYNC.ELF code overlaps data: {len(code)}")
    segment = bytearray(offsets["scratch"] + 32)
    segment[:len(code)] = code
    segment[offsets["worka"]:offsets["worka"] + 11] = WORKA_NAME
    segment[offsets["workb"]:offsets["workb"] + 11] = WORKB_NAME
    segment[offsets["missing"]:offsets["missing"] + 11] = b"MISSING ELF"
    return build_elf(bytes(segment), memory_size=0x1000)


def build_reuse_elf() -> bytes:
    base = 0x00400000
    results_offset = 0x180
    results_va = base + results_offset
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    syscall(52); store(0)
    syscall(2); store(1)
    syscall(12); store(2)
    syscall(22); store(3)
    syscall(43); store(4)
    code += mov_imm(0xBB, 1)
    syscall(44); store(5)
    code += mov_imm(0xBB, 0x90)
    syscall(3)
    code += b"\xF4"
    if len(code) > results_offset:
        raise RuntimeError(f"REUSE.ELF code overlaps data: {len(code)}")
    segment = bytearray(results_offset + 6 * 4)
    segment[:len(code)] = code
    return build_elf(bytes(segment), memory_size=0x1000)


def build_exec_elf(exit_code: int, sleep_ticks: int) -> bytes:
    base = 0x00400000
    results_offset = 0x180
    results_va = base + results_offset
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    syscall(52); store(0)
    syscall(2); store(1)
    syscall(12); store(2)
    code += mov_imm(0xBB, 0)
    syscall(29); store(3)
    code += mov_imm(0xBB, sleep_ticks)
    syscall(44); store(4)
    code += mov_imm(0xBB, exit_code)
    syscall(3)
    code += b"\xF4"
    if len(code) > results_offset:
        raise RuntimeError(f"exec workload overlaps data: {len(code)}")
    segment = bytearray(results_offset + 5 * 4)
    segment[:len(code)] = code
    return build_elf(bytes(segment), memory_size=0x1000)


def build_forker_elf() -> bytes:
    base = 0x00400000
    offsets = {
        "hello": 0x300,
        "missing": 0x310,
        "execa": 0x320,
        "execb": 0x330,
        "pipe": 0x340,
        "results": 0x360,
    }
    results_va = base + offsets["results"]
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    code += mov_imm(0xBB, base + offsets["hello"]) + mov_imm(0xB9, 11) + mov_imm(0xBA, OPEN_READ)
    syscall(4); store(0)
    code += mov_imm(0xBB, base + offsets["hello"]) + mov_imm(0xB9, 11) + mov_imm(0xBA, OPEN_READ | OPEN_CLOEXEC)
    syscall(4); store(1)
    code += mov_imm(0xBB, base + offsets["pipe"])
    syscall(18); store(2)
    syscall(50); store(3)
    code += b"\x85\xC0"
    child_jump = len(code)
    code += b"\x0F\x84\x00\x00\x00\x00"

    # Parent branch: failed exec must leave the image intact, then EXECA replaces it.
    code += mov_imm(0xBB, base + offsets["missing"]) + mov_imm(0xB9, 11)
    syscall(51); store(4)
    code += mov_imm(0xBB, base + offsets["execa"]) + mov_imm(0xB9, 11)
    syscall(51)
    code += b"\xF4"

    child_target = len(code)
    struct.pack_into("<i", code, child_jump + 2, child_target - (child_jump + 6))
    # Child branch: same atomic failure proof, then a different replacement image.
    code += mov_imm(0xBB, base + offsets["missing"]) + mov_imm(0xB9, 11)
    syscall(51); store(5)
    code += mov_imm(0xBB, base + offsets["execb"]) + mov_imm(0xB9, 11)
    syscall(51)
    code += b"\xF4"

    if len(code) > offsets["hello"]:
        raise RuntimeError(f"FORKER.ELF code overlaps data: {len(code)}")
    segment = bytearray(offsets["results"] + 6 * 4)
    segment[:len(code)] = code
    segment[offsets["hello"]:offsets["hello"] + 11] = HELLO_NAME
    segment[offsets["missing"]:offsets["missing"] + 11] = b"MISSING ELF"
    segment[offsets["execa"]:offsets["execa"] + 11] = EXECA_NAME
    segment[offsets["execb"]:offsets["execb"] + 11] = EXECB_NAME
    return build_elf(bytes(segment), memory_size=0x1000)


def build_genrun_elf() -> bytes:
    base = 0x00400000
    offsets = {
        "reuse": 0x700,
        "forker": 0x710,
        "fault": 0x720,
        "missing": 0x730,
        "results": 0x800,
        "status": 0xA00,
    }
    results_va = base + offsets["results"]
    status_va = base + offsets["status"]
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    def load_handle(index: int) -> None:
        code.extend(b"\x8B\x1D" + struct.pack("<I", results_va + index * 4))

    def spawn(name_key: str, result_index: int) -> None:
        code.extend(mov_imm(0xBB, base + offsets[name_key]))
        code.extend(mov_imm(0xB9, 11))
        syscall(49); store(result_index)

    syscall(2); store(0)
    syscall(12); store(1)
    syscall(52); store(2)  # outer synchronous parent has no task handle

    # Six sequential generations all reuse slot zero.
    for generation in range(6):
        handle_index = 3 + generation
        poll_index = 9 + generation
        wait_index = 15 + generation
        spawn("reuse", handle_index)
        load_handle(handle_index); code.extend(mov_imm(0xB9, status_va)); syscall(53); store(poll_index)
        if generation == 2:
            load_handle(handle_index); code.extend(mov_imm(0xB9, 7)); syscall(55); store(21)
        load_handle(handle_index); code.extend(mov_imm(0xB9, status_va)); syscall(54); store(wait_index)
        if generation == 0:
            load_handle(handle_index); code.extend(mov_imm(0xB9, status_va)); syscall(53); store(22)
        if generation == 5:
            load_handle(handle_index); code.extend(mov_imm(0xB9, status_va)); syscall(53); store(23)

    spawn("missing", 24)
    spawn("forker", 25)
    load_handle(25); code.extend(mov_imm(0xB9, status_va)); syscall(54); store(26)
    syscall(48); store(27)
    load_handle(25); code.extend(mov_imm(0xB9, status_va)); syscall(53); store(28)

    spawn("fault", 29)
    load_handle(29); code.extend(mov_imm(0xB9, status_va)); syscall(54); store(30)
    load_handle(29); code.extend(mov_imm(0xB9, 9)); syscall(55); store(31)
    load_handle(29); code.extend(mov_imm(0xB9, status_va)); syscall(54); store(32)

    spawn("reuse", 33)
    load_handle(33); code.extend(mov_imm(0xB9, status_va)); syscall(54); store(34)
    syscall(2); store(35)
    syscall(12); store(36)
    code += mov_imm(0xBB, 0x74)
    syscall(3)
    code += b"\xF4"

    if len(code) > offsets["reuse"]:
        raise RuntimeError(f"GENRUN.ELF code overlaps data: {len(code)}")
    segment = bytearray(offsets["status"] + 48)
    segment[:len(code)] = code
    segment[offsets["reuse"]:offsets["reuse"] + 11] = REUSE_NAME
    segment[offsets["forker"]:offsets["forker"] + 11] = FORKER_NAME
    segment[offsets["fault"]:offsets["fault"] + 11] = FAULT_NAME
    segment[offsets["missing"]:offsets["missing"] + 11] = b"MISSING ELF"
    return build_elf(bytes(segment), memory_size=0x1000)


def build_paths_elf() -> bytes:
    base = 0x00400000
    offsets = {
        "root": 0x600,
        "home": 0x610,
        "docs": 0x620,
        "dot_docs": 0x630,
        "empty": 0x640,
        "temp": 0x650,
        "dot_temp": 0x660,
        "moved_up": 0x670,
        "archive": 0x680,
        "moved": 0x690,
        "log_target": 0x6A0,
        "renamed": 0x6B0,
        "scratch": 0x6C0,
        "reuse": 0x6D8,
        "log_abs": 0x6F0,
        "results": 0x740,
        "cwd0": 0x7C0,
        "cwd1": 0x7F0,
        "cwd2": 0x820,
        "stat": 0x850,
        "list0": 0x880,
        "list1": 0x900,
        "payload": 0xA00,
        "readback": 0xC60,
    }
    strings = {
        "root": b"/",
        "home": b"/HOME",
        "docs": b"DOCS",
        "dot_docs": b"./DOCS",
        "empty": b"../EMPTY",
        "temp": b"TEMP.BIN",
        "dot_temp": b"./TEMP.BIN",
        "moved_up": b"../MOVED.BIN",
        "archive": b"ARCHIVE",
        "moved": b"MOVED.BIN",
        "log_target": b"ARCHIVE/LOG.TXT",
        "renamed": b"RENAMED.BIN",
        "scratch": b"DOCS/SCRATCH.BIN",
        "reuse": b"DOCS/REUSE.BIN",
        "log_abs": b"/HOME//ARCHIVE///LOG.TXT",
    }
    payload = bytes(((index * 29 + 7) & 0xFF) for index in range(600))
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", base + offsets["results"] + index * 4))

    def path_args(key: str) -> None:
        code.extend(mov_imm(0xBB, base + offsets[key]))
        code.extend(mov_imm(0xB9, len(strings[key])))

    # getcwd("/")
    code += mov_imm(0xBB, base + offsets["cwd0"]) + mov_imm(0xB9, 48)
    syscall(32); store(0)
    path_args("home"); syscall(34); store(1)
    path_args("home"); syscall(33); store(2)
    code += mov_imm(0xBB, base + offsets["cwd1"]) + mov_imm(0xB9, 48)
    syscall(32); store(3)
    path_args("docs"); syscall(34); store(4)
    path_args("dot_docs"); syscall(33); store(5)
    code += mov_imm(0xBB, base + offsets["cwd2"]) + mov_imm(0xB9, 48)
    syscall(32); store(6)
    path_args("empty"); syscall(34); store(7)
    path_args("empty"); syscall(35); store(8)

    # Create/truncate and write 600 bytes through a relative path.
    path_args("temp")
    code += mov_imm(0xBA, base + offsets["payload"])
    code += mov_imm(0xBE, len(payload)) + mov_imm(0xBF, 3)
    syscall(37); store(9)
    path_args("dot_temp")
    code += mov_imm(0xBA, base + offsets["stat"])
    syscall(36); store(10)
    path_args("temp")
    code += mov_imm(0xBA, base + offsets["readback"]) + mov_imm(0xBE, len(payload))
    syscall(38); store(11)

    # Cross-directory move to parent, then into a newly created sibling directory.
    path_args("temp")
    code += mov_imm(0xBA, base + offsets["renamed"]) + mov_imm(0xBE, len(strings["renamed"]))
    syscall(39); store(12)
    path_args("renamed")
    code += mov_imm(0xBA, base + offsets["moved_up"]) + mov_imm(0xBE, len(strings["moved_up"]))
    syscall(39); store(13)
    path_args("empty"); syscall(33); store(14)  # expected failure: EMPTY was removed
    path_args("root"); syscall(33); store(15)
    path_args("home"); syscall(33); store(16)
    path_args("archive"); syscall(34); store(17)
    path_args("moved")
    code += mov_imm(0xBA, base + offsets["log_target"]) + mov_imm(0xBE, len(strings["log_target"]))
    syscall(39); store(18)
    path_args("archive"); syscall(35); store(19)  # expected ENOTEMPTY

    # Enumerate parent and child directories, then read/stat the persistent file absolutely.
    code += mov_imm(0xBB, base + offsets["home"]) + mov_imm(0xB9, len(strings["home"]))
    code += mov_imm(0xBA, base + offsets["list0"]) + mov_imm(0xBE, 128)
    syscall(41); store(20)
    path_args("archive")
    code += mov_imm(0xBA, base + offsets["list1"]) + mov_imm(0xBE, 128)
    syscall(41); store(21)
    path_args("log_abs")
    code += mov_imm(0xBA, base + offsets["stat"])
    syscall(36); store(22)
    path_args("log_abs")
    code += mov_imm(0xBA, base + offsets["readback"]) + mov_imm(0xBE, len(payload))
    syscall(38); store(23)

    # Reclaim and first-fit reuse one temporary cluster.
    path_args("scratch")
    code += mov_imm(0xBA, base + offsets["payload"]) + mov_imm(0xBE, 1) + mov_imm(0xBF, 3)
    syscall(37); store(24)
    path_args("scratch"); syscall(40); store(25)
    path_args("reuse")
    code += mov_imm(0xBA, base + offsets["payload"]) + mov_imm(0xBE, 1) + mov_imm(0xBF, 3)
    syscall(37); store(26)
    path_args("reuse"); syscall(40); store(27)
    path_args("root"); syscall(33); store(28)
    code += mov_imm(0xBB, base + offsets["cwd0"]) + mov_imm(0xB9, 48)
    syscall(32); store(29)
    code += mov_imm(0xBB, 0x72); syscall(3)
    code += b"\xF4"

    if len(code) > offsets["root"]:
        raise RuntimeError(f"PATHS.ELF code overlaps data: {len(code)}")
    segment = bytearray(offsets["readback"] + len(payload))
    segment[:len(code)] = code
    for key, value in strings.items():
        segment[offsets[key]:offsets[key] + len(value)] = value
    segment[offsets["payload"]:offsets["payload"] + len(payload)] = payload
    return build_elf(bytes(segment), memory_size=0x1000)


def build_child_elf() -> bytes:
    base = 0x00400000
    patch_offset = 0x200
    results_offset = 0x220
    request_offset = 0x260
    reply_offset = 0x280
    patch_va = base + patch_offset
    results_va = base + results_offset
    request_va = base + request_offset
    reply_va = base + reply_offset
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    syscall(2); store(0)
    syscall(12); store(1)
    code += b"\x8B\x1D" + struct.pack("<I", patch_va + 8)
    syscall(29); store(2)
    syscall(22); store(3)
    code += mov_imm(0xB8, 5)
    code += b"\x8B\x1D" + struct.pack("<I", patch_va)
    code += mov_imm(0xB9, request_va)
    code += mov_imm(0xBA, len(ORCH_REQUEST))
    code += b"\xCD\x80"; store(4)
    code += mov_imm(0xB8, 7)
    code += b"\x8B\x1D" + struct.pack("<I", patch_va + 4)
    code += mov_imm(0xB9, reply_va)
    code += mov_imm(0xBA, len(CHILD_REPLY))
    code += b"\xCD\x80"; store(5)
    code += mov_imm(0xB8, 3) + mov_imm(0xBB, 0x77) + b"\xCD\x80\xF4"
    if len(code) > patch_offset:
        raise RuntimeError(f"CHILD.ELF code overlaps patch data: {len(code)}")
    segment = bytearray(reply_offset + len(CHILD_REPLY))
    segment[:len(code)] = code
    segment[reply_offset:reply_offset + len(CHILD_REPLY)] = CHILD_REPLY
    return build_elf(bytes(segment), memory_size=0x1000)


def build_orch_elf() -> bytes:
    base = 0x00400000
    child_name_offset = 0x500
    hello_name_offset = 0x510
    request_offset = 0x530
    pipe_fds_offset = 0x550
    file_fd_offset = 0x558
    results_offset = 0x580
    status_offset = 0x620
    info_offset = 0x640
    reply_offset = 0x680
    child_name_va = base + child_name_offset
    hello_name_va = base + hello_name_offset
    request_va = base + request_offset
    pipe_fds_va = base + pipe_fds_offset
    file_fd_va = base + file_fd_offset
    results_va = base + results_offset
    status_va = base + status_offset
    info_va = base + info_offset
    reply_va = base + reply_offset
    code = bytearray()

    def syscall(number: int) -> None:
        code.extend(mov_imm(0xB8, number))
        code.extend(b"\xCD\x80")

    def store(index: int) -> None:
        code.extend(b"\xA3" + struct.pack("<I", results_va + index * 4))

    code += mov_imm(0xBB, 0); syscall(9); store(0)
    code += mov_imm(0xBB, 0x00405000); syscall(9); store(1)
    code += b"\xC7\x05" + struct.pack("<I", 0x00403000) + struct.pack("<I", 0xDEADBEEF)
    code += mov_imm(0xBB, 0x00405000) + mov_imm(0xB9, 0x1000) + mov_imm(0xBA, 3)
    syscall(10); store(2)
    code += b"\xC7\x05" + struct.pack("<I", 0x00405000) + struct.pack("<I", 0xCAFEBABE)

    code += mov_imm(0xBB, hello_name_va) + mov_imm(0xB9, 11) + mov_imm(0xBA, OPEN_READ | OPEN_CLOEXEC)
    syscall(4); store(3)
    code += b"\xA3" + struct.pack("<I", file_fd_va)
    code += mov_imm(0xBB, pipe_fds_va); syscall(18); store(4)
    code += mov_imm(0xB8, 7)
    code += b"\x8B\x1D" + struct.pack("<I", pipe_fds_va + 4)
    code += mov_imm(0xB9, request_va) + mov_imm(0xBA, len(ORCH_REQUEST))
    code += b"\xCD\x80"; store(5)

    syscall(23); store(6)
    code += mov_imm(0xB8, 24)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += mov_imm(0xB9, 0x00403000) + b"\xCD\x80"; store(7)
    code += mov_imm(0xB8, 25)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += mov_imm(0xB9, 0x00403000) + mov_imm(0xBA, 0xAABBCCDD)
    code += b"\xCD\x80"; store(8)
    code += mov_imm(0xB8, 24)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += mov_imm(0xB9, 0x00403000) + b"\xCD\x80"; store(9)
    code += b"\xA1" + struct.pack("<I", 0x00403000); store(10)

    code += mov_imm(0xB8, 28)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += b"\x89\xD9\xCD\x80"; store(11)
    code += mov_imm(0xB8, 29)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += b"\xCD\x80"; store(12)
    code += mov_imm(0xB8, 30)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += mov_imm(0xB9, 12) + b"\xCD\x80"; store(13)

    code += mov_imm(0xB8, 26)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += mov_imm(0xB9, child_name_va) + mov_imm(0xBA, 11)
    code += b"\xCD\x80"; store(14)
    code += mov_imm(0xB8, 31)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += mov_imm(0xB9, info_va) + b"\xCD\x80"; store(15)
    code += mov_imm(0xB8, 27)
    code += b"\x8B\x1D" + struct.pack("<I", results_va + 6 * 4)
    code += mov_imm(0xB9, status_va) + b"\xCD\x80"; store(16)

    code += mov_imm(0xB8, 5)
    code += b"\x8B\x1D" + struct.pack("<I", pipe_fds_va)
    code += mov_imm(0xB9, reply_va) + mov_imm(0xBA, len(CHILD_REPLY))
    code += b"\xCD\x80"; store(17)
    for fd_va in (file_fd_va, pipe_fds_va, pipe_fds_va + 4):
        code += mov_imm(0xB8, 6)
        code += b"\x8B\x1D" + struct.pack("<I", fd_va)
        code += b"\xCD\x80"; store(18 + (fd_va != file_fd_va) + (fd_va == pipe_fds_va + 4))

    code += mov_imm(0xBB, 0x00405000) + mov_imm(0xB9, 0x1000)
    syscall(11); store(21)
    code += mov_imm(0xBB, 0x00403000); syscall(9); store(22)
    code += mov_imm(0xBB, 0x70); syscall(3)
    code += b"\xF4"

    if len(code) > child_name_offset:
        raise RuntimeError(f"ORCH.ELF code overlaps data: {len(code)}")
    segment = bytearray(reply_offset + len(CHILD_REPLY))
    segment[:len(code)] = code
    segment[child_name_offset:child_name_offset + 11] = CHILD_NAME
    segment[hello_name_offset:hello_name_offset + 11] = HELLO_NAME
    segment[request_offset:request_offset + len(ORCH_REQUEST)] = ORCH_REQUEST
    return build_elf(bytes(segment), memory_size=0x1000)


INIT_ELF = build_init_elf()
CAT_ELF = build_cat_elf()
SPINA_ELF = build_spin_elf()
SPINB_ELF = build_spin_elf()
FAULT_ELF = build_fault_elf()
WRITER_ELF = build_writer_elf()
SERVICE_ELF = build_service_elf()
ORCH_ELF = build_orch_elf()
CHILD_ELF = build_child_elf()
ASYNC_ELF = build_async_elf()
WORKA_ELF = build_worka_elf()
WORKB_ELF = build_workb_elf()
LEAF_ELF = build_leaf_elf()
GENRUN_ELF = build_genrun_elf()
REUSE_ELF = build_reuse_elf()
FORKER_ELF = build_forker_elf()
EXECA_ELF = build_exec_elf(0xA1, 1)
EXECB_ELF = build_exec_elf(0xB2, 5)
PATHS_ELF = build_paths_elf()

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
    (ORCH_NAME, ORCH_ELF),
    (CHILD_NAME, CHILD_ELF),
    (ASYNC_NAME, ASYNC_ELF),
    (WORKA_NAME, WORKA_ELF),
    (WORKB_NAME, WORKB_ELF),
    (LEAF_NAME, LEAF_ELF),
    (GENRUN_NAME, GENRUN_ELF),
    (REUSE_NAME, REUSE_ELF),
    (FORKER_NAME, FORKER_ELF),
    (EXECA_NAME, EXECA_ELF),
    (EXECB_NAME, EXECB_ELF),
    (PATHS_NAME, PATHS_ELF),
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
    message = b"ZigOs Capstone 14 FAT12"
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
        f"Created Capstone 14 FAT12 volume: {args.output} | hidden={args.hidden_sectors} "
        f"sectors={TOTAL} root={ROOT_START} data={DATA_START} {details} "
        f"notes-result={len(WRITER_RESULT)}/{fnv1a32(WRITER_RESULT):08X}"
    )


if __name__ == "__main__":
    main()
