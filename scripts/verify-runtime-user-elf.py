#!/usr/bin/env python3
"""Independent verifier for permanent-runtime ELF64 fixtures."""
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
IMAGE_SIZE = 0x3000


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    data = args.image.read_bytes()
    if len(data) != IMAGE_SIZE:
        raise SystemExit(f"runtime ELF must be {IMAGE_SIZE} bytes, got {len(data)}")
    if data[:16] != b"\x7fELF\x02\x01\x01\x00" + bytes(8):
        raise SystemExit("invalid ELF64 identity")
    fields = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    if fields != (2, 0x3E, 1, CODE_BASE, 64, 0, 0, 64, 56, 2, 0, 0, 0):
        raise SystemExit(f"invalid ELF64 header fields: {fields!r}")
    code = struct.unpack_from("<IIQQQQQQ", data, 64)
    rw = struct.unpack_from("<IIQQQQQQ", data, 120)
    if code[0:5] != (1, 5, CODE_OFFSET, CODE_BASE, 0):
        raise SystemExit(f"invalid executable PT_LOAD: {code!r}")
    if code[5] == 0 or code[5] > PAGE_SIZE or code[6] != code[5] or code[7] != PAGE_SIZE:
        raise SystemExit(f"invalid executable sizes: {code!r}")
    if rw != (1, 6, DATA_OFFSET, DATA_BASE, 0, PAGE_SIZE, PAGE_SIZE, PAGE_SIZE):
        raise SystemExit(f"invalid writable PT_LOAD: {rw!r}")
    if any(data[176:CODE_OFFSET]):
        raise SystemExit("non-zero header padding")
    print(f"Verified permanent-runtime ELF64 image: {args.image}")
    print(f"  code bytes:  {code[5]}")
    print(f"  image bytes: {len(data)}")
    print(f"  SHA-256:     {hashlib.sha256(data).hexdigest().upper()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
