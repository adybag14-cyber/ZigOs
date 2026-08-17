#!/usr/bin/env python3
"""Inject one real NVMe read EIO and prove propagation through FAT, VFS and the userspace ABI."""

from __future__ import annotations

import argparse
import atexit
import os
import json
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

PROMPT_HOME = b"root@zigos:/home/root$ "
PROMPT_ROOT = b"root@zigos:/$ "
FAULT_CLUSTER = 15_000
FAULT_LBA = 17_319


def process_is_running(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def acquire_run_lock(lock_path: pathlib.Path) -> None:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            descriptor = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            try:
                owner = int(lock_path.read_text(encoding="ascii").strip())
            except (OSError, ValueError):
                owner = 0
            if process_is_running(owner):
                raise RuntimeError(f"FAT EIO gate is already running as PID {owner}")
            lock_path.unlink(missing_ok=True)
            continue
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as stream:
            stream.write(f"{os.getpid()}\n")
        return
    raise RuntimeError("could not acquire FAT EIO gate lock")


def release_run_lock(lock_path: pathlib.Path) -> None:
    try:
        owner = int(lock_path.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return
    if owner == os.getpid():
        lock_path.unlink(missing_ok=True)


def remove_stale_workdirs(build_dir: pathlib.Path) -> None:
    for path in build_dir.glob("boot-fat-io-error-*"):
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)


def find_qemu() -> pathlib.Path:
    for candidate in (shutil.which("qemu-system-x86_64"), r"C:\Program Files\qemu\qemu-system-x86_64.exe"):
        if candidate and pathlib.Path(candidate).is_file():
            return pathlib.Path(candidate)
    raise RuntimeError("qemu-system-x86_64 was not found")


def find_firmware(qemu: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    share = qemu.parent / "share"
    code = next(
        (path for path in (share / "edk2-x86_64-code.fd", share / "edk2-x86_64-secure-code.fd", share / "OVMF_CODE.fd") if path.is_file()),
        None,
    )
    variables = next((path for path in (share / "edk2-i386-vars.fd", share / "OVMF_VARS.fd") if path.is_file()), None)
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
    start: int,
    timeout_seconds: float,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        read_available(client, output)
        if marker in output[start:]:
            return
        code = process.poll()
        if code is not None:
            raise RuntimeError(f"QEMU exited with code {code} before marker {marker!r}")
        time.sleep(0.05)
    tail = bytes(output[-6000:]).decode("ascii", errors="replace")
    raise RuntimeError(f"timed out waiting for {marker!r}; serial tail:\n{tail}")


def send(
    client: socket.socket,
    process: subprocess.Popen[bytes],
    output: bytearray,
    command: str,
    marker: bytes,
    timeout_seconds: float = 25.0,
) -> None:
    start = len(output)
    client.sendall(command.encode("ascii") + b"\r")
    wait_for(client, process, output, marker, start, timeout_seconds)
    time.sleep(0.1)
    read_available(client, output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--boot-timeout", type=int, default=220)
    args = parser.parse_args()

    root = args.repo_root.resolve()
    version = (root / ".toolchain-version").read_text(encoding="utf-8").strip()
    zig = root / ".toolchains" / "zig-canonical" / f"zig-x86_64-windows-{version}" / "zig.exe"

    build_dir = root / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    lock_path = build_dir / "test-boot-fat-io-error.lock"
    acquire_run_lock(lock_path)
    atexit.register(release_run_lock, lock_path)
    remove_stale_workdirs(build_dir)
    work = pathlib.Path(tempfile.mkdtemp(prefix="boot-fat-io-error-", dir=build_dir))
    install = work / "install"
    subprocess.run(
        [
            str(zig),
            "build",
            "-Doptimize=ReleaseSmall",
            "-Dnormal-boot=true",
            f"-Dnvme-read-fault-lba={FAULT_LBA}",
            "--prefix",
            str(install),
            "--cache-dir",
            str(work / "zig-cache"),
            "--summary",
            "all",
        ],
        cwd=root,
        check=True,
    )

    efi = install / "EFI" / "BOOT" / "BOOTX64.EFI"
    if not efi.is_file():
        raise RuntimeError("private normal profile produced no BOOTX64.EFI")
    sdk_elf = install / "artifacts" / "sdk.elf"
    if not sdk_elf.is_file():
        raise RuntimeError("private normal profile produced no sdk.elf")
    image = work / "io-error-nvme.img"
    metadata = work / "io-error-nvme.json"
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
            str(metadata),
            "--runtime-file-first-cluster",
            str(FAULT_CLUSTER),
        ],
        cwd=root,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    image_metadata = json.loads(metadata.read_text(encoding="utf-8"))
    readme_lba = int(image_metadata["first_data_lba"]) + (
        int(image_metadata["runtime_readme_cluster"]) - 2
    ) * int(image_metadata["sectors_per_cluster"])
    if image_metadata.get("runtime_file_first_cluster") != FAULT_CLUSTER or readme_lba != FAULT_LBA:
        raise RuntimeError("deterministic README.TXT fault target does not match the compiled NVMe trigger")

    qemu = find_qemu()
    code_source, vars_source = find_firmware(qemu)
    code_image = work / "code.fd"
    vars_image = work / "vars.fd"
    shutil.copyfile(code_source, code_image)
    shutil.copyfile(vars_source, vars_image)
    port = free_tcp_port()
    debug_log = work / "debug.log"
    serial_log = work / "serial.log"
    stdout_log = work / "qemu-stdout.log"
    stderr_log = work / "qemu-stderr.log"

    command = [
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
        f"file={image.name},if=none,id=nvme0,format=raw,cache=unsafe",
        "-device",
        "nvme,drive=nvme0,serial=ZIGOSNVME,logical_block_size=512,physical_block_size=512,bootindex=1",
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
        process = subprocess.Popen(command, cwd=work, stdout=stdout_stream, stderr=stderr_stream)
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                try:
                    client = socket.create_connection(("127.0.0.1", port), timeout=0.5)
                    client.settimeout(0.15)
                    break
                except OSError:
                    time.sleep(0.1)
            if client is None:
                raise RuntimeError("FAT EIO boot serial connection failed")

            wait_for(client, process, serial, b"ZigOs userspace init PID 1", 0, args.boot_timeout)
            wait_for(client, process, serial, b"ZigOs userspace shell PID 2", 0, 20)
            wait_for(client, process, serial, PROMPT_HOME, 0, 20)
            send(client, process, serial, "help", b"help echo pwd cd ls cat cp write append mkdir rm rmdir mv chmod sync pid status fg bg run shutdown")
            send(client, process, serial, "pwd", b"\r\n/home/root\r\n")
            send(client, process, serial, "cd /", PROMPT_ROOT)
            send(client, process, serial, "pwd", b"\r\n/\r\n")
            send(client, process, serial, "cat /boot/README.TXT", b"cat: input/output error")
            send(client, process, serial, "cat /boot/README.TXT", b"ZigOs block-backed FAT16 runtime")
            send(client, process, serial, "ls /bin", b"sh.elf")
            send(client, process, serial, "cat /proc/version", b"ZigOs 19.0.0 x86_64 persistent runtime")
            send(client, process, serial, "pid", b"\r\n2\r\n")
            send(client, process, serial, "mkdir /persist/shell-state", PROMPT_ROOT)
            send(client, process, serial, "write /persist/shell-state/message.txt alpha", PROMPT_ROOT)
            send(client, process, serial, "append /persist/shell-state/message.txt beta", PROMPT_ROOT)
            send(client, process, serial, "write /persist/shell-state/renamed.txt stale-destination", PROMPT_ROOT)
            send(client, process, serial, "mv /persist/shell-state/message.txt /persist/shell-state/renamed.txt", PROMPT_ROOT)
            send(client, process, serial, "chmod 600 /persist/shell-state/renamed.txt", PROMPT_ROOT)
            send(client, process, serial, "cat /persist/shell-state/renamed.txt", b"beta")
            send(client, process, serial, "rm /persist/shell-state/renamed.txt", PROMPT_ROOT)
            send(client, process, serial, "rmdir /persist/shell-state", PROMPT_ROOT)
            send(client, process, serial, "run hello", b"process 3 exited 42", 40)
            send(client, process, serial, "cp /bin/sdk.elf /persist/persist-sdk.elf", PROMPT_ROOT, 40)
            send(client, process, serial, "sync", b"writable mounts synchronized", 40)
            send(client, process, serial, "persist-sdk alpha beta", b"process 4 exited 86", 40)
            send(client, process, serial, "fs init", b"process 5 exited 88", 60)
            send(client, process, serial, "fs verify-live", b"process 6 exited 89", 60)
            send(client, process, serial, "shutdown", b"ZigOs normal boot verified:", 40)
            read_available(client, serial)
            text = bytes(serial).decode("ascii", errors="replace")
            serial_log.write_text(text, encoding="utf-8", newline="\n")

            required = (
                "Normal boot selected: skipping kernel heap, scheduler, Capstone 15 and Capstone 16 proof workloads",
                "ZigOs normal boot profile: userspace init PID 1 supervises userspace shell PID 2; diagnostic software suite skipped",
                "ZigOs userspace init PID 1",
                "userspace init launched shell PID 2",
                "ZigOs userspace shell PID 2",
                f"NVMe one-shot read error armed: requested LBA {FAULT_LBA}, command LBA 32768",
                "hello from VFS-loaded CPL3 ELF64",
                "process 3 exited 42",
                "writable mounts synchronized",
                "zig-sdk: envp/auxv passed",
                "zig-sdk: tmpfs mount/umount isolation, statfs and busy policy passed",
                "zig-sdk: timestamp precision/data/namespace/access ordering passed",
                "zig-sdk: uid/gid creation and hard-link ownership passed",
                "zig-sdk: advisory whole-file flock passed",
                "zig-sdk: advisory byte-range lock passed",
                "zig-sdk: directory watch notifications passed",
                "zig-sdk: startup/argv/abi/files/vm/file-mmap/errno/fsync/fdatasync/readv/writev/mount/umount/tmpfs/statfs/stattimes/statowner/umask/setid-metadata/flock/lockrange/watchdir passed",
                "process 4 exited 86",
                "fs-api: init/mkdir/write/seek/replace-rename/chmod/link/nlink/symlink/readlink/fallocate/sparse/open-unlink/rmdir/sync passed",
                "process 5 exited 88",
                "fs-api: baseline/mode/seek/hard-link/symlink/fallocate/sparse/cleanup passed",
                "process 6 exited 89",
                "userspace init reaped shell PID 2 status 0",
                "ZigOs normal userspace shutdown: init PID 1 status 0 shell PID 2 reaped yes",
                "cat: input/output error",
                "ZigOs block-backed FAT16 runtime",
                "ZigOs NVMe read fault injection: failures 1 armed no clean yes",
                "ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5710404 metadata/file/block reads 113/3/114 failures 1 clusters claimed/free/loop/cross/range 11157/4954/0/0/0 lock tickets/outstanding 4/0 quarantine state/reason/events no/none/0 clean yes",
                "ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes",
                "ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 144/144 cache-released 13 storage persistent clean yes",
                "ZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage persistent cleanup yes",
            )
            forbidden = (
                "Kernel heap active:",
                "Cooperative scheduler active:",
                "Preemptive scheduler active:",
                "ZigOs x86-64 Capstone 15 verified:",
                "ZigOs x86-64 Capstone 16 verified:",
                "init PID 1; serial shell PID 2",
                "ZigOs normal boot profile: init PID 1; userspace shell PID 2",
            )
            for marker in required:
                if marker not in text:
                    raise RuntimeError(f"FAT EIO boot missing marker: {marker}")
            for marker in forbidden:
                if marker in text:
                    raise RuntimeError(f"FAT EIO boot unexpectedly ran diagnostic marker: {marker}")
            if "ZigOs normal userspace resources:" not in text or "clean yes" not in text:
                raise RuntimeError("FAT EIO boot did not report clean resource reclamation")
        finally:
            if client is not None:
                client.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)

    print("FAT block-read EIO propagation boot passed.")
    print(f"  injected README.TXT LBA: {readme_lba}")
    print(f"  serial log: {serial_log}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
