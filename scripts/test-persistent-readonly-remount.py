#!/usr/bin/env python3
"""Inject one persistent NVMe write error and prove fail-stop read-only remount containment."""

from __future__ import annotations

import argparse
import atexit
import hashlib
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

PROMPT_HOME = b"root@zigos:/home/root$ "
PROMPT_ROOT = b"root@zigos:/$ "
FAULT_LBA = 18_434


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
                raise RuntimeError(f"persistent read-only remount gate is already running as PID {owner}")
            lock_path.unlink(missing_ok=True)
            continue
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as stream:
            stream.write(f"{os.getpid()}\n")
        return
    raise RuntimeError("could not acquire persistent read-only remount gate lock")


def release_run_lock(lock_path: pathlib.Path) -> None:
    try:
        owner = int(lock_path.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return
    if owner == os.getpid():
        lock_path.unlink(missing_ok=True)


def remove_stale_workdirs(build_dir: pathlib.Path) -> None:
    for path in build_dir.glob("persistent-readonly-remount-*"):
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)


def terminate_process_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("QEMU process tree did not terminate") from error


def file_identity(path: pathlib.Path) -> tuple[int, str] | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return path.stat().st_size, digest.hexdigest()


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
    tail = bytes(output[-8000:]).decode("ascii", errors="replace")
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
    if not zig.is_file():
        raise RuntimeError(f"canonical Zig toolchain is missing: {zig}")

    build_dir = root / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    lock_path = build_dir / "test-persistent-readonly-remount.lock"
    acquire_run_lock(lock_path)
    atexit.register(release_run_lock, lock_path)
    remove_stale_workdirs(build_dir)
    work = pathlib.Path(tempfile.mkdtemp(prefix="persistent-readonly-remount-", dir=build_dir))
    install = work / "install"
    shared_efi = root / "zig-out" / "EFI" / "BOOT" / "BOOTX64.EFI"
    shared_before = file_identity(shared_efi)
    success = False
    serial_log = work / "serial.log"
    retained_log = build_dir / "test-persistent-readonly-remount.serial.log"

    try:
        subprocess.run(
            [
                str(zig),
                "build",
                "-Doptimize=ReleaseSmall",
                "-Dnormal-boot=true",
                f"-Dnvme-write-fault-lba={FAULT_LBA}",
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
            raise RuntimeError("private read-only remount profile produced no BOOTX64.EFI")
        image = work / "readonly-remount-nvme.img"
        metadata = work / "readonly-remount-nvme.json"
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
            ],
            cwd=root,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        image_metadata = json.loads(metadata.read_text(encoding="utf-8"))
        data_first_lba = int(image_metadata["data_partition_first_lba"])
        payload_lba = data_first_lba + 2
        if data_first_lba != 18_432 or payload_lba != FAULT_LBA:
            raise RuntimeError("deterministic persistent payload write target does not match image geometry")

        qemu = find_qemu()
        code_source, vars_source = find_firmware(qemu)
        code_image = work / "code.fd"
        vars_image = work / "vars.fd"
        shutil.copyfile(code_source, code_image)
        shutil.copyfile(vars_source, vars_image)
        port = free_tcp_port()
        debug_log = work / "debug.log"
        stdout_log = work / "qemu-stdout.log"
        stderr_log = work / "qemu-stderr.log"

        command = [
            str(qemu),
            "-machine", "q35,i8042=off,hpet=off",
            "-m", "256M",
            "-cpu", "max",
            "-smp", "1",
            "-device", "qemu-xhci,id=xhci",
            "-drive", f"file={image.name},if=none,id=nvme0,format=raw,cache=unsafe",
            "-device", "nvme,drive=nvme0,serial=ZIGOSNVME,logical_block_size=512,physical_block_size=512,bootindex=1",
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code_image.as_posix()}",
            "-drive", f"if=pflash,format=raw,unit=1,file={vars_image.as_posix()}",
            "-debugcon", f"file:{debug_log.as_posix()}",
            "-global", "isa-debugcon.iobase=0xe9",
            "-display", "none",
            "-vga", "none",
            "-serial", f"tcp:127.0.0.1:{port},server=on,wait=off",
            "-monitor", "none",
            "-no-reboot",
            "-net", "none",
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
                    raise RuntimeError("persistent read-only remount serial connection failed")

                wait_for(client, process, serial, b"ZigOs userspace init PID 1", 0, args.boot_timeout)
                wait_for(client, process, serial, b"ZigOs userspace shell PID 2", 0, 20)
                wait_for(client, process, serial, PROMPT_HOME, 0, 20)
                send(client, process, serial, "help", b"help echo pwd cd ls cat cp write append mkdir rm rmdir mv chmod sync pid status fg bg run shutdown")
                send(client, process, serial, "cd /", PROMPT_ROOT)
                send(client, process, serial, "run hello", b"process 3 exited 42", 40)
                send(client, process, serial, "mkdir /persist/damaged", PROMPT_ROOT)
                send(client, process, serial, "write /persist/damaged/value.txt before", PROMPT_ROOT)
                send(client, process, serial, "cat /persist/damaged/value.txt", b"before")
                send(client, process, serial, "sync", b"sync: input/output error", 40)
                send(client, process, serial, "cat /proc/mounts", b"nvme-zigos-data on /persist type zigos_persist (ro)")
                send(client, process, serial, "write /persist/damaged/value.txt blocked", b"write: read-only filesystem")
                send(client, process, serial, "append /persist/damaged/value.txt blocked", b"append: read-only filesystem")
                send(client, process, serial, "mkdir /persist/new", b"mkdir: read-only filesystem")
                send(client, process, serial, "rm /persist/damaged/value.txt", b"rm: read-only filesystem")
                send(client, process, serial, "cat /persist/damaged/value.txt", b"before")
                send(client, process, serial, "sync", b"sync: read-only filesystem")
                send(client, process, serial, "shutdown", b"ZigOs normal boot verified:", 50)
                read_available(client, serial)
                text = bytes(serial).decode("ascii", errors="replace")
                serial_log.write_text(text, encoding="utf-8", newline="\n")
                shutil.copyfile(serial_log, retained_log)

                required = (
                    f"NVMe one-shot write error armed: requested LBA {FAULT_LBA}, command LBA 32768",
                    "process 3 exited 42",
                    "sync: input/output error",
                    "nvme-zigos-data on /persist type zigos_persist (ro)",
                    "write: read-only filesystem",
                    "append: read-only filesystem",
                    "mkdir: read-only filesystem",
                    "rm: read-only filesystem",
                    "sync: read-only filesystem",
                    "ZigOs NVMe write fault injection: failures 1 armed no clean yes",
                    "ZigOs persistent damage containment: damaged yes reason payload_write remounts/failures 1/0 discarded/rejected 2/1 vfs-remount/discard 1/2 mount-readonly yes clean yes",
                    "ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5799492 metadata/file/block reads 113/0/113 failures 0 clusters claimed/free/loop/cross/range 11331/4780/0/0/0 lock tickets/outstanding 1/0 quarantine state/reason/events no/none/0 clean yes",
                    "ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes",
                    "ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 64/64 cache-released 12 storage persistent-read-only clean yes",
                    "ZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage persistent-read-only cleanup yes",
                )
                forbidden = (
                    "ZigOs NVMe write fault injection: failures 0",
                    "mount-readonly no",
                    "storage persistent-read-only clean no",
                    "storage persistent-read-only cleanup no",
                    "Persistent runtime failure:",
                    "kernel fault:",
                )
                for marker in required:
                    if marker not in text:
                        raise RuntimeError(f"persistent read-only remount boot missing marker: {marker}")
                for marker in forbidden:
                    if marker in text:
                        raise RuntimeError(f"persistent read-only remount boot contained forbidden marker: {marker}")
            finally:
                if client is not None:
                    client.close()
                terminate_process_tree(process)

        shared_after = file_identity(shared_efi)
        if shared_after != shared_before:
            raise RuntimeError("private read-only remount build modified shared zig-out")
        success = True
        print("Persistent write-error read-only remount boot passed.")
        print(f"  injected persistent payload LBA: {FAULT_LBA}")
        print(f"  serial log: {retained_log}")
        return 0
    finally:
        if file_identity(shared_efi) != shared_before:
            raise RuntimeError("shared zig-out changed during persistent read-only remount gate")
        release_run_lock(lock_path)
        if success:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
