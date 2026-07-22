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

    service_bin = build / "service-user.bin"
    service_elf = build / "service-user.elf"
    process_bin = build / "process-user.bin"
    process_exec_bin = build / "process-exec.bin"
    process_elf = build / "process-user.elf"
    process_exec_elf = build / "process-exec.elf"
    cpu_object = build / "cpu.obj"
    trampoline = generated / "ap_trampoline.bin"

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

    run([nasm, "-w+error", "-f", "win64", str(arch / "cpu.asm"), "-o", str(cpu_object)], root)
    run([nasm, "-w+error", "-f", "bin", str(arch / "ap_trampoline.asm"), "-o", str(trampoline)], root)
    if trampoline.stat().st_size != 4096:
        raise SystemExit(f"AP trampoline must be exactly 4096 bytes, got {trampoline.stat().st_size}")

    embedded = {
        generated / "service_user.elf": service_elf,
        generated / "process_user.elf": process_elf,
        generated / "process_exec.elf": process_exec_elf,
    }
    for destination, source in embedded.items():
        shutil.copyfile(source, destination)

    outputs = [
        service_elf,
        process_elf,
        process_exec_elf,
        cpu_object,
        trampoline,
        *embedded.keys(),
    ]
    manifest = {
        "schema": 1,
        "python": sys.version.split()[0],
        "nasm": nasm,
        "outputs": {
            str(path.relative_to(root)).replace("\\", "/"): {
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
            for path in outputs
        },
    }
    manifest_path = build / "assets-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"Generated {len(outputs)} verified x86-64 build assets")
    print(f"Manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from error
