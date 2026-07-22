#!/usr/bin/env python3
"""Portable PE/COFF validation for the ZigOs x86-64 UEFI application."""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    args = parser.parse_args()

    path = args.path.resolve()
    data = path.read_bytes()
    if len(data) < 256:
        raise SystemExit("EFI image is unexpectedly small")
    if data[:2] != b"MZ":
        raise SystemExit("missing DOS MZ header")

    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_offset + 24 > len(data):
        raise SystemExit("invalid PE header offset")
    if data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise SystemExit("missing PE signature")

    machine = struct.unpack_from("<H", data, pe_offset + 4)[0]
    section_count = struct.unpack_from("<H", data, pe_offset + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe_offset + 20)[0]
    optional = pe_offset + 24
    if optional + optional_size > len(data):
        raise SystemExit("truncated PE optional header")

    magic = struct.unpack_from("<H", data, optional)[0]
    entry_rva = struct.unpack_from("<I", data, optional + 16)[0]
    image_size = struct.unpack_from("<I", data, optional + 56)[0]
    subsystem = struct.unpack_from("<H", data, optional + 68)[0]

    if machine != 0x8664:
        raise SystemExit(f"wrong machine type: 0x{machine:04X}")
    if magic != 0x020B:
        raise SystemExit(f"not PE32+: 0x{magic:04X}")
    if subsystem != 10:
        raise SystemExit(f"wrong subsystem: {subsystem}; expected EFI application (10)")
    if section_count == 0 or entry_rva == 0 or image_size == 0:
        raise SystemExit("PE image has empty sections, entry point, or image size")

    digest = hashlib.sha256(data).hexdigest()
    print(f"Verified EFI application: {path}")
    print(f"  size:       {len(data)} bytes")
    print("  machine:    AMD64 (0x8664)")
    print("  format:     PE32+")
    print("  subsystem:  EFI application (10)")
    print(f"  sections:   {section_count}")
    print(f"  entry RVA:  0x{entry_rva:08X}")
    print(f"  image size: {image_size}")
    print(f"  sha256:     {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
