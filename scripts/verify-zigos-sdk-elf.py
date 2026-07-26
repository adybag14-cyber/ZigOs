#!/usr/bin/env python3
"""Verify a directly linked freestanding ZigOs SDK ELF64 executable."""
from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

ELF_HEADER_SIZE = 64
PROGRAM_HEADER_SIZE = 56
PT_LOAD = 1
PF_X = 1
PF_W = 2
PF_R = 4
PAGE_SIZE = 4096
USER_BASE = 0x0000008000000000
MMAP_FLOOR = USER_BASE + 64 * 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    data = args.image.read_bytes()
    if len(data) < ELF_HEADER_SIZE:
        fail("SDK ELF is smaller than one ELF64 header")
    if data[:16] != b"\x7fELF\x02\x01\x01\x00" + bytes(8):
        fail("SDK ELF identity is not ELF64 little-endian System V")

    fields = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    e_type, machine, version, entry, phoff, shoff, flags, ehsize, phentsize, phnum, _, _, _ = fields
    if (e_type, machine, version, flags, ehsize, phentsize) != (2, 0x3E, 1, 0, 64, 56):
        fail(f"unsupported SDK ELF header fields: {fields!r}")
    if phnum == 0 or phnum > 4:
        fail(f"SDK ELF must contain 1..4 load segments, got {phnum}")
    if phoff > len(data) or phnum * PROGRAM_HEADER_SIZE > len(data) - phoff:
        fail("SDK ELF program header table exceeds the file")
    if entry < USER_BASE or entry >= MMAP_FLOOR:
        fail(f"SDK ELF entry is outside the image window: 0x{entry:X}")

    previous_end = USER_BASE
    executable_entry = False
    writable_segments = 0
    segment_lines: list[str] = []
    for index in range(phnum):
        values = struct.unpack_from("<IIQQQQQQ", data, phoff + index * PROGRAM_HEADER_SIZE)
        kind, segment_flags, offset, virtual, physical, file_size, memory_size, alignment = values
        if kind != PT_LOAD:
            fail(f"SDK ELF program header {index} is not PT_LOAD")
        if segment_flags == 0 or segment_flags & ~(PF_R | PF_W | PF_X):
            fail(f"SDK ELF program header {index} has invalid flags 0x{segment_flags:X}")
        if not segment_flags & PF_R or segment_flags & PF_W and segment_flags & PF_X:
            fail(f"SDK ELF program header {index} violates readable/W^X policy")
        if physical not in (0, virtual):
            fail(f"SDK ELF program header {index} has unsupported physical address")
        if file_size == 0 or memory_size < file_size:
            fail(f"SDK ELF program header {index} has invalid file/memory sizes")
        if alignment != PAGE_SIZE or offset % PAGE_SIZE != virtual % PAGE_SIZE:
            fail(f"SDK ELF program header {index} is not page-congruent")
        if offset > len(data) or file_size > len(data) - offset:
            fail(f"SDK ELF program header {index} exceeds the file")
        end = virtual + memory_size
        if virtual < USER_BASE or end <= virtual or end > MMAP_FLOOR:
            fail(f"SDK ELF program header {index} leaves the image window")
        if virtual < previous_end:
            fail(f"SDK ELF program header {index} overlaps or is unsorted")
        previous_end = (end + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
        if segment_flags & PF_X and virtual <= entry < end:
            executable_entry = True
        if segment_flags & PF_W:
            writable_segments += 1
        rendered = "".join(("R" if segment_flags & PF_R else "-", "W" if segment_flags & PF_W else "-", "X" if segment_flags & PF_X else "-"))
        segment_lines.append(
            f"  PT_LOAD {index}: {rendered} VA 0x{virtual:X}, file {file_size}, memory {memory_size}"
        )

    if not executable_entry:
        fail("SDK ELF entry is not contained in an executable segment")
    if writable_segments > 1:
        fail("SDK ELF contains more than one writable segment")
    section_size, section_count, section_name_index = fields[10], fields[11], fields[12]
    if shoff:
        if section_size != 64 or section_count == 0 or section_count > 256:
            fail("SDK ELF section table has invalid dimensions")
        if section_name_index >= section_count or shoff + section_count * section_size > len(data):
            fail("SDK ELF section table exceeds the file")
    elif section_size or section_count or section_name_index:
        fail("SDK ELF has section metadata without a section table")

    print(f"Verified directly linked ZigOs SDK ELF64 image: {args.image}")
    print(f"  bytes:       {len(data)}")
    print(f"  entry:       0x{entry:X}")
    print(f"  load count:  {phnum}")
    print(f"  SHA-256:     {hashlib.sha256(data).hexdigest().upper()}")
    for line in segment_lines:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
