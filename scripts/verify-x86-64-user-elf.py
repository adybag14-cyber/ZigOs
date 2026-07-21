#!/usr/bin/env python3
"""Independently verify the generated Capstone 15 x86-64 userspace ELF image."""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

CODE_BASE = 0x0000008000100000
DATA_BASE = 0x0000008000102000
MESSAGE = b"ZigOs x86-64 ELF64 service active."
PIPE_PAYLOAD = b"PIPE64-PAYLOAD-VERIFIED!"
EXPECTED_PAYLOAD_BYTES = 2628
EXPECTED_CODE_FNV = 0x8B9C77E6A0D03758
EXPECTED_ELF_SHA256 = "A166FAE8BCFD94663CA1CE0904AE2BF5D2044E831179910C173F9E4BCA1A8E28"


def fail(message: str) -> None:
    raise SystemExit(f"x86-64 user ELF verification failed: {message}")


def fnv1a64(data: bytes) -> int:
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    image = args.path.read_bytes()
    if len(image) != 0x2800:
        fail(f"image size {len(image)} is not 0x2800")
    fields = struct.unpack_from("<16sHHIQQQIHHHHHH", image, 0)
    ident, e_type, machine, version, entry, phoff, shoff, flags, ehsize, phentsize, phnum, shentsize, shnum, shstrndx = fields
    if ident[:8] != b"\x7fELF\x02\x01\x01\x00":
        fail("ELF identification is not ELF64 little-endian System V")
    if (e_type, machine, version, entry, phoff, shoff, flags) != (2, 0x3E, 1, CODE_BASE, 64, 0, 0):
        fail("ELF executable header contract mismatch")
    if (ehsize, phentsize, phnum, shentsize, shnum, shstrndx) != (64, 56, 2, 0, 0, 0):
        fail("ELF table sizes/counts mismatch")

    expected = (
        (1, 5, 0x1000, CODE_BASE, 0, None, None, 0x1000),
        (1, 6, 0x2000, DATA_BASE, 0, 0x800, 0x2000, 0x1000),
    )
    phdrs = []
    for index in range(2):
        ph = struct.unpack_from("<IIQQQQQQ", image, 64 + index * 56)
        phdrs.append(ph)
    text = phdrs[0]
    if text[:5] != expected[0][:5] or text[5] == 0 or text[5] > 0x1000 or text[6] != text[5] or text[7] != 0x1000:
        fail("RX PT_LOAD contract mismatch")
    if phdrs[1] != expected[1]:
        fail("RW PT_LOAD contract mismatch")
    if text[2] % text[7] != text[3] % text[7] or phdrs[1][2] % 0x1000 != phdrs[1][3] % 0x1000:
        fail("PT_LOAD offset/virtual alignment mismatch")
    code = image[0x1000:0x1000 + text[5]]
    data = image[0x2000:0x2800]
    if len(code) != EXPECTED_PAYLOAD_BYTES:
        fail(f"payload size {len(code)} is not {EXPECTED_PAYLOAD_BYTES}")
    if fnv1a64(code) != EXPECTED_CODE_FNV:
        fail(f"payload FNV {fnv1a64(code):016X} is not {EXPECTED_CODE_FNV:016X}")
    image_sha256 = hashlib.sha256(image).hexdigest().upper()
    if image_sha256 != EXPECTED_ELF_SHA256:
        fail(f"ELF SHA-256 {image_sha256} is not {EXPECTED_ELF_SHA256}")
    if data[0x400:0x400 + len(MESSAGE)] != MESSAGE:
        fail("message bytes mismatch")
    if data[0x440:0x440 + len(PIPE_PAYLOAD)] != PIPE_PAYLOAD:
        fail("pipe payload bytes mismatch")
    if struct.unpack_from("<Q", data, 0x7C0)[0] != 0x4543495652455336:
        fail("data identity marker mismatch")
    if struct.unpack_from("<Q", data, 0x7C8)[0] != fnv1a64(code):
        fail("embedded code FNV mismatch")
    if struct.unpack_from("<Q", data, 0x7D0)[0] != fnv1a64(data[:0x7D0]):
        fail("embedded data FNV mismatch")
    syscall_count = code.count(b"\xCD\x80")
    if syscall_count != 51:
        fail(f"expected 51 int 0x80 instructions, found {syscall_count}")
    if code.count(b"\x0F\x0B") != 4:
        fail("expected exactly four terminal/fault UD2 guards")
    print(f"Verified x86-64 ELF64 userspace image: {args.path}")
    print(f"  payload:       {len(code)} bytes")
    print(f"  syscalls:      {syscall_count} encoded int 0x80 sites")
    print(f"  segments:      RX {text[5]} bytes, RW 2048/8192 bytes")
    print(f"  code FNV-1a64: {fnv1a64(code):016X}")
    print(f"  SHA-256:       {image_sha256}")


if __name__ == "__main__":
    main()
