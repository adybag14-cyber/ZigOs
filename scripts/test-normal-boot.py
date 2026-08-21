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
            send(client, process, serial, "cp /bin/sdk.elf /persist/persist-sdk.elf", PROMPT_ROOT, 40)
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
            wait_for(client, process, serial, b"pipeline\r\n", foreground_start, 60)
            time.sleep(0.2)
            read_available(client, serial)
            if PROMPT_ROOT in serial[foreground_start:]:
                raise RuntimeError("G263 shell prompt returned before foreground pipeline received terminal input")
            client.sendall(b"TTYPIPE\r")
            wait_for(client, process, serial, PROMPT_ROOT, foreground_start, 60)
            send(client, process, serial, "status", b"\r\n0\r\n")

            rollback_start = len(serial)
            send(client, process, serial, "pipe-reader.elf|missing-g263-rollback", PROMPT_ROOT, 60)
            if PROMPT_ROOT not in serial[rollback_start:]:
                raise RuntimeError("G263 partial foreground pipeline did not restore the shell prompt")
            send(client, process, serial, "status", b"\r\n127\r\n")

            background_start = len(serial)
            client.sendall(b"runtime-sleep.elf &\r")
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
            client.sendall(b"runtime-sleep.elf &\r")
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
            client.sendall(b"runtime-sleep.elf &\r")
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

            send(client, process, serial, "write /tmp/g269-a.txt alpha", PROMPT_ROOT)
            send(client, process, serial, "write /tmp/g269-b.txt beta", PROMPT_ROOT)
            send(client, process, serial, "write /tmp/g269-list.txt /tmp/g269-*.txt", PROMPT_ROOT)
            send(client, process, serial, "status", b"\r\n0\r\n")
            glob_list_start = len(serial)
            send(client, process, serial, "cat /tmp/g269-list.txt", PROMPT_ROOT)
            glob_list = serial[glob_list_start:]
            if b"/tmp/g269-a.txt" not in glob_list or b"/tmp/g269-b.txt" not in glob_list:
                raise RuntimeError("G269 wildcard expansion did not produce both directory matches")
            no_match_start = len(serial)
            send(client, process, serial, "echo /tmp/g269-none-*.txt", PROMPT_ROOT)
            if serial[no_match_start:].count(b"/tmp/g269-none-*.txt") != 1:
                raise RuntimeError("G269 unmatched wildcard appeared beyond the terminal command echo")
            send(client, process, serial, "status", b"\r\n1\r\n")
            double_star_start = len(serial)
            send(client, process, serial, "echo /tmp/g269-**.txt", PROMPT_ROOT)
            if serial[double_star_start:].count(b"/tmp/g269-**.txt") != 1:
                raise RuntimeError("G269 second wildcard escaped failure-closed validation")
            send(client, process, serial, "status", b"\r\n1\r\n")
            prefix_star_start = len(serial)
            send(client, process, serial, "echo /tmp/*/g269-a.txt", PROMPT_ROOT)
            if serial[prefix_star_start:].count(b"/tmp/*/g269-a.txt") != 1:
                raise RuntimeError("G269 directory-prefix wildcard escaped failure-closed validation")
            send(client, process, serial, "status", b"\r\n1\r\n")
            command_glob_start = len(serial)
            send(client, process, serial, "g269-*", PROMPT_ROOT)
            if serial[command_glob_start:].count(b"g269-*") != 1:
                raise RuntimeError("G269 command-name wildcard executed or leaked as an outer argument")
            send(client, process, serial, "status", b"\r\n1\r\n")
            background_glob = len(serial)
            send(client, process, serial, "hello /tmp/g269-*.txt &", b"syntax: invalid conditional list")
            if b"hello from VFS-loaded CPL3 ELF64" in serial[background_glob:]:
                raise RuntimeError("G269 background wildcard executed before rejection")
            send(client, process, serial, "status", b"\r\n2\r\n")
            pipeline_glob = len(serial)
            send(client, process, serial, "hello /tmp/g269-*.txt|hello", b"pipeline: external stages only")
            if b"hello from VFS-loaded CPL3 ELF64" in serial[pipeline_glob:]:
                raise RuntimeError("G269 pipeline wildcard executed before rejection")
            send(client, process, serial, "status", b"\r\n2\r\n")
            send(client, process, serial, "rm /tmp/g269-list.txt", PROMPT_ROOT)
            send(client, process, serial, "rm /tmp/g269-a.txt", PROMPT_ROOT)
            send(client, process, serial, "rm /tmp/g269-b.txt", PROMPT_ROOT)

            send(client, process, serial, "cd ~", PROMPT_HOME)
            send(client, process, serial, "pwd", b"\r\n/home/root\r\n")
            send(client, process, serial, "cd /", PROMPT_ROOT)
            send(client, process, serial, "cd ~/..", b"root@zigos:/home$ ")
            send(client, process, serial, "pwd", b"\r\n/home\r\n")
            send(client, process, serial, "cd /", PROMPT_ROOT)
            named_tilde_start = len(serial)
            send(client, process, serial, "echo ~nobody", PROMPT_ROOT)
            if serial[named_tilde_start:].count(b"~nobody") != 1:
                raise RuntimeError("G270 named-user tilde escaped failure-closed validation")
            send(client, process, serial, "status", b"\r\n1\r\n")
            long_tilde = "~/123456789012345678901"
            tilde_overflow_start = len(serial)
            send(client, process, serial, f"echo {long_tilde}", PROMPT_ROOT)
            if serial[tilde_overflow_start:].count(long_tilde.encode("ascii")) != 1:
                raise RuntimeError("G270 overlong tilde expansion escaped the 31-byte argument bound")
            send(client, process, serial, "status", b"\r\n1\r\n")
            background_tilde = len(serial)
            send(client, process, serial, "hello ~ &", b"syntax: invalid conditional list")
            if b"hello from VFS-loaded CPL3 ELF64" in serial[background_tilde:]:
                raise RuntimeError("G270 background tilde expansion executed before rejection")
            send(client, process, serial, "status", b"\r\n2\r\n")
            pipeline_tilde = len(serial)
            send(client, process, serial, "hello ~|hello", b"pipeline: external stages only")
            if b"hello from VFS-loaded CPL3 ELF64" in serial[pipeline_tilde:]:
                raise RuntimeError("G270 pipeline tilde expansion executed before rejection")
            send(client, process, serial, "status", b"\r\n2\r\n")

            history_start = len(serial)
            send(client, process, serial, "cat /persist/.sh_history", PROMPT_ROOT)
            if b"cd ~" not in serial[history_start:]:
                raise RuntimeError("G272 persistent history did not contain an earlier interactive command")

            ls_start = len(serial)
            client.sendall(b"/bin/ls.elf /home/root\r")
            wait_for(client, process, serial, b"\r\nreadme.txt\r\n", ls_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, ls_start, 40)
            if b"ls: " in serial[ls_start:]:
                raise RuntimeError("G273 standalone ls reported an unexpected filesystem error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            cat_start = len(serial)
            client.sendall(b"/bin/cat.elf /home/root/readme.txt\r")
            wait_for(client, process, serial, b"This filesystem remains available after boot validation.", cat_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, cat_start, 40)
            if b"cat: " in serial[cat_start:]:
                raise RuntimeError("G274 standalone cat reported an unexpected filesystem error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            echo_start = len(serial)
            client.sendall(b"/bin/echo.elf G275_ALPHA G275_BETA\r")
            wait_for(client, process, serial, b"\r\nG275_ALPHA G275_BETA\r\n", echo_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, echo_start, 40)
            send(client, process, serial, "status", b"\r\n0\r\n")

            pwd_start = len(serial)
            client.sendall(b"/bin/pwd.elf\r")
            wait_for(client, process, serial, b"\r\n/\r\n", pwd_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, pwd_start, 40)
            send(client, process, serial, "status", b"\r\n0\r\n")

            mkdir_start = len(serial)
            client.sendall(b"/bin/mkdir.elf /tmp/g277-dir\r")
            wait_for(client, process, serial, PROMPT_ROOT, mkdir_start, 40)
            if b"mkdir: " in serial[mkdir_start:]:
                raise RuntimeError("G277 standalone mkdir reported an unexpected filesystem error")
            send(client, process, serial, "status", b"\r\n0\r\n")
            mkdir_check = len(serial)
            send(client, process, serial, "ls /tmp", PROMPT_ROOT)
            if b"g277-dir/" not in serial[mkdir_check:]:
                raise RuntimeError("G277 standalone mkdir did not publish the created directory")
            send(client, process, serial, "rmdir /tmp/g277-dir", PROMPT_ROOT)

            send(client, process, serial, "write /tmp/g278-file G278_PAYLOAD", PROMPT_ROOT)
            send(client, process, serial, "mkdir /tmp/g278-dir", PROMPT_ROOT)
            rm_start = len(serial)
            client.sendall(b"/bin/rm.elf /tmp/g278-file\r")
            wait_for(client, process, serial, PROMPT_ROOT, rm_start, 40)
            if b"rm: " in serial[rm_start:]:
                raise RuntimeError("G278 standalone rm reported an unexpected filesystem error")
            send(client, process, serial, "status", b"\r\n0\r\n")
            rmdir_start = len(serial)
            client.sendall(b"/bin/rmdir.elf /tmp/g278-dir\r")
            wait_for(client, process, serial, PROMPT_ROOT, rmdir_start, 40)
            if b"rmdir: " in serial[rmdir_start:]:
                raise RuntimeError("G278 standalone rmdir reported an unexpected filesystem error")
            send(client, process, serial, "status", b"\r\n0\r\n")
            remove_check = len(serial)
            send(client, process, serial, "ls /tmp", PROMPT_ROOT)
            removed_listing = serial[remove_check:]
            if b"g278-file" in removed_listing or b"g278-dir" in removed_listing:
                raise RuntimeError("G278 standalone removal left a proof path visible")

            send(client, process, serial, "write /tmp/g279-source G279_PAYLOAD", PROMPT_ROOT)
            same_cp_start = len(serial)
            client.sendall(b"/bin/cp.elf /tmp/g279-source /tmp/g279-source\r")
            wait_for(client, process, serial, b"cp: same file\r\n", same_cp_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, same_cp_start, 40)
            send(client, process, serial, "status", b"\r\n1\r\n")
            same_cp_check = len(serial)
            send(client, process, serial, "cat /tmp/g279-source", PROMPT_ROOT)
            if b"G279_PAYLOAD" not in serial[same_cp_check:]:
                raise RuntimeError("G279 standalone cp self-copy guard damaged the source")
            cp_start = len(serial)
            client.sendall(b"/bin/cp.elf /tmp/g279-source /tmp/g279-copy\r")
            wait_for(client, process, serial, PROMPT_ROOT, cp_start, 40)
            if b"cp: " in serial[cp_start:]:
                raise RuntimeError("G279 standalone cp reported an unexpected filesystem error")
            send(client, process, serial, "status", b"\r\n0\r\n")
            cp_check = len(serial)
            send(client, process, serial, "cat /tmp/g279-copy", PROMPT_ROOT)
            if b"G279_PAYLOAD" not in serial[cp_check:]:
                raise RuntimeError("G279 standalone cp did not preserve source bytes")
            mv_start = len(serial)
            client.sendall(b"/bin/mv.elf /tmp/g279-copy /tmp/g279-moved\r")
            wait_for(client, process, serial, PROMPT_ROOT, mv_start, 40)
            if b"mv: " in serial[mv_start:]:
                raise RuntimeError("G279 standalone mv reported an unexpected filesystem error")
            send(client, process, serial, "status", b"\r\n0\r\n")
            mv_check = len(serial)
            send(client, process, serial, "ls /tmp", PROMPT_ROOT)
            moved_listing = serial[mv_check:]
            if b"g279-copy" in moved_listing or b"g279-moved" not in moved_listing:
                raise RuntimeError("G279 standalone mv did not move the copied namespace entry")
            moved_check = len(serial)
            send(client, process, serial, "cat /tmp/g279-moved", PROMPT_ROOT)
            if b"G279_PAYLOAD" not in serial[moved_check:]:
                raise RuntimeError("G279 standalone mv did not preserve copied file bytes")
            send(client, process, serial, "rm /tmp/g279-source", PROMPT_ROOT)
            send(client, process, serial, "rm /tmp/g279-moved", PROMPT_ROOT)

            stat_start = len(serial)
            client.sendall(b"/bin/stat.elf /home/root/readme.txt\r")
            wait_for(client, process, serial, b"type file\r\n", stat_start, 40)
            wait_for(client, process, serial, b"mode 0644\r\n", stat_start, 40)
            wait_for(client, process, serial, b"size 57\r\n", stat_start, 40)
            wait_for(client, process, serial, b"links 1\r\n", stat_start, 40)
            wait_for(client, process, serial, b"owner 0:0\r\n", stat_start, 40)
            wait_for(client, process, serial, b"readonly no\r\n", stat_start, 40)
            wait_for(client, process, serial, b"times ", stat_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, stat_start, 40)
            if b"stat: " in serial[stat_start:]:
                raise RuntimeError("G280 standalone stat reported an unexpected metadata error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            send(client, process, serial, "write /tmp/g281-text G281_L01", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L02", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_MATCH_A", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L04", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L05", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L06", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L07", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L08", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_MATCH_B", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L10", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L11", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g281-text G281_L12", PROMPT_ROOT)

            head_start = len(serial)
            client.sendall(b"/bin/head.elf /tmp/g281-text\r")
            wait_for(client, process, serial, b"G281_L01", head_start, 40)
            wait_for(client, process, serial, b"G281_L10", head_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, head_start, 40)
            head_output = serial[head_start:]
            if b"G281_L11" in head_output or b"head: " in head_output:
                raise RuntimeError("G281 standalone head did not stop after ten lines")
            send(client, process, serial, "status", b"\r\n0\r\n")

            tail_start = len(serial)
            client.sendall(b"/bin/tail.elf /tmp/g281-text\r")
            wait_for(client, process, serial, b"G281_MATCH_A", tail_start, 40)
            wait_for(client, process, serial, b"G281_L12", tail_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, tail_start, 40)
            tail_output = serial[tail_start:]
            if b"G281_L02" in tail_output or b"tail: " in tail_output:
                raise RuntimeError("G281 standalone tail did not emit the final ten lines")
            send(client, process, serial, "status", b"\r\n0\r\n")

            wc_start = len(serial)
            client.sendall(b"/bin/wc.elf /tmp/g281-text\r")
            wait_for(client, process, serial, b"12 12 116\r\n", wc_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, wc_start, 40)
            if b"wc: " in serial[wc_start:]:
                raise RuntimeError("G281 standalone wc reported an unexpected read error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            grep_start = len(serial)
            client.sendall(b"/bin/grep.elf MATCH /tmp/g281-text\r")
            wait_for(client, process, serial, b"G281_MATCH_A", grep_start, 40)
            wait_for(client, process, serial, b"G281_MATCH_B", grep_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, grep_start, 40)
            grep_output = serial[grep_start:]
            if b"G281_L04" in grep_output or b"grep: " in grep_output:
                raise RuntimeError("G281 standalone grep emitted a nonmatching line")
            send(client, process, serial, "status", b"\r\n0\r\n")

            grep_none_start = len(serial)
            client.sendall(b"/bin/grep.elf ABSENT /tmp/g281-text\r")
            wait_for(client, process, serial, PROMPT_ROOT, grep_none_start, 40)
            if b"grep: " in serial[grep_none_start:]:
                raise RuntimeError("G281 standalone grep no-match path reported an error")
            send(client, process, serial, "status", b"\r\n1\r\n")
            send(client, process, serial, "rm /tmp/g281-text", PROMPT_ROOT)

            send(client, process, serial, "write /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)
            send(client, process, serial, "append /tmp/g282-hex ABCDEFGHIJKLMNOP", PROMPT_ROOT)

            hexdump_start = len(serial)
            client.sendall(b"/bin/hexdump.elf /tmp/g282-hex\r")
            wait_for(client, process, serial, b"0000  41 42 43 44 45 46 47 48", hexdump_start, 40)
            wait_for(client, process, serial, b"49 4A 4B 4C 4D 4E 4F 50", hexdump_start, 40)
            wait_for(client, process, serial, b"ABCDEFGHIJKLMNOP\r\n", hexdump_start, 40)
            wait_for(client, process, serial, b"00F0  ", hexdump_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, hexdump_start, 40)
            hexdump_output = serial[hexdump_start:]
            if b"0100  " in hexdump_output or b"hexdump: " in hexdump_output:
                raise RuntimeError("G282 standalone hexdump exceeded its 256-byte ceiling or reported an error")
            send(client, process, serial, "status", b"\r\n0\r\n")
            send(client, process, serial, "rm /tmp/g282-hex", PROMPT_ROOT)

            ps_start = len(serial)
            client.sendall(b"/bin/ps.elf\r")
            wait_for(client, process, serial, b"PID PPID STATE      TICKS FDS SOCK NAME\r\n", ps_start, 40)
            wait_for(client, process, serial, b"1 0 blocked", ps_start, 40)
            wait_for(client, process, serial, b"2 1 blocked", ps_start, 40)
            wait_for(client, process, serial, b" 2 running   ", ps_start, 40)
            wait_for(client, process, serial, b" 4 0 ps.elf\r\n", ps_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, ps_start, 40)
            if b"ps: " in serial[ps_start:]:
                raise RuntimeError("G283 standalone ps reported an unexpected procfs error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            sleep_start = len(serial)
            client.sendall(b"/bin/sleep.elf 2\r")
            wait_for(client, process, serial, PROMPT_ROOT, sleep_start, 40)
            if b"sleep: " in serial[sleep_start:]:
                raise RuntimeError("G284 standalone sleep reported an unexpected syscall error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            background_start = len(serial)
            client.sendall(b"/bin/sleep.elf 1000 &\r")
            wait_for(client, process, serial, PROMPT_ROOT, background_start, 40)
            ps_kill_start = len(serial)
            client.sendall(b"/bin/ps.elf\r")
            wait_for(client, process, serial, b" sleep.elf\r\n", ps_kill_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, ps_kill_start, 40)
            sleep_pid = None
            for row in bytes(serial[ps_kill_start:]).splitlines():
                fields = row.strip().split()
                if len(fields) >= 7 and fields[1] == b"2" and fields[-1] == b"sleep.elf":
                    sleep_pid = int(fields[0])
                    break
            if sleep_pid is None or sleep_pid <= 2:
                raise RuntimeError("G284 could not discover the live standalone sleep PID through procfs")
            kill_start = len(serial)
            client.sendall(f"/bin/kill.elf {sleep_pid}\r".encode("ascii"))
            wait_for(client, process, serial, b"] done 137\r\n", kill_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, kill_start, 40)
            if b"kill: " in serial[kill_start:]:
                raise RuntimeError("G284 standalone kill reported an unexpected signal error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            mount_start = len(serial)
            client.sendall(b"/bin/mount.elf\r")
            wait_for(client, process, serial, b"ramfs on / type ramfs (rw)\r\n", mount_start, 40)
            wait_for(client, process, serial, b"process-table on /proc type procfs (ro)\r\n", mount_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, mount_start, 40)
            if b"mount: " in serial[mount_start:]:
                raise RuntimeError("G285 standalone mount reported an unexpected procfs error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            df_start = len(serial)
            client.sendall(b"/bin/df.elf /\r")
            wait_for(client, process, serial, b"type ramfs\r\n", df_start, 40)
            wait_for(client, process, serial, b"block-size 4096\r\n", df_start, 40)
            wait_for(client, process, serial, b"blocks 256\r\n", df_start, 40)
            wait_for(client, process, serial, b"nodes 128\r\n", df_start, 40)
            wait_for(client, process, serial, b"mount 1\r\n", df_start, 40)
            wait_for(client, process, serial, b"flags rw shared-blocks shared-nodes\r\n", df_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, df_start, 40)
            df_output = bytes(serial[df_start:]).splitlines()
            df_values = {}
            for row in df_output:
                fields = row.strip().split()
                if len(fields) == 2 and fields[0] in (b"free", b"available", b"free-nodes"):
                    df_values[fields[0]] = int(fields[1])
            if df_values.get(b"free") is None or df_values.get(b"available") != df_values[b"free"] or df_values[b"free"] > 256:
                raise RuntimeError("G286 standalone df reported invalid shared block availability")
            if df_values.get(b"free-nodes") is None or df_values[b"free-nodes"] > 96:
                raise RuntimeError("G286 standalone df reported invalid node availability")
            if b"df: " in serial[df_start:]:
                raise RuntimeError("G286 standalone df reported an unexpected statfs error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            fsck_start = len(serial)
            client.sendall(b"/bin/fsck.elf\r")
            wait_for(client, process, serial, b"fsck: clean\r\n", fsck_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, fsck_start, 40)
            if b"fsck: corrupt" in serial[fsck_start:] or b"fsck: unavailable" in serial[fsck_start:] or b"fsck: input/output error" in serial[fsck_start:] or b"fsck: error" in serial[fsck_start:]:
                raise RuntimeError("G287 standalone fsck reported a filesystem consistency failure")
            send(client, process, serial, "status", b"\r\n0\r\n")

            uname_start = len(serial)
            client.sendall(b"/bin/uname.elf\r")
            wait_for(client, process, serial, b"ZigOs 19.0.0 x86_64 persistent runtime\r\n", uname_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, uname_start, 40)
            if b"uname: " in serial[uname_start:]:
                raise RuntimeError("G288 standalone uname reported an unexpected procfs error")
            send(client, process, serial, "status", b"\r\n0\r\n")

            env_start = len(serial)
            client.sendall(b"/bin/env.elf\r")
            for marker in (
                b"PATH=/bin:/persist\r\n",
                b"HOME=/home/root\r\n",
                b"TERM=zigos\r\n",
                b"SHELL=/bin/sh.elf\r\n",
                b"G267_A=two\r\n",
                b"G267_B=two\r\n",
                b"G267_C=three\r\n",
            ):
                wait_for(client, process, serial, marker, env_start, 40)
            wait_for(client, process, serial, PROMPT_ROOT, env_start, 40)
            env_output = serial[env_start:]
            if b"G267_D=four" in env_output or b"env: " in env_output:
                raise RuntimeError("G289 standalone env exposed rejected or malformed environment state")
            send(client, process, serial, "status", b"\r\n0\r\n")

            send(client, process, serial, "write /tmp/g290-edit BASE", PROMPT_ROOT)
            edit_start = len(serial)
            client.sendall(b"/bin/edit.elf /tmp/g290-edit\r")
            wait_for(client, process, serial, b"edit: 5 bytes\r\n", edit_start, 40)
            wait_for(client, process, serial, b"edit> ", edit_start, 40)
            edit_print = len(serial)
            client.sendall(b"p\r")
            wait_for(client, process, serial, b"BASE\n", edit_print, 40)
            wait_for(client, process, serial, b"edit> ", edit_print, 40)
            # Queue several canonical lines at once, including an exact 256-byte command.
            # G290 must frame commands by newline rather than assuming one read() == one line.
            edit_burst = len(serial)
            maximum_append = b"a " + (b"X" * 254) + b"\r"
            client.sendall(maximum_append + b"d\ra REMOVE\rd\ra FINAL\rwq\r")
            wait_for(client, process, serial, b"edit: wrote 11 bytes\r\n", edit_burst, 40)
            wait_for(client, process, serial, PROMPT_ROOT, edit_burst, 40)
            edit_output = serial[edit_start:]
            for forbidden_edit in (
                b"edit: error",
                b"edit: input/output error",
                b"edit: command too long",
                b"edit: command must be",
            ):
                if forbidden_edit in edit_output:
                    raise RuntimeError("G290 standalone editor failed bounded command framing")
            send(client, process, serial, "status", b"\r\n0\r\n")
            edit_cat = len(serial)
            client.sendall(b"cat /tmp/g290-edit\r")
            wait_for(client, process, serial, b"BASE\nFINAL\n", edit_cat, 40)
            wait_for(client, process, serial, PROMPT_ROOT, edit_cat, 40)
            if b"REMOVE" in serial[edit_cat:]:
                raise RuntimeError("G290 standalone editor failed to delete the discarded line")
            send(client, process, serial, "rm /tmp/g290-edit", PROMPT_ROOT)

            send(client, process, serial, "write /etc/shrc write /tmp/g271-order SYSTEM", PROMPT_ROOT)
            send(client, process, serial, "write /home/root/.shrc append /tmp/g271-order USER", PROMPT_ROOT)
            send(client, process, serial, "append /home/root/.shrc echo G271US", PROMPT_ROOT)
            startup = len(serial)
            client.sendall(b"sh|pipe-reader.elf\r")
            wait_for(client, process, serial, b"pipeline\r\n", startup, 20)
            wait_for(client, process, serial, b"G271US\r\n", startup, 20)
            client.sendall(b"\x03")
            wait_for(client, process, serial, PROMPT_ROOT, startup, 20)
            send(client, process, serial, "status", b"\r\n0\r\n")
            order_start = len(serial)
            send(client, process, serial, "cat /tmp/g271-order", PROMPT_ROOT)
            order_output = serial[order_start:]
            system_index = order_output.find(b"SYSTEM")
            user_index = order_output.find(b"USER")
            if system_index < 0 or user_index < 0 or system_index >= user_index:
                raise RuntimeError("G271 startup files did not execute system-before-user side effects")
            send(client, process, serial, "rm /etc/shrc", PROMPT_ROOT)
            send(client, process, serial, "rm /home/root/.shrc", PROMPT_ROOT)
            send(client, process, serial, "rm /tmp/g271-order", PROMPT_ROOT)

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
                "zig-sdk: startup/argv/abi/files/vm/file-mmap/errno/fsync/fdatasync/readv/writev/mount/umount/tmpfs/statfs/stattimes/statowner/umask/setid-metadata/flock/lockrange/watchdir/kill passed",
                "process 4 exited 86",
                "fs-api: init/mkdir/write/seek/replace-rename/chmod/link/nlink/symlink/readlink/fallocate/sparse/open-unlink/rmdir/sync passed",
                "process 5 exited 88",
                "fs-api: baseline/mode/seek/hard-link/symlink/fallocate/sparse/cleanup passed",
                "process 6 exited 89",
                "pipeline",
                "pipeline: external stages only",
                "pipeline",
                "PIPE-CPL",
                "pipeline",
                "TTYPIPE",
                "[1] done 7",
                "zig-sdk: bad envp/auxv",
                "G271US",
                "userspace init reaped shell PID 2 status 0",
                "ZigOs normal userspace shutdown: init PID 1 status 0 shell PID 2 reaped yes",
                "ZigOs boot FAT: block-backed yes files/directories 3/2 bytes ",
                " metadata/file/block reads 113/0/113 failures 0 clusters claimed/free/loop/cross/range 11345/4766/0/0/0 lock tickets/outstanding 1/0 quarantine state/reason/events no/none/0 clean yes",
                "ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes",
                "ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 929/929 cache-released 13 storage persistent clean yes",
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

    # G272: reboot the exact same persistent NVMe image and prove that a command
    # from the first PID-2 shell session was durably recovered. Use a fresh OVMF
    # variable store so firmware state cannot masquerade as filesystem persistence.
    history_vars_image = work / "history-vars.fd"
    shutil.copyfile(vars_source, history_vars_image)
    history_port = free_tcp_port()
    history_debug_log = work / "history-debug.log"
    history_serial_log = work / "history-serial.log"
    history_stdout_log = work / "history-qemu-stdout.log"
    history_stderr_log = work / "history-qemu-stderr.log"
    history_command = [
        str(qemu),
        "-machine", "q35,i8042=off,hpet=off",
        "-m", "256M",
        "-cpu", "max",
        "-smp", "1",
        "-device", "qemu-xhci,id=xhci",
        "-drive", f"file={image.as_posix()},if=none,id=nvme0,format=raw,cache=unsafe",
        "-device", "nvme,drive=nvme0,serial=ZIGOSNVME,logical_block_size=512,physical_block_size=512",
        "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code_image.as_posix()}",
        "-drive", f"if=pflash,format=raw,unit=1,file={history_vars_image.as_posix()}",
        "-debugcon", f"file:{history_debug_log.as_posix()}",
        "-global", "isa-debugcon.iobase=0xe9",
        "-display", "none",
        "-vga", "none",
        "-serial", f"tcp:127.0.0.1:{history_port},server=on,wait=off",
        "-monitor", "none",
        "-no-reboot",
        "-net", "none",
    ]
    history_serial = bytearray()
    history_client: socket.socket | None = None
    with history_stdout_log.open("wb") as stdout_stream, history_stderr_log.open("wb") as stderr_stream:
        history_process = subprocess.Popen(history_command, stdout=stdout_stream, stderr=stderr_stream)
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                try:
                    history_client = socket.create_connection(("127.0.0.1", history_port), timeout=0.5)
                    history_client.settimeout(0.15)
                    break
                except OSError:
                    time.sleep(0.1)
            if history_client is None:
                raise RuntimeError("G272 history-recovery serial connection failed")
            wait_for(history_client, history_process, history_serial, b"ZigOs userspace init PID 1", 0, args.boot_timeout)
            wait_for(history_client, history_process, history_serial, PROMPT_HOME, 0, 20)
            history_start = len(history_serial)
            send(history_client, history_process, history_serial, "cat /persist/.sh_history", b"cd ~", 40)
            recovered = bytes(history_serial[history_start:])
            if b"cd ~" not in recovered:
                raise RuntimeError("G272 reboot did not recover first-session shell history")
            send(history_client, history_process, history_serial, "sync", b"writable mounts synchronized", 40)
            send(history_client, history_process, history_serial, "hello", b"process 3 exited 42", 40)
            send(history_client, history_process, history_serial, "shutdown", b"ZigOs normal boot verified:", 40)
            read_available(history_client, history_serial)
            history_text = bytes(history_serial).decode("ascii", errors="replace")
            if "storage persistent cleanup yes" not in history_text or "clean yes" not in history_text:
                raise RuntimeError("G272 recovery boot did not finish with clean persistent shutdown")
            history_serial_log.write_bytes(history_serial)
        finally:
            if history_client is not None:
                history_client.close()
            if history_process.poll() is None:
                history_process.kill()
                history_process.wait(timeout=10)

    print("Normal x86-64 userspace-shell boot passed.")
    print(f"  serial log: {serial_log}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
