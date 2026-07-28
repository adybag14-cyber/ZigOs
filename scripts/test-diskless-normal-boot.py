#!/usr/bin/env python3
"""Boot the normal profile from USB and verify a storage-less RAM-root recovery session."""

from __future__ import annotations

import argparse
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time

PROMPT_HOME = b"root@zigos:/home/root$ "


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
    timeout_seconds: float = 30.0,
) -> None:
    start = len(output)
    client.sendall(command.encode("ascii") + b"\r")
    wait_for(client, process, output, marker, start, timeout_seconds)
    time.sleep(0.1)
    read_available(client, output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--boot-timeout", type=int, default=220)
    args = parser.parse_args()

    root = args.repo_root.resolve()
    version = (root / ".toolchain-version").read_text(encoding="utf-8").strip()
    zig = root / ".toolchains" / "zig-canonical" / f"zig-x86_64-windows-{version}" / "zig.exe"
    if not args.skip_build:
        subprocess.run(
            [str(zig), "build", "-Doptimize=ReleaseSmall", "-Dnormal-boot=true", "--summary", "all"],
            cwd=root,
            check=True,
        )

    efi = root / "zig-out" / "EFI" / "BOOT" / "BOOTX64.EFI"
    if not efi.is_file():
        raise RuntimeError("normal profile produced no BOOTX64.EFI")

    (root / "build").mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="diskless-normal-", dir=root / "build"))
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
    fat_path = (root / "zig-out").as_posix()

    command = [
        str(qemu),
        "-machine", "q35,i8042=off,hpet=off",
        "-m", "256M",
        "-cpu", "max",
        "-smp", "1",
        "-device", "qemu-xhci,id=xhci",
        "-drive", f"if=none,id=bootusb,format=raw,file=fat:rw:{fat_path}",
        "-device", "usb-storage,drive=bootusb,bus=xhci.0,bootindex=1",
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
        process = subprocess.Popen(command, stdout=stdout_stream, stderr=stderr_stream)
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
                raise RuntimeError("diskless normal-boot serial connection failed")

            wait_for(client, process, serial, b"ZigOs userspace init PID 1", 0, args.boot_timeout)
            wait_for(client, process, serial, b"ZigOs userspace shell PID 2", 0, 20)
            wait_for(client, process, serial, PROMPT_HOME, 0, 20)
            send(client, process, serial, "pwd", b"\r\n/home/root\r\n")
            send(client, process, serial, "ls /bin", b"c-sdk.elf")
            send(client, process, serial, "cat /proc/version", b"ZigOs 19.0.0 x86_64 persistent runtime")
            send(client, process, serial, "write /tmp/recovery.txt diskless recovery", PROMPT_HOME)
            send(client, process, serial, "cat /tmp/recovery.txt", b"diskless recovery")
            send(client, process, serial, "c-sdk alpha beta", b"process 3 exited 87", 50)
            send(client, process, serial, "sync", b"sync: unsupported")
            send(client, process, serial, "shutdown", b"ZigOs normal boot verified:", 50)
            read_available(client, serial)
            text = bytes(serial).decode("ascii", errors="replace")
            serial_log.write_text(text, encoding="utf-8", newline="\n")

            required = (
                "No permanent storage backend usable; continuing normal boot with embedded assets and RAM-backed root",
                "Storage backends ready: NVMe no, AHCI no",
                "Normal boot selected: skipping kernel heap, scheduler, Capstone 15 and Capstone 16 proof workloads",
                "ZigOs normal boot profile: userspace init PID 1 supervises userspace shell PID 2; diagnostic software suite skipped",
                "ZigOs userspace init PID 1",
                "ZigOs userspace shell PID 2",
                "c-sdk: ABI 1.6 discovery passed",
                "c-sdk: generated header/library/device/ioctl/stat/openat/fsync passed",
                "process 3 exited 87",
                "sync: unsupported",
                "userspace shell requested shutdown",
                "userspace init reaped shell PID 2 status 0",
                "storage diskless-ram-root clean yes",
                "ZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage diskless-ram-root cleanup yes",
            )
            forbidden = (
                "STORAGE FAILURE",
                "NVMe controller active",
                "NVMe retained for permanent runtime",
                "persistent storage synchronized",
                "Kernel heap active:",
                "Cooperative scheduler active:",
                "Preemptive scheduler active:",
                "ZigOs x86-64 Capstone 15 verified:",
                "ZigOs x86-64 Capstone 16 verified:",
            )
            for marker in required:
                if marker not in text:
                    raise RuntimeError(f"diskless normal boot missing marker: {marker}")
            for marker in forbidden:
                if marker in text:
                    raise RuntimeError(f"diskless normal boot unexpectedly emitted: {marker}")
        finally:
            if client is not None:
                client.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)

    print("Diskless normal x86-64 RAM-root recovery boot passed.")
    print(f"  serial log: {serial_log}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
