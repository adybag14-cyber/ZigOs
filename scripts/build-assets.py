#!/usr/bin/env python3
"""Generate every non-Zig input required by the x86-64 UEFI build.

This script is intentionally host-neutral. It requires Python 3 and NASM, and
uses the repository's existing deterministic ELF generators/verifiers.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path


def run(command: list[str], cwd: Path) -> None:
    printable = " ".join(command)
    print(f"+ {printable}")
    subprocess.run(command, cwd=cwd, check=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_tool(name: str) -> str:
    resolved = shutil.which(name)
    if resolved is None:
        raise SystemExit(f"required build tool not found in PATH: {name}")
    return resolved



def runtime_wait_data() -> bytes:
    data = bytearray(280)
    fields = {
        0: b"wait-api: start\r\n",
        32: b"wait-api: concurrent wait-any ordering passed\r\n",
        128: b"/bin/runtime-sleep.elf",
        160: b"/bin/wait-short.elf",
    }
    for offset, value in fields.items():
        data[offset : offset + len(value)] = value
    return bytes(data)



def runtime_tty_data() -> bytes:
    data = bytearray(512)
    fields = {
        0: b"tty-api: start\r\n",
        64: b"tty-api: blocking read/poll/line discipline passed\r\n",
    }
    for offset, value in fields.items():
        data[offset : offset + len(value)] = value
    return bytes(data)


def runtime_socket_data() -> bytes:
    data = bytearray(4096)
    fields = {
        0: b"socket-api: start\r\n",
        64: b"socket-api: UDP partial-send + TCP connect/listen/accept/shutdown + sockopt + txwake passed\r\n",
        160: b"UDP-CPL3",
        192: bytes.fromhex("5A5A01000001000000000000096C6F63616C686F73740000010001"),
    }
    for offset, value in fields.items():
        data[offset : offset + len(value)] = value
    for index in range(1476):
        data[1024 + index] = (index * 3 + 7) & 0xFF
    for index in range(1024):
        data[3072 + index] = (index * 5 + 11) & 0xFF
    return bytes(data)


def runtime_io_data() -> bytes:
    data = bytearray(2048)
    fields = {
        0: b"io-api: start\r\n",
        64: b"io-api: open/read/fstat/getdents/poll passed\r\n",
        160: b"/proc/version\0",
        192: b"/bin\0",
        224: b"/dev/zero\0",
    }
    for offset, value in fields.items():
        data[offset : offset + len(value)] = value
    return bytes(data)


def runtime_vm_data() -> bytes:
    data = bytearray(512)
    fields = {
        0: b"vm-api: start\r\n",
        64: b"vm-api: ABI/mmap/mprotect/munmap/brk passed\r\n",
    }
    for offset, value in fields.items():
        data[offset : offset + len(value)] = value
    return bytes(data)

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="ZigOs repository root",
    )
    parser.add_argument("--nasm", default="nasm", help="NASM executable name or path")
    args = parser.parse_args()

    root = args.repo_root.resolve()
    build = root / "build"
    generated = root / "src" / "generated"
    scripts = root / "scripts"
    user = root / "src" / "user"
    arch = root / "src" / "arch" / "x86_64"

    build.mkdir(parents=True, exist_ok=True)
    generated.mkdir(parents=True, exist_ok=True)

    nasm = require_tool(args.nasm)
    python = sys.executable
    run([python, str(scripts / "generate-abi.py"), "--repo-root", str(root)], root)
    run([python, str(scripts / "generate-abi.py"), "--repo-root", str(root), "--check"], root)

    service_bin = build / "service-user.bin"
    service_elf = build / "service-user.elf"
    process_bin = build / "process-user.bin"
    process_exec_bin = build / "process-exec.bin"
    process_elf = build / "process-user.elf"
    process_exec_elf = build / "process-exec.elf"
    cpu_object = build / "cpu.obj"
    sdk_syscall_object = build / "sdk" / "syscall.o"
    trampoline = generated / "ap_trampoline.bin"
    runtime_program_data = {
        "hello": b"hello from VFS-loaded CPL3 ELF64\r\n",
        "sleep": b"sleep: before\r\n" + bytes(17) + b"sleep: after\r\n",
        "wait-short": b"wait-any short child",
        "crash": b"crash: real page fault follows\r\n",
        "spin": b"runtime spin loop",
        "pipe-reader": b"pipe reader data",
        "pipe-writer": b"PIPE-CPL",
        "wait": runtime_wait_data(),
        "vm": runtime_vm_data(),
        "io": runtime_io_data(),
        "tty": runtime_tty_data(),
        "socket": runtime_socket_data(),
    }
    runtime_outputs: list[Path] = []
    sdk_syscall_object.parent.mkdir(parents=True, exist_ok=True)

    run([nasm, "-w+error", "-f", "bin", str(user / "service.asm"), "-o", str(service_bin)], root)
    run(
        [python, str(scripts / "create-x86-64-user-elf.py"), "--payload", str(service_bin), "--output", str(service_elf)],
        root,
    )
    run([python, str(scripts / "verify-x86-64-user-elf.py"), str(service_elf)], root)

    run([nasm, "-w+error", "-f", "bin", str(user / "process.asm"), "-o", str(process_bin)], root)
    run([nasm, "-w+error", "-f", "bin", str(user / "process-exec.asm"), "-o", str(process_exec_bin)], root)
    run(
        [
            python,
            str(scripts / "create-x86-64-process-elf.py"),
            "--payload",
            str(process_bin),
            "--output",
            str(process_elf),
            "--kind",
            "main",
        ],
        root,
    )
    run(
        [
            python,
            str(scripts / "create-x86-64-process-elf.py"),
            "--payload",
            str(process_exec_bin),
            "--output",
            str(process_exec_elf),
            "--kind",
            "exec",
        ],
        root,
    )
    run([python, str(scripts / "verify-x86-64-process-elf.py"), str(process_elf), "--kind", "main"], root)
    run([python, str(scripts / "verify-x86-64-process-elf.py"), str(process_exec_elf), "--kind", "exec"], root)

    for program_name, data_bytes in runtime_program_data.items():
        code_path = build / f"runtime-{program_name}.bin"
        data_path = build / f"runtime-{program_name}.data"
        elf_path = build / f"runtime-{program_name}.elf"
        data_path.write_bytes(data_bytes)
        run([nasm, "-w+error", "-f", "bin", str(user / f"runtime-{program_name}.asm"), "-o", str(code_path)], root)
        run(
            [
                python,
                str(scripts / "create-runtime-user-elf.py"),
                "--code",
                str(code_path),
                "--data",
                str(data_path),
                "--output",
                str(elf_path),
            ],
            root,
        )
        run([python, str(scripts / "verify-runtime-user-elf.py"), str(elf_path)], root)
        runtime_outputs.append(elf_path)

    run([nasm, "-w+error", "-f", "elf64", str(root / "sdk" / "zig" / "syscall.asm"), "-o", str(sdk_syscall_object)], root)
    run([nasm, "-w+error", "-f", "win64", str(arch / "cpu.asm"), "-o", str(cpu_object)], root)
    run([nasm, "-w+error", "-f", "bin", str(arch / "ap_trampoline.asm"), "-o", str(trampoline)], root)
    if trampoline.stat().st_size != 4096:
        raise SystemExit(f"AP trampoline must be exactly 4096 bytes, got {trampoline.stat().st_size}")

    embedded = {
        generated / "service_user.elf": service_elf,
        generated / "process_user.elf": process_elf,
        generated / "process_exec.elf": process_exec_elf,
    }
    for runtime_elf in runtime_outputs:
        embedded[generated / runtime_elf.name.replace("-", "_")] = runtime_elf
    for destination, source in embedded.items():
        shutil.copyfile(source, destination)

    outputs = [
        service_elf,
        process_elf,
        process_exec_elf,
        *runtime_outputs,
        trampoline,
        *embedded.keys(),
    ]
    manifest = {
        "schema": 2,
        "outputs": {
            str(path.relative_to(root)).replace("\\", "/"): {
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
            for path in outputs
        },
    }
    manifest_path = build / "assets-manifest.json"
    with manifest_path.open("w", encoding="utf-8", newline="\n") as manifest_file:
        manifest_file.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    print(f"Generated {len(outputs)} verified x86-64 build assets")
    print(f"Manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from error
