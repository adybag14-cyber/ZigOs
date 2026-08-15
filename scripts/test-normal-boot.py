#!/usr/bin/env python3
"""Boot the normal x86-64 profile and prove userspace PID 1 supervision of the interactive PID 2 Zig shell."""

from __future__ import annotations

import argparse
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

PROMPT_HOME = b"root@zigos:/home/root$ "
PROMPT_ROOT = b"root@zigos:/$ "


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
    sdk_elf = root / "zig-out" / "artifacts" / "sdk.elf"
    if not sdk_elf.is_file():
        raise RuntimeError("normal profile produced no sdk.elf")
    sdk_copy_marker = f"copied {sdk_elf.stat().st_size} bytes"

    (root / "build").mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="normal-boot-", dir=root / "build"))
    image = work / "normal-nvme.img"
    metadata = work / "normal-nvme.json"
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
                raise RuntimeError("normal boot serial connection failed")

            wait_for(client, process, serial, b"ZigOs userspace init PID 1", 0, args.boot_timeout)
            wait_for(client, process, serial, b"ZigOs userspace shell PID 2", 0, 20)
            wait_for(client, process, serial, PROMPT_HOME, 0, 20)
            send(client, process, serial, "help", b"help echo pwd cd ls cat cp write append mkdir rm rmdir mv chmod sync pid status fg bg run shutdown")
            send(client, process, serial, "pwd", b"\r\n/home/root\r\n")
            send(client, process, serial, "cd /", PROMPT_ROOT)
            send(client, process, serial, "pwd", b"\r\n/\r\n")
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
            send(client, process, serial, "status", b"\r\n42\r\n")
            send(client, process, serial, "missing-g258-command", b"run: not found")
            send(client, process, serial, "status", b"\r\n127\r\n")
            send(client, process, serial, "cd /missing-g258-directory", b"cd: not found")
            send(client, process, serial, "status", b"\r\n1\r\n")
            send(client, process, serial, "pwd", b"\r\n/\r\n")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "pwd&&echo G259_AND_RAN", b"G259_AND_RAN")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "missing-g259-and&&echo G259_AND_SHOULD_NOT_RUN", b"run: not found")
            send(client, process, serial, "status", b"\r\n127\r\n")
            send(client, process, serial, "pwd||echo G259_OR_SHOULD_NOT_RUN", b"\r\n/\r\n")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "missing-g259-or||echo G259_OR_RAN", b"G259_OR_RAN")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "missing-g259-mixed&&echo G259_MIXED_BAD||echo G259_MIXED_RECOVERED", b"G259_MIXED_RECOVERED")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "echo G259_TRAILING&&", b"syntax: invalid conditional list")
            send(client, process, serial, "status", b"\r\n2\r\n")
            send(client, process, serial, "echo G260_FIRST;echo G260_SECOND", b"G260_SECOND")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "missing-g260;echo G260_AFTER_FAILURE", b"G260_AFTER_FAILURE")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "missing-g260-status;status", b"\r\n127\r\n")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "missing-g260-and&&echo G260_COND_SKIP;echo G260_AFTER_COND", b"G260_AFTER_COND")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "echo G260_TRAILING_OK;", b"G260_TRAILING_OK")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "echo G260_PREFIX_SHOULD_NOT_RUN;;echo G260_SUFFIX_SHOULD_NOT_RUN", b"syntax: invalid conditional list")
            send(client, process, serial, "status", b"\r\n2\r\n")
            send(client, process, serial, "echo G260_OVER1;echo G260_OVER2;echo G260_OVER3;echo G260_OVER4;echo G260_OVER5", b"syntax: invalid conditional list")
            send(client, process, serial, "status", b"\r\n2\r\n")
            send(client, process, serial, "cp /bin/sdk.elf /persist/persist-sdk.elf", sdk_copy_marker.encode("ascii"), 40)
            send(client, process, serial, "sync", b"writable mounts synchronized", 40)
            send(client, process, serial, "persist-sdk alpha beta", b"process 4 exited 86", 40)
            send(client, process, serial, "fs init", b"process 5 exited 88", 60)
            send(client, process, serial, "fs verify-live", b"process 6 exited 89", 60)
            send(client, process, serial, "hello|hello", PROMPT_ROOT, 60)
            send(client, process, serial, "status", b"\r\n42\r\n")
            send(client, process, serial, "echo G261_BUILTIN_SHOULD_NOT_RUN|hello", b"pipeline: external stages only")
            send(client, process, serial, "status", b"\r\n2\r\n")
            send(client, process, serial, "hello|", b"syntax: invalid conditional list")
            send(client, process, serial, "status", b"\r\n2\r\n")
            send(client, process, serial, "pipe-writer.elf|pipe-reader.elf", PROMPT_ROOT, 60)
            send(client, process, serial, "status", b"\r\n0\r\n")

            foreground_start = len(serial)
            client.sendall(b"pipe-reader.elf|pipe-reader.elf\r")
            wait_for(client, process, serial, b"pipeline group 11 stages 2", foreground_start, 60)
            time.sleep(0.2)
            read_available(client, serial)
            if PROMPT_ROOT in serial[foreground_start:]:
                raise RuntimeError("G263 shell prompt returned before foreground pipeline received terminal input")
            client.sendall(b"TTYPIPE\r")
            wait_for(client, process, serial, PROMPT_ROOT, foreground_start, 60)
            send(client, process, serial, "status", b"\r\n0\r\n")

            background_start = len(serial)
            client.sendall(b"sleep &\r")
            wait_for(client, process, serial, PROMPT_ROOT, background_start, 20)
            time.sleep(0.05)
            read_available(client, serial)
            if b"[1] done 7" in serial[background_start:]:
                raise RuntimeError("G264 background job completed before the shell returned its prompt")
            wait_for(client, process, serial, b"[1] done 7", background_start, 20)
            wait_for(client, process, serial, PROMPT_ROOT, background_start, 20)
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "echo G264_BUILTIN_SHOULD_NOT_RUN &", b"syntax: invalid conditional list")
            send(client, process, serial, "status", b"\r\n2\r\n")

            fg_launch = len(serial)
            client.sendall(b"sleep &\r")
            wait_for(client, process, serial, PROMPT_ROOT, fg_launch, 20)
            read_available(client, serial)
            if b"[1] done 7" in serial[fg_launch:]:
                raise RuntimeError("G265 fg fixture completed before adoption")
            fg_wait = len(serial)
            client.sendall(b"fg 1\r")
            wait_for(client, process, serial, b"sleep: after", fg_wait, 20)
            after_index = bytes(serial).find(b"sleep: after", fg_wait)
            if after_index < 0 or PROMPT_ROOT in serial[fg_wait:after_index]:
                raise RuntimeError("G265 fg returned the shell prompt before the adopted job completed")
            wait_for(client, process, serial, PROMPT_ROOT, after_index, 20)
            send(client, process, serial, "status", b"\r\n7\r\n")

            bg_launch = len(serial)
            client.sendall(b"sleep &\r")
            wait_for(client, process, serial, PROMPT_ROOT, bg_launch, 20)
            bg_command = len(serial)
            client.sendall(b"bg 1\r")
            wait_for(client, process, serial, PROMPT_ROOT, bg_command, 20)
            time.sleep(0.02)
            read_available(client, serial)
            if b"[1] done 7" in serial[bg_command:]:
                raise RuntimeError("G265 bg job completed before detached prompt return")
            wait_for(client, process, serial, b"[1] done 7", bg_command, 20)
            wait_for(client, process, serial, PROMPT_ROOT, bg_command, 20)
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "fg 4", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n1\r\n")
            send(client, process, serial, "bg 0", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n2\r\n")

            send(client, process, serial, "PATH=/missing", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "/bin/sdk.elf alpha beta", b"zig-sdk: bad envp/auxv", 40)
            send(client, process, serial, "status", b"\r\n233\r\n")
            send(client, process, serial, "hello", b"run: not found")
            send(client, process, serial, "status", b"\r\n127\r\n")
            send(client, process, serial, "PATH=/bin:/persist", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "G267_A=one", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "G267_A=two", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "G267_B=two", PROMPT_ROOT)
            send(client, process, serial, "G267_C=three", PROMPT_ROOT)
            send(client, process, serial, "G267_D=four", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n1\r\n")
            send(client, process, serial, "PATH=/blocked &", b"syntax: invalid conditional list")
            send(client, process, serial, "status", b"\r\n2\r\n")
            send(client, process, serial, "hello", b"hello from VFS-loaded CPL3 ELF64", 40)
            send(client, process, serial, "status", b"\r\n42\r\n")

            send(client, process, serial, "write /tmp/g268.txt $(pipe-writer.elf)", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "cat /tmp/g268.txt", b"PIPE-CPL")
            send(client, process, serial, "rm /tmp/g268.txt", PROMPT_ROOT)
            overflow_start = len(serial)
            send(client, process, serial, "echo $(hello)", PROMPT_ROOT)
            if b"hello from VFS-loaded CPL3 ELF64" in serial[overflow_start:]:
                raise RuntimeError("G268 overflow capture leaked child stdout to the terminal")
            send(client, process, serial, "status", b"\r\n1\r\n")
            background_substitution = len(serial)
            send(client, process, serial, "hello $(pipe-writer.elf) &", b"syntax: invalid conditional list")
            if b"hello from VFS-loaded CPL3 ELF64" in serial[background_substitution:] or b"PIPE-CPL" in serial[background_substitution:]:
                raise RuntimeError("G268 background substitution executed before rejection")
            send(client, process, serial, "status", b"\r\n2\r\n")
            pipeline_substitution = len(serial)
            send(client, process, serial, "hello $(pipe-writer.elf)|hello", b"pipeline: external stages only")
            if b"hello from VFS-loaded CPL3 ELF64" in serial[pipeline_substitution:] or b"PIPE-CPL" in serial[pipeline_substitution:]:
                raise RuntimeError("G268 pipeline substitution executed before rejection")
            send(client, process, serial, "status", b"\r\n2\r\n")
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
                "hello from VFS-loaded CPL3 ELF64",
                "process 3 exited 42",
                "help echo pwd cd ls cat cp write append mkdir rm rmdir mv chmod sync pid status fg bg run shutdown",
                "run: not found",
                "cd: not found",
                "G259_AND_RAN",
                "G259_OR_RAN",
                "G259_MIXED_RECOVERED",
                "syntax: invalid conditional list",
                "G260_FIRST",
                "G260_SECOND",
                "G260_AFTER_FAILURE",
                "G260_AFTER_COND",
                "G260_TRAILING_OK",
                sdk_copy_marker,
                "writable mounts synchronized",
                "zig-sdk: envp/auxv passed",
                "zig-sdk: tmpfs mount/umount isolation, statfs and busy policy passed",
                "zig-sdk: timestamp precision/data/namespace/access ordering passed",
                "zig-sdk: uid/gid creation and hard-link ownership passed",
                "zig-sdk: process umask file/directory creation passed",
                "zig-sdk: setuid/setgid metadata inert-exec policy passed",
                "zig-sdk: advisory whole-file flock passed",
                "zig-sdk: advisory byte-range lock passed",
                "zig-sdk: directory watch notifications passed",
                "zig-sdk: startup/argv/abi/files/vm/file-mmap/errno/fsync/fdatasync/readv/writev/mount/umount/tmpfs/statfs/stattimes/statowner/umask/setid-metadata/flock/lockrange/watchdir passed",
                "process 4 exited 86",
                "fs-api: init/mkdir/write/seek/replace-rename/chmod/link/nlink/symlink/readlink/fallocate/sparse/open-unlink/rmdir/sync passed",
                "process 5 exited 88",
                "fs-api: baseline/mode/seek/hard-link/symlink/fallocate/sparse/cleanup passed",
                "process 6 exited 89",
                "pipeline group 7 stages 2",
                "pipeline: external stages only",
                "pipeline group 9 stages 2",
                "PIPE-CPL",
                "pipeline group 11 stages 2",
                "TTYPIPE",
                "[1] done 7",
                "zig-sdk: bad envp/auxv",
                "userspace shell requested shutdown",
                "userspace init reaped shell PID 2 status 0",
                "ZigOs normal userspace shutdown: init PID 1 status 0 shell PID 2 reaped yes",
                "ZigOs boot FAT: block-backed yes files/directories 3/2 bytes ",
                " metadata/file/block reads 111/0/111 failures 0 clusters claimed/free/loop/cross/range 10939/5172/0/0/0 lock tickets/outstanding 1/0 quarantine state/reason/events no/none/0 clean yes",
                "ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes",
                "ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 380/380 cache-released 15 storage persistent clean yes",
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
                "\r\nG259_AND_SHOULD_NOT_RUN\r\n",
                "\r\nG259_OR_SHOULD_NOT_RUN\r\n",
                "\r\nG259_MIXED_BAD\r\n",
                "\r\nG264_BUILTIN_SHOULD_NOT_RUN\r\n",
                "\r\nG259_TRAILING\r\n",
                "\r\nG260_COND_SKIP\r\n",
                "\r\nG260_PREFIX_SHOULD_NOT_RUN\r\n",
                "\r\nG260_SUFFIX_SHOULD_NOT_RUN\r\n",
                "\r\nG260_OVER1\r\n",
                "\r\nG260_OVER2\r\n",
                "\r\nG260_OVER3\r\n",
                "\r\nG260_OVER4\r\n",
                "\r\nG260_OVER5\r\n",
                "\r\nG261_BUILTIN_SHOULD_NOT_RUN\r\n",
            )
            for marker in required:
                if marker not in text:
                    raise RuntimeError(f"normal boot missing marker: {marker}")
            for marker in forbidden:
                if marker in text:
                    raise RuntimeError(f"normal boot unexpectedly ran diagnostic marker: {marker}")
            if text.count("hello from VFS-loaded CPL3 ELF64") < 2:
                raise RuntimeError("G261 grouped pipeline did not retain visible final-stage execution")
            if "ZigOs normal userspace resources:" not in text or "clean yes" not in text:
                raise RuntimeError("normal boot did not report clean resource reclamation")
        finally:
            if client is not None:
                client.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)

    print("Normal x86-64 userspace-shell boot passed.")
    print(f"  serial log: {serial_log}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
