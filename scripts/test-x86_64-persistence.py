#!/usr/bin/env python3
"""Prove global sync and file-scoped fsync across three independent x86-64 boots."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass

PROMPT = b"root@zigos:/home/root# "
HEADER_MAGIC = b"ZIGPERS1"
HEADER_VERSION = 1
HEADER_SIZE = 48
COMMIT_MARKER = 0x434F4D54


@dataclass(frozen=True)
class Header:
    slot: int
    generation: int
    payload_length: int
    payload_crc32: int
    record_count: int


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_qemu() -> pathlib.Path:
    candidates = [
        shutil.which("qemu-system-x86_64"),
        r"C:\Program Files\qemu\qemu-system-x86_64.exe",
    ]
    for candidate in candidates:
        if candidate and pathlib.Path(candidate).is_file():
            return pathlib.Path(candidate)
    raise RuntimeError("qemu-system-x86_64 was not found")


def find_firmware(qemu: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    share = qemu.parent / "share"
    code_candidates = [
        share / "edk2-x86_64-code.fd",
        share / "edk2-x86_64-secure-code.fd",
        share / "OVMF_CODE.fd",
    ]
    vars_candidates = [share / "edk2-i386-vars.fd", share / "OVMF_VARS.fd"]
    code = next((path for path in code_candidates if path.is_file()), None)
    variables = next((path for path in vars_candidates if path.is_file()), None)
    if code is None or variables is None:
        raise RuntimeError("compatible split OVMF images were not found")
    return code, variables


def free_tcp_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def read_available(client: socket.socket, output: bytearray) -> None:
    while True:
        try:
            chunk = client.recv(65536)
        except (TimeoutError, socket.timeout):
            return
        if not chunk:
            return
        output.extend(chunk)
        if len(chunk) < 65536:
            return


def wait_for(
    client: socket.socket,
    process: subprocess.Popen[bytes],
    output: bytearray,
    marker: bytes,
    start_offset: int,
    timeout_seconds: float,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        read_available(client, output)
        if marker in output[start_offset:]:
            return
        code = process.poll()
        if code is not None:
            raise RuntimeError(f"QEMU exited with code {code} before marker {marker!r}")
        time.sleep(0.05)
    tail = bytes(output[-4000:]).decode("ascii", errors="replace")
    raise RuntimeError(f"timed out waiting for {marker!r}; serial tail:\n{tail}")


def send_command(
    client: socket.socket,
    process: subprocess.Popen[bytes],
    output: bytearray,
    command: str,
    marker: str | None = None,
    timeout_seconds: float = 20.0,
) -> None:
    start = len(output)
    client.sendall(command.encode("ascii") + b"\r")
    if marker is None:
        time.sleep(0.45)
        read_available(client, output)
        return
    wait_for(client, process, output, marker.encode("ascii"), start, timeout_seconds)
    time.sleep(0.1)
    read_available(client, output)


def run_boot(
    *,
    boot_number: int,
    qemu: pathlib.Path,
    code_source: pathlib.Path,
    vars_source: pathlib.Path,
    work: pathlib.Path,
    image: pathlib.Path,
    commands: list[tuple[str, str | None]],
    required_markers: list[str],
    boot_timeout: int,
) -> str:
    code_image = work / f"boot{boot_number}-code.fd"
    vars_image = work / f"boot{boot_number}-vars.fd"
    debug_log = work / f"boot{boot_number}-debug.log"
    serial_log = work / f"boot{boot_number}-serial.log"
    stdout_log = work / f"boot{boot_number}-qemu-stdout.log"
    stderr_log = work / f"boot{boot_number}-qemu-stderr.log"
    shutil.copyfile(code_source, code_image)
    shutil.copyfile(vars_source, vars_image)
    port = free_tcp_port()

    arguments = [
        str(qemu),
        "-machine",
        "q35,i8042=off,hpet=off",
        "-m",
        "256M",
        "-cpu",
        "max",
        "-smp",
        "1",
        "-device",
        "qemu-xhci,id=xhci",
        "-drive",
        f"file={image.as_posix()},if=none,id=nvme0,format=raw,cache=unsafe",
        "-device",
        "nvme,drive=nvme0,serial=ZIGOSNVME,logical_block_size=512,physical_block_size=512",
        "-drive",
        f"if=pflash,format=raw,unit=0,readonly=on,file={code_image.as_posix()}",
        "-drive",
        f"if=pflash,format=raw,unit=1,file={vars_image.as_posix()}",
        "-debugcon",
        f"file:{debug_log.as_posix()}",
        "-global",
        "isa-debugcon.iobase=0xe9",
        "-display",
        "none",
        "-vga",
        "none",
        "-serial",
        f"tcp:127.0.0.1:{port},server=on,wait=off",
        "-monitor",
        "none",
        "-no-reboot",
        "-net",
        "none",
    ]

    serial = bytearray()
    client: socket.socket | None = None
    with stdout_log.open("wb") as stdout_stream, stderr_log.open("wb") as stderr_stream:
        process = subprocess.Popen(arguments, stdout=stdout_stream, stderr=stderr_stream)
        try:
            connect_deadline = time.monotonic() + 20
            while time.monotonic() < connect_deadline:
                try:
                    client = socket.create_connection(("127.0.0.1", port), timeout=0.5)
                    client.settimeout(0.15)
                    break
                except OSError:
                    time.sleep(0.1)
            if client is None:
                raise RuntimeError(f"boot {boot_number}: serial connection failed")

            wait_for(client, process, serial, PROMPT, 0, boot_timeout)
            for command, marker in commands:
                send_command(client, process, serial, command, marker)
            text = bytes(serial).decode("ascii", errors="replace")
            for marker in required_markers:
                if marker not in text:
                    raise RuntimeError(f"boot {boot_number}: missing marker: {marker}")
            serial_log.write_text(text, encoding="utf-8", newline="\n")
            return text
        finally:
            if client is not None:
                client.close()
            if process.poll() is None:
                process.kill()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.terminate()


def parse_header(image: pathlib.Path, first_lba: int, slot: int, block_size: int = 512) -> Header | None:
    with image.open("rb") as stream:
        stream.seek((first_lba + slot) * block_size)
        block = bytearray(stream.read(block_size))
    if len(block) != block_size:
        raise RuntimeError("persistence header read was truncated")
    if not any(block):
        return None
    if block[:8] != HEADER_MAGIC:
        raise RuntimeError(f"slot {slot}: invalid persistence magic")
    version = int.from_bytes(block[8:12], "little")
    header_size = int.from_bytes(block[12:16], "little")
    generation = int.from_bytes(block[16:24], "little")
    payload_length = int.from_bytes(block[24:28], "little")
    payload_crc32 = int.from_bytes(block[28:32], "little")
    encoded_slot = int.from_bytes(block[32:36], "little")
    record_count = int.from_bytes(block[36:40], "little")
    stored_crc = int.from_bytes(block[40:44], "little")
    marker = int.from_bytes(block[44:48], "little")
    block[40:44] = b"\0\0\0\0"
    calculated_crc = binascii.crc32(block[:HEADER_SIZE]) & 0xFFFFFFFF
    if version != HEADER_VERSION or header_size != HEADER_SIZE:
        raise RuntimeError(f"slot {slot}: unsupported persistence header version")
    if encoded_slot != slot or marker != COMMIT_MARKER:
        raise RuntimeError(f"slot {slot}: persistence commit fields were invalid")
    if stored_crc != calculated_crc:
        raise RuntimeError(f"slot {slot}: persistence header CRC mismatch")
    return Header(slot, generation, payload_length, payload_crc32, record_count)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--boot-timeout", type=int, default=180)
    args = parser.parse_args()

    root = args.repo_root.resolve()
    work = root / "build" / "x86_64-persistence-test"
    lock = root / "build" / "x86_64-persistence-test.lock"
    work.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(descriptor)
    except FileExistsError as error:
        raise RuntimeError(f"persistence test lock already exists: {lock}") from error

    try:
        if not args.skip_build:
            subprocess.run(
                ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(root / "scripts" / "build.ps1")],
                cwd=root,
                check=True,
                timeout=900,
            )
        efi = root / "zig-out" / "EFI" / "BOOT" / "BOOTX64.EFI"
        if not efi.is_file():
            raise RuntimeError("installed BOOTX64.EFI is missing")
        sdk_elf = root / "zig-out" / "artifacts" / "sdk.elf"
        if not sdk_elf.is_file():
            raise RuntimeError("installed sdk.elf is missing")
        sdk_copy_marker = f"copied {sdk_elf.stat().st_size} bytes"

        if work.exists():
            for child in work.iterdir():
                if child.is_dir():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        qemu = find_qemu()
        code_source, vars_source = find_firmware(qemu)
        image = work / "persistent-nvme.img"
        metadata_path = work / "persistent-nvme.json"
        subprocess.run(
            [
                sys.executable,
                str(root / "scripts" / "create-nvme-test-image.py"),
                "--output",
                str(image),
                "--efi",
                str(efi),
                "--block-size",
                "512",
                "--metadata",
                str(metadata_path),
            ],
            cwd=root,
            check=True,
        )
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        data_first_lba = int(metadata["data_partition_first_lba"])
        initial_hash = sha256(image)

        first_text = run_boot(
            boot_number=1,
            qemu=qemu,
            code_source=code_source,
            vars_source=vars_source,
            work=work,
            image=image,
            boot_timeout=args.boot_timeout,
            commands=[
                ("mkdir /persist/config", None),
                ("write /persist/config/message.txt survived-generation-one", None),
                ("cp /bin/sdk.elf /persist/persist-sdk.elf", sdk_copy_marker),
                ("exec /bin/fs.elf init", "exec: PID 3 state zombie status 0x58"),
                ("fsck", "fsck ramfs/persist: clean"),
                ("cat /persist/config/message.txt", "survived-generation-one"),
                ("shutdown", "ZigOs persistent storage: mounted yes generation/slot 1/0"),
            ],
            required_markers=[
                "fs-api: init/mkdir/write/seek/replace-rename/chmod/link/nlink/symlink/readlink/fallocate/sparse/open-unlink/rmdir/sync passed",
                "exec: PID 3 state zombie status 0x58",
                "ZigOs persistent storage: mounted yes generation/slot 1/0 records/payload 8/",
                "errors 0/0 clean yes",
                "persistent-storage yes canned-results no explicit-shutdown yes",
            ],
        )
        after_first_hash = sha256(image)
        if after_first_hash == initial_hash:
            raise RuntimeError("boot 1 did not modify the NVMe image")
        header_a = parse_header(image, data_first_lba, 0)
        header_b = parse_header(image, data_first_lba, 1)
        if header_a is None or header_a.generation != 1 or header_a.record_count != 8 or header_b is not None:
            raise RuntimeError(f"unexpected generation-1 headers: A={header_a}, B={header_b}")

        second_text = run_boot(
            boot_number=2,
            qemu=qemu,
            code_source=code_source,
            vars_source=vars_source,
            work=work,
            image=image,
            boot_timeout=args.boot_timeout,
            commands=[
                ("exec /bin/fs.elf fsync", "exec: PID 3 state zombie status 0x5B"),
            ],
            required_markers=[
                "fs-api: file-fsync target data/mode committed unrelated dirty state excluded",
                "exec: PID 3 state zombie status 0x5B",
            ],
        )
        after_second_hash = sha256(image)
        if after_second_hash == after_first_hash:
            raise RuntimeError("boot 2 file fsync did not commit a new NVMe generation")
        header_a = parse_header(image, data_first_lba, 0)
        header_b = parse_header(image, data_first_lba, 1)
        if header_a is None or header_b is None:
            raise RuntimeError(f"file fsync did not leave both A/B headers committed: A={header_a}, B={header_b}")
        if (header_a.generation, header_b.generation) != (1, 2):
            raise RuntimeError(f"unexpected post-fsync A/B generations: A={header_a}, B={header_b}")
        if header_a.record_count != 8 or header_b.record_count != 8:
            raise RuntimeError(f"file fsync changed persistent namespace cardinality: A={header_a}, B={header_b}")

        third_text = run_boot(
            boot_number=3,
            qemu=qemu,
            code_source=code_source,
            vars_source=vars_source,
            work=work,
            image=image,
            boot_timeout=args.boot_timeout,
            commands=[
                ("cat /persist/config/message.txt", "survived-generation-one"),
                ("exec /persist/persist-sdk.elf alpha beta", "exec: PID 3 state zombie status 0x56"),
                ("append /persist/config/message.txt survived-generation-three", None),
                ("exec /bin/fs.elf verify", "exec: PID 4 state zombie status 0x59"),
                ("fsck", "fsck ramfs/persist: clean"),
                ("cat /persist/config/message.txt", "survived-generation-three"),
                ("shutdown", "ZigOs persistent storage: mounted yes generation/slot 3/0"),
            ],
            required_markers=[
                "survived-generation-one",
                "survived-generation-three",
                "zig-sdk: envp/auxv passed",
                "exec: PID 3 state zombie status 0x56",
                "fs-api: recovery/file-fsync-isolation/mode/hard-link/symlink/fallocate/sparse/cleanup passed",
                "exec: PID 4 state zombie status 0x59",
                "ZigOs persistent storage: mounted yes generation/slot 3/0 records/payload 3/",
                "errors 0/0 clean yes",
                "persistent-storage yes canned-results no explicit-shutdown yes",
            ],
        )
        after_third_hash = sha256(image)
        if after_third_hash == after_second_hash:
            raise RuntimeError("boot 3 did not commit a new NVMe generation")
        header_a = parse_header(image, data_first_lba, 0)
        header_b = parse_header(image, data_first_lba, 1)
        if header_a is None or header_b is None:
            raise RuntimeError(f"both A/B headers were not committed: A={header_a}, B={header_b}")
        if (header_a.generation, header_b.generation) != (3, 2):
            raise RuntimeError(f"unexpected final A/B generations: A={header_a}, B={header_b}")
        if header_a.record_count != 3 or header_b.record_count != 8:
            raise RuntimeError(f"unexpected final A/B record counts: A={header_a}, B={header_b}")

        summary = {
            "initial_sha256": initial_hash,
            "after_boot1_sha256": after_first_hash,
            "after_boot2_fsync_sha256": after_second_hash,
            "after_boot3_sha256": after_third_hash,
            "slot_a": header_a.__dict__,
            "slot_b": header_b.__dict__,
            "boot1_serial_bytes": len(first_text.encode("utf-8")),
            "boot2_serial_bytes": len(second_text.encode("utf-8")),
            "boot3_serial_bytes": len(third_text.encode("utf-8")),
        }
        (work / "result.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8", newline="\n")
        print("Persistent x86-64 NVMe three-boot fsync session passed.")
        print(f"  boot 1: slot A generation 1, records 8")
        print(f"  boot 2 crash: slot B generation 2, records 8 (one-file fsync)")
        print(f"  boot 3: slot A generation {header_a.generation}, records {header_a.record_count}")
        print(f"  image SHA-256: {initial_hash[:12]} -> {after_first_hash[:12]} -> {after_second_hash[:12]} -> {after_third_hash[:12]}")
        return 0
    finally:
        try:
            lock.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
