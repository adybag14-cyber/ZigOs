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
    diskless_normal_boot_test = text("scripts/test-diskless-normal-boot.py")
    c_header = text("sdk/c/include/zigos.h")
    c_library = text("sdk/c/zigos.c")
    c_conformance = text("sdk/c/conformance.c")
    elf_source = text("src/elf64.zig")
    sdk_source = text("sdk/zig/zigos.zig")
    sdk_startup = text("sdk/zig/syscall.asm")
    sdk_conformance = text("sdk/zig/conformance.zig")
    socket_conformance = text("src/user/runtime-socket.asm")
    wait_conformance = text("src/user/runtime-wait.asm")
    wait_short_conformance = text("src/user/runtime-wait-short.asm")
    sdk_init = text("sdk/zig/init.zig")
    fs_conformance = text("sdk/zig/fs_conformance.zig")
    dns_source = text("sdk/zig/dns.zig")
    dns_conformance = text("sdk/zig/dns_conformance.zig")
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
    require(executor, "try dispatch(handle, tick)", "one retained scheduler dispatches selected CPL3 contexts")
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
    require(workflow, "test-diskless-normal-boot.py", "Windows CI runs the diskless RAM-root recovery gate")
    require(build_graph, '"normal-boot"', "build graph exposes an explicit normal-boot profile")
    require(build_graph, 'sdk/zig/init.zig', "build graph compiles the userspace init")
    require(build_graph, '"artifacts/init.elf"', "userspace init is installed as a standalone artifact")
    require(build_graph, 'sdk/zig/shell.zig', "build graph compiles the userspace shell")
    require(build_graph, '"artifacts/sh.elf"', "userspace shell is installed as a standalone artifact")
    require(kernel, "build_options.normal_boot", "kernel branches to the normal profile before software proof workloads")
    require(kernel, "Normal boot selected: skipping kernel heap, scheduler, Capstone 15 and Capstone 16 proof workloads", "normal profile reports skipped diagnostic workloads")
    require(runtime, "pub const Profile = enum", "runtime has explicit diagnostic and normal profiles")
    require(runtime, '"/bin/init.elf"', "userspace init ELF is installed in the runtime VFS")
    require(runtime, '"/bin/sh.elf"', "userspace shell ELF is installed in the runtime VFS")
    require(runtime, "runtime_user.attachExisting", "reserved PID 1 receives a real userspace address space")
    require(runtime, "configureNormalChild", "userspace init child creation establishes the foreground shell")
    require(runtime, "state.init_reaped_shell", "normal shutdown requires PID 1 to reap PID 2")
    require(process_source, "configureInitUserspace", "process table promotes the reserved PID 1 record to userspace")
    require(process_source, 'test "reserved PID 1 can become a schedulable userspace init"', "PID 1 promotion has an isolated regression test")
    require(runtime, "finishNormalRuntime", "normal shutdown has a dedicated cleanup invariant")
    require(runtime, "flushUserspaceOutput", "userspace shell and child output stream after every dispatch")
    require(executor, "syscallShutdown", "normal-profile PID 1 and PID 2 use the privileged staged shutdown syscall")
    require(executor, "setChildSpawnCallback", "executor reports init-spawned children to the runtime supervisor")
    require(executor, "attachExisting", "executor can attach an ELF context to the reserved PID 1 handle")
    require(executor, "const blocking_target: ?u64 = if (target_pid == 0) null else target_handle;", "blocking wait-any preserves an unconstrained child target")
    require(executor, "activeProcesses().wait(context.handle, blocking_target, false)", "blocking wait uses the PID-sensitive target")
    forbid(executor, "activeProcesses().wait(context.handle, target_handle, false)", "wait-any collapses to the first live child")
    require(wait_conformance, "Both children are live when wait-any blocks", "CPL3 wait-any regression overlaps long and short children")
    require(wait_conformance, "32 ticks", "CPL3 wait-any regression keeps a wide deterministic completion margin")
    require(wait_conformance, "cmp eax, r13d", "wait-any must return the short child's PID")
    require(wait_conformance, "mov esi, WNOHANG", "fixture proves the long child remains live after wait-any")
    require(wait_conformance, "cmp eax, r12d", "fixture later waits for the long child explicitly")
    require(wait_short_conformance, "mov edi, 1", "short wait child exits after one scheduler tick")
    require(executor, "syscallGetcwd", "userspace shell can query its process working directory")
    require(executor, "syscallChdir", "userspace shell can change its process working directory")
    require(sdk_source, "pub fn shutdown", "SDK wraps normal-profile shutdown")
    require(sdk_source, "pub fn getcwd", "SDK wraps getcwd")
    require(sdk_source, "pub fn chdir", "SDK wraps chdir")
    require(sdk_source, "pub fn ioctl", "Zig SDK wraps ioctl")
    require(sdk_source, "pub fn stat", "Zig SDK wraps path stat")
    require(sdk_source, "pub fn openat", "Zig SDK wraps openat")
    require(sdk_source, "pub fn fsync", "Zig SDK wraps descriptor fsync")
    require(sdk_init, "ZigOs userspace init PID 1", "standalone Zig init identifies its real PID 1 role")
    require(sdk_init, "zigos.spawnv", "userspace init launches the shell through the public ABI")
    require(sdk_init, "zigos.wait", "userspace init waits for and reaps the shell")
    require(sdk_init, "zigos.shutdown", "userspace init requests final system shutdown")
    require(sdk_shell, "ZigOs userspace shell PID 2", "standalone Zig shell identifies its real PID 2 role")
    require(sdk_shell, "zigos.spawn", "userspace shell launches child ELF programs through the ABI")
    require(sdk_shell, "zigos.wait", "userspace shell waits and reports child status")
    require(normal_boot_test, "ZigOs userspace init PID 1", "normal QEMU gate requires a real CPL3 PID 1")
    require(normal_boot_test, "userspace init reaped shell PID 2 status 0", "normal QEMU gate requires PID 1 supervision and reap")
    require(normal_boot_test, "process 3 exited 42", "normal QEMU gate proves userspace shell spawn/wait")
    require(normal_boot_test, "alloc/free 99/99 storage persistent clean yes", "normal QEMU gate requires exact physical reclamation and persistent mode")
    require(normal_boot_test, "forbidden", "normal QEMU gate rejects diagnostic proof markers")
    require(kernel, "continuing normal boot with embedded assets and RAM-backed root", "normal boot no longer hard-fails without permanent storage")
    require(runtime, "diskless-ram-root", "normal shutdown distinguishes the diskless recovery profile")
    require(diskless_normal_boot_test, "usb-storage", "diskless gate boots the EFI image from unsupported USB storage")
    require(diskless_normal_boot_test, "sync: unsupported", "diskless userspace reports persistence unavailability explicitly")
    require(diskless_normal_boot_test, "storage diskless-ram-root cleanup yes", "diskless QEMU gate requires clean resource reclamation")
    require(runtime, "ZigOs shutdown drain:", "diagnostic shutdown drains and reaps delayed terminal userspace")
    if abi_spec["abi"]["major"] != 1 or abi_spec["abi"]["minor"] != 8:
        raise SystemExit("permanent-userspace contract missing: ABI version 1.8")
    expected_fs_syscalls = {"lseek": 98, "mkdir": 99, "unlink": 100, "rmdir": 101, "rename": 102, "chmod": 103}
    expected_network_syscalls = {"sendto": 104, "recvfrom": 105, "getpeername": 106, "setnonblock": 107}
    expected_platform_syscalls = {"ioctl": 108, "stat": 109, "openat": 110, "fsync": 111, "symlink": 112, "readlink": 113, "link": 114}
    syscall_spec = abi_spec["syscalls"]
    core_numbering_valid = syscall_spec.get("spawnv") == 96 and syscall_spec.get("sync") == 97
    fs_numbering_valid = all(syscall_spec.get(name) == number for name, number in expected_fs_syscalls.items())
    network_numbering_valid = all(syscall_spec.get(name) == number for name, number in expected_network_syscalls.items())
    platform_numbering_valid = all(syscall_spec.get(name) == number for name, number in expected_platform_syscalls.items())
    if not core_numbering_valid or not fs_numbering_valid or not network_numbering_valid or not platform_numbering_valid:
        raise SystemExit("permanent-userspace contract missing: ABI 1.8 syscall numbering")
    if abi_spec.get("message_flags") != {"dontwait": 1}:
        raise SystemExit("permanent-userspace contract missing: bounded MSG_DONTWAIT value")
    if abi_spec.get("seek_whence") != {"start": 0, "current": 1, "end": 2}:
        raise SystemExit("permanent-userspace contract missing: seek-whence values")
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
    require(executor, "syscallSync", "userspace can commit the persistent VFS through the versioned ABI")
    require(runtime, "syncPersistentStorage", "sync syscall reaches the crash-safe journal backend")
    require(sdk_source, "pub fn sync", "SDK exposes persistence sync")
    require(sdk_shell, "fn commandCp", "userspace shell copies files through descriptors")
    require(sdk_shell, "fn spawnFromPath", "userspace shell searches multiple PATH directories")
    require(normal_boot_test, "cp /bin/sdk.elf /persist/persist-sdk.elf", "normal profile installs an ELF into the persistent mount")
    require(normal_boot_test, "persistent storage synchronized", "normal profile commits the installed ELF")
    require(persistence_test, "exec /persist/persist-sdk.elf alpha beta", "boot two executes the restored persistent ELF")
    require(persistence_test, "header_a.record_count != 7 or header_b.record_count != 3", "two-boot gate requires file, directory, symbolic-link and hard-link records then userspace cleanup")
    require(executor, "syscallLseek", "ABI exposes descriptor seek without offset truncation")
    require(executor, "syscallMkdir", "ABI exposes userspace directory creation")
    require(executor, "syscallSinglePathMutation", "ABI exposes unlink and rmdir through one checked path")
    require(executor, "syscallRename", "ABI copies both rename paths before mutation")
    require(executor, "syscallChmod", "ABI exposes permission-bit mutation")
    for wrapper in ("pub fn lseek", "pub fn mkdir", "pub fn unlink", "pub fn rmdir", "pub fn rename", "pub fn chmod"):
        require(sdk_source, wrapper, f"SDK exposes {wrapper[7:]}")
    require(build_graph, "sdk/zig/fs_conformance.zig", "build graph compiles the independent filesystem ABI fixture")
    require(build_graph, "sdk/zig/dns_conformance.zig", "build graph compiles the userspace resolver fixture")
    require(build_graph, '"artifacts/dns.elf"', "userspace resolver is installed as a standalone artifact")
    require(runtime, '"/bin/dns.elf"', "userspace resolver fixture is installed into the runtime VFS")
    require(dns_source, "pub fn resolveA", "SDK exposes a bounded userspace DNS A resolver")
    require(dns_source, "try zigos.sendto", "userspace resolver transmits through the current generated datagram ABI")
    require(dns_source, "zigos.recvfrom", "userspace resolver receives through the current generated datagram ABI")
    require(dns_source, "error.WouldBlock", "userspace resolver retries nonblocking receive until a tick deadline")
    require(dns_source, "fn skipName", "userspace resolver validates compressed DNS names")
    require(dns_conformance, 'dns.resolveA(server, "localhost", 200)', "live Zig fixture resolves localhost through the SDK")
    require(runtime_test, "exec /bin/dns.elf", "required live COM1 session executes the userspace resolver")
    require(runtime_test, "dns-sdk: userspace resolver localhost -> 127.0.0.1 passed", "required live COM1 session verifies the resolver result")
    require(runtime, '"/bin/fs.elf"', "filesystem ABI fixture is installed into the runtime VFS")
    require(fs_conformance, "init/mkdir/write/seek/replace-rename/chmod/link/nlink/symlink/readlink/open-unlink/rmdir/sync passed", "fixture exercises replacement rename and deferred open-file unlink")
    require(vfs_source, "const Dentry = struct", "VFS separates directory-entry names from node identity")
    require(vfs_source, "dentries: [maximum_dentries]Dentry", "VFS owns a bounded dentry namespace table")
    require(vfs_source, "const DentryCacheEntry = struct", "VFS separates cached lookup entries from authoritative dentries")
    require(vfs_source, "references: u16 = 0", "dentry cache entries retain explicit reference counts")
    require(vfs_source, "dentry_cache: [maximum_dentry_cache_entries]DentryCacheEntry", "VFS owns a bounded dentry lookup cache")
    require(vfs_source, "fn acquireDentry", "path traversal pins cache entries during use")
    require(vfs_source, "fn releaseDentryReference", "path traversal releases cache references on every exit path")
    require(vfs_source, "fn invalidateCachedDentry", "namespace mutation invalidates matching cached dentries")
    require(vfs_source, "fn cacheInsertionSlot", "cache insertion selects an unreferenced LRU slot")
    require(vfs_source, "if (cache_entry.references != 0) continue", "referenced cache entries cannot be evicted")
    require(vfs_source, "return .{ .dentry = dentry_index }", "cache exhaustion falls back to authoritative lookup")
    require(vfs_source, 'test "VFS dentry cache references protect pinned entries and invalidate mutations"', "isolated test proves reference pinning, LRU eviction and mutation invalidation")
    require(vfs_source, "link_count: u16 = 0", "VFS nodes retain explicit namespace link counts")
    require(vfs_source, "fn entryForPath", "namespace mutations resolve final dentries independently of node lookup")
    require(vfs_source, "fn detachOrReclaimEntry", "unlink and replacement rename release one dentry before inode reclamation")
    require(vfs_source, "fn maybeReclaimUnlinked", "last open handle reclaims zero-link nodes")
    require(vfs_source, "pub fn link", "VFS creates same-mount hard-link dentries")
    require(vfs_source, "const node_index = try self.resolveNoFollow(cwd, old_path);", "hard-link creation does not follow a final symbolic-link source")
    require(runtime, "output.decimal(info.link_count)", "diagnostic shell stat exposes namespace link counts")
    require(runtime, "fs_report.dentry_cache_references == 0", "normal and diagnostic release gates require zero live cache references")
    require(runtime, "fs_report.dentry_cache_acquires == fs_report.dentry_cache_releases", "release gates require balanced cache reference accounting")
    require(runtime, "fs_report.dentry_cache_hits > 0", "release gates require real cache hits")
    require(runtime, "cache entries/refs", "diagnostic shutdown reports cache occupancy and references")
    require(runtime, "acquire/release", "diagnostic shutdown reports cache reference accounting")
    require(runtime_test, "cache entries/refs ", "required permanent-runtime sessions expose dentry-cache resource state")
    require(runtime_test, " acquire/release ", "required permanent-runtime sessions expose balanced cache references")
    require(vfs_source, 'test "VFS hard links share node identity data and deferred lifetime"', "hard-link identity, nlink and final-close lifetime are isolated-tested")
    require(vfs_source, "pub const maximum_symlink_depth: usize = 8", "VFS publishes a bounded symbolic-link traversal limit")
    require(vfs_source, "pub fn resolveNoFollow", "VFS exposes final-component no-follow lookup for namespace mutation")
    require(vfs_source, "const entry_index = try self.entryForPath(cwd, path);", "unlink and rmdir mutate the final dentry without following it")
    require(vfs_source, "const source_entry = try self.entryForPath(cwd, old_path);", "rename mutates the source dentry rather than a symbolic-link target")
    require(vfs_source, "const node_index = try self.resolveNoFollow(cwd, path);\n        const target = try self.symlinkTargetNode(node_index);", "readlink reads the final link object without traversal")
    require(vfs_source, "pub fn symlink", "VFS creates symbolic-link nodes")
    require(vfs_source, "pub fn readlink", "VFS reads link target text without following the final node")
    require(vfs_source, 'test "VFS symbolic links follow relative and absolute targets with bounded loops"', "symbolic-link traversal and loop rejection are isolated-tested")
    require(vfs_source, 'test "VFS replacement rename preserves open destination handles"', "replacement rename is isolated-tested with an open old destination")
    require(vfs_source, 'test "VFS unlink detaches names and reclaims after the final open handle"', "deferred unlink is isolated-tested across independent handles")
    require(fd_source, 'test "directory openat and deferred unlink survive descriptor aliases"', "descriptor test combines directory-relative openat with shared-description lifetime")
    require(fd_source, "pub fn statFromVfs", "path stat and descriptor fstat share one descriptor-layer VFS-to-ABI metadata conversion")
    require(fs_conformance, "recovery/mode/seek/hard-link/symlink/cleanup passed", "fixture verifies rebooted data and cleans it through userspace")
    require(normal_boot_test, "mkdir /persist/shell-state", "normal shell exercises userspace mkdir")
    require(normal_boot_test, "write /persist/shell-state/renamed.txt stale-destination", "normal shell creates an existing rename destination")
    require(normal_boot_test, "chmod 600 /persist/shell-state/renamed.txt", "normal shell exercises replacement rename and chmod")
    require(persistence_test, "exec /bin/fs.elf init", "boot one commits mutations from a CPL3 fixture")
    require(persistence_test, "exec /bin/fs.elf verify", "boot two verifies and removes the restored objects in CPL3")
    require(persist_source, "symlink = 3", "persistent record model retains symbolic-link identity")
    require(persist_source, "hard_link = 4", "persistent record model retains hard-link aliases")
    require(persist_source, "try self.restorePass(vfs, candidate, tick, true)", "persistent restore resolves hard links in a second pass")
    require(persist_source, "vfs.canonicalEntryNode", "persistent serialization writes file data only for a canonical dentry")
    require(fs_conformance, "zigos.symlink", "booted Zig filesystem fixture creates persistent and cyclic symbolic links")
    require(fs_conformance, "zigos.readlink", "booted Zig filesystem fixture reads link text before and after reboot")
    require(fs_conformance, "zigos.link", "booted Zig filesystem fixture creates and reboot-verifies a hard-link alias")
    require(fs_conformance, "link_count != 2", "booted Zig filesystem fixture verifies shared stat link counts")
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
    require(abi_generator, 'sdk" / "c" / "include" / "zigos.h"', "machine-readable ABI generator emits the public C header")
    require(build_graph, "sdk/c/conformance.c", "build graph compiles an independent freestanding C conformance program")
    require(build_graph, '"artifacts/c-sdk.elf"', "C SDK conformance is installed as a standalone artifact")
    require(runtime, '"/bin/c-sdk.elf"', "C SDK conformance is installed in the runtime VFS")
    require(c_header, "ZIGOS_ABI_MINOR UINT16_C(8)", "generated C header publishes ABI 1.8")
    require(c_header, "ZIGOS_IOCTL_TTY_GET_FLAGS", "generated C header publishes terminal ioctl requests")
    require(c_library, "zigos_openat", "C wrapper library exposes openat")
    require(c_library, "zigos_fsync", "C wrapper library exposes descriptor fsync")
    require(c_library, "zigos_symlink", "C wrapper library exposes symbolic-link creation")
    require(c_library, "zigos_readlink", "C wrapper library exposes link-target reads")
    require(c_library, "zigos_link", "C wrapper library exposes hard-link creation")
    require(c_header, "uint8_t link_count", "generated C stat layout exposes namespace link counts")
    require(c_conformance, "generated header/library/device/ioctl/stat/directory-openat/fsync/symlink/readlink/link/nlink passed", "booted C fixture covers devices, directory-relative openat, symbolic links and hard-link identity/counts")
    require(c_conformance, "nondirectory != ZIGOS_ERRNO_NOT_DIRECTORY", "C fixture rejects relative openat on a non-directory descriptor")
    require(c_conformance, 'INT64_C(32767), "/etc/hostname"', "absolute openat ignores an otherwise invalid directory descriptor")
    require(sdk_startup, "mov rdi, [r12]", "SDK startup reads argc from the canonical initial stack")
    require(sdk_startup, "lea rsi, [r12 + 8]", "SDK startup derives argv from the canonical initial stack")
    require(sdk_startup, "zigos_syscall6:", "SDK supplies the six-register int 0x80 bridge")
    require(sdk_source, "pub fn queryAbi", "SDK exposes typed ABI discovery")
    require(sdk_source, "pub fn mmap", "SDK exposes typed virtual-memory wrappers")
    require(sdk_source, "pub fn socket", "SDK exposes typed UDP socket wrappers")
    require(runtime_abi, "pub fn messageFlagBits", "ABI rejects unknown full-width message flags before narrowing")
    require(executor, "fn syscallSendTo", "kernel exposes unconnected UDP datagram transmission")
    require(executor, "fn syscallRecvFrom", "kernel exposes source-address UDP reception")
    require(executor, "fn syscallGetPeerName", "kernel exposes connected UDP peer inspection")
    require(executor, "fn syscallSetNonblocking", "kernel stores explicit per-socket nonblocking mode")
    require(executor, "fn syscallIoctl", "kernel exposes descriptor ioctl")
    require(executor, "fn syscallStat", "kernel exposes path-based stat")
    require(executor, "fn syscallOpenAt", "kernel exposes directory-relative openat")
    require(executor, "fn syscallFsync", "kernel exposes descriptor-targeted persistence sync")
    require(executor, "fn syscallSymlink", "kernel exposes symbolic-link creation")
    require(executor, "fn syscallReadlink", "kernel exposes non-following link-target reads")
    require(executor, "fn syscallLink", "kernel exposes same-mount hard-link creation")
    require(sdk_source, "pub fn symlink", "Zig SDK wraps symbolic-link creation")
    require(sdk_source, "pub fn readlink", "Zig SDK wraps link-target reads")
    require(sdk_source, "pub fn link", "Zig SDK wraps hard-link creation")
    require(sdk_abi, "link_count: u8", "generated Zig stat layout exposes namespace link counts")
    require(executor, "@min(maximum_socket_slots, e1000e.udpEndpointCapacity())", "ABI reports the four usable driver endpoints rather than eight bookkeeping slots")
    require(e1000e_source, "pub fn udpEndpointCapacity", "retained NIC publishes its hardware UDP endpoint capacity")
    require(executor, "slot.nonblocking or (flags & runtime_abi.message_dontwait) != 0", "empty UDP receives return EWOULDBLOCK in both nonblocking modes")
    for wrapper in ("pub fn sendto", "pub fn recvfrom", "pub fn getpeername", "pub fn setNonblocking"):
        require(sdk_source, wrapper, f"SDK exposes UDP ABI 1.6 wrapper {wrapper[7:]}")
    require(socket_conformance, "SYS_SENDTO", "CPL3 socket fixture transmits an unconnected DNS datagram")
    require(socket_conformance, "SYS_RECVFROM", "CPL3 socket fixture receives source metadata")
    require(socket_conformance, "SYS_GETPEERNAME", "CPL3 socket fixture checks its connected peer")
    require(socket_conformance, "SYS_SETNONBLOCK", "CPL3 socket fixture checks socket-level nonblocking mode")
    require(socket_conformance, "ZIGOS_MSG_DONTWAIT", "CPL3 socket fixture checks per-call nonblocking mode")
    require(runtime_test, "socket-api: sendto/recvfrom/getpeername/nonblocking passed", "required live QEMU session proves ABI 1.6 UDP controls")
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
    require(vfs_source, "pub const PseudoOperations", "pseudo and device nodes publish per-node operation tables")
    require(vfs_source, "pub fn createPseudoWithOperations", "VFS registers independently operated pseudo/device nodes")
    require(vfs_source, "pub fn ioctlOpen", "VFS dispatches device ioctl through the node operation table")
    require(runtime, "/dev/null", "runtime registers a writable null device")
    require(runtime, "/dev/zero", "runtime registers a writable zero device")
    require(runtime, "/dev/console", "runtime registers an openable console stream")
    forbid(vfs_source, "setPseudoReader", "a global pseudo-reader shortcut returned")
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
    forbid(runtime, "runtime_user.dispatch(", "kernel shell bypasses the retained userspace scheduler")
    forbid(runtime, "foreground_handle", "foreground ownership is duplicated outside the TTY and process table")
    forbid(runtime, "state.jobs", "background jobs are duplicated outside the process table")
    forbid(runtime, "const Job = struct", "a second bounded job table returned")
    forbid(executor, "excluded_handle", "the scheduler can hide a shell-selected userspace context")
    require(runtime, "fn serviceUserspace(tick: u64)", "one runtime service path owns every CPL3 dispatch")
    require(runtime, "runtime_user.serviceOne(tick)", "the runtime delegates every CPL3 selection to the retained scheduler")
    require(runtime, "state.processes.wait(state.shell_handle, handle, false)", "foreground execution blocks the shell through process wait")
    require(runtime, "writeProcessCommand(process, output)", "job reporting is derived from process records")
    require(process_source, "pub fn scheduleNextKind(self: *Table, kind: Kind, current_handle: ?u64)", "kind scheduling has no exclusion side channel")
    require(executor, "childForWait(context.handle, target_pid)", "userspace wait queries children without materializing a process snapshot")
    require(process_source, "terminal_sequence", "wait-any records terminal completion order independently of process-table slots")
    require(process_source, "earliest_sequence", "wait-any selects the earliest completed terminal child")
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
    require(runtime_abi, "open protection map and message flags reject unknown or contradictory bits", "hostile ABI flag tests")
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
        "sdk/zig/dns.zig",
    )
    declared_tests = sum(
        len(re.findall(r'^test "', text(source_path), flags=re.MULTILINE))
        for source_path in canonical_test_sources
    )
    if declared_tests != 73:
        raise SystemExit(f"canonical isolated-test declaration total must be 73, found {declared_tests}")

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
        '"sdk/zig/dns.zig"',
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
        "peak 48 alloc/free 247/247 failed/rejected 0/0 clean yes",
        "peak 48 alloc/free 278/278 failed/rejected 0/0 clean yes",
        "launches/exits/faults 15/13/1",
        "launches/exits/faults 17/15/1",
        "reclaimed 247 stale-contexts-swept 0 allocator alloc/release/retains 247/247/0",
        "reclaimed 278 stale-contexts-swept 0 allocator alloc/release/retains 278/278/0",
        "tty-api: blocking read/poll/line discipline passed",
        "zig-sdk: startup/argv/abi/files/vm/errno passed",
        "c-sdk: ABI 1.8 discovery passed",
        "c-sdk: generated header/library/device/ioctl/stat/directory-openat/fsync/symlink/readlink/link/nlink passed",
        "ZigOs shutdown drain:",
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

    print("Verified permanent runtime contract: ABI 1.8 Zig/C SDKs, per-node devices, diagnostic/persistent/diskless normal profiles, retained networking and storage, and complete cleanup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
