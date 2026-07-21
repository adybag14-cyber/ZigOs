#!/usr/bin/env python3
"""Wrap the deterministic x86-64 userspace payload in a strict two-segment ELF64 image."""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

CODE_BASE = 0x0000008000100000
DATA_BASE = 0x0000008000102000
CODE_OFFSET = 0x1000
DATA_OFFSET = 0x2000
PAGE_SIZE = 0x1000
DATA_FILE_SIZE = 0x800
DATA_MEMORY_SIZE = 0x2000
MESSAGE_OFFSET = 0x400
PIPE_OFFSET = 0x440
MESSAGE = b"ZigOs x86-64 ELF64 service active."
PIPE_PAYLOAD = b"PIPE64-PAYLOAD-VERIFIED!"


def fnv1a64(data: bytes) -> int:
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def build_elf(code: bytes) -> bytes:
    if not code or len(code) > PAGE_SIZE:
        raise ValueError(f"service payload must fit one page, got {len(code)} bytes")
    if len(MESSAGE) != 34:
        raise AssertionError(len(MESSAGE))
    if len(PIPE_PAYLOAD) != 24:
        raise AssertionError(len(PIPE_PAYLOAD))

    data = bytearray(DATA_FILE_SIZE)
    data[MESSAGE_OFFSET:MESSAGE_OFFSET + len(MESSAGE)] = MESSAGE
    data[PIPE_OFFSET:PIPE_OFFSET + len(PIPE_PAYLOAD)] = PIPE_PAYLOAD
    data[0x7C0:0x7C8] = struct.pack("<Q", 0x4543495652455336)
    data[0x7C8:0x7D0] = struct.pack("<Q", fnv1a64(code))
    data[0x7D0:0x7D8] = struct.pack("<Q", fnv1a64(data[:0x7D0]))

    ident = bytearray(16)
    ident[:4] = b"\x7fELF"
    ident[4] = 2  # ELFCLASS64
    ident[5] = 1  # little-endian
    ident[6] = 1  # current version
    ident[7] = 0  # System V

    ehdr = struct.pack(
        "<16sHHIQQQIHHHHHH",
        bytes(ident),
        2,          # ET_EXEC
        0x3E,       # EM_X86_64
        1,
        CODE_BASE,
        64,
        0,
        0,
        64,
        56,
        2,
        0,
        0,
        0,
    )
    text_phdr = struct.pack(
        "<IIQQQQQQ",
        1,          # PT_LOAD
        5,          # PF_R | PF_X
        CODE_OFFSET,
        CODE_BASE,
        0,
        len(code),
        len(code),
        PAGE_SIZE,
    )
    data_phdr = struct.pack(
        "<IIQQQQQQ",
        1,
        6,          # PF_R | PF_W
        DATA_OFFSET,
        DATA_BASE,
        0,
        len(data),
        DATA_MEMORY_SIZE,
        PAGE_SIZE,
    )

    image = bytearray(DATA_OFFSET + len(data))
    image[:64] = ehdr
    image[64:120] = text_phdr
    image[120:176] = data_phdr
    image[CODE_OFFSET:CODE_OFFSET + len(code)] = code
    image[DATA_OFFSET:DATA_OFFSET + len(data)] = data
    return bytes(image)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    code = args.payload.read_bytes()
    image = build_elf(code)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    print(f"Created ELF64 service image: {args.output}")
    print(f"  payload bytes: {len(code)}")
    print(f"  image bytes:   {len(image)}")
    print(f"  code FNV-1a64: {fnv1a64(code):016X}")
    print(f"  ELF SHA-256:   {hashlib.sha256(image).hexdigest().upper()}")


if __name__ == "__main__":
    main()
