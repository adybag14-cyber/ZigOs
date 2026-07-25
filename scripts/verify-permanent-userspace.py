#!/usr/bin/env python3
"""Enforce the permanent-userspace source and release contract."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(source: str, needle: str, description: str) -> None:
    if needle not in source:
        raise SystemExit(f"permanent-userspace contract missing: {description}")


def forbid(source: str, needle: str, description: str) -> None:
    if needle in source:
        raise SystemExit(f"permanent-userspace contract violation: {description}")


def main() -> int:
    runtime = text("src/runtime.zig")
    executor = text("src/runtime_user.zig")
    cpu = text("src/arch/x86_64/cpu.asm")
    paging = text("src/paging.zig")
    exceptions = text("src/exceptions.zig")
    syscalls = text("src/user_mode.zig")
    assets = text("scripts/build-assets.py")
    runtime_test = text("scripts/test-runtime.ps1")

    for forbidden, description in (
        ("launchPseudoJob", "timed pseudo-job launcher returned"),
        ("pseudo-job", "pseudo-job wording returned"),
        ("192.0.2.42", "canned DNS answer returned"),
        ("deterministic-QEMU-path", "canned ping path returned"),
        ("contained fault in PID", "fabricated shell crash path returned"),
    ):
        forbid(runtime, forbidden, description)

    require(runtime, "runtime_user.spawn(", "shell launches the retained CPL3 executor")
    require(runtime, "runtime_user.dispatch(", "scheduler dispatches retained CPL3 contexts")
    require(runtime, '"/bin/hello.elf"', "storage-backed hello fixture")
    require(runtime, '"/bin/crash.elf"', "storage-backed crash fixture")
    require(runtime, '"/bin/pipe-reader.elf"', "storage-backed pipe reader")
    require(runtime, '"/bin/pipe-writer.elf"', "storage-backed pipe writer")
    require(runtime, "network-facades-removed yes", "release marker rejects network facades")
    require(runtime, "userspace_report.used_pages == 0", "release gate requires frame reclamation")
    require(runtime, "userspace_report.live_contexts == 0", "release gate requires context cleanup")
    require(runtime, "e1000e.pingIpv4", "shell performs retained ICMP echo transactions")
    require(runtime, "e1000e.openDnsResolver", "shell opens the retained UDP DNS resolver")
    require(runtime, "e1000e.pollDnsResolverA", "shell polls live DNS responses")
    require(runtime, "state.live_ping_passes", "release gate counts validated ping replies")
    require(runtime, "state.live_dns_passes", "release gate counts completed DNS results")
    require(runtime, "e1000e was not initialized for this boot", "offline commands report device absence explicitly")

    require(executor, "paging.activateAddressSpace", "private CR3 activation")
    require(executor, "zigos_enter_user_context", "complete context entry")
    require(executor, "frame.rip -= 2", "blocked syscall retry")
    require(executor, "activeProcesses().fault(context.handle", "exception-derived fault recording")
    require(executor, "copyToUser", "validated userspace copyout")
    require(executor, "std.math.add(u64, address, index)", "overflow-safe user strings")
    require(executor, "reclaimed_pages", "arena reclamation accounting")
    require(executor, "releasePage(physical);", "failed owned mappings release their arena page")
    require(executor, "paging.userAddressSpaceEmpty", "teardown requires an empty private page table")
    require(executor, "std.math.add(u64, current_tick, frame.rdi)", "overflow-safe sleep deadlines")

    require(cpu, "zigos_enter_user_context:", "assembly retained-context entry")
    require(cpu, ".runtime_return_to_kernel:", "timer return to scheduler")
    require(paging, "createUserAddressSpaceFromFrames", "recyclable private page tables")
    require(exceptions, "runtime_user.handleException", "permanent exception routing")
    require(syscalls, "runtime_user.handleSyscall", "permanent syscall routing")

    for name in ("hello", "sleep", "crash", "spin", "pipe-reader", "pipe-writer"):
        require(assets, f'"{name}"', f"generated {name} ELF fixture")
        if not (ROOT / "src" / "user" / f"runtime-{name}.asm").is_file():
            raise SystemExit(f"permanent-userspace contract missing fixture source: {name}")

    for marker in (
        "hello from VFS-loaded CPL3 ELF64",
        "contained genuine CPL3 exception",
        "real CPL3 reader blocked; real CPL3 writer woke it",
        "reply from 10.0.2.2:",
        "localhost A 127.0.0.1",
        "ping: unavailable: e1000e was not initialized for this boot",
        "dns: unavailable: e1000e was not initialized for this boot",
        "ZigOs permanent userspace: arena 256 used 0",
        "ZigOs permanent network: device yes ping 1 dns 1 failures 0 clean yes",
        "ZigOs permanent network: device no ping 0 dns 0 failures 0 clean yes",
        "ZigOs x86-64 Capstone 19 verified:",
    ):
        require(runtime_test, marker, f"canonical COM1 assertion: {marker}")

    for forbidden in ("192.0.2.42", "deterministic-QEMU-path", "reply from 192.0.2.1"):
        if runtime_test.count(forbidden) != 1:
            raise SystemExit(
                f"network facade sentinel must occur exactly once in the forbidden-output list: {forbidden}"
            )

    capstone = text("docs/CAPSTONE-19.0.md") if (ROOT / "docs/CAPSTONE-19.0.md").exists() else ""
    if capstone:
        goals = re.findall(r"^\d+\. ", capstone, flags=re.MULTILINE)
        if len(goals) != 32:
            raise SystemExit(f"Capstone 19 must document exactly 32 goals, found {len(goals)}")

    print("Verified permanent userspace contract: real ELF execution, faults, blocking, cleanup, live networking, and honest offline status")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
