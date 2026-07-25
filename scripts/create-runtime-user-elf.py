#!/usr/bin/env python3
"""Create a deterministic fixed-window ELF64 image for the permanent runtime."""
from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

CODE_BASE = 0x0000008000000000
DATA_BASE = 0x0000008000002000
CODE_OFFSET = 0x1000
DATA_OFFSET = 0x2000
PAGE_SIZE = 0x1000
DATA_FILE_SIZE = PAGE_SIZE


def fnv1a64(data: bytes) -> int:
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def build(code: bytes, data: bytes) -> bytes:
    if not code or len(code) > PAGE_SIZE:
        raise ValueError(f"runtime code must be 1..4096 bytes, got {len(code)}")
    if len(data) > DATA_FILE_SIZE:
        raise ValueError(f"runtime data must be <=4096 bytes, got {len(data)}")
    padded_data = data + bytes(DATA_FILE_SIZE - len(data))
    ident = bytearray(16)
    ident[:4] = b"\x7fELF"
    ident[4:8] = bytes((2, 1, 1, 0))
    header = struct.pack(
        "<16sHHIQQQIHHHHHH",
        bytes(ident),
        2,
        0x3E,
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
    code_header = struct.pack(
        "<IIQQQQQQ", 1, 5, CODE_OFFSET, CODE_BASE, 0, len(code), len(code), PAGE_SIZE
    )
    data_header = struct.pack(
        "<IIQQQQQQ",
        1,
        6,
        DATA_OFFSET,
        DATA_BASE,
        0,
        len(padded_data),
        len(padded_data),
        PAGE_SIZE,
    )
    image = bytearray(DATA_OFFSET + len(padded_data))
    image[:64] = header
    image[64:120] = code_header
    image[120:176] = data_header
    image[CODE_OFFSET : CODE_OFFSET + len(code)] = code
    image[DATA_OFFSET:] = padded_data
    return bytes(image)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--code", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    code = args.code.read_bytes()
    data = args.data.read_bytes()
    image = build(code, data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    print(f"Created permanent-runtime ELF64 image: {args.output}")
    print(f"  code bytes:    {len(code)}")
    print(f"  data bytes:    {len(data)} / {DATA_FILE_SIZE}")
    print(f"  image bytes:   {len(image)}")
    print(f"  code FNV-1a64: {fnv1a64(code):016X}")
    print(f"  SHA-256:       {hashlib.sha256(image).hexdigest().upper()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
