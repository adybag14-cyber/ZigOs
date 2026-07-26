#!/usr/bin/env python3
"""Enforce the permanent-userspace source and release contract."""
from __future__ import annotations

import json
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
    kernel = text("src/kernel.zig")
    executor = text("src/runtime_user.zig")
    cpu = text("src/arch/x86_64/cpu.asm")
    paging = text("src/paging.zig")
    exceptions = text("src/exceptions.zig")
    syscalls = text("src/user_mode.zig")
    assets = text("scripts/build-assets.py")
    runtime_test = text("scripts/test-runtime.ps1")
    runtime_abi = text("src/runtime_abi.zig")
    abi_spec = json.loads(text("abi/zigos-abi.json"))
    abi_generator = text("scripts/generate-abi.py")
    memory_source = text("src/memory.zig")
    process_source = text("src/runtime_process.zig")
    command_source = text("src/runtime_command.zig")
    e1000e_source = text("src/e1000e.zig")
    page_pool_source = text("src/runtime_page_pool.zig")
    vfs_source = text("src/runtime_vfs.zig")
    tty_source = text("src/runtime_tty.zig")
    fd_source = text("src/runtime_fd.zig")
    persist_source = text("src/runtime_persist.zig")
    nvme_source = text("src/nvme.zig")
    gpt_source = text("src/gpt.zig")
    nvme_image_builder = text("scripts/create-nvme-test-image.py")
    qemu_test = text("scripts/test-qemu.ps1")
    persistence_test = text("scripts/test-x86_64-persistence.py")
    normal_boot_test = text("scripts/test-normal-boot.py")
    elf_source = text("src/elf64.zig")
    sdk_source = text("sdk/zig/zigos.zig")
    sdk_startup = text("sdk/zig/syscall.asm")
    sdk_conformance = text("sdk/zig/conformance.zig")
    sdk_shell = text("sdk/zig/shell.zig")
    sdk_abi = text("sdk/zig/abi.zig")
    sdk_verifier = text("scripts/verify-zigos-sdk-elf.py")
    workflow = text(".github/workflows/build.yml")
    build_graph = text("build.zig")
    workflow = text(".github/workflows/build.yml")
    asset_builder = text("scripts/build-assets.py")
    asset_manifest = json.loads(text("build/assets-manifest.json"))

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
    require(runtime, "kill defaults to forced signal 9", "help documents forced default termination")
    require(runtime, "else 9;", "kill defaults to a signal with implemented terminal semantics")
    require(runtime, "state.shell_waiting = true", "shell wait enters a real blocking state")
    require(runtime, "state.processes.wait(state.shell_handle, handle, false)", "shell wait uses process-table blocking wait")
    forbid(runtime, "wait: process is still running", "wait remained a status query")
    require(runtime, "state.config.physical_memory.report()", "runtime shutdown validates the post-bootstrap physical manager")
    require(runtime, "physical_report.clean", "release gate requires physical-page reclamation")
    require(runtime, "ZigOs post-bootstrap physical memory:", "runtime reports physical-memory handoff accounting")
    require(runtime, "ZigOs permanent userspace: page-limit", "runtime distinguishes ownership slots from reserved pages")
    require(runtime, "state.descriptors.setTerminalBackend(&state.tty)", "standard input is backed by the retained terminal")
    require(runtime, "state.tty.setForeground", "foreground process groups own terminal input")
    require(runtime, "serviceForegroundInput", "foreground execution services COM1 while a syscall is blocked")
    require(runtime, "state.processes.setProcessGroup(state.shell_handle, handle, 0)", "top-level jobs receive independent process groups")
    require(runtime, "ZigOs permanent TTY:", "shutdown reports terminal line-discipline accounting")
    require(runtime, "tty_report.bytes_submitted == tty_report.bytes_read", "release gate requires complete terminal input consumption")
    require(fd_source, "terminal.read(processes, process_handle, output)", "fd 0 delegates to the terminal input backend")
    require(fd_source, "terminal.poll(processes, process_handle, requested)", "terminal readiness is visible through poll")
    require(tty_source, "try processes.block(process_handle, .terminal_read", "empty foreground reads block in the process table")
    require(tty_source, "wakeMatching(.terminal_read", "committed lines wake terminal readers")
    require(tty_source, "process.process_group == self.foreground_process_group", "background process groups cannot read the terminal")
    require(tty_source, "0x08, 0x7F", "canonical erase accepts Backspace and DEL")
    require(tty_source, "sendGroupSignal(self.controller_handle, self.foreground_process_group, 2)", "Ctrl-C targets the foreground process group")
    require(nvme_image_builder, "ZIGOS_DATA_PARTITION_GUID", "deterministic GPT image contains a dedicated ZigOs data partition")
    require(nvme_image_builder, "data_partition_first_lba", "data partition geometry is exported to test metadata")
    require(gpt_source, "isZigOsDataPartition", "kernel GPT parser identifies the dedicated persistence partition")
    require(nvme_source, "pub fn writeBlock", "retained NVMe supports data writes")
    require(nvme_source, "pub fn flush", "retained NVMe supports volatile-cache flushes")
    require(nvme_source, "nvm_force_unit_access", "journal commit headers can request force-unit-access")
    require(nvme_source, "pub fn enterRuntimePollingMode", "NVMe interrupts are explicitly handed off to bounded runtime polling")
    require(runtime, "initializePersistentStorage", "permanent runtime mounts the retained data partition")
    require(runtime, "runtime_persist.BlockDevice", "persistence is layered over a generic block interface")
    require(runtime, "state.persistence.sync(&state.vfs)", "sync commits the persistent VFS subtree")
    require(runtime, "state.persistence.check()", "fsck validates the committed journal generation")
    require(runtime, "ZigOs persistent storage:", "shutdown reports persistent generation and device accounting")
    require(runtime, "persistence_clean", "release gate requires a valid committed journal")
    require(persist_source, "const commit_marker", "journal headers carry an explicit commit marker")
    require(persist_source, "const slot: u8 = if (self.active_slot == 0) 1 else 0", "sync alternates between A/B generations")
    require(persist_source, "if (!device.flush())", "payload and header writes are ordered by device flushes")
    require(persist_source, "device.write(slot, self.sector[0..block_size], true)", "the generation header is committed with FUA")
    require(persist_source, "gpt.crc32(self.payload", "journal payloads are checksummed")
    require(persist_source, "if (second_valid.?.generation > first_valid.?.generation)", "mount selects the newest fully valid generation")
    require(persist_source, 'test "mount falls back to the previous valid generation"', "corrupt newest generation recovery test")
    require(persist_source, 'test "relative path validation rejects traversal but permits dotted names"', "restored paths reject component traversal")
    require(persist_source, "path_scratch", "journal path construction cannot alias the traversal queue")
    require(qemu_test, "NVMe ZigOs Data Partition", "hosted boot gate verifies data-partition discovery")
    require(qemu_test, "NVMe retained for permanent runtime", "hosted boot gate verifies the polling handoff")
    require(persistence_test, "Persistent x86-64 NVMe two-boot session passed.", "dedicated persistence gate spans two independent boots")
    require(persistence_test, "header_a.generation != 1", "host gate requires slot A generation one")
    require(persistence_test, "survived-generation-one", "boot two must read data written by boot one")
    require(persistence_test, "parse_header", "host gate validates on-disk A/B header CRCs")
    require(persistence_test, "after_second_hash == after_first_hash", "host gate requires a second physical disk mutation")
    require(workflow, "test-x86_64-persistence.py", "Windows CI runs the two-boot persistence gate")
    require(workflow, "test-normal-boot.py", "Windows CI runs the normal userspace-shell gate")
    require(build_graph, '"normal-boot"', "build graph exposes an explicit normal-boot profile")
    require(build_graph, 'sdk/zig/shell.zig', "build graph compiles the userspace shell")
    require(build_graph, '"artifacts/sh.elf"', "userspace shell is installed as a standalone artifact")
    require(kernel, "build_options.normal_boot", "kernel branches to the normal profile before software proof workloads")
    require(kernel, "Normal boot selected: skipping kernel heap, scheduler, Capstone 15 and Capstone 16 proof workloads", "normal profile reports skipped diagnostic workloads")
    require(runtime, "pub const Profile = enum", "runtime has explicit diagnostic and normal profiles")
    require(runtime, '"/bin/sh.elf"', "userspace shell ELF is installed in the runtime VFS")
    require(runtime, "finishNormalRuntime", "normal shutdown has a dedicated cleanup invariant")
    require(runtime, "flushUserspaceOutput", "userspace shell and child output stream after every dispatch")
    require(executor, "syscallShutdown", "PID 2 userspace shell has a privileged shutdown syscall")
    require(executor, "syscallGetcwd", "userspace shell can query its process working directory")
    require(executor, "syscallChdir", "userspace shell can change its process working directory")
    require(sdk_source, "pub fn shutdown", "SDK wraps normal-profile shutdown")
    require(sdk_source, "pub fn getcwd", "SDK wraps getcwd")
    require(sdk_source, "pub fn chdir", "SDK wraps chdir")
    require(sdk_shell, "ZigOs userspace shell PID 2", "standalone Zig shell identifies its real PID 2 role")
    require(sdk_shell, "zigos.spawn", "userspace shell launches child ELF programs through the ABI")
    require(sdk_shell, "zigos.wait", "userspace shell waits and reports child status")
    require(normal_boot_test, "process 3 exited 42", "normal QEMU gate proves userspace shell spawn/wait")
    require(normal_boot_test, "alloc/free 52/52 clean yes", "normal QEMU gate requires exact physical reclamation")
    require(normal_boot_test, "forbidden", "normal QEMU gate rejects diagnostic proof markers")
    if abi_spec["abi"]["major"] != 1 or abi_spec["abi"]["minor"] != 3:
        raise SystemExit("permanent-userspace contract missing: ABI version 1.3")
    if abi_spec["syscalls"].get("spawnv") != 96 or abi_spec["syscalls"].get("sync") != 97:
        raise SystemExit("permanent-userspace contract missing: spawnv/sync syscall numbering")
    if abi_spec.get("limits") != {
        "arguments": 8,
        "argument_bytes": 31,
        "environment": 8,
        "environment_bytes": 63,
    }:
        raise SystemExit("permanent-userspace contract missing: bounded spawn-vector limits")
    require(runtime_abi, "pub const UserString = extern struct", "ABI publishes bounded user-string descriptors")
    require(runtime_abi, "pub const SpawnRequest = extern struct", "ABI publishes spawnv request layout")
    require(runtime_abi, "pub const AuxvEntry = extern struct", "ABI publishes auxiliary-vector entries")
    require(runtime_abi, 'test "spawnv request and startup vector layouts are stable"', "spawnv structures have exact layout tests")
    require(executor, "syscallSpawnv", "kernel implements copied and validated spawn vectors")
    require(executor, "fn buildInitialStack", "kernel builds argv, envp and auxiliary vectors")
    require(executor, "const auxiliary = [_]runtime_abi.AuxvEntry", "initial stack carries the bounded auxiliary contract")
    require(sdk_startup, ".scan_environment:", "SDK startup locates envp termination and auxv")
    require(sdk_source, "pub fn spawnv", "SDK exposes argument and environment propagation")
    require(sdk_source, "pub fn environmentValue", "SDK exposes bounded environment lookup")
    require(sdk_source, "pub fn auxiliaryValue", "SDK exposes bounded auxiliary lookup")
    require(sdk_shell, "zigos.spawnv", "userspace shell passes argv and envp to external programs")
    require(sdk_shell, 'environmentValue(startup_environment, "PATH")', "userspace shell searches PATH")
    require(sdk_conformance, "zig-sdk: envp/auxv passed", "SDK conformance validates startup vectors")
    require(normal_boot_test, "persist-sdk alpha beta", "normal QEMU gate proves persistent PATH lookup, argv and inherited envp")
    require(normal_boot_test, "process 4 exited 86", "normal QEMU gate proves spawnv child status")
    require(executor, "syscallSync", "userspace can commit the persistent VFS through ABI 1.3")
    require(runtime, "syncPersistentStorage", "sync syscall reaches the crash-safe journal backend")
    require(sdk_source, "pub fn sync", "SDK exposes persistence sync")
    require(sdk_shell, "fn commandCp", "userspace shell copies files through descriptors")
    require(sdk_shell, "fn spawnFromPath", "userspace shell searches multiple PATH directories")
    require(normal_boot_test, "cp /bin/sdk.elf /persist/persist-sdk.elf", "normal profile installs an ELF into the persistent mount")
    require(normal_boot_test, "persistent storage synchronized", "normal profile commits the installed ELF")
    require(persistence_test, "exec /persist/persist-sdk.elf alpha beta", "boot two executes the restored persistent ELF")
    require(persistence_test, "record_count != 3", "two-boot gate requires directory, message and ELF records")
    require(elf_source, 'test "parser accepts a pure BSS writable load segment"', "ELF loader accepts standard pure-BSS RW segments")
    require(sdk_verifier, "memory_size == 0 or memory_size < file_size", "SDK ELF verifier accepts pure-BSS PT_LOAD")
    require(vfs_source, "pub const maximum_file_size: usize = 32 * 1024", "runtime VFS accepts the linked userspace shell")
    require(vfs_source, 'test "VFS accepts the full 32 KiB file boundary"', "32 KiB VFS boundary is isolated-tested")
    require(runtime, '"/bin/sdk.elf"', "directly linked Zig SDK conformance executable is installed in the VFS")
    require(build_graph, 'sdk/zig/conformance.zig', "build graph compiles the SDK conformance program as Zig source")
    require(build_graph, '.code_model = .large', "SDK supports the high permanent userspace address window")
    require(build_graph, 'verify-zigos-sdk-elf.py', "directly linked SDK ELF has an independent host verifier")
    require(asset_builder, 'sdk_syscall_object', "asset graph assembles the freestanding syscall/startup bridge")
    require(abi_generator, 'sdk" / "zig" / "abi.zig"', "machine-readable ABI generator emits the public Zig SDK ABI")
    require(sdk_startup, "mov rdi, [r12]", "SDK startup reads argc from the canonical initial stack")
    require(sdk_startup, "lea rsi, [r12 + 8]", "SDK startup derives argv from the canonical initial stack")
    require(sdk_startup, "zigos_syscall6:", "SDK supplies the six-register int 0x80 bridge")
    require(sdk_source, "pub fn queryAbi", "SDK exposes typed ABI discovery")
    require(sdk_source, "pub fn mmap", "SDK exposes typed virtual-memory wrappers")
    require(sdk_source, "pub fn socket", "SDK exposes typed UDP socket wrappers")
    require(sdk_conformance, "startup/argv/abi/files/vm/errno passed", "Zig conformance binary spans startup and core wrappers")
    require(sdk_abi, "pub const AbiInfo = extern struct", "generated SDK ABI publishes stable structure layouts")
    require(sdk_verifier, "physical not in (0, virtual)", "SDK ELF verifier accepts only zero or conventional p_paddr")
    require(elf_source, "section_header_offset", "production loader validates optional standard section tables")
    require(elf_source, "physical_address != virtual_address", "production loader accepts conventional p_paddr only")
    require(elf_source, 'test "parser accepts conventional physical addresses and a bounded section table"', "ELF compatibility regression test")
    require(command_source, "stable argument slices preserve distinct extra arguments", "multi-argument launch regression is tested")

    require(executor, "paging.activateAddressSpace", "private CR3 activation")
    require(executor, "zigos_enter_user_context", "complete context entry")
    require(executor, "frame.rip -= 2", "blocked syscall retry")
    require(executor, "activeProcesses().fault(context.handle", "exception-derived fault recording")
    require(executor, "copyToUser", "validated userspace copyout")
    require(executor, "std.math.add(u64, address, index)", "overflow-safe user strings")
    require(executor, "allocator_report.frees", "owned page-pool reclamation accounting")
    require(executor, "releasePage(physical, context.handle);", "failed owned mappings release their owned page")
    require(executor, "paging.userAddressSpaceEmpty", "teardown requires an empty private page table")
    require(executor, "syscall.syscall_abi_query", "versioned ABI discovery syscall")
    require(executor, "syscall.syscall_mmap", "anonymous process mappings")
    require(executor, "syscall.syscall_munmap", "process mapping release")
    require(executor, "syscall.syscall_mprotect", "process mapping protection transitions")
    require(executor, "syscall.syscall_brk", "process heap-break management")
    require(executor, "syscall.syscall_fstat", "descriptor metadata syscall")
    require(executor, "syscall.syscall_getdents", "descriptor directory iteration syscall")
    require(executor, "syscall.syscall_poll", "descriptor readiness syscall")
    require(executor, "syscall.syscall_socket", "descriptor-backed IPv4 datagram sockets")
    require(executor, "syscall.syscall_bind", "userspace UDP bind")
    require(executor, "syscall.syscall_connect", "userspace UDP connect")
    require(executor, "syscall.syscall_send", "userspace UDP send")
    require(executor, "syscall.syscall_recv", "blocking userspace UDP receive")
    require(executor, "serviceNetwork", "network ingress wakes blocked socket readers")
    require(vfs_source, "setPseudoReader", "pseudo files use a VFS backend rather than shell path dispatch")
    require(executor, "std.math.add(u64, current_tick, frame.rdi)", "overflow-safe sleep deadlines")
    require(executor, "runtime_abi.descriptor(frame.rdi)", "descriptor registers are range-checked before narrowing")
    require(executor, "runtime_abi.openFlagBits(frame.rsi)", "open flags are validated before narrowing")
    forbid(executor, "const fd: u16 = @truncate(frame.rdi)", "descriptor arguments truncate before validation")
    forbid(executor, "const bits: u8 = @truncate(frame.rsi)", "open flags truncate before validation")
    forbid(vfs_source, "const node = self.nodes[", "full 16 KiB VFS nodes are copied onto the retained kernel stack")
    forbid(vfs_source, "for (self.nodes", "VFS node arrays are iterated by value on the retained kernel stack")
    forbid(vfs_source, "for (self.nodes[", "VFS node slices are iterated by value on the retained kernel stack")
    forbid(executor, "for (contexts) |context|", "full retained userspace contexts are copied onto the kernel stack")
    forbid(executor, "for (contexts,", "retained context lookup copies multi-kilobyte contexts onto the kernel stack")
    forbid(executor, "context: Context", "syscall helpers copy the full retained context onto the kernel stack")
    forbid(executor, "context.*", "syscall paths pass retained contexts by value")
    forbid(executor, "const context = contexts[service_cursor]", "scheduler copies a retained context onto the kernel stack")
    require(vfs_source, "const node = &self.nodes[node_index]", "VFS node access stays pointer-based")
    require(vfs_source, "pub fn readOnlyView", "executable loading uses a bounded read-only VFS view")
    require(runtime, "state.vfs.readOnlyView", "shell executable loading avoids a 16 KiB staging copy")
    require(executor, "activeVfs().readOnlyView", "userspace spawn avoids a 16 KiB staging copy")
    require(runtime, "state.foreground_handle", "foreground execution has one explicit scheduler owner")
    require(executor, "excluded_handle", "retained scheduler excludes the shell-owned foreground context")
    require(executor, "childForWait(context.handle, target_pid)", "userspace wait queries children without materializing a process snapshot")
    forbid(executor, "activeProcesses().snapshot()", "userspace wait copies the full process table onto the syscall stack")
    require(process_source, "pub fn processAt", "process inspection uses bounded slot views")
    require(runtime, "state.processes.processAt", "the shell process listing avoids a full process-table return value")
    forbid(runtime, "state.processes.snapshot()", "the shell process listing copies the full process table onto a kernel or IST stack")
    forbid(process_source, "pub const Snapshot = struct", "process-table snapshots can materialize tens of kilobytes on an interrupt stack")
    require(executor, "initializeManager(physical_memory, page_limit, memory.four_gib, true)", "permanent userspace allocates pages on demand from physical memory")
    forbid(executor, "allocateContiguousBelow(arena_pages", "permanent userspace reserves a fixed physical slab")

    forbid(process_source, "for (self.processes", "process-table scans copy the complete process array onto the syscall IST")
    require(process_source, "const process = &self.processes[slot]", "process-table scans use indexed pointer access")

    for function_name in ("waitForTx", "waitForRx"):
        match = re.search(rf"fn {function_name}\(.*?\n\}}", e1000e_source, flags=re.DOTALL)
        if match is None:
            raise SystemExit(f"permanent-userspace contract missing: e1000e {function_name}")
        body = match.group(0)
        require(
            body,
            "!runtime_completion_polling_enabled and apic.currentId() == target_apic_id",
            f"{function_name} enables interrupts only during boot-time MSI-X validation",
        )
        require(body, "if (interrupt_assisted) zigos_enable_interrupts();", f"{function_name} guards interrupt enablement")
        require(body, "if (interrupt_assisted) zigos_disable_interrupts();", f"{function_name} restores boot-time interrupt state")
        forbid(body, "const local_target", f"{function_name} reintroduced unconditional local-APIC interrupt enablement")

    require(memory_source, "pub const PhysicalMemoryManager", "post-bootstrap reclaiming physical-memory manager")
    require(memory_source, "initializeFromBootstrap", "explicit bootstrap-to-permanent allocator handoff")
    require(memory_source, "current_region_full_end", "low-address allocation preserves deferred high-memory pages")
    require(memory_source, "bootstrap.sealed = true", "monotonic bootstrap allocator is sealed after handoff")
    require(memory_source, "pub fn allocateBelow", "physical allocations support explicit address limits")
    require(memory_source, "PhysicalMemoryError.DoubleFree", "physical manager detects double frees")
    require(memory_source, 'test "physical manager handoff preserves low and high remaining regions"', "handoff retains untouched high-memory extents")
    require(memory_source, 'test "physical manager merges fragmented releases"', "physical free extents are coalesced")
    require(page_pool_source, "manager.free(address)", "final page-owner release returns the page to physical memory")
    require(page_pool_source, "poison_on_free", "released permanent-runtime pages are poisoned before physical reuse")
    require(page_pool_source, 'test "manager-backed pages return to post-bootstrap physical memory"', "manager-backed page ownership integration test")

    require(runtime_abi, 'pub const constants = @import("generated/runtime_abi_constants.zig")', "kernel ABI consumes generated constants")
    require(runtime_abi, "pub const AbiInfo = extern struct", "versioned machine-readable ABI information")
    require(runtime_abi, "pub fn fromError", "stable kernel-error to userspace-errno mapping")
    require(runtime_abi, "descriptor arguments reject narrowing aliases", "hostile descriptor-width tests")
    require(runtime_abi, "open protection and map flags reject unknown or contradictory bits", "hostile ABI flag tests")
    require(abi_generator, 'newline="\\n"', "ABI generator emits deterministic LF files")
    require(assets, '"generate-abi.py"', "asset generation refreshes ABI constants before assembly")
    if abi_spec.get("abi", {}).get("major") != 1 or abi_spec.get("abi", {}).get("page_size") != 4096:
        raise SystemExit("versioned ABI specification does not declare the required major version/page size")
    syscall_values = list(abi_spec.get("syscalls", {}).values())
    if not syscall_values or len(syscall_values) != len(set(syscall_values)):
        raise SystemExit("versioned ABI syscall numbers are empty or duplicated")

    canonical_test_sources = (
        "src/runtime_fd.zig",
        "src/runtime_command.zig",
        "src/runtime_process.zig",
        "src/runtime_tty.zig",
        "src/runtime_vfs.zig",
        "src/runtime_abi.zig",
        "src/runtime_page_pool.zig",
        "src/memory.zig",
        "src/runtime_persist.zig",
        "src/elf64.zig",
    )
    declared_tests = sum(
        len(re.findall(r'^test "', text(source_path), flags=re.MULTILINE))
        for source_path in canonical_test_sources
    )
    if declared_tests != 59:
        raise SystemExit(f"canonical isolated-test declaration total must be 59, found {declared_tests}")

    for source_path in (
        '"src/runtime_fd.zig"',
        '"src/runtime_command.zig"',
        '"src/runtime_process.zig"',
        '"src/runtime_tty.zig"',
        '"src/runtime_vfs.zig"',
        '"src/runtime_abi.zig"',
        '"src/runtime_page_pool.zig"',
        '"src/runtime_persist.zig"',
        '"src/elf64.zig"',
    ):
        require(build_graph, source_path, f"isolated test graph includes {source_path}")

    require(workflow, ".\\scripts\\test-runtime.ps1 -TimeoutSeconds 180 -Network", "hosted live permanent-shell network test")
    require(workflow, "Cross-platform artifact identity gate", "hosted cross-platform reproducibility gate")
    require(workflow, "cmp --", "artifact bytes are compared instead of only printed")
    require(asset_builder, '"schema": 2', "host-independent generated-asset manifest schema")
    forbid(asset_builder, '"python": sys.version', "host Python version leaked into compared manifest")
    forbid(asset_builder, '"nasm": nasm', "host NASM path leaked into compared manifest")
    require(asset_builder, 'newline="\\n"', "release manifest uses explicit cross-platform LF newlines")
    if asset_manifest.get("schema") != 2:
        raise SystemExit("generated-asset manifest does not use deterministic schema 2")
    manifest_outputs = asset_manifest.get("outputs", {})
    if "build/cpu.obj" in manifest_outputs:
        raise SystemExit("non-deterministic intermediate COFF object leaked into release manifest")
    if not manifest_outputs:
        raise SystemExit("generated-asset release manifest is empty")

    require(cpu, "zigos_enter_user_context:", "assembly retained-context entry")
    require(cpu, "zigos_trace_probe_level1:", "deterministic exception unwind frame chain")
    require(cpu, "zigos_trace_probe_level3:", "deterministic invalid-opcode caller frame")
    require(cpu, ".runtime_return_to_kernel:", "timer return to scheduler")
    require(paging, "createUserAddressSpaceFromFrames", "recyclable private page tables")
    require(paging, "installUserPageTableInSpace", "process address spaces grow beyond one fixed 2 MiB table")
    require(paging, "removeUserPageTableInSpace", "dynamic user page tables are explicitly reclaimed")
    require(paging, "userPageTableAddressInSpace", "dynamic user table lookup validates hierarchy ownership")
    require(exceptions, "runtime_user.handleException", "permanent exception routing")
    require(syscalls, "runtime_user.handleSyscall", "permanent syscall routing")

    for name in ("hello", "sleep", "crash", "spin", "pipe-reader", "pipe-writer", "wait", "vm", "io", "tty", "socket"):
        require(assets, f'"{name}"', f"generated {name} ELF fixture")
        if not (ROOT / "src" / "user" / f"runtime-{name}.asm").is_file():
            raise SystemExit(f"permanent-userspace contract missing fixture source: {name}")

    for marker in (
        "hello from VFS-loaded CPL3 ELF64",
        "contained genuine CPL3 exception",
        "real CPL3 reader blocked; real CPL3 writer woke it",
        "PID 8 status 0x7 state zombie",
        "forced termination signal 9 sent to real PID 9 state zombie",
        "reply from 10.0.2.2:",
        "localhost A 127.0.0.1",
        "ping: unavailable: e1000e was not initialized for this boot",
        "dns: unavailable: e1000e was not initialized for this boot",
        "Post-bootstrap physical memory manager active:",
        "bootstrap allocator sealed",
        "ZigOs post-bootstrap physical memory: total ",
        "peak 32 alloc/free 231/231 failed/rejected 0/0 clean yes",
        "peak 32 alloc/free 247/247 failed/rejected 0/0 clean yes",
        "launches/exits/faults 14/12/1",
        "launches/exits/faults 15/13/1",
        "reclaimed 231 allocator alloc/release/retains 231/231/0",
        "reclaimed 247 allocator alloc/release/retains 247/247/0",
        "tty-api: blocking read/poll/line discipline passed",
        "zig-sdk: startup/argv/abi/files/vm/errno passed",
        "exec: PID 16 state zombie status 0x56",
        "ZigOs permanent TTY: foreground group/session 1/1 buffered/edit/eof 0/0/0 lines 1 bytes submitted/read 7/7 blocked/wakeups 1/1 erase/interrupt/overflow 1/0/0 clean yes",
        "sync complete: ramfs mutations ",
        "fsck ramfs/persist: clean",
        "ZigOs persistent storage: mounted yes generation/slot 1/0 records/payload 0/4 mounts/syncs/checks/recoveries 1/1/1/0 payload/header/flush 1/1/2 NVMe read/write/flush ",
        " errors 0/0 clean yes",
        "persistent-storage yes canned-results no explicit-shutdown yes",
        "ZigOs permanent userspace: page-limit 4096 used 0",
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

    print("Verified permanent runtime contract: diagnostic and normal userspace profiles, real Zig SDK/ELF/TTY/network execution, retained NVMe writes, crash-safe A/B persistence, and complete cleanup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
